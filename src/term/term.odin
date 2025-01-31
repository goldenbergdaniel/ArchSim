package term

import "core:fmt"

@(private)
current_color: ColorKind

ColorKind :: enum
{
  BLACK,
  BLUE,
  GRAY,
  GREEN,
  ORANGE,
  RED,
  WHITE,
  YELLOW,
}

StyleKind :: enum
{
  NONE,
  BOLD,
  ITALIC,
  UNDERLINE,
}

CursorMode :: enum
{
  DEFAULT,
  BLINK,
}

reset :: proc()
{
  fmt.print("\u001b[0m")
}

color :: proc(kind: ColorKind)
{
  switch kind
  {
  case .BLACK:  fmt.print("\u001b[38;5;16m")
  case .BLUE:   fmt.print("\u001b[38;5;4m")
  case .GRAY:   fmt.print("\u001b[38;5;7m")
  case .GREEN:  fmt.print("\u001b[38;5;2m")
  case .ORANGE: fmt.print("\u001b[38;5;166m")
  case .RED:    fmt.print("\u001b[38;5;1m")
  case .WHITE:  fmt.print("\u001b[38;5;15m")
  case .YELLOW: fmt.print("\u001b[93m")
  }

  current_color = kind
}

style :: proc(set: bit_set[StyleKind])
{
  if .NONE in set
  {
    fmt.print("\u001b[0m")
  }
  else
  {
    if .BOLD in set do fmt.print("\u001b[1m")
    else if .ITALIC in set do fmt.print("\u001b[23m")
    else if .UNDERLINE in set do fmt.print("\u001b[24m")
  }
}

cursor_mode :: proc(mode: CursorMode)
{
  switch mode
  {
  case .DEFAULT: fmt.print("\u001b[0m"); color(current_color)
  case .BLINK:   fmt.print("\u001b[25m")
  }
}
