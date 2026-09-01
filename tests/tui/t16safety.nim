import std/[random, strutils, unicode]
import common
import tsuki/tui/[ansi_text, buffer, diff, graphemes, layout, text]
import tsuki/tui/private/writer

proc testPlainSanitization =
  let hostile = "safe\x1b]0;owned\a\x1b[31mred\x1bPimage\x1b\\" &
    "\xC2\x9B31m\xE2\x80\xAEtxt"
  let safe = sanitizeText(hostile)
  check '\x1b' notin safe, "plain text removes ESC"
  check '\a' notin safe, "plain text removes BEL"
  check "owned" in safe and "red" in safe, "plain content remains visible"
  check sanitizeText("a\r\nb\rc") == "a\nb\nc", "CR and CRLF normalize"
  check sanitizeText("\xF0\x28\x8C\x28").validateUtf8 == -1,
    "invalid UTF-8 becomes valid replacement text"
  let escaped = sanitizeText("x\x1by\a", escapedControlPolicy())
  check '\x1b' notin escaped and '\a' notin escaped,
    "visible control mode remains terminal-safe"

proc testAnsiAllowlist =
  let rich = parseAnsiText("a\x1b[31mred\x1b[0m" &
    "\x1b]52;c;Y2xpcA==\a\x1b]0;title\a" &
    "\x1b[2Jtail")
  var combined = ""
  for lineIndex, line in rich.lines:
    if lineIndex > 0: combined.add '\n'
    for span in line.spans:
      combined.add span.text
      check '\x1b' notin span.text and '\a' notin span.text,
        "ANSI parser never retains controls"
  check "red" in combined and "[OSC]" in combined and "[CSI 2J]" in combined,
    "unsafe operations become inert visible text"

proc testCompleteGraphemes =
  let samples = ["e\u0301", "👍🏽", "🇮🇩", "👨‍👩‍👧‍👦",
      "क्\u0937", "你"]
  for sample in samples:
    var b = initBuffer(8, 1)
    b.writeStr(0, 0, sample)
    check b.checkInvariants, "grapheme keeps cell invariants: " & sample
    check b.glyphString(b.cellAt(0, 0)) == sample,
      "grapheme round trips byte-for-byte: " & sample
    var previous = initBuffer(8, 1)
    var output = initFakeOut()
    diffInto(previous, b, output)
    check sample in cast[string](output.fake.bytes),
      "diff serializes complete grapheme: " & sample

  let pathological = "e" & repeat("\u0301", 40_000)
  var bounded = initBuffer(2, 1)
  bounded.writeStr(0, 0, pathological)
  let stored = bounded.glyphString(bounded.cellAt(0, 0))
  check stored.len <= int(high(uint16)) and stored.validateUtf8 == -1,
    "oversized graphemes retain a bounded valid UTF-8 prefix"
  check bounded.checkInvariants,
    "oversized grapheme truncation preserves cell invariants"

proc testUnicodeConformance =
  let fixture = readFile("tests/tui/corpora/unicode_grapheme_16.txt")
  var checked = 0
  for rawLine in fixture.splitLines:
    let body = rawLine.split('#', maxsplit = 1)[0].strip
    if body.len == 0: continue
    var source = ""
    var expected: seq[string]
    var current = ""
    for token in strutils.splitWhitespace(body):
      if token == "÷":
        if current.len > 0:
          expected.add current
          current.setLen 0
      elif token != "×":
        let rune = Rune(parseHexInt(token))
        let encoded = $rune
        source.add encoded
        current.add encoded
    if current.len > 0: expected.add current
    var actual: seq[string]
    for cluster in source.graphemes: actual.add cluster
    check actual == expected,
      "Unicode 16 grapheme conformance line " & $(checked + 1)
    inc checked
  check checked > 1000, "full Unicode grapheme fixture was exercised"
  check Rune(0x03B1).runeWidth(awWide) == 2,
    "official ambiguous-width table supports wide policy"

proc testWideRepair =
  var b = initBuffer(6, 2)
  b.writeStr(1, 0, "你")
  b.setCell(2, 0, Cell(rune: Rune(ord('x'))))
  check b.cellAt(1, 0).rune == Rune(0x20), "tail overwrite clears head"
  check b.cellAt(2, 0).rune == Rune(ord('x')), "tail overwrite lands"
  check b.checkInvariants, "tail overwrite preserves invariants"
  b.writeStr(3, 0, "好")
  b.clear(initRect(4, 0, 1, 1))
  check b.cellAt(3, 0).rune == Rune(0x20), "partial clear repairs head"
  check b.checkInvariants, "partial clear preserves invariants"
  b.writeStr(4, 1, "界")
  b.resize(5, 2)
  check b.cellAt(4, 1).rune == Rune(0x20), "resize omits clipped wide glyph"
  check b.checkInvariants, "resize preserves invariants"

proc testInvariantMutations =
  randomize(7162)
  var b = initBuffer(30, 8)
  for iteration in 0 ..< 1000:
    let x = rand(0 ..< b.width)
    let y = rand(0 ..< b.height)
    case rand(0 .. 3)
    of 0: b.writeStr(x, y, "你")
    of 1: b.writeStr(x, y, "e\u0301")
    of 2: b.clear(initRect(x, y, rand(1 .. 4), 1))
    else: b.setCell(x, y, Cell(rune: Rune(ord('a') + rand(0 .. 25))))
    check b.checkInvariants, "random buffer mutation preserves invariants"

proc testOverlayInvariants =
  var destination = initBuffer(8, 3)
  destination.writeStr(0, 0, "background")
  var source = initBuffer(4, 2)
  source.writeStr(1, 0, "你")
  source.writeStr(0, 1, "é")
  destination.overlay(source, 2, 1)
  check destination.glyphString(destination.cellAt(3, 1)) == "你",
    "overlay retains complete wide glyph"
  check destination.glyphString(destination.cellAt(2, 2)) == "é",
    "overlay retains complete combining cluster"
  check destination.checkInvariants, "overlay preserves wide-cell invariants"

testPlainSanitization()
testAnsiAllowlist()
testCompleteGraphemes()
testUnicodeConformance()
testWideRepair()
testInvariantMutations()
testOverlayInvariants()
echo "safety ok"
