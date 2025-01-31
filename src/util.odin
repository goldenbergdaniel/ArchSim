package main

import "core:math"

str_is_dec :: proc(str: string) -> bool
{
  if len(str) == 0                 do return false
  if len(str) > 1 && str[0] == '0' do return false

  is_negative: bool
  if len(str) > 1 && str[0] == '-'
  {
    is_negative = true
  }

  start := 1 if is_negative else 0
  for i in start..<len(str)
  {
    if str[i] < '0' || str[i] > '9' do return false
  }

  return true
}

str_is_hex :: proc(str: string) -> bool
{
  if len(str) < 3    do return false
  if str[:2] != "0x" do return false

  for c in str[2:]
  {
    if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F')
    {
      return false
    }
  }

  return true
}

str_is_bin :: proc(str: string) -> bool
{
  if len(str) < 3    do return false
  if str[:2] != "0b" do return false

  for c in str[2:]
  {
    if c != '0' && c != '1' do return false
  }

  return true
}

str_get_number_base :: proc(str: string) -> int
{
  result: int

  /**/ if str_is_bin(str) do result = 2
  else if str_is_dec(str) do result = 10
  else if str_is_hex(str) do result = 16

  return result
}

str_is_numeric :: #force_inline proc(str: string) -> bool
{
  return str_is_bin(str) || str_is_dec(str) || str_is_hex(str)
}

str_to_int :: proc(str: string) -> int
{
  assert(str_is_numeric(str))

  result: int

  switch str_get_number_base(str)
  {
  case 2:
    for i := 2; i < len(str); i += 1
    {
      result += int(str[i] - 48) * int(math.pow(2, f32(len(str)-i-1)))
    }
  case 10:
    is_negative: bool
    if str[0] == '-'
    {
      is_negative = true
    }

    digits := str
    if is_negative
    {
      digits = str[1:]
    }

    for i := 0; i < len(digits); i += 1
    {
      result += int(digits[i] - 48) * int(math.pow(10, f32(len(digits)-i-1)))
    }

    if is_negative
    {
      result *= -1
    }
  case 16:
    @(static)
    hex_table: [128]u8 = {
      '0' = 0,  '1' = 1,  '2' = 2,  '3' = 3,  '4' = 4,  '5' = 5,  '6' = 6,  '7' = 7,
      '8' = 8,  '9' = 9,  'a' = 10, 'b' = 11, 'c' = 12, 'd' = 13, 'e' = 14, 'f' = 15,
      'A' = 10, 'B' = 11, 'C' = 12, 'D' = 13, 'E' = 14, 'F' = 15,
    }

    for i := len(str)-1; i >= 2; i -= 1
    {
      result += int(hex_table[str[i]]) * int(math.pow(16, f32(len(str)-i-1)))
    }
  }

  return result
}

str_to_char :: proc(str: string) -> (result: byte, ok: bool)
{
  if len(str) == 1
  {
    result = str[0]
  }
  else
  {
    switch str
    {
    case "\\a": result = '\a'
    case "\\b": result = '\b'
    case "\\e": result = '\e'
    case "\\f": result = '\f'
    case "\\n": result = '\n'
    case "\\r": result = '\r'
    case "\\t": result = '\t'
    case "\\v": result = '\v'
    case "\\0": result = 0
    case: ok = false
    }
  }

  return result, ok
}

strip_crlf :: proc(str: string) -> string
{
  result := str

  if len(str) >= 2 && str[len(str)-2] == '\r'
  {
    result = str[:len(str)-2]
  }
  else if len(str) >= 1 && str[len(str)-1] == '\n'
  {
    result = str[:len(str)-1]
  }

  return result
}
