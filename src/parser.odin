package main

import "core:fmt"
import "core:strings"

import "basic/mem"
import "term"

Token :: struct
{
  data:        string,
  type:        Token_Type,
  opcode_type: Opcode_Kind,
  register_id: Register_ID,
  line:        int,
  column:      int,
}

Token_Type :: enum
{
  NIL,
  OPCODE,
  REGISTER,
  LABEL,
  DIRECTIVE,
  NUMBER,
  CHARACTER,
  STRING,
  COLON,
  EQUALS,
}

Line :: struct
{
  tokens:         []Token,
  line_idx:       int,
  has_breakpoint: bool,
}

opcode_table: map[string]Opcode_Kind = make_opcode_table()

tokenize_source_code :: proc(src_data: []byte)
{
  scratch := mem.scope_scratch()

  line_start, line_end: int
  for line_idx := 0; line_end < len(src_data); line_idx += 1
  {
    line_end = next_line_from_bytes(src_data, line_start)
    if line_start == line_end
    {
      line_start = line_end + 1
      end_of_file := line_end == len(src_data) - 1

      if end_of_file do break
      else           do continue
    }

    // - Skip lines containing only whitespace ---
    {
      is_whitespace := true
      line_bytes := src_data[line_start:line_end]
      for b in line_bytes
      {
        if b != ' ' && b != '\n' && b != '\r' && b != '\t'
        {
          is_whitespace = false
          break
        }
      }

      if is_whitespace
      {
        line_start = line_end + 1
        continue
      }
    }

    sim.lines[line_idx].tokens = make([]Token, MAX_TOKENS_PER_LINE, mem.a(&sim.perm_arena))
    
    // - Tokenize line ---
    {
      line_bytes := src_data[line_start:line_end]
      line := sim.lines[line_idx]
      token_cnt: int

      Tokenizer :: struct { pos, end: int }
      tokenizer: Tokenizer
      tokenizer.end = len(line_bytes)

      // Ignore commented portion
      for i in 0..<tokenizer.end-1
      {
        if line_bytes[i] == '/' && line_bytes[i+1] == '/'
        {
          tokenizer.end = i
          break
        }
      }

      get_next_token_string :: proc(tokenizer: ^Tokenizer, buf: []byte) -> string
      {
        start, end, offset: int
        whitespace: bool
      
        i: int
        for i = tokenizer.pos; i < tokenizer.end; i += 1
        {
          b := buf[i]

          if i == tokenizer.pos && b == ' '
          {
            whitespace = true
          }

          if whitespace
          {
            if b == ' '
            {
              start += 1
            }
            else
            {
              whitespace = false
            }
          }
          else if b == ':' || b == '=' || b == ','  || b == ' ' || b == '[' || b == ']'
          {
            offset = cast(int) (i == tokenizer.pos)
            break
          }
        }

        start += tokenizer.pos
        end = i + offset
        tokenizer.pos = end

        return cast(string) buf[start:end]
      }

      tokenizer_loop: for tokenizer.pos < tokenizer.end
      {
        tok_str := get_next_token_string(&tokenizer, line_bytes)
        if tok_str == "" || tok_str == "," || tok_str == "[" || tok_str == "]"
        {
          continue tokenizer_loop
        }

        // - Tokenize opcode ---
        { 
          tok_str_lower := strings.to_lower(tok_str, mem.a(scratch.arena))
          op_type := opcode_table[tok_str_lower]
          if op_type != .NIL
          {
            line.tokens[token_cnt] = Token{
              data=tok_str, 
              type=.OPCODE,
            }

            line.tokens[token_cnt].opcode_type = op_type
            token_cnt += 1
            continue tokenizer_loop
          }
        }

        // - Tokenize number ---
        if str_is_bin(tok_str) || str_is_dec(tok_str) || str_is_hex(tok_str)
        {
          line.tokens[token_cnt] = Token{
            data=tok_str, 
            type=.NUMBER,
          }

          token_cnt += 1
          continue tokenizer_loop
        }

        // - Tokenize character -
        if tok_str[0] == '\''
        {
          chr := tok_str[1:len(tok_str)-1]
          line.tokens[token_cnt] = Token{
            data=chr, 
            type=.CHARACTER,
          }

          token_cnt += 1
          continue tokenizer_loop
        }

        // - Tokenize string ---
        if tok_str[0] == '\"'
        {
          str := tok_str[1:len(tok_str)-1]
          line.tokens[token_cnt] = Token{
            data=str, 
            type=.STRING,
          }

          token_cnt += 1
          continue tokenizer_loop
        }

        // - Tokenize operator ---
        {
          @(static)
          operators := [?]Token_Type{':' = .COLON, '=' = .EQUALS}
          
          if tok_str == ":" || tok_str == "="
          {
            line.tokens[token_cnt] = Token{
              data=tok_str, 
              type=operators[tok_str[0]],
            }

            token_cnt += 1
            continue tokenizer_loop
          }
        }

        // - Tokenize directive ---
        if tok_str[0] == '.'
        {
          line.tokens[token_cnt] = Token{
            data=tok_str, 
            type=.DIRECTIVE,
          }

          token_cnt += 1
          continue tokenizer_loop
        }

        // - Tokenize register ---
        {
          register_id, ok := register_from_string(tok_str)
          if ok
          {
            line.tokens[token_cnt] = Token{
              data = tok_str, 
              type = .REGISTER, 
              register_id = register_id,
            }
            
            token_cnt += 1
            continue tokenizer_loop
          }
        }

        // - Tokenize label ---
        {
          line.tokens[token_cnt] = Token{
            data=tok_str, 
            type=.LABEL,
          }

          token_cnt += 1
          continue tokenizer_loop
        }
      }
    }

    line_start = line_end + 1
 
    for &token, i in sim.lines[line_idx].tokens
    {
      token.line = line_idx + 1
      token.column = i
    }

    sim.lines[line_idx].line_idx = line_idx
    sim.line_count = line_idx + 1
  }
}

syntax_check_lines :: proc() -> bool
{
  for line_idx := 0; line_idx < sim.line_count; line_idx += 1
  {
    error: Parser_Error
    line := sim.lines[line_idx]

    if line.tokens == nil do continue

    if line.tokens[0].type == .LABEL &&
       line.tokens[1].type == .OPCODE
    {
      error = Syntax_Error{
        type = .MISSING_COLON,
        line = line.tokens[0].line,
      }
    }

    if resolve_parser_error(error, line_idx) do return false
  }

  return true
}

semantics_check_instructions :: proc() -> (ok: bool)
{
  ok = true

  for instruction_idx := 0; instruction_idx < sim.instruction_count; instruction_idx += 1
  {
    instruction := sim.instructions[instruction_idx]
    error: Parser_Error

    // - Fetch opcode and operands ---
    opcode: Token
    operands: [3]Token
    operand_cnt: int
    {
      opcode_pos := opcode_pos_in_instruction(instruction^)
      if opcode_pos == 0
      {
        opcode = instruction.tokens[0]
        operands[0] = instruction.tokens[1]
        operands[1] = instruction.tokens[2]
        operands[2] = instruction.tokens[3]

        for operand, idx in instruction.tokens do if idx > 0
        {
          if operand.type != .NIL
          {
            operand_cnt += 1
          }
        }
      }
      else if opcode_pos == 2
      {
        opcode = instruction.tokens[2]
        operands[0] = instruction.tokens[3]
        operands[1] = instruction.tokens[4]
        operands[2] = instruction.tokens[5]

        for operand, idx in instruction.tokens do if idx > 2
        {
          if operand.type != .NIL
          {
            operand_cnt += 1
          }
        }
      }
    }

    error_check_loop: for error == nil
    {
      switch opcode.opcode_type
      {
      case .NIL:
      case .NOP: fallthrough
      case .RET:
        if operand_cnt != 0
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 0,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }
      case .MV:   fallthrough
      case .SLTZ: fallthrough
      case .SGTZ:
        if operand_cnt != 2
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 2,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break
        }

        if operands[1].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }
      case .LI:  fallthrough
      case .LUI: fallthrough
      case .AUIPC:
        if operand_cnt != 2
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 2,
            actual_operand_cnt = operand_cnt,
          }

          break
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .NUMBER && operands[1].type != .CHARACTER
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }
      case .ADD: fallthrough
      case .SUB: fallthrough
      case .AND: fallthrough
      case .OR:  fallthrough
      case .XOR: fallthrough
      case .SLL: fallthrough
      case .SRL: fallthrough
      case .SRA: fallthrough
      case .SLT: fallthrough
      case .SGT:
        if operand_cnt != 3
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 3,
            actual_operand_cnt = operand_cnt,
          }

          break
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }

        if operands[2].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[2].type,
          }

          break error_check_loop
        }
      case .NOT: fallthrough
      case .NEG:
        if operand_cnt != 1
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 1,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }
      case .ADDI: fallthrough
      case .ANDI: fallthrough
      case .ORI:  fallthrough
      case .XORI: fallthrough
      case .SLLI: fallthrough
      case .SRLI: fallthrough
      case .SRAI: fallthrough
      case .SLTI: fallthrough
      case .SGTI:
        if operand_cnt != 3
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 3,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[1].type,
          }

          break
        }

        if operands[2].type != .NUMBER && operands[1].type != .CHARACTER
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[2].type,
          }

          break error_check_loop
        }
      case .J:  fallthrough
      case .JAL:
        if operand_cnt != 1
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 1,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .LABEL && (operands[0].type != .NUMBER && 
                                          operands[1].type != .CHARACTER)
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

      case .JR: fallthrough
      case .JALR:
        if operand_cnt != 1
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 1,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }
      case .BEQ: fallthrough
      case .BNE: fallthrough
      case .BLT: fallthrough
      case .BGT: fallthrough
      case .BLE: fallthrough
      case .BGE:
        if operand_cnt != 3
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 3,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }

        if operands[2].type != .NUMBER &&
           operands[1].type != .CHARACTER &&
           operands[2].type != .LABEL
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[2].type,
          }

          break error_check_loop
        }
      case .BEQZ: fallthrough
      case .BNEZ: fallthrough
      case .BLTZ: fallthrough
      case .BGTZ: fallthrough
      case .BLEZ: fallthrough
      case .BGEZ:
        if operand_cnt != 2
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 2,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .NUMBER && 
           operands[1].type != .CHARACTER &&
           operands[2].type != .LABEL
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }
      case .LB: fallthrough
      case .LH: fallthrough
      case .LW: fallthrough
      case .SB: fallthrough
      case .SH: fallthrough
      case .SW:
        if operand_cnt != 2 && operand_cnt != 3
        {
          error = Opcode_Error{
            token = opcode,
            type = .INVALID_OPERAND_COUNT,
            expected_operand_cnt = 2,
            actual_operand_cnt = operand_cnt,
          }

          break error_check_loop
        }

        if operands[0].type != .REGISTER
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[0].type,
          }

          break error_check_loop
        }

        if operands[1].type != .REGISTER && operands[1].type != .LABEL
        {
          error = Type_Error{
            expected_type = .REGISTER,
            actual_type = operands[1].type,
          }

          break error_check_loop
        }

        if operands[2].type != .NIL && 
           operands[2].type != .NUMBER && 
           operands[2].type != .CHARACTER && 
           operands[2].type != .LABEL
        {
          error = Type_Error{
            expected_type = .NUMBER,
            actual_type = operands[2].type,
          }

          break error_check_loop
        }
      }

      if error == nil do break error_check_loop
    }

    if resolve_parser_error(error, instruction.line_idx)
    {
      ok = false
    }
  }

  return ok
}

next_line_from_bytes :: proc(buf: []byte, start: int) -> (end: int)
{
  length := len(buf)

  end = start
  for i in start..<length
  {
    if buf[i] == '\n' || buf[i] == '\r'
    {
      end = i
      break
    }
  }

  return end
}

print_tokens :: proc()
{
  for i in 0..<sim.line_count
  {
    for tok in sim.lines[i].tokens
    {
      if tok.type == .NIL do continue
      fmt.print("{", tok.data, "|", tok.type , "}", "")
    }

    fmt.print("\n")
  }

  fmt.print("\n")
}

print_tokens_at :: proc(idx: int)
{
  for tok in sim.lines[idx].tokens do if tok.type != .NIL
  {
    fmt.print("{", tok.data, "|", tok.type, "|", tok.opcode_type, "}", "")
  }
  
  fmt.print("\n")
}

register_from_string :: proc(str: string) -> (result: Register_ID, ok: bool)
{
  ok = true

  switch str
  {
  case "x0", "zero": result = .ZR
  case "x1", "ra":   result = .RA
  case "x2", "sp":   result = .SP
  case "x3", "gp":   result = .GP
  case "x4", "tp":   result = .TP
  case "x5", "t0":   result = .T0
  case "x6", "t1":   result = .T1
  case "x7", "t2":   result = .T2
  case "x8", "fp":   result = .FP
  case "x9", "s1":   result = .S1
  case "x10", "a0":  result = .A0
  case "x11", "a1":  result = .A1
  case "x12", "a2":  result = .A2
  case "x13", "a3":  result = .A3
  case "x14", "a4":  result = .A4
  case "x15", "a5":  result = .A5
  case "x16", "a6":  result = .A6
  case "x17", "a7":  result = .A7
  case "x18", "s2":  result = .S2
  case "x19", "s3":  result = .S3
  case "x20", "s4":  result = .S4
  case "x21", "s5":  result = .S5
  case "x22", "s6":  result = .S6
  case "x23", "s7":  result = .S7
  case "x24", "s8":  result = .S8
  case "x25", "s9":  result = .S9
  case "x26", "s10": result = .S10
  case "x27", "s11": result = .S11
  case "x28", "t3":  result = .T3
  case "x29", "t4":  result = .T4
  case "x30", "t5":  result = .T5
  case "x31", "t6":  result = .T6
  case: ok = false
  }

  return result, ok
}

opcode_pos_in_instruction :: proc(instruction: Line) -> int
{
  result: int = -1

  if instruction.tokens[0].opcode_type != .NIL
  {
    result = 0
  }
  else if instruction.tokens[2].opcode_type != .NIL
  {
    result = 2
  }

  return result
}

operand_from_token :: proc(token: Token) -> (result: Operand, ok: bool)
{
  #partial switch token.type
  {
  case .NUMBER:
    result = cast(Number) str_to_int(token.data)
  case .CHARACTER:
    conv_b, conv_ok := str_to_char(token.data)
    result = cast(Number) conv_b
    ok = conv_ok && ok
  case .REGISTER:
    result = token.register_id
  case .LABEL:
    map_ok: bool
    result, map_ok = sim.symbol_table[token.data]
    ok = map_ok && ok
  }

  return result, ok
}

line_is_instruction :: proc(line: Line) -> bool
{
  return line.tokens != nil && 
         len(line.tokens) != 0 &&
         (line.tokens[0].type == .OPCODE ||
         (line.tokens[0].type == .LABEL && line.tokens[2].type == .OPCODE))
}

// ParserError ///////////////////////////////////////////////////////////////////////////

Parser_Error :: union
{
  Syntax_Error,
  Type_Error,
  Opcode_Error,
}

Syntax_Error :: struct
{
  line:   int,
  column: int,
  token:  Token,
  type:   Syntax_Error_Type,
}

Syntax_Error_Type :: enum
{
  MISSING_IDENTIFIER,
  MISSING_LITERAL,
  MISSING_COLON,
  UNIDENTIFIED_IDENTIFIER,
}

Type_Error :: struct
{
  line:          int,
  column:        int,
  token:         Token,
  expected_type: Token_Type,
  actual_type:   Token_Type,
}

Opcode_Error :: struct
{
  line:                 int,
  column:               int,
  token:                Token,
  type:                 Opcode_Error_Type,
  expected_operand_cnt: int,
  actual_operand_cnt:   int,
}

Opcode_Error_Type :: enum
{
  INVALID_OPERAND_COUNT,
}

resolve_parser_error :: proc(error: Parser_Error, line_idx: int) -> bool
{
  if error == nil do return false

  term.color(.RED)
  fmt.printf("Error on line %i: ", line_idx + 1)

  switch v in error
  {
  case Syntax_Error:
    switch v.type
    {
    case .MISSING_COLON: 
      fmt.printf("Missing colon after label.\n", v.line)
    case .MISSING_IDENTIFIER: 
      fmt.printf("")
    case .MISSING_LITERAL: 
      fmt.printf("")
    case .UNIDENTIFIED_IDENTIFIER: 
      fmt.printf("")
    }
  case Type_Error:
    fmt.printf("Type mismatch. Expected \'%s\', got \'%s\'.\n", 
                v.expected_type, 
                v.actual_type)
  case Opcode_Error:
    switch v.type
    {
    case .INVALID_OPERAND_COUNT:
      fmt.printf("Invalid operand count. \'%s\' expects %i, got %i.\n",
                 v.token.opcode_type,
                 v.expected_operand_cnt,
                 v.actual_operand_cnt)
    }
  }

  term.color(.WHITE)

  return true
}

@(private="file")
make_opcode_table :: proc() -> map[string]Opcode_Kind
{
  table := make(map[string]Opcode_Kind, 52, mem.a(&sim.perm_arena))
  table[""]      = .NIL
  table["nop"]   = .NOP
  table["mv" ]   = .MV
  table["li" ]   = .LI
  table["add"]   = .ADD
  table["addi"]  = .ADDI
  table["sub"]   = .SUB
  table["and"]   = .AND
  table["andi"]  = .ANDI
  table["or" ]   = .OR
  table["ori"]   = .ORI
  table["xor"]   = .XOR
  table["xori"]  = .XORI
  table["not"]   = .NOT
  table["neg"]   = .NEG
  table["sll"]   = .SLL
  table["slli"]  = .SLLI
  table["srl"]   = .SRL
  table["srli"]  = .SRLI
  table["sra"]   = .SRA
  table["srai"]  = .SRAI
  table["slt"]   = .SLT
  table["slti"]  = .SLTI
  table["sltz"]  = .SLTZ
  table["sgt"]   = .SGT
  table["sgti"]  = .SGTI
  table["sgtz"]  = .SGTZ
  table["j"]     = .J
  table["jr"]    = .JR
  table["jal"]   = .JAL
  table["jalr"]  = .JALR
  table["ret"]   = .RET
  table["beq"]   = .BEQ
  table["bne"]   = .BNE
  table["blt"]   = .BLT
  table["bgt"]   = .BGT
  table["ble"]   = .BLE
  table["bge"]   = .BGE
  table["beqz"]  = .BEQZ
  table["bnez"]  = .BNEZ
  table["bltz"]  = .BLTZ
  table["bgtz"]  = .BGTZ
  table["blez"]  = .BLEZ
  table["bgez"]  = .BGEZ
  table["lb"]    = .LB
  table["lh"]    = .LH
  table["lw"]    = .LW
  table["sb"]    = .SB
  table["sh"]    = .SH
  table["sw"]    = .SW
  table["lui"]   = .LUI
  table["auipc"] = .AUIPC

  return table
}
