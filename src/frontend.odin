package main

import "core:fmt"
import "core:strings"
import "core:os"

import "src:basic/mem"
import "src:term"

TUI_Command :: struct
{
  type: TUI_Command_Kind,
  args: [3]string,
}

TUI_Command_Kind :: enum
{
  NIL,

  QUIT,
  HELP,
  CONTINUE,
  STEP,
  BREAKPOINT,
  VIEW,
}

TUI_Register_Group :: enum
{
  TEMPORARIES,
  SAVED,
  ARGUMENTS,
  EXTRAS,
}

TUI_Base :: enum
{
  BIN,
  DEC,
  HEX,
}

TUI_Config :: struct
{
  base: TUI_Base,
}

@(private="file")
command_table: map[string]TUI_Command_Kind = make_command_table()

@(private="file")
global_config: TUI_Config = { base=.HEX }

tui_prompt_command :: proc() -> bool
{
  done: bool

  buf: [64]byte
  term.color(.GRAY)
  fmt.print("\n(riscbox) ")
  term.color(.WHITE)

  input_len, _ := os.read(os.stdin, buf[:])
  
  cmd_str := strip_crlf(string(buf[:input_len]))
  command := tui_command_from_string(cmd_str)

  if command.type != .QUIT
  {
    fmt.print("\n")
  }

  switch command.type
  {
  case .QUIT:
    sim.should_quit = true
    done = true
  case .HELP:
    tui_print_commands_list()
    done = false
  case .STEP:
    sim.step_to_next = true
    done = true
  case .CONTINUE:
    sim.step_to_next = false
    done = true
  case .BREAKPOINT:
    modifier: string
    line_idx: int

    if str_is_numeric(command.args[0])
    {
      line_idx = str_to_int(command.args[0]) - 1
      
      if sim.lines[line_idx].has_breakpoint
      {
        term.color(.GRAY)
        fmt.printf("Breakpoint at line %i.\n", line_idx + 1)
        term.color(.WHITE)
      }
    }
    else
    {
      modifier = command.args[0]
      if command.args[1] != ""
      {
        line_idx = str_to_int(command.args[1]) - 1
      }

      switch modifier
      {
      case "set":
        if sim.lines[line_idx].has_breakpoint == false
        {
          sim.lines[line_idx].has_breakpoint = true

          term.color(.GREEN)
          fmt.printf("Breakpoint set at line %i.\n", line_idx + 1)
          term.color(.WHITE)
        }
      case "rem":
        if sim.lines[line_idx].has_breakpoint == true
        {
          sim.lines[line_idx].has_breakpoint = false

          term.color(.ORANGE)
          fmt.printf("Breakpoint removed at line %i.\n", line_idx + 1)
          term.color(.WHITE)
        }
      case "clear":
        for &line in sim.lines
        {
          line.has_breakpoint = false
        }

        term.color(.ORANGE)
        fmt.print("Breakpoints cleared.\n")
        term.color(.WHITE)
      case "list":
        term.color(.GRAY)
        fmt.print("Breakpoints:\n")
        term.color(.WHITE)

        for line in sim.lines do if line.has_breakpoint
        {
          fmt.printf(" %i\n", line.line_idx + 1)
        }
      }
    }
    
    done = false
  case .VIEW:
    if command.args[0] == "r" || command.args[0] == "reg"
    {
      set: bit_set[TUI_Register_Group]
      switch command.args[1]
      {
      case "":                     set = {.TEMPORARIES, .SAVED, .ARGUMENTS}
      case "all":                  set = {.TEMPORARIES, .SAVED, .ARGUMENTS, .EXTRAS}
      case "temps", "temp", "t":   set = {.TEMPORARIES}
      case "saved", "s":           set = {.SAVED}
      case "args", "arg", "a":     set = {.ARGUMENTS}
      case "extras", "extra", "x": set = {.EXTRAS}
      }

      tui_print_register_view(set, global_config.base)
    }
    else if command.args[0] == "m" || command.args[0] == "mem"
    {
      address: Address
      if str_is_numeric(command.args[1])
      {
        address = cast(Address) str_to_int(command.args[1])
        if !address_is_valid(address)
        {
          tui_print_message(.ERROR, "Address out of range.")
        }
      }
      else 
      {
        reg, ok1 := register_from_string(command.args[1])
        if ok1
        {
          address = cast(Address) sim.registers[reg]
        }
        else
        {
          val, ok2 := sim.symbol_table[command.args[1]]
          if !ok2
          {
            tui_print_message(.ERROR, "Unidentified token for address.")
            done = false
            return done
          }
          else
          {
            address = cast(Address) val
          }
        }
      }

      offset: int
      if str_is_numeric(command.args[2])
      {
        offset = str_to_int(command.args[2])
      }

      padding := (address + Address(offset)) % 8
      
      tui_print_memory_view(address + Address(offset) - padding, global_config.base)
    }
    else if command.args[0] == "base" || command.args[0] == "mode"
    {
      err: bool
      switch command.args[1]
      {
      case "2", "bin", "binary":       global_config.base = .BIN
      case "10", "dec", "decimal":     global_config.base = .DEC
      case "16", "hex", "hexadecimal": global_config.base = .HEX
      case: err = true
      }

      if err
      {
        tui_print_message(.ERROR, "Invalid base. Must be 2, 10, or 16.")
      }
    }
  case .NIL:
    tui_print_message(.ERROR, "Please enter a valid command.")
    done = false
  }
  
  return done
}

tui_command_from_string :: proc(str: string) -> TUI_Command
{
  result: TUI_Command

  if len(str) == 0
  {
    return TUI_Command{type=.STEP}
  }

  start, end: int
  for i := 0; i <= len(result.args) && end < len(str); i += 1
  {
    end = strings.index_byte(str[start:], ' ')
    if end == -1
    {
      end = len(str)
    }
    else
    {
      end += start
    }

    substr := str[start:end]
    
    if i == 0
    {
      result.type = command_table[substr]
    }
    else
    {
      result.args[i-1] = substr
    }

    start = end + 1
  }

  return result
}

tui_print_welcome :: proc()
{
  term.color(.BLUE)
  term.style({.BOLD})
  fmt.print("RISC")
  term.color(.YELLOW)
  term.style({.BOLD})
  fmt.print("BOX\n")
  term.style({.NONE})
  term.color(.GRAY)
  fmt.print("Welcome RISCBOX, a RISC-V simulation sandbox.\n")
  fmt.print("Type 'r' + 'path/to/assembly' to start.\n")
  fmt.print("Type 'h' for a list of commands.\n")
  term.color(.WHITE)
}

tui_print_sim_result :: proc(instruction: Line, next_idx: int)
{
  term.color(.GRAY)
  fmt.print("Instruction:  ")
  term.color(.WHITE)
  for tok in instruction.tokens
  {
    if tok.data != ""
    {
      fmt.print(tok.data, "")
    }
  }
  fmt.printf(" (line %i)\n", instruction.line_idx+1)

  term.color(.GRAY)
  fmt.print("Address:      ")
  term.color(.WHITE)
  fmt.printf("%#X\n", address_from_instruction_index(sim.program_counter))

  term.color(.GRAY)
  fmt.print("Next address: ")
  term.color(.WHITE)
  fmt.printf("%#X\n", address_from_instruction_index(next_idx))

  print_register_title := true
  for reg in Register_ID
  {
    if sim.registers[reg] != sim.registers_prev[reg]
    {
      if print_register_title
      {
        term.color(.GRAY)
        fmt.print("Register:     ")
        term.color(.WHITE)

        print_register_title = false
      }

      fmt.printf("%s=%i\n", reg, sim.registers[reg])
      sim.registers_prev[reg] = sim.registers[reg]
    }
  }
}

tui_print_register_view :: proc(which: bit_set[TUI_Register_Group], base: TUI_Base)
{
  // - Print temporaries ---
  if .TEMPORARIES in which
  {
    fmt.print("[temporaries]\n")

    for reg in Register_ID
    {
      if (reg >= .T0 && reg <= .T2) || (reg >= .T3 && reg <= .T6)
      {
        switch base
        {
        case .BIN:
          fmt.printf(" %s=%b\n", reg, sim.registers[reg])
        case .DEC:
          fmt.printf(" %s=%i\n", reg, sim.registers[reg])
        case .HEX:
          fmt.printf(" %s=%X\n", reg, sim.registers[reg])
        }
      }
    }
  }

  // - Print saved ---
  if .SAVED in which
  {
    fmt.print("[saved]\n")

    for reg in Register_ID
    {
      if reg == .S1 || (reg >= .S2 && reg <= .S11)
      {
        switch base
        {
        case .BIN:
          fmt.printf(" %s=%b\n", reg, sim.registers[reg])
        case .DEC:
          fmt.printf(" %s=%i\n", reg, sim.registers[reg])
        case .HEX:
          fmt.printf(" %s=%X\n", reg, sim.registers[reg])
        }
      }
    }
  }

  // - Print arguments ---
  if .ARGUMENTS in which
  {
    fmt.print("[arguments]\n")

    for reg in Register_ID
    {
      if reg >= .A0 && reg <= .A7
      {
        switch base
        {
        case .BIN:
          fmt.printf(" %s=%b\n", reg, sim.registers[reg])
        case .DEC:
          fmt.printf(" %s=%i\n", reg, sim.registers[reg])
        case .HEX:
          fmt.printf(" %s=%X\n", reg, sim.registers[reg])
        }
      }
    }
  }

  // - Print extras ---
  if .EXTRAS in which
  {
    fmt.print("[extras]\n")

    for reg in Register_ID
    {
      if (reg >= .RA && reg <= .TP) || reg == .FP
      {
        switch base
        {
        case .BIN:
          fmt.printf(" %s=%b\n", reg, sim.registers[reg])
        case .DEC:
          fmt.printf(" %s=%i\n", reg, sim.registers[reg])
        case .HEX:
          fmt.printf(" %s=%X\n", reg, sim.registers[reg])
        }
      }
    }
  }
}

tui_print_memory_view :: proc(address: Address, base: TUI_Base)
{
  address := cast(int) address

  for i in 0..<4
  {
    fmt.printf("%X : ", address + (i * 8))

    for addr, j in address+(i*8)..<address+((i+1)*8)
    {
      if !address_is_valid(Address(addr)) do break
      
      if sim.memory[addr - BASE_ADDRESS] < 0x10
      {
        fmt.print("0")
      }

      fmt.printf("%X", sim.memory[addr - BASE_ADDRESS])
      if j == 3 do fmt.print("  "); else do fmt.print(" ")
    }
    
    fmt.print("\n")
  }
}

tui_print_commands_list :: proc()
{
  fmt.print(" r, run 'path'   |   Use assembly file from path.\n")
  fmt.print(" c, continue     |   Continue to next breakpoint.\n")
  fmt.print(" s, step         |   Step to next instruction.\n")
  fmt.print(" b, break        |   \n")
  fmt.print("  'X'            |   Peak breakpoint at line.\n")
  fmt.print("  set 'X'        |   Set breakpoint at line.\n")
  fmt.print("  rem 'X'        |   Remove breakpoint at line.\n")
  fmt.print("  clear          |   Remove all breakpoints.\n")
  fmt.print("  list           |   List all breakpoints.\n")
  fmt.print(" v, view         |   \n")
  fmt.print("  r, reg 'G'     |   View registers of group.\n")
  fmt.print("  m, mem 'A'     |   View memory at address.\n")
  fmt.print(" q, quit         |   Quit simulator.\n")
}

TUI_Message_Level :: enum
{
  INFO,
  WARNING,
  ERROR,
}

tui_print_message :: proc(level: TUI_Message_Level, msg: string, args: ..any)
{
  switch level
  {
  case .INFO:    term.color(.GRAY)
  case .WARNING: term.color(.YELLOW)
  case .ERROR:   term.color(.RED)
  }

  if args != nil
  {
    fmt.printfln(msg, args)
  }
  else
  {
    fmt.println(msg)
  }
  
  term.color(.WHITE)
}

@(private="file")
make_command_table :: proc() -> map[string]TUI_Command_Kind
{
  table := make(map[string]TUI_Command_Kind, 16, mem.a(&sim.perm_arena))
  table["q"]        = .QUIT
  table["quit"]     = .QUIT
  table["h"]        = .HELP
  table["help"]     = .HELP
  table["c"]        = .CONTINUE
  table["continue"] = .CONTINUE
  table[""]         = .STEP
  table["s"]        = .STEP
  table["step"]     = .STEP
  table["b"]        = .BREAKPOINT
  table["break"]    = .BREAKPOINT
  table["v"]        = .VIEW
  table["view"]     = .VIEW

  return table
}
