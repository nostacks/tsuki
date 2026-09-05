import std/[random, unicode, sequtils]
import common
import he3/layout
import he3/graphemes
import he3/buffer
import he3/style

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

proc testScrollRows =
  var b = initBuffer(3, 4)
  for y in 0 ..< 4:
    b.writeStr(0, y, $y & "ab")
  var up = b
  up.scrollRows(1, 2, 1)
  check up.cellAt(0, 0).rune == Rune(ord('0')) and
    up.cellAt(0, 3).rune == Rune(ord('3')), "rows outside the region stay"
  check up.cellAt(0, 1).rune == Rune(ord('2')) and
    up.cellAt(1, 1).rune == Rune(ord('a')), "rows inside move up"
  check up.cellAt(0, 2) == defaultCell(), "the exposed row is blank"
  var down = b
  down.scrollRows(0, 4, -2)
  check down.cellAt(0, 2).rune == Rune(ord('0')) and
    down.cellAt(0, 3).rune == Rune(ord('1')), "rows move down"
  check down.cellAt(0, 0) == defaultCell() and
    down.cellAt(0, 1) == defaultCell(), "exposed top rows are blank"
  var whole = b
  whole.scrollRows(0, 4, 9)
  for y in 0 ..< 4:
    check whole.cellAt(0, y) == defaultCell(), "over-scrolling blanks all rows"
  var untouched = b
  untouched.scrollRows(2, 5, 1)
  check untouched == b, "an out-of-range region is ignored"
  check untouched.checkInvariants, "scrolled buffers keep invariants"

proc testScrollHint =
  var b = initBuffer(4, 4)
  b.hintScroll(initRect(0, 0, 4, 4), 0)
  check b.scrollHint.rows == 0, "a zero move records nothing"
  b.hintScroll(initRect(0, 0, 4, 4), 2)
  check b.scrollHint.rows == 2 and b.scrollHint.region == initRect(0, 0, 4, 4),
    "hint recorded"
  b.hintScroll(initRect(0, 0, 4, 4), 2)
  check b.scrollHint.rows == 2, "an identical hint is idempotent"
  b.hintScroll(initRect(0, 1, 4, 2), 1)
  check b.scrollHint.rows == 0, "a different hint cancels"
  b.hintScroll(initRect(0, 0, 4, 4), 3)
  check b.scrollHint.rows == 0, "the conflict persists for the frame"
  b.reset()
  b.hintScroll(initRect(0, 0, 4, 4), 3)
  check b.scrollHint.rows == 3, "reset clears the conflict"

proc testLinks =
  var b = initBuffer(8, 2)
  let first = b.internLink("https://example.com")
  let again = b.internLink("https://example.com")
  let second = b.internLink("https://other.example")
  check first == 1 and again == 1 and second == 2,
    "links intern once per frame and number from one"
  check b.internLink("") == 0, "an empty URI never links"
  b.writeStr(0, 0, "site")
  b.linkCells(0, 0, 4, first)
  check b.cellAt(0, 0).link == first and b.cellAt(3, 0).link == first and
    b.cellAt(4, 0).link == 0, "linkCells marks exactly the requested cells"
  check b.linkUri(first) == "https://example.com" and b.linkUri(0) == "",
    "linkUri resolves ids and treats zero as no link"
  var other = initBuffer(8, 2)
  discard other.internLink("https://other.example")
  let sameUri = other.internLink("https://example.com")
  other.writeStr(0, 0, "site")
  other.linkCells(0, 0, 4, sameUri)
  check sameCell(b, 0, other, 0),
    "cells compare links by URI even when the ids differ"
  other.linkCells(0, 0, 1, 1)
  check not sameCell(b, 0, other, 0),
    "a different URI makes otherwise equal cells differ"
  b.resize(6, 2)
  check b.linkUri(b.cellAt(0, 0).link) == "https://example.com",
    "resizing keeps links by re-interning their URIs"
  b.writeStr(0, 0, "x")
  check b.cellAt(0, 0).link == 0, "overwriting a cell drops its link"
  b.reset()
  check b.links.len == 0, "reset clears the link table"

proc testImages =
  var b = initBuffer(10, 4)
  b.writeStr(0, 1, "under text")
  b.placeImage(7, 2, 1, 4, 2)
  check b.images.len == 1 and b.images[0].rect == initRect(2, 1, 4, 2) and
    b.images[0].offsetX == 0 and b.images[0].offsetY == 0,
    "a placement inside the buffer keeps its full box"
  check b.cellAt(2, 1) == defaultCell() and b.cellAt(6, 1).rune == Rune('t'),
    "the image box is blanked and cells beside it stay"
  b.placeImage(8, -2, -1, 5, 3)
  check b.images[1].rect == initRect(0, 0, 3, 2) and
    b.images[1].offsetX == 2 and b.images[1].offsetY == 1 and
    b.images[1].cols == 5 and b.images[1].rows == 3,
    "a box cut by the top-left edge records the visible part and offsets"
  b.placeImage(9, 20, 20, 2, 2)
  b.placeImage(0, 0, 0, 2, 2)
  check b.images.len == 2, "boxes outside the buffer and id zero are ignored"
  b.reset()
  check b.images.len == 0, "reset drops placements"

proc main =
  testBasics()
  testResize()
  testScrollRows()
  testScrollHint()
  testLinks()
  testImages()
  testWriteStr()
  testNewline()
  testWideChars()
  testCombining()
  testClearFill()
  testProps()
  echo "buffer ok"

main()
