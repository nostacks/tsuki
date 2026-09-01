import std/[random, strutils, unicode]
import common
import tsuki/tui/layout
import tsuki/tui/graphemes
import tsuki/tui/buffer
import tsuki/tui/render
import tsuki/tui/widgets/paragraph

func rowText(b: Buffer, r: Rect, y: int): string =
  for x in r.x ..< r.x + r.width:
    let c = b.cellAt(x, y)
    if c.wideTail:
      continue
    result.add $c.rune

proc refWrap(text: string, width: int): seq[string] =
  for line in text.split('\n'):
    var cur = ""
    var curW = 0
    var sawWord = false
    for word in line.split(' '):
      if word.len == 0:
        continue
      sawWord = true
      var ww = 0
      for cl in word.graphemes:
        ww += cl.clusterWidth
      if curW > 0 and curW + 1 + ww <= width:
        cur.add ' '
        cur.add word
        inc curW, 1 + ww
        continue
      if curW > 0:
        result.add cur
        cur = ""
        curW = 0
      for cl in word.graphemes:
        let w = cl.clusterWidth
        if curW + w > width:
          if curW > 0:
            result.add cur
            cur = ""
            curW = 0
          if w > width:
            continue
        cur.add cl
        inc curW, w
    if cur.len > 0:
      result.add cur
    elif not sawWord:
      result.add ""

proc testCjkMix =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 7, 2))
  f.paragraph("你好世界 test")
  check b.cellAt(0, 0).rune == Rune(0x4F60), "ni base"
  check b.cellAt(1, 0).wideTail, "ni tail"
  check b.cellAt(2, 0).rune == Rune(0x597D), "hao base"
  check b.cellAt(3, 0).wideTail, "hao tail"
  check b.cellAt(4, 0).rune == Rune(0x4E16), "shi base row0"
  check b.cellAt(6, 0).rune == Rune(0x0020), "row0 pad"
  check b.cellAt(0, 1).rune == Rune(0x754C), "jie base row1"
  check b.cellAt(1, 1).wideTail, "jie tail row1"
  check b.cellAt(2, 1).rune == Rune(0x0020), "row1 space"
  check b.cellAt(3, 1).rune == Rune(ord('t')), "row1 t"
  check b.cellAt(6, 1).rune == Rune(ord('t')), "row1 last t"
  check b.cellAt(0, 2).rune == Rune(0x0020), "nothing row2"

proc testEmojiAtomic =
  var b = initBuffer(10, 4)
  let f = initFrame(b, initRect(0, 0, 5, 2))
  let grinning = $Rune(0x1F600)
  f.paragraph("a " & grinning & " b")
  check b.cellAt(0, 0).rune == Rune(ord('a')), "a first"
  check b.cellAt(1, 0).rune == Rune(0x0020), "space after a"
  check b.cellAt(2, 0).rune == Rune(0x1F600), "emoji base"
  check b.cellAt(3, 0).wideTail, "emoji tail same row"
  check b.cellAt(4, 0).rune == Rune(0x0020), "row0 pad"
  check b.cellAt(0, 1).rune == Rune(ord('b')), "b wrapped to row1"
  var n = initBuffer(10, 4)
  let g = initFrame(n, initRect(0, 0, 4, 2))
  g.paragraph("aa " & grinning)
  check n.cellAt(0, 0).rune == Rune(ord('a')), "aa row0"
  check n.cellAt(1, 0).rune == Rune(ord('a')), "aa row0 second"
  check n.cellAt(2, 0).rune == Rune(0x0020), "no emoji on row0"
  check n.cellAt(0, 1).rune == Rune(0x1F600), "emoji moved whole to row1"
  check n.cellAt(1, 1).wideTail, "emoji tail row1"

proc testNewlines =
  var b = initBuffer(10, 5)
  let f = initFrame(b, initRect(0, 0, 10, 4))
  f.paragraph("ab\ncd\n\nef")
  check b.cellAt(0, 0).rune == Rune(ord('a')), "line1"
  check b.cellAt(1, 0).rune == Rune(ord('b')), "line1 b"
  check b.cellAt(0, 1).rune == Rune(ord('c')), "line2"
  for x in 0 ..< 10:
    check b.cellAt(x, 2).rune == Rune(0x0020), "blank line preserved"
  check b.cellAt(0, 3).rune == Rune(ord('e')), "line4"

proc testScrollBottom =
  var b = initBuffer(10, 6)
  let f = initFrame(b, initRect(0, 0, 5, 2))
  f.paragraph("one two three four")
  check rowText(b, initRect(0, 0, 5, 2), 0).strip == "three",
    "scroll0 shows three"
  check rowText(b, initRect(0, 0, 5, 2), 1).strip == "four",
    "scroll0 shows four"
  var c = initBuffer(10, 6)
  let g = initFrame(c, initRect(0, 0, 5, 2))
  g.paragraph("one two three four", 1)
  check rowText(c, initRect(0, 0, 5, 2), 0).strip == "two",
    "scroll1 hides last line"
  check rowText(c, initRect(0, 0, 5, 2), 1).strip == "three",
    "scroll1 second row"
  var d = initBuffer(10, 6)
  let h = initFrame(d, initRect(0, 0, 5, 2))
  h.paragraph("one two three four", 99)
  for y in 0 ..< 6:
    for x in 0 ..< 10:
      check d.cellAt(x, y).rune == Rune(0x0020), "scroll past end blank"

proc testScrollTopNoWrap =
  var b = initBuffer(10, 6)
  let f = initFrame(b, initRect(0, 0, 8, 2))
  f.paragraph("l1\nl2\nl3\nl4", 1, false)
  check rowText(b, initRect(0, 0, 8, 2), 0).strip == "l2",
    "nowrap scroll1 skips first line"
  check rowText(b, initRect(0, 0, 8, 2), 1).strip == "l3",
    "nowrap scroll1 second"
  var c = initBuffer(10, 6)
  let g = initFrame(c, initRect(0, 0, 8, 2))
  g.paragraph("l1\nl2\nl3\nl4", 0, false)
  check rowText(c, initRect(0, 0, 8, 2), 0).strip == "l1", "nowrap scroll0 first"
  check rowText(c, initRect(0, 0, 8, 2), 1).strip == "l2", "nowrap scroll0 second"
  var d = initBuffer(12, 4)
  let h = initFrame(d, initRect(0, 0, 6, 3))
  h.paragraph("a long line stays verbatim", 0, false)
  check rowText(d, initRect(0, 0, 6, 3), 0) == "a long", "nowrap clips verbatim"
  check rowText(d, initRect(0, 0, 6, 3), 1).strip == "", "nowrap row1 blank"

proc testHardSplit =
  var b = initBuffer(10, 6)
  let f = initFrame(b, initRect(0, 0, 4, 3))
  f.paragraph("abcdefghij")
  check rowText(b, initRect(0, 0, 4, 3), 0) == "abcd", "split row0"
  check rowText(b, initRect(0, 0, 4, 3), 1) == "efgh", "split row1"
  check rowText(b, initRect(0, 0, 4, 3), 2).strip == "ij", "split row2"
  var c = initBuffer(10, 6)
  let g = initFrame(c, initRect(0, 0, 3, 2))
  g.paragraph("你好世界")
  check rowText(c, initRect(0, 0, 3, 2), 0).strip == "世",
    "wide split scroll0 row0"
  check rowText(c, initRect(0, 0, 3, 2), 1).strip == "界",
    "wide split scroll0 row1"

proc testProps =
  randomize(20260828)
  for iter in 0 ..< 200:
    var b = initBuffer(40, 20)
    let before = b.cells
    let w = rand(3 .. 30)
    let h = rand(1 .. 8)
    let x = rand(0 .. 40 - w)
    let y = rand(0 .. 20 - h)
    let r = initRect(x, y, w, h)
    var text = ""
    let nLines = rand(1 .. 4)
    for li in 0 ..< nLines:
      if li > 0:
        text.add '\n'
      let nWords = rand(0 .. 6)
      for wi in 0 ..< nWords:
        if wi > 0:
          text.add ' '
        let nCh = rand(1 .. 8)
        for ci in 0 ..< nCh:
          text.add chr(ord('a') + rand(0 .. 25))
    let f = initFrame(b, r)
    let scroll = rand(0 .. 12)
    f.paragraph(text, scroll)
    for yy in 0 ..< 20:
      for xx in 0 ..< 40:
        if r.contains(xx, yy):
          continue
        check b.cells[yy * 40 + xx] == before[yy * 40 + xx],
          "no writes outside rect"
    if scroll != 0:
      continue
    let refRows = refWrap(text, w)
    let count = min(h, refRows.len)
    for i in 0 ..< count:
      let want = refRows[refRows.len - count + i]
      let got = rowText(b, r, y + i)
      check got.strip == want, "wrap scroll0 bottom row match"
    for i in count ..< h:
      for xx in r.x ..< r.x + r.width:
        check b.cellAt(xx, y + i).rune == Rune(0x0020), "rows below blank"

proc main =
  testCjkMix()
  testEmojiAtomic()
  testNewlines()
  testScrollBottom()
  testScrollTopNoWrap()
  testHardSplit()
  testProps()
  echo "paragraph ok"

main()
