## Safe plain and rich text values used by all public rendering paths.

import std/[strutils, unicode]
import style

type
  TextPolicyKind* = enum
    ## How terminal controls and malformed UTF-8 are represented.
    tpkPlain
    tpkEscapedControls
    tpkReplacement
    tpkParsedAnsi

  TextPolicy* = object
    ## Policy applied before external text enters a render buffer.
    kind*: TextPolicyKind
    maxBytes*: int
    maxCodepoints*: int
    allowNewlines*: bool
    allowTabs*: bool

  Hyperlink* = object
    ## Safe hyperlink metadata. Backends emit it only after an explicit,
    ## capability-gated application choice.
    uri*: string
    id*: string

  Span* = object
    ## A styled run of safe UTF-8 text.
    text*: string
    style*: Style
    hyperlink*: Hyperlink

  ImageRef* = object
    ## An image a line stands for. Views that can show images resolve
    ## `source` through their host; every other view draws the line's spans.
    source*: string
    alt*: string

  Line* = object
    ## One logical line of rich text, optionally standing for an image.
    spans*: seq[Span]
    image*: ImageRef

  Text* = object
    ## Versioned rich text suitable for cached measurement and wrapping.
    lines*: seq[Line]
    version*: uint64

const
  replacement = "\xEF\xBF\xBD"
  controlEscape = "\xE2\x90\x9B" # U+241B SYMBOL FOR ESCAPE

func plainTextPolicy*(maxBytes = 1_048_576,
    maxCodepoints = 262_144): TextPolicy =
  ## Returns the default untrusted-text policy. Newlines and tabs survive;
  ## all other terminal and directionality controls become U+FFFD.
  TextPolicy(kind: tpkPlain, maxBytes: maxBytes,
    maxCodepoints: maxCodepoints, allowNewlines: true, allowTabs: true)

func escapedControlPolicy*(maxBytes = 1_048_576,
    maxCodepoints = 262_144): TextPolicy =
  ## Returns a policy that displays controls as visible Unicode/control tags.
  TextPolicy(kind: tpkEscapedControls, maxBytes: maxBytes,
    maxCodepoints: maxCodepoints, allowNewlines: true, allowTabs: true)

func replacementPolicy*(maxBytes = 1_048_576,
    maxCodepoints = 262_144): TextPolicy =
  ## Returns a policy replacing every invalid or unsafe code point with U+FFFD.
  TextPolicy(kind: tpkReplacement, maxBytes: maxBytes,
    maxCodepoints: maxCodepoints, allowNewlines: true, allowTabs: true)

func parsedAnsiPolicy*(maxBytes = 1_048_576,
    maxCodepoints = 262_144): TextPolicy =
  ## Marks input for the opt-in allowlisted ANSI parser. Plain render methods
  ## still treat this policy as replacement; they never emit raw ANSI bytes.
  TextPolicy(kind: tpkParsedAnsi, maxBytes: maxBytes,
    maxCodepoints: maxCodepoints, allowNewlines: true, allowTabs: true)

func isBidiControl*(r: Rune): bool =
  ## True for invisible directionality controls unsafe in untrusted logs/code.
  let v = int(r)
  v == 0x061C or v == 0x200E or v == 0x200F or
    (v >= 0x202A and v <= 0x202E) or (v >= 0x2066 and v <= 0x2069)

func isUnsafeControl*(r: Rune): bool =
  ## True for C0/C1, DEL, bidi controls, and noncharacter sentinels.
  let v = int(r)
  v < 0x20 or (v >= 0x7F and v <= 0x9F) or r.isBidiControl or
    (v >= 0xFDD0 and v <= 0xFDEF) or (v and 0xFFFF) == 0xFFFE or
    (v and 0xFFFF) == 0xFFFF

proc addRuneUtf8(dest: var string, r: Rune) {.inline.} =
  let v = uint32(r)
  if v < 0x80:
    dest.add char(v)
  elif v < 0x800:
    dest.add char(0xC0'u32 or (v shr 6))
    dest.add char(0x80'u32 or (v and 0x3F))
  elif v < 0x10000:
    dest.add char(0xE0'u32 or (v shr 12))
    dest.add char(0x80'u32 or ((v shr 6) and 0x3F))
    dest.add char(0x80'u32 or (v and 0x3F))
  else:
    dest.add char(0xF0'u32 or (v shr 18))
    dest.add char(0x80'u32 or ((v shr 12) and 0x3F))
    dest.add char(0x80'u32 or ((v shr 6) and 0x3F))
    dest.add char(0x80'u32 or (v and 0x3F))

func hexDigit(v: int): char {.inline.} =
  if v < 10: char(ord('0') + v)
  else: char(ord('A') + v - 10)

proc addVisibleControl(dest: var string, r: Rune) =
  let v = int(r)
  if v == 0x1B:
    dest.add controlEscape
  elif v >= 0 and v < 0x20:
    dest.addRuneUtf8 Rune(0x2400 + v)
  elif v == 0x7F:
    dest.addRuneUtf8 Rune(0x2421)
  else:
    dest.add "[U+"
    let digits = if v <= 0xFFFF: 4 else: 6
    for shift in countdown((digits - 1) * 4, 0, 4):
      dest.add hexDigit((v shr shift) and 0xF)
    dest.add ']'

func decodeUtf8(data: openArray[char], at: int, r: var Rune): int =
  ## Strict UTF-8 decoder. Invalid starts consume one byte so arbitrary input
  ## always makes progress and cannot smuggle a control through overlong UTF-8.
  if at < 0 or at >= data.len:
    return 0
  let b0 = uint8(data[at])
  if b0 < 0x80:
    r = Rune(b0)
    return 1
  var need: int
  var value: uint32
  var minimum: uint32
  if b0 >= 0xC2 and b0 <= 0xDF:
    need = 2
    value = uint32(b0 and 0x1F)
    minimum = 0x80
  elif b0 >= 0xE0 and b0 <= 0xEF:
    need = 3
    value = uint32(b0 and 0x0F)
    minimum = 0x800
  elif b0 >= 0xF0 and b0 <= 0xF4:
    need = 4
    value = uint32(b0 and 0x07)
    minimum = 0x10000
  else:
    return -1
  if at + need > data.len:
    return -1
  for i in 1 ..< need:
    let b = uint8(data[at + i])
    if b < 0x80 or b > 0xBF:
      return -1
    value = (value shl 6) or uint32(b and 0x3F)
  if value < minimum or value > 0x10FFFF or
      (value >= 0xD800 and value <= 0xDFFF):
    return -1
  r = Rune(value)
  need

proc addChars*(dest: var string, value: openArray[char]) =
  ## Appends a byte range to `dest` without an intermediate string.
  if value.len == 0:
    return
  let start = dest.len
  dest.setLen(start + value.len)
  copyMem(addr dest[start], unsafeAddr value[0], value.len)

func isSanitized*(input: openArray[char],
    policy = plainTextPolicy()): bool =
  ## True when `sanitizeText` would return `input` unchanged: valid UTF-8,
  ## no controls beyond the newlines and tabs the policy allows, no CR, and
  ## within the policy's size limits. Render paths use this to skip copying.
  if policy.maxBytes > 0 and input.len > policy.maxBytes:
    return false
  let cpLimit = if policy.maxCodepoints <= 0: high(int) else:
    policy.maxCodepoints
  var i = 0
  var count = 0
  while i < input.len:
    let b0 = uint8(input[i])
    if b0 < 0x80:
      if b0 < 0x20:
        if b0 == 0x0A:
          if not policy.allowNewlines: return false
        elif b0 == 0x09:
          if not policy.allowTabs: return false
        else:
          return false
      elif b0 == 0x7F:
        return false
      inc i
    else:
      var r: Rune
      let n = decodeUtf8(input, i, r)
      if n <= 0 or r.isUnsafeControl:
        return false
      inc i, n
    inc count
    if count >= cpLimit:
      return false
  true

proc sanitizeText*(input: string,
    policy = plainTextPolicy()): string =
  ## Sanitizes arbitrary bytes into safe UTF-8. The result never contains ESC,
  ## BEL, C1, bidi overrides, or other terminal controls. CR and CRLF normalize
  ## to LF when newlines are enabled. Size limits truncate at code-point
  ## boundaries and append a visible ellipsis.
  if input.isSanitized(policy):
    return input
  let byteLimit = if policy.maxBytes <= 0: input.len else:
    min(input.len, policy.maxBytes)
  let cpLimit = if policy.maxCodepoints <= 0: high(int) else:
    policy.maxCodepoints
  result = newStringOfCap(min(byteLimit + 8, input.len + 8))
  var i = 0
  var count = 0
  var truncated = byteLimit < input.len
  while i < byteLimit and count < cpLimit:
    var r: Rune
    let n = decodeUtf8(input, i, r)
    if n <= 0 or i + n > byteLimit:
      result.add replacement
      inc i
      inc count
      continue
    inc i, n
    inc count
    let v = int(r)
    if v == 0x0D:
      if i < byteLimit and input[i] == '\n':
        inc i
      if policy.allowNewlines:
        result.add '\n'
      elif policy.kind == tpkEscapedControls:
        result.addVisibleControl r
      else:
        result.add replacement
    elif v == 0x0A and policy.allowNewlines:
      result.add '\n'
    elif v == 0x09 and policy.allowTabs:
      result.add '\t'
    elif r.isUnsafeControl:
      if policy.kind == tpkEscapedControls:
        result.addVisibleControl r
      else:
        result.add replacement
    else:
      result.addRuneUtf8 r
  if i < input.len or count >= cpLimit:
    truncated = true
  if truncated:
    result.add "\xE2\x80\xA6" # U+2026

func safeUri*(uri: string): bool =
  ## Accepts only explicit web/mail schemes and rejects control characters.
  let lower = uri.toLower
  if not (lower.startsWith("https://") or lower.startsWith("http://") or
      lower.startsWith("mailto:")):
    return false
  for ch in uri:
    if ord(ch) < 0x20 or ord(ch) == 0x7F:
      return false
  true

proc initSpan*(value: string, style = styleDefault(),
    policy = plainTextPolicy()): Span =
  ## Creates a sanitized styled span.
  Span(text: sanitizeText(value, policy), style: style)

proc initLine*(spans: varargs[Span]): Line =
  ## Creates a logical line from styled spans.
  Line(spans: @spans)

proc initText*(value: string, style = styleDefault(),
    policy = plainTextPolicy()): Text =
  ## Creates rich text from sanitized plain text, preserving explicit lines.
  let safe = sanitizeText(value, policy)
  var start = 0
  for i, ch in safe:
    if ch == '\n':
      result.lines.add Line(spans: @[Span(text: safe[start ..< i],
        style: style)])
      start = i + 1
  result.lines.add Line(spans: @[Span(text: safe[start ..< safe.len],
    style: style)])
  result.version = 1

proc add*(text: var Text, line: sink Line) =
  ## Appends a logical line and advances the content version.
  text.lines.add line
  inc text.version

proc add*(line: var Line, span: sink Span) =
  ## Appends a span to a logical line.
  line.spans.add span
