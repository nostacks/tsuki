## Unicode 16 grapheme segmentation and terminal-cell width policy.

import std/unicode
import unicode_width

export unicode_width.unicodeVersion

type
  AmbiguousWidth* = enum
    awNarrow
    awWide
  WidthResolver* = proc (cluster: string, defaultWidth: int): int {.
    nimcall, noSideEffect, gcsafe.}
  WidthPolicy* = object
    ambiguous*: AmbiguousWidth
    resolver*: WidthResolver

const fastLimit = 0x800'u32

func packProperties(value: uint32): uint16 =
  var entry = uint16(ord(value.graphemeBreak))
  entry = entry or (uint16(ord(value.eastAsianWidth)) shl 4)
  entry = entry or (uint16(ord(value.indicConjunctBreak)) shl 6)
  if value.isExtendedPictographic:
    entry = entry or (1'u16 shl 8)
  entry

const fastTable: array[fastLimit, uint16] = block:
  var table: array[fastLimit, uint16]
  for value in 0'u32 ..< fastLimit:
    table[value] = packProperties(value)
  table

func isControl(property: GraphemeBreak): bool {.inline.} =
  property in {gbCR, gbLF, gbControl}

func breakOf(value: uint32): GraphemeBreak {.inline.} =
  if value < fastLimit:
    GraphemeBreak(fastTable[value] and 0xF)
  else:
    value.graphemeBreak

func widthOf(value: uint32): EastAsianWidth {.inline.} =
  if value < fastLimit:
    EastAsianWidth((fastTable[value] shr 4) and 0x3)
  else:
    value.eastAsianWidth

func indicOf(value: uint32): IndicConjunctBreak {.inline.} =
  if value < fastLimit:
    IndicConjunctBreak((fastTable[value] shr 6) and 0x3)
  else:
    value.indicConjunctBreak

func pictographic(value: uint32): bool {.inline.} =
  if value < fastLimit:
    (fastTable[value] and (1'u16 shl 8)) != 0
  else:
    value.isExtendedPictographic

func toStr(value: openArray[char]): string =
  result = newString(value.len)
  for index, ch in value:
    result[index] = ch

func runeAtFast(value: openArray[char], offset: int): Rune {.inline.} =
  let first = uint8(value[offset])
  if first < 0x80'u8: Rune(first) else: value.runeAt(offset)

func isJoiner*(r: Rune): bool {.inline.} =
  ## True for the zero-width joiner used in emoji and script sequences.
  uint32(r) == 0x200D'u32

func runeWidth*(r: Rune, ambiguous = awNarrow): int =
  ## Returns the Unicode 16 terminal width for one scalar.
  let value = uint32(r)
  if value < 0x80'u32:
    return if value < 0x20'u32 or value == 0x7F'u32: 0 else: 1
  let grapheme = value.breakOf
  if grapheme.isControl or grapheme in {gbExtend, gbZWJ}:
    return 0
  case value.widthOf
  of eawWide: 2
  of eawAmbiguous:
    if ambiguous == awWide: 2 else: 1
  of eawNeutral: 1

func shouldJoin(previous, current: GraphemeBreak, currentValue: uint32,
    regionalCount: int, emojiZwjReady, indicConsonantSeen,
    indicLinkerSeen: bool): bool =
  if previous == gbCR and current == gbLF: # GB3
    return true
  if previous.isControl or current.isControl: # GB4/GB5
    return false
  if previous == gbL and current in {gbL, gbV, gbLV, gbLVT}: # GB6
    return true
  if previous in {gbLV, gbV} and current in {gbV, gbT}: # GB7
    return true
  if previous in {gbLVT, gbT} and current == gbT: # GB8
    return true
  if current in {gbExtend, gbZWJ}: # GB9
    return true
  if current == gbSpacingMark: # GB9a
    return true
  if previous == gbPrepend: # GB9b
    return true
  if currentValue.indicOf == incbConsonant and
      indicConsonantSeen and indicLinkerSeen: # GB9c
    return true
  if currentValue.pictographic and emojiZwjReady: # GB11
    return true
  if previous == gbRI and current == gbRI and regionalCount mod 2 == 1:
    return true # GB12/GB13
  false

iterator graphemeSpans*(value: openArray[char]): Slice[int] =
  ## Iterates the byte range of each Unicode 16 extended grapheme cluster
  ## (UAX #29) without allocating.
  var offset = 0
  while offset < value.len:
    let start = offset
    let firstByte = uint8(value[offset])
    if firstByte < 0x80'u8:
      let atEnd = offset + 1 >= value.len
      let nextByte = if atEnd: 0x80'u8 else: uint8(value[offset + 1])
      if firstByte == 0x0D'u8 and nextByte == 0x0A'u8:
        offset += 2
        yield start ..< offset
        continue
      if nextByte < 0x80'u8 or firstByte < 0x20'u8 or firstByte == 0x7F'u8:
        inc offset
        yield start .. start
        continue
    var previousRune = value.runeAtFast(start)
    offset = start + previousRune.size
    var previous = uint32(previousRune).breakOf
    var regionalCount = if previous == gbRI: 1 else: 0
    var epChain = uint32(previousRune).pictographic
    var emojiZwjReady = false
    let firstIndic = uint32(previousRune).indicOf
    var indicConsonantSeen = firstIndic == incbConsonant
    var indicLinkerSeen = false
    while offset < value.len:
      let currentRune = value.runeAtFast(offset)
      let currentValue = uint32(currentRune)
      let current = currentValue.breakOf
      if not shouldJoin(previous, current, currentValue, regionalCount,
          emojiZwjReady, indicConsonantSeen, indicLinkerSeen):
        break
      offset += currentRune.size
      if current == gbRI: inc regionalCount else: regionalCount = 0
      if current == gbExtend:
        discard
      elif current == gbZWJ:
        emojiZwjReady = epChain
        epChain = false
      else:
        epChain = currentValue.pictographic
        emojiZwjReady = false
      case currentValue.indicOf
      of incbConsonant:
        indicConsonantSeen = true
        indicLinkerSeen = false
      of incbLinker:
        if indicConsonantSeen: indicLinkerSeen = true
      of incbExtend:
        discard
      of incbNone:
        indicConsonantSeen = false
        indicLinkerSeen = false
      previousRune = currentRune
      previous = current
    yield start ..< offset

iterator graphemes*(value: string): string =
  ## Iterates Unicode 16 extended grapheme clusters as strings; prefer
  ## `graphemeSpans` on hot paths.
  for span in value.graphemeSpans:
    yield value[span]

func clusterWidth*(cluster: openArray[char], policy = WidthPolicy()): int =
  ## Returns a complete cluster width with configurable ambiguous behavior and
  ## an optional terminal-specific resolver.
  if cluster.len == 0: return 0
  if cluster.len == 1 and uint8(cluster[0]) < 0x80'u8:
    var width = if uint8(cluster[0]) < 0x20'u8 or
      uint8(cluster[0]) == 0x7F'u8: 0 else: 1
    if not policy.resolver.isNil: width = policy.resolver(cluster.toStr, width)
    return min(2, max(0, width))
  var width = 0
  var regional = 0
  var emojiPresentation = false
  var offset = 0
  while offset < cluster.len:
    let rune = cluster.runeAtFast(offset)
    let scalar = uint32(rune)
    width = max(width, rune.runeWidth(policy.ambiguous))
    if scalar == 0xFE0F'u32 or scalar == 0x20E3'u32 or
        scalar == 0x200D'u32:
      emojiPresentation = true
    if scalar.breakOf == gbRI: inc regional
    offset += rune.size
  if emojiPresentation or regional >= 2: width = 2
  if not policy.resolver.isNil:
    width = policy.resolver(cluster.toStr, width)
  min(2, max(0, width))

func clusterWidth*(cluster: string, policy = WidthPolicy()): int {.inline.} =
  ## Returns a complete cluster width; see the `openArray` overload.
  clusterWidth(cluster.toOpenArray(0, cluster.len - 1), policy)

func textWidth*(value: openArray[char], policy = WidthPolicy()): int =
  ## Measures safe UTF-8 text in terminal cells without allocating.
  for span in value.graphemeSpans:
    result += clusterWidth(value.toOpenArray(span.a, span.b), policy)
