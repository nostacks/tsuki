import common
import std/unicode
import he3/layout
import he3/buffer
import he3/style
import he3/render
import he3/widgets/border

proc testBasicBox =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.border()
  check b.cellAt(0, 0).rune == Rune(0x250C), "top-left corner"
  check b.cellAt(9, 0).rune == Rune(0x2510), "top-right corner"
  check b.cellAt(0, 3).rune == Rune(0x2514), "bottom-left corner"
  check b.cellAt(9, 3).rune == Rune(0x2518), "bottom-right corner"
  for x in 1 ..< 9:
    check b.cellAt(x, 0).rune == Rune(0x2500), "top edge"
    check b.cellAt(x, 3).rune == Rune(0x2500), "bottom edge"
  for y in 1 ..< 3:
    check b.cellAt(0, y).rune == Rune(0x2502), "left edge"
    check b.cellAt(9, y).rune == Rune(0x2502), "right edge"
  for y in 1 ..< 3:
    for x in 1 ..< 9:
      check b.cellAt(x, y).rune == Rune(0x0020), "interior untouched"
  for y in 0 ..< 4:
    for x in 0 ..< 10:
      check b.cellAt(x, y).style == styleDefault(), "default style"

proc testRounded =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.border(rounded = true)
  check b.cellAt(0, 0).rune == Rune(0x256D), "rounded top-left"
  check b.cellAt(9, 0).rune == Rune(0x256E), "rounded top-right"
  check b.cellAt(0, 3).rune == Rune(0x2570), "rounded bottom-left"
  check b.cellAt(9, 3).rune == Rune(0x256F), "rounded bottom-right"
  check b.cellAt(5, 0).rune == Rune(0x2500), "same horizontal rune"
  check b.cellAt(0, 2).rune == Rune(0x2502), "same vertical rune"

proc testTitle =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.border(title = "abc")
  check b.cellAt(2, 0).rune == Rune(ord('a')), "title first char at x=2"
  check b.cellAt(3, 0).rune == Rune(ord('b')), "title second char"
  check b.cellAt(4, 0).rune == Rune(ord('c')), "title third char"
  check b.cellAt(5, 0).rune == Rune(0x2500), "edge after title"
  check b.cellAt(0, 0).rune == Rune(0x250C), "corner kept with title"
  check b.cellAt(9, 0).rune == Rune(0x2510), "corner kept with title 2"

proc testTitleTruncation =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.border(title = "abcdefghij")
  check b.cellAt(2, 0).rune == Rune(ord('a')), "truncation first"
  check b.cellAt(7, 0).rune == Rune(ord('f')), "truncation last kept"
  check b.cellAt(8, 0).rune == Rune(0x2500), "truncation drops g"
  check b.cellAt(9, 0).rune == Rune(0x2510), "truncation keeps corner"

proc testTitleMinWidth =
  var b = initBuffer(5, 4)
  let f = initFrame(b, initRect(0, 0, 5, 4))
  f.border(title = "hi")
  check b.cellAt(2, 0).rune == Rune(0x2500), "no title below width 6"
  var c = initBuffer(6, 4)
  let g = initFrame(c, initRect(0, 0, 6, 4))
  g.border(title = "hi")
  check c.cellAt(2, 0).rune == Rune(ord('h')), "title at min width"
  check c.cellAt(3, 0).rune == Rune(ord('i')), "title at min width 2"
  check c.cellAt(0, 0).rune == Rune(0x250C), "min width corner"

proc testTinyRects =
  var b = initBuffer(4, 4)
  let f = initFrame(b, initRect(0, 0, 1, 1))
  f.border()
  check b.cellAt(0, 0).rune == Rune(0x0020), "1x1 draws nothing"
  var c = initBuffer(4, 4)
  let g = initFrame(c, initRect(0, 0, 2, 2))
  g.border()
  check c.cellAt(0, 0).rune == Rune(0x250C), "2x2 top-left"
  check c.cellAt(1, 0).rune == Rune(0x2510), "2x2 top-right"
  check c.cellAt(0, 1).rune == Rune(0x2514), "2x2 bottom-left"
  check c.cellAt(1, 1).rune == Rune(0x2518), "2x2 bottom-right"
  check c.cellAt(2, 0).rune == Rune(0x0020), "2x2 no writes outside"
  var d = initBuffer(4, 4)
  let e = initFrame(d, initRect(0, 0, 1, 3))
  e.border()
  check d.cellAt(0, 1).rune == Rune(0x0020), "1-wide draws nothing"

proc testCustomStyle =
  let st = fg(named(ncRed)).withAttrs({attrBold})
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.border(st)
  check b.cellAt(0, 0).style == st, "corner style"
  check b.cellAt(5, 0).style == st, "top edge style"
  check b.cellAt(0, 2).style == st, "left edge style"
  check b.cellAt(9, 3).style == st, "bottom-right style"
  f.border(rounded = true, style = st)
  check b.cellAt(5, 3).style == st, "bottom edge style rounded"

proc testFrameOffset =
  var b = initBuffer(14, 7)
  let f = initFrame(b, initRect(2, 1, 10, 4))
  f.border()
  check b.cellAt(2, 1).rune == Rune(0x250C), "offset top-left"
  check b.cellAt(11, 1).rune == Rune(0x2510), "offset top-right"
  check b.cellAt(2, 4).rune == Rune(0x2514), "offset bottom-left"
  check b.cellAt(11, 4).rune == Rune(0x2518), "offset bottom-right"
  check b.cellAt(6, 2).rune == Rune(0x0020), "offset interior blank"
  check b.cellAt(0, 0).rune == Rune(0x0020), "outside frame blank"

proc main =
  testBasicBox()
  testRounded()
  testTitle()
  testTitleTruncation()
  testTitleMinWidth()
  testTinyRects()
  testCustomStyle()
  testFrameOffset()
  echo "border ok"

main()
