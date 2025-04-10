package main

import os "core:os"

decode_instruction :: proc(
  encoding: u32,
) -> (
  opcode:   Opcode_Kind, 
  operands: [3]Operand, 
)
{
  return opcode, {}
}

encode_instruction :: proc(
  opcode:   Opcode_Kind,
  operands: [3]Operand = nil,
) -> (
  encoding: u32,
)
{
  return encoding
}

// ELF ///////////////////////////////////////////////////////////////////////////////////

ELF_File :: struct
{

}

ELF_FD :: distinct i32

elf_open :: proc(path: string) -> (fd: ELF_FD, ok: bool)
{
  internal_fd, open_err := os.open(path, os.O_RDONLY); defer os.close(internal_fd)
  if open_err != nil
  {
    return -1, false
  }

  return ELF_FD(internal_fd), true
}

elf_read :: proc(fd: ELF_FD) -> (result: ELF_File, ok: bool)
{
  return result, true
}

elf_write :: proc(fd: ELF_FD, file: ELF_File) -> (ok: bool)
{
  return true
}
