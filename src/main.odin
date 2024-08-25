package main

MAX_SRC_BUF_BYTES   :: 1024
MAX_LINES           :: 64
MAX_TOKENS_PER_LINE :: 8

BASE_ADDRESS :: 0x10000000
INSTRUCTION_SIZE :: 4

Address :: distinct u64
Number  :: distinct i64

Simulator :: struct
{
  should_quit: bool,
  step_to_next: bool,

  instructions: []Instruction,
  line_count : int,
  symbol_table: map[string]Number,
  data_section_pos: int,
  text_section_pos: int,
  branch_to_idx: int,

  memory: []byte,
  registers: [RegisterID]Number,
  status_flag: struct
  {
    equal: bool,
    greater: bool,
    negative: bool,
  },
}

OpcodeType :: enum
{
  NIL,

  MOV,

  ADD,
  SUB,
  SHL,
  SHR,

  CMP,
  CBZ,
  CBNZ,

  B,
  BEQ,
  BNE,
  BLT,
  BGT,
  BLE,
  BGE,
  BMI,
  BPL,
  BL,
  BR,
  BLR,
}

RegisterID :: enum
{
  NIL,

  R0,
  R1,
  R2,
  R3,
  LR,
}

Operand :: union
{
  Number,
  RegisterID,
}

opcode_table: map[string]OpcodeType = {
  ""     = .NIL,

  "mov"  = .MOV,

  "add"  = .ADD,
  "sub"  = .SUB,
  "shl"  = .SHL,
  "shr"  = .SHR,

  "cmp"  = .CMP,
  "cbz"  = .CBZ,
  "cbnz" = .CBNZ,

  "b"    = .B,
  "beq"  = .BEQ,
  "bne"  = .BNE,
  "blt"  = .BLT,
  "bgt"  = .BGT,
  "ble"  = .BLE,
  "bge"  = .BGE,
  "bmi"  = .BMI,
  "bpl"  = .BPL,
  "bl"   = .BL,
  "br"   = .BR,
  "blr"  = .BLR,
}

sim: Simulator

main :: proc()
{
  // gui_run()

  perm_arena := basic.create_arena(basic.MIB * 8)
  context.allocator = perm_arena.ally
  temp_arena := basic.create_arena(basic.MIB * 8)
  context.temp_allocator = temp_arena.ally

  sim.memory = make([]byte, 1024)
  memory_store_bytes(BASE_ADDRESS, bytes_from_value(510, 4))
  value := value_from_bytes(memory_load_bytes(BASE_ADDRESS, 4))
  fmt.println("Expected:", 510)
  fmt.println("  Actual:", value)

  if true do return

  tui_print_welcome()

  src_file_path := "res/main.asm"
  if len(os.args) > 1
  {
    src_file_path = os.args[1]
  }

  src_file, err := os.open(src_file_path)
  if err != 0
  {
    term.color(.RED)
    fmt.eprintf("Error opening file \"%s\"\n", src_file_path)
    return
  }

  src_buf: [MAX_SRC_BUF_BYTES]byte
  src_size, _ := os.read(src_file, src_buf[:])
  src_data := src_buf[:src_size]
  os.close(src_file)

  sim.instructions = make([]Instruction, MAX_LINES)

  // Tokenize ----------------
  {
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

      // Skip lines containing only whitespace
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

      sim.instructions[line_idx].tokens = make([]Token, MAX_TOKENS_PER_LINE)
      
      // Tokenize line
      {
        line_bytes := src_data[line_start:line_end]
        line := sim.instructions[line_idx]
        token_cnt: int

        Tokenizer :: struct { pos, end: int }
        tokenizer: Tokenizer
        tokenizer.end = len(line_bytes)

        // Ignore commented section
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
            else if b == ':' || b == '=' || b == ',' || b == ' '
            {
              offset = int(i == tokenizer.pos)
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
          buf_str := get_next_token_string(&tokenizer, line_bytes)
          if buf_str == "" || buf_str == "," do continue tokenizer_loop

          // Tokenize opcode
          { 
            buf_str_lower := str_to_lower(buf_str)
            op_type := opcode_table[buf_str_lower]
            if op_type != .NIL
            {
              line.tokens[token_cnt] = Token{data=buf_str, type=.OPCODE}
              line.tokens[token_cnt].opcode_type = op_type
              token_cnt += 1
              continue tokenizer_loop
            }

            free_all(context.temp_allocator)
          }

          // Tokenize number
          if str_is_bin(buf_str) || str_is_dec(buf_str) || str_is_hex(buf_str)
          {
            line.tokens[token_cnt] = Token{data=buf_str, type=.NUMBER}
            token_cnt += 1
            continue tokenizer_loop
          }

          // Tokenize operator
          {
            @(static)
            operators := [?]TokenType{':' = .COLON, '=' = .EQUALS}
            
            if buf_str == ":" || buf_str == "="
            {
              line.tokens[token_cnt] = Token{data=buf_str, type=operators[buf_str[0]]}
              token_cnt += 1
              continue tokenizer_loop
            }
          }

          // Tokenize directive
          if buf_str[0] == '$'
          {
            line.tokens[token_cnt] = Token{data=buf_str, type=.DIRECTIVE}
            token_cnt += 1
            continue tokenizer_loop
          }

          // Tokenize identifier
          {
            line.tokens[token_cnt] = Token{data=buf_str, type=.IDENTIFIER}
            token_cnt += 1
            continue tokenizer_loop
          }
        }
      }

      line_start = line_end + 1
      sim.line_count = line_idx + 1
      
      for &token, i in sim.instructions[sim.line_count].tokens
      {
        token.line = line_idx + 1
        token.column = i
      }
    }
  }

  // print_tokens()

  // Preprocess ----------------
  {
    for line_num := 0; line_num < sim.line_count; line_num += 1
    {
      if sim.instructions[line_num].tokens == nil do continue
      
      instruction := sim.instructions[line_num]

      // Directives
      if instruction.tokens[0].type == .DIRECTIVE
      {
        if len(instruction.tokens) < 2 do continue

        switch instruction.tokens[0].data
        {
          case "$define":
          {
            val := Number(str_to_int(instruction.tokens[2].data))
            sim.symbol_table[instruction.tokens[1].data] = val
          }
          case "$section":
          {
            section := instruction.tokens[1].data
            switch section
            {
              case ".data": sim.data_section_pos = line_num + 1
              case ".text": sim.text_section_pos = line_num + 1
              case: {}
            }
          }
        }
      }

      // Labels
      if instruction.tokens[0].type == .IDENTIFIER && 
         instruction.tokens[1].type == .COLON
      {
        sim.symbol_table[instruction.tokens[0].data] = Number(line_num)
      }
    }
  }

  // Error check ----------------
  {
    // Syntax
    for line_num := 0; line_num < sim.line_count; line_num += 1
    {
      if sim.instructions[line_num].tokens == nil do continue

      error: ParserError
      instruction := sim.instructions[line_num]

      if  instruction.tokens[0].line >= sim.text_section_pos && 
          instruction.tokens[0].type == .IDENTIFIER && 
          instruction.tokens[0].opcode_type == .NIL &&
          instruction.tokens[1].type == .OPCODE
      {
        error = SyntaxError{
          type = .MISSING_COLON,
          line = instruction.tokens[0].line
        }

        break
      }

      if resolve_parser_error(error) do return
    }

    // Semantics
    for line_num := 0; line_num < sim.line_count; line_num += 1
    {
      if sim.instructions[line_num].tokens == nil do continue

      error: ParserError
      instruction := sim.instructions[line_num]

      if line_num >= sim.text_section_pos
      {
        if instruction.tokens[0].opcode_type == .NIL && 
           instruction.tokens[2].opcode_type == .NIL
        {
          error = TypeError{
            line = instruction.tokens[0].line,
            column = instruction.tokens[0].column,
            token = instruction.tokens[0],
            expected_type = .OPCODE,
            actual_type = instruction.tokens[0].type
          }
        }
      }

      if resolve_parser_error(error) do return
    }
  }

  sim.step_to_next = true

  // Execute ----------------
  for line_num := sim.text_section_pos; line_num < sim.line_count;
  {
    if sim.instructions[line_num].tokens == nil
    {
      line_num += 1
      continue
    }

    instruction := sim.instructions[line_num]

    if instruction.has_breakpoint
    {
      sim.step_to_next = true
    }

    // Prompt user command ----------------
    if sim.step_to_next && line_num < sim.line_count
    {
      for done: bool; !done;
      {
        done = tui_prompt_command()
      }
    }

    if sim.should_quit do return

    sim.branch_to_idx = line_num + 1

    // Fetch opcode and operands ----------------
    opcode: Token
    operands: [3]Token
    {
      if instruction.tokens[0].type == .OPCODE
      {
        opcode = instruction.tokens[0]
        operands[0] = instruction.tokens[1]
        operands[1] = instruction.tokens[2]
        operands[2] = instruction.tokens[3]
      }
      else if instruction.tokens[2].type == .OPCODE
      {
        opcode = instruction.tokens[2]
        operands[0] = instruction.tokens[3]
        operands[1] = instruction.tokens[4]
        operands[2] = instruction.tokens[5]
      }
    }

    error: bool

    switch opcode.opcode_type
    {
      case .NIL: {}
      case .MOV:
      {
        dest_reg, err0 := operand_from_operands(operands[:], 0)
        op1_reg, err1  := operand_from_operands(operands[:], 1)
        
        error = err0 || err1
        if !error
        {
          val: Number
          switch v in op1_reg
          {
            case Number:   val = v
            case RegisterID: val = sim.registers[v]
          }

          sim.registers[dest_reg.(RegisterID)] = val
        }
      }
      case .ADD: fallthrough
      case .SUB: fallthrough
      case .SHL: fallthrough
      case .SHR:
      {
        dest_reg, err0 := operand_from_operands(operands[:], 0)
        op1_reg,  err1 := operand_from_operands(operands[:], 1)
        op2_reg,  err2 := operand_from_operands(operands[:], 2)

        error = err0 || err1 || err2
        if !error
        {
          val1, val2: Number
          
          switch v in op1_reg
          {
            case Number:     val1 = v
            case RegisterID: val1 = sim.registers[v]
          }

          switch v in op2_reg
          {
            case Number:     val2 = v
            case RegisterID: val2 = sim.registers[v]
          }
          
          result: Number
          #partial switch instruction.tokens[0].opcode_type
          {
            case .ADD: result = val1 + val2
            case .SUB: result = val1 - val2
            case .SHL: result = val1 << u64(val2)
            case .SHR: result = val1 >> u64(val2)
          }

          sim.registers[dest_reg.(RegisterID)] = result
        }
      }
      case .CMP: fallthrough
      case .CBZ: fallthrough
      case .CBNZ:
      {
        oper1, err0 := operand_from_operands(operands[:], 0)
        oper2, err1 := operand_from_operands(operands[:], 1)

        error = err0 || err1
        if !error
        {
          val1, val2: Number

          switch v in oper1
          {
            case Number:   val1 = v
            case RegisterID: val1 = sim.registers[v]
          }

          switch v in oper2
          {
            case Number:   val2 = v
            case RegisterID: val2 = sim.registers[v]
          }

          sim.status_flag.equal = val1 == val2
          sim.status_flag.greater = val1 > val2
          // @NOTE(dg): This may be invalid ARM
          sim.status_flag.negative = val1 < 0

          should_jump: bool
          #partial switch opcode.opcode_type
          {
            case .CMP:  should_jump = false
            case .CBZ:  should_jump = val1 == 0
            case .CBNZ: should_jump = val1 != 0
          }

          if should_jump
          {
            sim.branch_to_idx = cast(int) oper2.(Number)
          }
        }
      }
      case .B:   fallthrough
      case .BEQ: fallthrough
      case .BNE: fallthrough
      case .BLT: fallthrough
      case .BGT: fallthrough
      case .BLE: fallthrough
      case .BGE: fallthrough
      case .BMI: fallthrough
      case .BPL: fallthrough
      case .BL:  fallthrough
      case .BR:  fallthrough
      case .BLR:
      {
        oper, err0 := operand_from_operands(operands[:], 0)

        target_line_num: int
        if opcode.opcode_type == .BR || opcode.opcode_type == .BL
        {
          target_line_num = cast(int) sim.registers[oper.(RegisterID)]
        }
        else
        {
          target_line_num = cast(int) oper.(Number)
        }

        error = err0
        if !error
        {
          should_jump: bool
          #partial switch opcode.opcode_type
          {
            case .B:   should_jump = true
            case .BEQ: should_jump = sim.status_flag.equal
            case .BNE: should_jump = !sim.status_flag.equal
            case .BLT: should_jump = !sim.status_flag.greater
            case .BGT: should_jump = sim.status_flag.greater
            case .BLE: should_jump = sim.status_flag.greater || sim.status_flag.equal
            case .BGE: should_jump = sim.status_flag.greater || sim.status_flag.equal
            case .BMI: should_jump = sim.status_flag.negative
            case .BPL: should_jump = !sim.status_flag.negative
            case .BL:
            {
              should_jump = true
              sim.registers[.LR] = cast(Number) target_line_num + 1
            }
            case .BR:
            {
              should_jump = true
              target_line_num = line_number_from_address(Address(target_line_num))
            }
            case .BLR:
            {
              should_jump = true
              sim.registers[.LR] = cast(Number) target_line_num + 1
              target_line_num = line_number_from_address(Address(target_line_num))
            }
          }

          if should_jump
          {
            sim.branch_to_idx = target_line_num
          }
        }
      }
    }

    if error
    {
      term.color(.RED)
      fmt.eprintf("[ERROR]: Failed to execute instruction on line %i.\n", line_num+1)
      term.color(.WHITE)
      return
    }

    tui_print_sim_result(instruction, line_num)

    // Set next instruction to result of branch
    line_num = sim.branch_to_idx

    if !(sim.step_to_next && line_num < sim.line_count - 1)
    {
      fmt.print("\n")
    }
  }
}

next_line_from_bytes :: proc(buf: []byte, start: int) -> (end: int)
{
  length := len(buf)

  end = start
  for i in start..<length
  {
    if (buf[i] == '\n' || buf[i] == '\r') 
    {
      end = i
      break
    }
  }

  return end
}

address_from_line_number :: proc(line_num: int) -> Address
{
  assert(line_num < MAX_LINES)

  result: Address

  @(static)
  line_num_to_address_cache: [MAX_LINES]Address

  if line_num_to_address_cache[line_num] != 0
  {
    result = line_num_to_address_cache[line_num]
  }
  else
  {
    for i := sim.text_section_pos; i < line_num; i += 1
    {
      if sim.instructions[i].tokens != nil
      {
        result += INSTRUCTION_SIZE
      }
    }

    line_num_to_address_cache[line_num] = result
  }

  result += BASE_ADDRESS

  return result
}

// @TODO(dg): Not good. Needs a simplification rewrite.
line_number_from_address :: proc(address: Address) -> int
{
  assert(int(address - BASE_ADDRESS) < sim.line_count * INSTRUCTION_SIZE)

  result: int

  address := address
  address -= BASE_ADDRESS
  accumulator: Address

  @(static)
  address_to_line_num_cache: [MAX_LINES]int

  if address_to_line_num_cache[address] != 0
  {
    result = address_to_line_num_cache[address]
  }
  else
  {
    for i := 0; i < sim.line_count && accumulator <= address; i += 1
    {
      if sim.instructions[i].tokens != nil && i >= sim.text_section_pos
      {
        accumulator += INSTRUCTION_SIZE
      }

      result += 1
    }

    address_to_line_num_cache[address] = result
  }

  result -= 1

  return result
}

memory_load_bytes :: proc(address: Address, size: int) -> []byte
{
  address := cast(int) address
  assert(address >= BASE_ADDRESS && address + size <= BASE_ADDRESS + 0xFFFF)
  address -= BASE_ADDRESS

  return sim.memory[address:address+size]
}

memory_store_bytes :: proc(address: Address, bytes: []byte)
{
  address := cast(int) address
  size := len(bytes)
  assert(address >= BASE_ADDRESS && address + size <= BASE_ADDRESS + 0xFFFF)
  address -= BASE_ADDRESS

  for i in address..<address+size
  {
    sim.memory[i] = bytes[i - address]
  }
}

value_from_bytes :: proc(bytes: []byte) -> Number
{
  result: Number
  size := len(bytes)

  assert(size == 1 || size == 2 || size == 4 || size == 8)

  for i in 0..<size
  {
    result |= Number(bytes[i]) << (uint(size-i-1) * 8)
  }

  return result
}

bytes_from_value :: proc(value: Number, size: int) -> []byte
{
  result: []byte = make([]byte, size)

  for i in 0..<size
  {
    result[i] = byte((value >> (uint(size-i-1) * 8)) & 0b11111111)
  }

  return result
}

// @Token ///////////////////////////////////////////////////////////////////////////////

Token :: struct
{
  data: string,
  type: TokenType,
  opcode_type: OpcodeType,

  line: int,
  column: int,
}

TokenType :: enum
{
  NIL,

  OPCODE,
  NUMBER,
  IDENTIFIER,
  DIRECTIVE,
  COLON,
  EQUALS,
}

Instruction :: struct
{
  tokens: []Token,
  line_num: int,
  has_breakpoint: bool,
}

register_from_token :: proc(token: Token) -> (RegisterID, bool)
{
  result: RegisterID
  err: bool

  switch token.data
  {
    case "r0": result = .R0
    case "r1": result = .R1
    case "r2": result = .R2
    case "r3": result = .R3
    case: err = true
  }

  return result, err
}

operand_from_operands :: proc(operands: []Token, idx: int) -> (Operand, bool)
{
  result: Operand
  err: bool

  token := operands[idx]

  if token.type == .NUMBER
  {
    result = cast(Number) str_to_int(token.data)
  }
  else if token.type == .IDENTIFIER
  {
    result, err = register_from_token(token)
    if err
    {
      ok: bool
      result, ok = sim.symbol_table[token.data]
      err = !ok
    }
  }
  else
  {
    err = true
  }

  return result, err
}

print_tokens :: proc()
{
  for i in 0..<sim.line_count
  {
    for tok in sim.instructions[i].tokens
    {
      if tok.type == .NIL do continue
      fmt.print("{", tok.data, "|", tok.type , "}", "")
    }

    fmt.print("\n")
  }

  fmt.print("\n")
}

print_tokens_at :: proc(line_num: int)
{
  for tok in sim.instructions[line_num].tokens
  {
    if tok.type == .NIL do continue
    fmt.print("{", tok.data, "|", tok.type , "}", "")
  }
  
  fmt.print("\n")
}

// @ParserError /////////////////////////////////////////////////////////////////////////

ParserError :: union
{
  SyntaxError,
  TypeError,
  OpcodeError,
}

SyntaxError :: struct
{
  type: SyntaxErrorType,
  line: int,
  column: int,
  token: Token,
}

SyntaxErrorType :: enum
{
  MISSING_IDENTIFIER,
  MISSING_LITERAL,
  MISSING_COLON,
  UNIDENTIFIED_IDENTIFIER,
}

TypeError :: struct
{
  line: int,
  column: int,
  expected_type: TokenType,
  actual_type: TokenType,
  token: Token,
}

OpcodeError :: struct
{
  line: int,
  column: int,
  token: Token,
}

resolve_parser_error :: proc(error: ParserError) -> bool
{
  if error == nil do return false
  
  term.color(.RED)
  fmt.print("[PARSER ERROR]: ")
  
  switch v in error
  {
    case SyntaxError:
    {
      switch v.type
      {
        case .MISSING_COLON: fmt.printf("Missing colon after label on line %i.\n", 
                                        v.line)
        case .MISSING_IDENTIFIER: fmt.printf("")
        case .MISSING_LITERAL: fmt.printf("")
        case .UNIDENTIFIED_IDENTIFIER: fmt.printf("")
      }
    }
    case TypeError:
    {
      fmt.printf("Type mismatch on line %i. Expected \'%s\', got \'%s\'.\n", 
                 v.line, 
                 v.expected_type, 
                 v.actual_type)
    }
    case OpcodeError: {}
  }

  term.color(.WHITE)

  return true
}

// @Imports /////////////////////////////////////////////////////////////////////////////

import "core:fmt"
import "core:os"

import "basic"
import "term"

// import sapp "ext:sokol/app"
