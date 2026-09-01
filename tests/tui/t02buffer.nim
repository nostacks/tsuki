import std/[random, unicode, sequtils]
import common
import tsuki/tui/layout
import tsuki/tui/graphemes
import tsuki/tui/buffer
import tsuki/tui/style

proc testBasics =
  var b = initBuffer(4, 3)
  check b.width == 4 and b.height == 3, "dims"
  for y in 0 ..< 3:
    for x in 0 ..< 4:
      let c = b.cellAt(x, y)
      check c.rune == Rune(0x0020) and not c.wideTail, "blank init"
      check c.style == styleDefault(), "default style"
  b.setCell(-1, 0, Cell(rune: Rune(ord('x'))))
  b.setCell(4, 0, Cell(rune: Rune(ord('x'))))
  b.setCell(0, -1, Cell(rune: Rune(ord('x'))))
  b.setCell(0, 3, Cell(rune: Rune(ord('x'))))
  check b.cellAt(0, 0).rune == Rune(0x0020), "oob setCell no-op"

proc testResize =
  var b = initBuffer(4, 2)
  b.writeStr(0, 0, "abcd", styleDefault())
  b.writeStr(0, 1, "efgh", styleDefault())
  b.resize(6, 3)
  check b.width == 6 and b.height == 3, "new dims"
  check b.cellAt(0, 0).rune == Rune(ord('a')), "preserved a"
  check b.cellAt(3, 1).rune == Rune(ord('h')), "preserved h"
  check b.cellAt(4, 0).rune == Rune(0x0020), "new area blank"

proc testWriteStr =
  var b = initBuffer(10, 2)
  let st = fg(named(ncRed))
  b.writeStr(2, 0, "abc", st)
  check b.cellAt(2, 0).rune == Rune(ord('a')), "first char"
  check b.cellAt(2, 0).style == st, "first char style"
  check b.cellAt(4, 0).rune == Rune(ord('c')), "third char"
  check b.cellAt(1, 0).rune == Rune(0x0020), "untouched col"
  b.writeStr(9, 0, "xyz", st)
  check b.cellAt(9, 0).rune == Rune(ord('x')), "truncated write"

proc testNewline =
  var b = initBuffer(10, 3)
  b.writeStr(1, 0, "ab\ncd", styleDefault())
  check b.cellAt(1, 0).rune == Rune(ord('a')), "line1 a"
  check b.cellAt(2, 0).rune == Rune(ord('b')), "line1 b"
  check b.cellAt(1, 1).rune == Rune(ord('c')), "line2 c"
  check b.cellAt(1, 2).rune == Rune(0x0020), "no third line"

proc testWideChars =
  var b = initBuffer(10, 2)
  b.writeStr(0, 0, "你好", styleDefault())
  check b.cellAt(0, 0).rune == Rune(0x4F60), "wide base 你"
  check b.cellAt(1, 0).wideTail, "wide tail marker"
  check b.cellAt(2, 0).rune == Rune(0x597D), "wide base 好"
  check b.cellAt(3, 0).wideTail, "wide tail marker 2"
  check not b.cellAt(4, 0).wideTail, "rest blank"
  var n = initBuffer(2, 1)
  n.writeStr(1, 0, "你", styleDefault())
  check n.cellAt(1, 0).rune == Rune(0x0020), "wide char dropped at edge"

proc testCombining =
  var b = initBuffer(10, 1)
  b.writeStr(0, 0, "e\u0301", styleDefault())
  check b.cellAt(0, 0).rune == Rune(ord('e')), "combining folds into base"
  check b.cellAt(1, 0).rune == Rune(0x0020), "no extra cell"
  check "e\u0301".graphemes.toSeq.len == 1, "single cluster"

proc testClearFill =
  var b = initBuffer(8, 4)
  b.fill(initRect(1, 1, 4, 2), Rune(ord('#')), fg(named(ncBlue)))
  check b.cellAt(1, 1).rune == Rune(ord('#')), "fill hit"
  check b.cellAt(5, 1).rune == Rune(0x0020), "fill edge exclusive"
  check b.cellAt(0, 1).rune == Rune(0x0020), "fill left edge"
  b.clear(initRect(0, 0, 8, 4))
  check b.cellAt(1, 1).rune == Rune(0x0020), "cleared"


proc testProps =
  randomize(20260828)
  for iter in 0 ..< 200:
    var b = initBuffer(20, 5)
    let before = b.cells
    let x = rand(0 .. 19)
    let y = rand(0 .. 4)
    let n = rand(0 .. 30)
    var s = ""
    for i in 0 ..< n:
      s.add chr(ord('a') + rand(0 .. 25))
    b.writeStr(x, y, s, styleDefault())
    for yy in 0 ..< 5:
      for xx in 0 ..< 20:
        if yy == y and xx >= x:
          continue
        check b.cells[yy * 20 + xx] == before[yy * 20 + xx],
          "no writes outside affected row"
    var readback = ""
    for xx in x ..< 20:
      let c = b.cellAt(xx, y)
      if not c.wideTail:
        readback.add $c.rune
    check readback.strip == s[0 ..< min(s.len, 20 - x)],
      "readback reproduces written string"

proc main =
  testBasics()
  testResize()
  testWriteStr()
  testNewline()
  testWideChars()
  testCombining()
  testClearFill()
  testProps()
  echo "buffer ok"

main()
