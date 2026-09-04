## Allocation-free SGR emission. Every style change is one combined CSI
## sequence appended directly to the frame byte buffer.

import ../style

const attrOn: array[Attr, int] =
  [1, 2, 3, 4, 5, 7, 9]
const attrOff: array[Attr, int] =
  [22, 22, 23, 24, 25, 27, 29]

func addParam(f: var seq[byte], value: int) {.inline.} =
  var digits: array[20, byte]
  var value = max(0, value)
  var count = 0
  if value == 0:
    f.add byte('0')
    return
  while value > 0:
    digits[count] = byte(ord('0') + value mod 10)
    value = value div 10
    inc count
  while count > 0:
    dec count
    f.add digits[count]

func addColorParams(f: var seq[byte], c: Color, fg: bool,
    truecolor: bool) =
  case c.kind
  of ckDefault:
    discard
  of ckNamed:
    let base = ord(c.name)
    f.add byte(';')
    if fg:
      f.addParam(if base < 8: 30 + base else: 90 + (base - 8))
    else:
      f.addParam(if base < 8: 40 + base else: 100 + (base - 8))
  of ckIndexed:
    f.add byte(';')
    f.addParam(if fg: 38 else: 48)
    f.add byte(';')
    f.add byte('5')
    f.add byte(';')
    f.addParam(int(c.index))
  of ckRgb:
    let channels = c.rgb
    f.add byte(';')
    f.addParam(if fg: 38 else: 48)
    if truecolor:
      f.add byte(';')
      f.add byte('2')
      for channel in channels:
        f.add byte(';')
        f.addParam(int(channel))
    else:
      f.add byte(';')
      f.add byte('5')
      f.add byte(';')
      f.addParam(int(closestIndex(channels[0], channels[1], channels[2])))

func addStyleReset*(f: var seq[byte], s: Style, truecolor = false) =
  ## Appends one SGR forcing the terminal into `s` from unknown state.
  f.add byte(0x1b)
  f.add byte('[')
  f.add byte('0')
  f.addColorParams(s.bg, false, truecolor)
  f.addColorParams(s.fg, true, truecolor)
  for attr in s.attrs:
    f.add byte(';')
    f.addParam(attrOn[attr])
  f.add byte('m')

func addStyleTransition*(f: var seq[byte], current, next: Style,
    truecolor = false) =
  ## Appends the smallest SGR turning `current` into `next`. Attribute
  ## removal and returning a color to default reset first, because reset is
  ## the only transition every terminal implements identically.
  if current == next:
    return
  if current.attrs - next.attrs != {} or
      (next.fg.kind == ckDefault and current.fg.kind != ckDefault) or
      (next.bg.kind == ckDefault and current.bg.kind != ckDefault):
    f.addStyleReset(next, truecolor)
    return
  let start = f.len
  f.add byte(0x1b)
  if next.bg != current.bg:
    f.addColorParams(next.bg, false, truecolor)
  if next.fg != current.fg:
    f.addColorParams(next.fg, true, truecolor)
  for attr in next.attrs - current.attrs:
    f.add byte(';')
    f.addParam(attrOn[attr])
  if f.len == start + 1:
    f.setLen start
    return
  f[start + 1] = byte('[')
  f.add byte('m')

func bytesToString(f: seq[byte]): string =
  result = newString(f.len)
  for i, value in f:
    result[i] = char(value)

func ansiFg*(c: Color, truecolor = false): string =
  ## ANSI sequence setting the foreground, empty for default.
  if c.kind == ckDefault:
    return ""
  var f: seq[byte]
  f.addColorParams(c, true, truecolor)
  result = "\x1b[" & bytesToString(f)[1 .. ^1] & "m"

func ansiBg*(c: Color, truecolor = false): string =
  ## ANSI sequence setting the background, empty for default.
  if c.kind == ckDefault:
    return ""
  var f: seq[byte]
  f.addColorParams(c, false, truecolor)
  result = "\x1b[" & bytesToString(f)[1 .. ^1] & "m"

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
  var f: seq[byte]
  f.addStyleReset(s, truecolor)
  bytesToString(f)
