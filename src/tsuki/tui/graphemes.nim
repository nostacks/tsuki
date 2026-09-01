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

func isControl(property: GraphemeBreak): bool {.inline.} =
  property in {gbCR, gbLF, gbControl}

func breakOf(value: uint32): GraphemeBreak {.inline.} =
  if value < 0x20'u32:
    if value == 0x0A'u32: gbLF
    elif value == 0x0D'u32: gbCR
    else: gbControl
  elif value < 0x7F'u32: gbOther
  elif value == 0x7F'u32: gbControl
  else: value.graphemeBreak

func runeAtFast(value: string, offset: int): Rune {.inline.} =
  let first = uint8(value[offset])
  if first < 0x80'u8: Rune(first) else: value.runeAt(offset)

func indicOf(value: uint32): IndicConjunctBreak {.inline.} =
  if value < 0x900'u32: incbNone else: value.indicConjunctBreak

func isJoiner*(r: Rune): bool {.inline.} =
  ## True for the zero-width joiner used in emoji and script sequences.
  uint32(r) == 0x200D'u32

func runeWidth*(r: Rune, ambiguous = awNarrow): int =
  ## Returns the Unicode 16 terminal width for one scalar.
  let value = uint32(r)
  let grapheme = value.breakOf
  if grapheme.isControl or grapheme in {gbExtend, gbZWJ}:
    return 0
  if value < 0x80'u32: return 1
  case value.eastAsianWidth
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
  if currentValue >= 0xA9'u32 and currentValue.isExtendedPictographic and
      emojiZwjReady: # GB11
    return true
  if previous == gbRI and current == gbRI and regionalCount mod 2 == 1:
    return true # GB12/GB13
  false

iterator graphemes*(value: string): string =
  ## Iterates Unicode 16 extended grapheme clusters (UAX #29), including
  ## Hangul, emoji ZWJ sequences, flags, spacing marks, and Indic conjuncts.
  var offset = 0
  while offset < value.len:
    let start = offset
    var previousRune = value.runeAtFast(offset)
    var previous = uint32(previousRune).breakOf
    offset += previousRune.size
    var regionalCount = if previous == gbRI: 1 else: 0
    var epChain = uint32(previousRune) >= 0xA9'u32 and
      uint32(previousRune).isExtendedPictographic
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
        epChain = currentValue >= 0xA9'u32 and
          currentValue.isExtendedPictographic
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
    yield value[start ..< offset]

func clusterWidth*(cluster: string, policy = WidthPolicy()): int =
  ## Returns a complete cluster width with configurable ambiguous behavior and
  ## an optional terminal-specific resolver.
  if cluster.len == 0: return 0
  if cluster.len == 1 and uint8(cluster[0]) < 0x80'u8:
    var width = if uint8(cluster[0]) < 0x20'u8 or
      uint8(cluster[0]) == 0x7F'u8: 0 else: 1
    if not policy.resolver.isNil: width = policy.resolver(cluster, width)
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
    width = policy.resolver(cluster, width)
  min(2, max(0, width))
