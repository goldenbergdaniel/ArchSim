package main

encode_instruction :: proc(
  opcode:   Opcode_Kind,
  operands: [3]Operand = nil,
) -> (
  encoding: u32,
)
{
  return encoding
}

decode_instruction :: proc(
  encoding: u32,
) -> (
  opcode:   Opcode_Kind, 
  operands: [3]Operand, 
)
{
  return opcode, {}
}
