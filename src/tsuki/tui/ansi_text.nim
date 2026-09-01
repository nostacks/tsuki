## Opt-in, allowlisted ANSI SGR parser for untrusted subprocess output.
## Terminal commands other than styling become inert visible placeholders.

import std/strutils
import style
import text

func parseNumber(value: string, fallback = 0): int =
  if value.len == 0:
    return fallback
  for ch in value:
    if ch < '0' or ch > '9':
      return fallback
    result = min(65_535, result * 10 + ord(ch) - ord('0'))

func ansiNamed(index: int, bright: bool): Color =
  named(NamedColor(index + (if bright: 8 else: 0)))

proc applySgr(current: var Style, body: string) =
  let fields = if body.len == 0: @["0"] else: body.split(';')
  var i = 0
  while i < fields.len:
    let code = parseNumber(fields[i])
    case code
    of 0: current = styleDefault()
    of 1: current = current.withAttrs({attrBold})
    of 2: current = current.withAttrs({attrDim})
    of 3: current = current.withAttrs({attrItalic})
    of 4: current = current.withAttrs({attrUnderline})
    of 5: current = current.withAttrs({attrBlink})
    of 7: current = current.withAttrs({attrReverse})
    of 9: current = current.withAttrs({attrStrikethrough})
    of 22: current = current.withoutAttrs({attrBold, attrDim})
    of 23: current = current.withoutAttrs({attrItalic})
    of 24: current = current.withoutAttrs({attrUnderline})
    of 25: current = current.withoutAttrs({attrBlink})
    of 27: current = current.withoutAttrs({attrReverse})
    of 29: current = current.withoutAttrs({attrStrikethrough})
    of 30 .. 37: current = current.withFg(ansiNamed(code - 30, false))
    of 39: current = current.withFg(Color())
    of 40 .. 47: current = current.withBg(ansiNamed(code - 40, false))
    of 49: current = current.withBg(Color())
    of 90 .. 97: current = current.withFg(ansiNamed(code - 90, true))
    of 100 .. 107: current = current.withBg(ansiNamed(code - 100, true))
    of 38, 48:
      if i + 2 < fields.len and parseNumber(fields[i + 1]) == 5:
        let value = min(255, parseNumber(fields[i + 2]))
        if code == 38: current = current.withFg(indexed(value))
        else: current = current.withBg(indexed(value))
        inc i, 2
      elif i + 4 < fields.len and parseNumber(fields[i + 1]) == 2:
        let red = min(255, parseNumber(fields[i + 2]))
        let green = min(255, parseNumber(fields[i + 3]))
        let blue = min(255, parseNumber(fields[i + 4]))
        if code == 38: current = current.withFg(rgb(red, green, blue))
        else: current = current.withBg(rgb(red, green, blue))
        inc i, 4
    else: discard
    inc i

proc appendRich(result: var Text, value: string, style: Style) =
  if result.lines.len == 0:
    result.lines.add Line()
  var start = 0
  for i, ch in value:
    if ch == '\n':
      if i > start:
        result.lines[^1].spans.add Span(text: value[start ..< i],
          style: style)
      result.lines.add Line()
      start = i + 1
  if start < value.len:
    result.lines[^1].spans.add Span(text: value[start ..< value.len],
      style: style)

proc parseAnsiText*(input: string,
    policy = parsedAnsiPolicy()): Text =
  ## Parses only SGR styling. OSC, DCS, APC, PM, cursor movement, clipboard,
  ## title, image, hyperlink, and malformed sequences never reach a terminal.
  ## Non-SGR escape sequences are represented by visible bracketed labels.
  let limit = if policy.maxBytes <= 0: input.len else:
    min(input.len, policy.maxBytes)
  var current = styleDefault()
  var plain = newStringOfCap(min(limit, 4096))

  template flushPlain() =
    if plain.len > 0:
      result.appendRich(sanitizeText(plain, replacementPolicy(
        maxBytes = policy.maxBytes, maxCodepoints = policy.maxCodepoints)),
        current)
      plain.setLen 0

  var i = 0
  while i < limit:
    if input[i] != '\x1b':
      plain.add input[i]
      inc i
      continue
    flushPlain()
    if i + 1 >= limit:
      result.appendRich("\xE2\x90\x9B", current)
      inc i
      continue
    let introducer = input[i + 1]
    if introducer == '[':
      var finish = i + 2
      while finish < limit and not (ord(input[finish]) >= 0x40 and
          ord(input[finish]) <= 0x7E):
        inc finish
      if finish >= limit:
        result.appendRich("[incomplete CSI]", current)
        i = limit
      else:
        let final = input[finish]
        let body = input[i + 2 ..< finish]
        if final == 'm' and body.len <= 256:
          current.applySgr(body)
        else:
          result.appendRich("[CSI " & sanitizeText(body,
            replacementPolicy(maxBytes = 256)) & final & "]", current)
        i = finish + 1
    elif introducer in {']', 'P', '_', '^'}:
      let label = case introducer
        of ']': "OSC"
        of 'P': "DCS"
        of '_': "APC"
        else: "PM"
      var finish = i + 2
      while finish < limit:
        if input[finish] == '\a':
          inc finish
          break
        if input[finish] == '\x1b' and finish + 1 < limit and
            input[finish + 1] == '\\':
          inc finish, 2
          break
        inc finish
      result.appendRich("[" & label & "]", current)
      i = finish
    else:
      result.appendRich("[ESC " & sanitizeText($introducer,
        replacementPolicy(maxBytes = 4)) & "]", current)
      inc i, 2
  flushPlain()
  if limit < input.len:
    result.appendRich("\xE2\x80\xA6", current)
  if result.lines.len == 0:
    result.lines.add Line()
  result.version = 1
