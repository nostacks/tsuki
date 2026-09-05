import std/[strutils, unicode]
import common
import he3/style
import he3/buffer
import he3/private/writer

proc testSimpleFrame =
  var t = initFakeTty()
  var o = t.wr
  var b = initBuffer(4, 2)
  b.writeStr(0, 0, "ab", fg(named(ncRed)))
  o.flushFull(b)
  check t.writes == 1, "single write"
  let expected = "\x1b[H\x1b[0;31mab\x1b[0m\x1b[K" &
    "\x1b[2;1H\x1b[K"
  check t.bytes == cast[seq[byte]](expected), "exact frame bytes"

proc testBlankFrame =
  var t = initFakeTty()
  var o = t.wr
  var b = initBuffer(3, 2)
  o.flushFull(b)
  let expected = "\x1b[H\x1b[0m\x1b[K\x1b[2;1H\x1b[K"
  check t.bytes == cast[seq[byte]](expected), "all blank frame"

proc testWideFrame =
  var t = initFakeTty()
  var o = t.wr
  var b = initBuffer(4, 1)
  b.writeStr(0, 0, "你", styleDefault())
  o.flushFull(b)
  let expected = "\x1b[H\x1b[0m你\x1b[K"
  check t.bytes == cast[seq[byte]](expected), "wide char frame"

proc testTruecolorFullFrame =
  var output = initFakeOut()
  output.truecolor = true
  var buffer = initBuffer(2, 1)
  buffer.writeStr(0, 0, "x", fg(rgb(12, 34, 56)))
  output.flushFull(buffer)
  check "\x1b[0;38;2;12;34;56m" in cast[string](output.fake.bytes),
    "full-frame redraws preserve advertised truecolor"

proc testFullSizeSingleWrite =
  var t = initFakeTty()
  var o = t.wr
  var b = initBuffer(200, 60)
  for y in 0 ..< 60:
    for x in 0 ..< 200:
      let c = Cell(rune: Rune(ord('a') + (x + y) mod 26))
      b.setCell(x, y, c)
  o.flushFull(b)
  check t.writes == 1, "200x60 in one write"
  check t.bytes.len > 200 * 60, "full frame bytes emitted"

proc main =
  testSimpleFrame()
  testBlankFrame()
  testWideFrame()
  testTruecolorFullFrame()
  testFullSizeSingleWrite()
  echo "writer ok"

main()
