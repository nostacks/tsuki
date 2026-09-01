import std/unicode
import common
import tsuki/tui/style
import tsuki/tui/buffer
import tsuki/tui/layout
import tsuki/tui/render

proc testBasics =
  var b = initBuffer(10, 4)
  let r = initRect(2, 1, 6, 2)
  var f = initFrame(b, r)
  f.write(0, 0, "hi")
  check b.cellAt(2, 1).rune == Rune(ord('h')), "first char at frame origin"
  check b.cellAt(3, 1).rune == Rune(ord('i')), "second char"
  check b.cellAt(0, 0).rune == Rune(0x0020), "outside frame untouched"
  f.write(4, 0, "overflow!")
  check b.cellAt(6, 1).rune == Rune(ord('o')), "clipped at frame edge"
  check b.cellAt(7, 1).rune == Rune(ord('v')), "last fitting char"
  check b.cellAt(8, 1).rune == Rune(0x0020), "no write past rect"

proc testStyle =
  var b = initBuffer(10, 4)
  var f = initFrame(b, initRect(0, 0, 10, 4), fg(named(ncRed)))
  f.write(0, 0, "x")
  check b.cellAt(0, 0).style == fg(named(ncRed)), "frame style used"
  f.write(1, 0, "y", fg(named(ncBlue)))
  check b.cellAt(1, 0).style == fg(named(ncBlue)), "explicit style wins"

proc testSub =
  var b = initBuffer(20, 10)
  var f = initFrame(b, initRect(0, 0, 20, 10))
  var s1 = f.sub(initRect(5, 2, 10, 5))
  s1.write(0, 0, "S")
  check b.cellAt(5, 2).rune == Rune(ord('S')), "sub frame translated"
  var s2 = s1.sub(initRect(8, 0, 10, 5))
  s2.write(0, 0, "N")
  check b.cellAt(13, 2).rune == Rune(ord('N')), "nested sub translated"
  s2.write(0, 0, "XY")
  check b.cellAt(13, 2).rune == Rune(ord('X')), "sub clipped to parent"
  check b.cellAt(14, 2).rune == Rune(ord('Y')), "y in second column"
  check b.cellAt(15, 2).rune == Rune(0x0020), "no bleed outside"

proc testFillClear =
  var b = initBuffer(8, 4)
  var f = initFrame(b, initRect(1, 1, 6, 2))
  f.fill(initRect(0, 0, 20, 20), Rune(ord('#')), fg(named(ncRed)))
  check b.cellAt(1, 1).rune == Rune(ord('#')), "fill starts at frame"
  check b.cellAt(6, 2).rune == Rune(ord('#')), "fill ends at frame"
  check b.cellAt(0, 1).rune == Rune(0x0020), "no fill outside left"
  check b.cellAt(7, 3).rune == Rune(0x0020), "no fill outside bottom"
  f.clear(initRect(0, 0, 6, 2))
  check b.cellAt(1, 1).rune == Rune(0x0020), "cleared"

proc testNegativeCoords =
  var b = initBuffer(6, 3)
  var f = initFrame(b, initRect(2, 1, 4, 1))
  f.write(-2, 0, "abcd")
  check b.cellAt(0, 1).rune == Rune(0x0020), "outside frame clipped"
  check b.cellAt(1, 1).rune == Rune(0x0020), "outside frame clipped 2"
  check b.cellAt(2, 1).rune == Rune(ord('c')), "c lands at frame origin"
  check b.cellAt(3, 1).rune == Rune(ord('d')), "d follows"

proc testWideClipping =
  var b = initBuffer(6, 2)
  var f = initFrame(b, initRect(0, 0, 3, 1))
  f.write(0, 0, "你好")
  check b.cellAt(0, 0).rune == Rune(0x4F60), "wide base fits"
  check b.cellAt(1, 0).wideTail, "wide tail"
  check b.cellAt(2, 0).rune == Rune(0x0020), "wide dropped at edge"

  var clipped = initBuffer(4, 1)
  let clippedFrame = initFrame(clipped, initRect(0, 0, 4, 1))
  clippedFrame.write(-1, 0, "你ab")
  check clipped.cellAt(0, 0).rune == Rune(0x0020),
    "a partially clipped wide glyph is omitted atomically"
  check clipped.cellAt(1, 0).rune == Rune(ord('a')) and
    clipped.cellAt(2, 0).rune == Rune(ord('b')),
    "text after a clipped wide glyph keeps its logical cell position"

proc testSnapshot =
  var b = initBuffer(12, 3)
  var f = initFrame(b, initRect(0, 0, 12, 3))
  let cols = f.rect.splitH(fixed(4), fill(2))
  var left = f.sub(cols[0])
  var mid = f.sub(cols[1])
  left.write(1, 0, "L")
  mid.write(1, 1, "M")
  var expect = initBuffer(12, 3)
  expect.writeStr(1, 0, "L", styleDefault())
  expect.writeStr(5, 1, "M", styleDefault())
  check b == expect, "snapshot deterministic"
  var b2 = initBuffer(12, 3)
  var f2 = initFrame(b2, initRect(0, 0, 12, 3))
  let cols2 = f2.rect.splitH(fixed(4), fill(2))
  f2.sub(cols2[0]).write(1, 0, "L")
  f2.sub(cols2[1]).write(1, 1, "M")
  check b2 == expect, "byte snapshot stable"

proc main =
  testBasics()
  testStyle()
  testSub()
  testFillClear()
  testNegativeCoords()
  testWideClipping()
  testSnapshot()
  echo "frame ok"

main()
