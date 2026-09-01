import std/unicode
import tsuki/tui/graphemes
import tsuki/tui/widgets/spinner
import common

const
  dotsFrames = [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
  ]
  brailleFrames = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"
  ]
  barFrames = [
    "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅",
    "▄", "▃", "▂"
  ]

proc cycleLen(kind: SpinnerKind): int =
  ## Counts how many next calls bring frame back to 0.
  var s = initSpinner(kind)
  discard s.next
  result = 1
  while s.frame != 0:
    discard s.next
    inc result

proc cycleSeq(kind: SpinnerKind, count: int): seq[string] =
  ## Collects count frames from a fresh spinner.
  var s = initSpinner(kind)
  for i in 0 ..< count:
    result.add s.next

proc testPreset(kind: SpinnerKind, expected: openArray[string]) =
  ## Asserts order, wrap, fresh first frame, and stable cycle length.
  let n = expected.len
  let got = cycleSeq(kind, n + 1)
  check got.len == n + 1, "cycle collects n plus one: " & $kind
  for i in 0 ..< n:
    check got[i] == expected[i], "frame order " & $kind & " at " & $i
  check got[n] == expected[0], "wraps to first frame: " & $kind
  var fresh = initSpinner(kind)
  check fresh.next == expected[0], "fresh returns first frame: " & $kind
  check fresh.frame == 1, "fresh frame advances to 1: " & $kind
  check cycleLen(kind) == n, "cycle length: " & $kind
  check cycleLen(kind) == n, "cycle length constant after wrapping: " & $kind

testPreset(spDots, dotsFrames)
testPreset(spBraille, brailleFrames)
testPreset(spBar, barFrames)

for kind in SpinnerKind:
  var s = initSpinner(kind)
  for i in 0 ..< 3 * cycleLen(kind):
    let f = s.next
    check validateUtf8(f) == -1, "valid utf8: " & $kind
    let r = runeAt(f, 0)
    check $r == f, "single decoded rune: " & $kind
    check runeWidth(r) == 1, "rune width 1: " & $kind

echo "spinner ok"
