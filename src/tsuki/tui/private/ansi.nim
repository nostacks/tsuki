import ../style

func sgrCode(c: Color, fg: bool, truecolor = false): string =
  ## Returns the SGR parameters for `c`, empty for ckDefault. RGB colors emit
  ## direct truecolor sequences when the terminal advertises support.
  case c.kind
  of ckDefault:
    ""
  of ckNamed:
    let base = ord(c.name)
    if fg:
      $(if base < 8: 30 + base else: 90 + (base - 8))
    else:
      $(if base < 8: 40 + base else: 100 + (base - 8))
  of ckIndexed:
    if fg: "38;5;" & $c.index
    else: "48;5;" & $c.index
  of ckRgb:
    if truecolor:
      if fg: "38;2;" & $c.rgb[0] & ";" & $c.rgb[1] & ";" & $c.rgb[2]
      else: "48;2;" & $c.rgb[0] & ";" & $c.rgb[1] & ";" & $c.rgb[2]
    else:
      let i = closestIndex(c.rgb[0], c.rgb[1], c.rgb[2])
      if fg: "38;5;" & $i
      else: "48;5;" & $i

func ansiFg*(c: Color, truecolor = false): string =
  ## ANSI sequence setting the foreground, empty for default.
  let p = sgrCode(c, true, truecolor)
  if p.len == 0: ""
  else: "\x1b[" & p & "m"

func ansiBg*(c: Color, truecolor = false): string =
  ## ANSI sequence setting the background, empty for default.
  let p = sgrCode(c, false, truecolor)
  if p.len == 0: ""
  else: "\x1b[" & p & "m"

const attrOn: array[Attr, int] =
  [1, 2, 3, 4, 5, 7, 9]
const attrOff: array[Attr, int] =
  [22, 22, 23, 24, 25, 27, 29]

func ansiAttrsOn*(attrs: set[Attr]): string =
  ## ANSI sequences enabling `attrs`.
  result = ""
  for a in attrs:
    result.add "\x1b[" & $attrOn[a] & "m"

func ansiAttrsOff*(attrs: set[Attr]): string =
  ## ANSI sequences disabling `attrs`.
  result = ""
  for a in attrs:
    result.add "\x1b[" & $attrOff[a] & "m"

func ansiReset*: string =
  ## ANSI sequence resetting all SGR state.
  "\x1b[0m"

func styleDiffToSeq*(s: Style, truecolor = false): string =
  ## ANSI sequence forcing the terminal into style `s` from unknown state.
  result = ansiReset()
  result.add ansiBg(s.bg, truecolor)
  result.add ansiFg(s.fg, truecolor)
  result.add ansiAttrsOn(s.attrs)
