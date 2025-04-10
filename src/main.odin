package main

import "core:fmt"
import "core:os"

import "src:basic/mem"
import "src:term"

MAX_SRC_BUF_BYTES   :: 2048
MAX_LINES           :: 64
MAX_TOKENS_PER_LINE :: 8

BASE_ADDRESS     :: 0x10000000
MEMORY_SIZE      :: 65535
INSTRUCTION_SIZE :: 4

Address :: distinct u32
Number  :: distinct i64

Simulator :: struct
{
  should_quit:          bool,
  step_to_next:         bool,
  
  lines:                []Line,
  line_count:           int,
  instructions:         []^Line,
  instruction_count:    int,
  next_instruction_idx: int,
  symbol_table:         map[string]Number,
  program_counter:      int,
  registers:            [Register_ID]Number,
  registers_prev:       [Register_ID]Number,
  memory:               []byte,

  perm_arena:           mem.Arena,
}

Opcode_Kind :: enum
{
  NIL,

  NOP,

  MV,
  LI,
  
  ADD,
  ADDI,
  SUB,
  AND,
  ANDI,
  OR,
  ORI,
  XOR,
  XORI,
  NOT,
  NEG,
  SLL,
  SLLI,
  SRL,
  SRLI,
  SRA,
  SRAI,
  SLT,
  SLTI,
  SLTZ,
  SGT,
  SGTI,
  SGTZ,

  J,
  JR,
  JAL,
  JALR,
  RET,

  BEQ,
  BNE,
  BLT,
  BGT,
  BLE,
  BGE,
  BEQZ,
  BNEZ,
  BLTZ,
  BGTZ,
  BLEZ,
  BGEZ,

  LB,
  LH,
  LW,
  SB,
  SH,
  SW,

  LUI,
  AUIPC,
}

Register_ID :: enum
{
  ZR, RA, SP, GP, TP, T0, T1, T2, 
  FP, S1, A0, A1, A2, A3, A4, A5, 
  A6, A7, S2, S3, S4, S5, S6, S7, 
  S8, S9, S10, S11, T3, T4, T5, T6, 
}

Operand :: union
{
  Number,
  Register_ID,
}

sim: Simulator

main :: proc()
{
  // - Initialize permenant arena ---
  {
    err := mem.init_arena_static(&sim.perm_arena)
    assert(err == nil, "Failed to initialize perm arena!")
  }

  tui_print_welcome()

  src_file_path := "in/main.s"
  if len(os.args) > 1
  {
    src_file_path = os.args[1]
  }

  src_file, err := os.open(src_file_path)
  if err != 0
  {
    term.color(.RED)
    fmt.eprintf("Error: File \'%s\' not found.\n", src_file_path)
    return
  }

  src_buf := make([]byte, MAX_SRC_BUF_BYTES, mem.a(&sim.perm_arena))
  src_size, _ := os.read(src_file, src_buf[:])
  src_data := src_buf[:src_size]
  os.close(src_file)

  sim.lines = make([]Line, MAX_LINES, mem.a(&sim.perm_arena))
  sim.instructions = make([]^Line, MAX_LINES, mem.a(&sim.perm_arena))
  sim.memory = make([]byte, MEMORY_SIZE, mem.a(&sim.perm_arena))
  sim.symbol_table = make(map[string]Number, 16, mem.get_default_allocator())
  sim.step_to_next = true

  // - Tokenize ---
  tokenize_source_code(src_data)
  // print_tokens()
  // if true do return

  // - Preprocess ---
  {
    scratch := mem.scope_scratch()

    data_offset: int
    for line_idx := 0; line_idx < sim.line_count; line_idx += 1
    {
      if sim.lines[line_idx].tokens == nil do continue

      line := sim.lines[line_idx]
      if line.tokens[0].type == .DIRECTIVE
      {
        should_store_number: bool
        should_store_string: bool
        size_to_store: int
        
        switch line.tokens[0].data
        {
        case ".equ":
          val := cast(Number) str_to_int(line.tokens[2].data)
          sim.symbol_table[line.tokens[1].data] = val
        case ".byte":
          should_store_number = true
          size_to_store = 1
        case ".short", ".hword":
          should_store_number = true
          size_to_store = 2
        case ".word":
          should_store_number = true
          size_to_store = 4
        case ".long", ".dword":
          should_store_number = true
          size_to_store = 8
        case ".ascii":
          should_store_string = true
        }

        if should_store_number
        {
          for token, idx in line.tokens[2:]
          {
            if token.type == .NIL do break

            num: Number
            if token.type == .NUMBER
            {
              num = cast(Number) str_to_int(token.data)
            }
            else if token.type == .CHARACTER
            {
              num = cast(Number) str_to_char(token.data) or_continue
            }

            bytes := bytes_from_value(num, size_to_store, scratch.arena)
            address := cast(Address) (BASE_ADDRESS + data_offset)
            memory_store_bytes(address, bytes)

            if idx == 0
            {
              sim.symbol_table[line.tokens[1].data] = cast(Number) address
            }

            data_offset += size_to_store
          }
        }
        else if should_store_string
        {
          str := line.tokens[2].data
          for i in 0..<len(str)
          {
            bytes := transmute([]byte) str[i:i+1]
            address := cast(Address) (BASE_ADDRESS + data_offset)
            memory_store_bytes(address, bytes)

            if i == 0
            {
              sim.symbol_table[line.tokens[1].data] = cast(Number) address
            }

            data_offset += 1
          }
        }
      }

      if line.tokens[0].type == .LABEL && line.tokens[1].type == .COLON
      {
        address := address_from_line_index(line_idx)
        sim.symbol_table[line.tokens[0].data] = cast(Number) address
      }
    }
  }

  syntax_ok := syntax_check_lines()
  if !syntax_ok do return

  // - Instructions from lines ---
  for &line in sim.lines do if line_is_instruction(line)
  {
    sim.instructions[sim.instruction_count] = &line
    sim.instruction_count += 1
  }

  semantics_ok := semantics_check_instructions()
  if !semantics_ok do return

  // - Execute ---
  for sim.program_counter < sim.instruction_count
  {
    temp := mem.begin_temp(mem.get_scratch())
    defer mem.end_temp(temp)

    instruction := sim.instructions[sim.program_counter]

    if instruction.has_breakpoint
    {
      sim.step_to_next = true
    }

    // - Prompt user command ---
    if sim.step_to_next && sim.program_counter < sim.line_count
    {
      for done: bool; !done;
      {
        done = tui_prompt_command()
      }
    }

    if sim.should_quit do return

    sim.next_instruction_idx = sim.program_counter + 1

    // - Fetch opcode and operands ---
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

    switch opcode.opcode_type
    {
    case .NIL: panic("NIL opcode!")
    case .NOP:
    case .MV: fallthrough
    case .LI:
      dst_reg, _ := operand_from_token(operands[0])
      op1_reg, _ := operand_from_token(operands[1])
      
      #partial switch opcode.opcode_type
      {
      case .MV:
        sim.registers[dst_reg.(Register_ID)] = sim.registers[op1_reg.(Register_ID)]
      case .LI:
        sim.registers[dst_reg.(Register_ID)] = op1_reg.(Number)
      }
    case .ADD:  fallthrough
    case .ADDI: fallthrough
    case .SUB:  fallthrough
    case .AND:  fallthrough
    case .ANDI: fallthrough
    case .OR:   fallthrough
    case .ORI:  fallthrough
    case .XOR:  fallthrough
    case .XORI: fallthrough
    case .NOT:  fallthrough
    case .NEG:  fallthrough
    case .SLL:  fallthrough
    case .SLLI: fallthrough
    case .SRL:  fallthrough
    case .SRLI: fallthrough
    case .SRA:  fallthrough
    case .SRAI: fallthrough
    case .SLT:  fallthrough
    case .SLTI: fallthrough
    case .SLTZ: fallthrough
    case .SGT:  fallthrough
    case .SGTI: fallthrough
    case .SGTZ: fallthrough
    case .LUI:  fallthrough
    case .AUIPC:
      dest_reg, _ := operand_from_token(operands[0])
      op1_reg, _ := operand_from_token(operands[1])
      op2_reg, _ := operand_from_token(operands[2])

      val1, val2: Number
      
      switch v in op1_reg
      {
      case Number:      val1 = v
      case Register_ID: val1 = sim.registers[v]
      }

      switch v in op2_reg
      {
      case Number:      val2 = v
      case Register_ID: val2 = sim.registers[v]
      }
      
      result: Number
      #partial switch instruction.tokens[0].opcode_type
      {
      case .ADD, .ADDI: result = val1 + val2
      case .SUB:        result = val1 - val2
      case .AND, .ANDI: result = val1 & val2
      case .OR,  .ORI:  result = val1 | val2
      case .XOR:        result = val1 | val2
      case .NOT:        result = ~val1
      case .NEG:        result = -result
      case .SLL, .SLLI: result = Number(val1 << uint(val2))
      case .SRL, .SRLI: result = Number(val1 >> uint(val2))
      case .SRA, .SRAI: result = val1 >> uint(val2)
      case .SLT, .SLTI: result = val1 < val2 ? 1 : 0
      case .SLTZ:       result = val1 < 0 ? 1 : 0
      case .SGT, .SGTI: result = val1 > val2 ? 1 : 0
      case .SGTZ:       result = val1 > 0 ? 1 : 0
      case .LUI:        result = val1 << 12
      case .AUIPC:      result = Number(sim.program_counter) + val1 << 12

      sim.registers[dest_reg.(Register_ID)] = result
    }
    case .BEQ:  fallthrough
    case .BNE:  fallthrough
    case .BLT:  fallthrough
    case .BGT:  fallthrough
    case .BLE:  fallthrough
    case .BGE:  fallthrough
    case .BEQZ: fallthrough
    case .BNEZ: fallthrough
    case .BLTZ: fallthrough
    case .BGTZ: fallthrough
    case .BLEZ: fallthrough
    case .BGEZ:
      oper1, _ := operand_from_token(operands[0])
      oper2, _ := operand_from_token(operands[1])
      dest, _ := operand_from_token(operands[2])

      val1, val2: Number

      switch v in oper1
      {
      case Number:      val1 = v
      case Register_ID: val1 = sim.registers[v]
      }

      switch v in oper2
      {
      case Number:      val2 = v
      case Register_ID: val2 = sim.registers[v]
      }

      should_jump: bool
      #partial switch opcode.opcode_type
      {
        case .BEQ:  should_jump = val1 == val2
        case .BNE:  should_jump = val1 != val2
        case .BLT:  should_jump = val1 < val2
        case .BGT:  should_jump = val1 > val2
        case .BLE:  should_jump = val1 <= val2
        case .BGE:  should_jump = val1 >= val2
        case .BEQZ: should_jump = val1 == 0
        case .BNEZ: should_jump = val1 != 0
        case .BLTZ: should_jump = val1 < 0
        case .BGTZ: should_jump = val1 > 0
        case .BLEZ: should_jump = val1 <= 0
        case .BGEZ: should_jump = val1 >= 0
      }

      if should_jump
      {
        target_branch_idx := instruction_index_from_address(Address(dest.(Number)))
        sim.next_instruction_idx = target_branch_idx
      }
    case .J:    fallthrough
    case .JR:   fallthrough
    case .JAL:  fallthrough
    case .JALR: fallthrough
    case .RET:
      oper, _ := operand_from_token(operands[0])
      target_jump_addr := address_from_instruction_index(sim.program_counter + 1)
      
      #partial switch opcode.opcode_type
      {
      case .J:
        target_jump_addr = cast(Address) oper.(Number)
      case .JR:
        target_jump_addr = cast(Address) sim.registers[oper.(Register_ID)]
      case .JAL:
        sim.registers[.RA] = cast(Number) target_jump_addr
        target_jump_addr = cast(Address) oper.(Number)
      case .JALR:
        sim.registers[.RA] = cast(Number) target_jump_addr
        target_jump_addr = cast(Address) sim.registers[oper.(Register_ID)]
      case .RET:
        target_jump_addr = cast(Address) sim.registers[.RA]
      }

      target_jump_idx := instruction_index_from_address(target_jump_addr)
      sim.next_instruction_idx = target_jump_idx
    case .LB: fallthrough
    case .LH: fallthrough
    case .LW:
      dest, _ := operand_from_token(operands[0])
      src, _ := operand_from_token(operands[1])
      off, _ := operand_from_token(operands[2])

      src_addr: Address
      if off != nil
      {
        src_addr = cast(Address) off.(Number)
      }
      else
      {
        src_addr = 0
      }

      switch v in src
      {
      case Number:      src_addr += cast(Address) v
      case Register_ID: src_addr += cast(Address) sim.registers[v]
      }

      @(static)
      sizes := [?]uint{Opcode_Kind.LB = 1, Opcode_Kind.LH = 2, Opcode_Kind.LW = 4}
      
      type := opcode.opcode_type
      bytes := memory_load_bytes(src_addr, sizes[type])
      value := value_from_bytes(bytes)
      sim.registers[dest.(Register_ID)] = value
    case .SB: fallthrough
    case .SH: fallthrough
    case .SW:
      src, _ := operand_from_token(operands[0])
      dest, _ := operand_from_token(operands[1])
      off, _ := operand_from_token(operands[2])

      dest_address := cast(Address) off.(Number)
      switch v in dest
      {
      case Number:     dest_address += cast(Address) v
      case Register_ID: dest_address += cast(Address) sim.registers[v]
      }

      @(static)
      sizes := [?]int{Opcode_Kind.SB = 1, Opcode_Kind.SH = 2, Opcode_Kind.SW = 4}
      
      type := opcode.opcode_type
      value := sim.registers[src.(Register_ID)]
      bytes := bytes_from_value(value, sizes[type], temp.arena)
      memory_store_bytes(dest_address, bytes)
    }

    tui_print_sim_result(instruction^, sim.next_instruction_idx)
    sim.program_counter = sim.next_instruction_idx

    if !(sim.step_to_next && sim.program_counter < (sim.instruction_count - 1) * 4)
    {
      fmt.print("\n")
    }
  }
}

address_is_valid :: proc(address: Address) -> bool
{
  return address >= BASE_ADDRESS && address <= BASE_ADDRESS + MEMORY_SIZE
}

instruction_index_from_address :: proc(address: Address) -> int
{
  result: int = cast(int) address
  result -= BASE_ADDRESS
  result /= INSTRUCTION_SIZE
  return result
}

address_from_instruction_index :: proc(idx: int) -> Address
{
  result: Address = cast(Address) idx
  result *= INSTRUCTION_SIZE
  result += BASE_ADDRESS
  return result
}

address_from_line_index :: proc(idx: int) -> Address
{
  result: Address

  @(static)
  line_idx_to_address_cache: [MAX_LINES]Address

  if line_idx_to_address_cache[idx] != 0
  {
    result = line_idx_to_address_cache[idx]
  }
  else
  {
    for i in 0..<idx do if line_is_instruction(sim.lines[i])
    {
      result += INSTRUCTION_SIZE
    }

    line_idx_to_address_cache[idx] = result
  }

  result += BASE_ADDRESS
  return result
}

line_index_from_address :: proc(address: Address) -> int
{
  assert(int(address - BASE_ADDRESS) < sim.line_count * INSTRUCTION_SIZE)

  result: int
  instruction_idx := instruction_index_from_address(address)
  result = sim.instructions[instruction_idx].line_idx
  return result
}

memory_load_bytes :: proc(address: Address, size: uint) -> []byte
{
  assert(address >= BASE_ADDRESS && address + Address(size) <= BASE_ADDRESS + 0xFFFF)

  address := cast(uint) address
  address -= BASE_ADDRESS
  return sim.memory[address:address+size]
}

memory_store_bytes :: proc(address: Address, bytes: []byte)
{
  assert(address >= BASE_ADDRESS && address + Address(len(bytes)) <= BASE_ADDRESS + 0xFFFF)

  address := cast(int) address
  address -= BASE_ADDRESS

  for i in address..<address+len(bytes)
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

bytes_from_value :: proc(value: Number, size: int, arena: ^mem.Arena) -> []byte
{
  result := make([]byte, size, mem.a(arena))

  for i in 0..<size
  {
    result[i] = byte((value >> (uint(size-i-1) * 8)) & 0xFF)
  }

  return result
}
