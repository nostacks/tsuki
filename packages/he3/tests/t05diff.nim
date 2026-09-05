import std/[random, strutils, unicode]
import common
import he3/style
import he3/buffer
import he3/layout
import he3/graphemes
import he3/private/writer
import he3/diff

type Sim = object
  buf: Buffer
  cx: int
  cy: int
  cur: Style
  top: int
  bottom: int

proc applySgr(s: var Sim, params: seq[int]) =
  let def = styleDefault()
  var i = 0
  while i < params.len:
    let p = params[i]
    case p
    of 0:
      s.cur = def
    of 38, 48:
      if i + 2 < params.len and params[i + 1] == 5:
        let c = indexed(params[i + 2])
        if p == 38: s.cur = s.cur.withFg(c)
        else: s.cur = s.cur.withBg(c)
        inc i, 2
    of 30 .. 37:
      s.cur = s.cur.withFg(named(NamedColor(p - 30)))
    of 90 .. 97:
      s.cur = s.cur.withFg(named(NamedColor(p - 90 + 8)))
    of 40 .. 47:
      s.cur = s.cur.withBg(named(NamedColor(p - 40)))
    of 100 .. 107:
      s.cur = s.cur.withBg(named(NamedColor(p - 100 + 8)))
    of 1: s.cur = s.cur.withAttrs({attrBold})
    of 2: s.cur = s.cur.withAttrs({attrDim})
    of 3: s.cur = s.cur.withAttrs({attrItalic})
    of 4: s.cur = s.cur.withAttrs({attrUnderline})
    of 5: s.cur = s.cur.withAttrs({attrBlink})
    of 7: s.cur = s.cur.withAttrs({attrReverse})
    of 9: s.cur = s.cur.withAttrs({attrStrikethrough})
    of 22: s.cur = s.cur.withoutAttrs({attrBold, attrDim})
    of 23: s.cur = s.cur.withoutAttrs({attrItalic})
    of 24: s.cur = s.cur.withoutAttrs({attrUnderline})
    of 25: s.cur = s.cur.withoutAttrs({attrBlink})
    of 27: s.cur = s.cur.withoutAttrs({attrReverse})
    of 29: s.cur = s.cur.withoutAttrs({attrStrikethrough})
    else: discard
    inc i

proc putRune(s: var Sim, r: Rune) =
  let w = r.runeWidth
  if w == 0:
    return
  if s.cy >= 0 and s.cy < s.buf.height and s.cx >= 0 and s.cx < s.buf.width:
    s.buf.cells[s.cy * s.buf.width + s.cx] = Cell(rune: r, style: s.cur)
    if w == 2 and s.cx + 1 < s.buf.width:
      s.buf.cells[s.cy * s.buf.width + s.cx + 1] =
        Cell(rune: Rune(0), style: s.cur, wideTail: true)
  inc s.cx, w

proc scrollRegion(s: var Sim, rows: int) =
  let bottom = if s.bottom <= 0: s.buf.height - 1 else: s.bottom
  let height = bottom - s.top + 1
  if height <= 0: return
  var region = initBuffer(s.buf.width, height)
  for y in 0 ..< height:
    for x in 0 ..< s.buf.width:
      region.cells[y * s.buf.width + x] =
        s.buf.cells[(s.top + y) * s.buf.width + x]
  region.scrollRows(0, height, rows)
  for y in 0 ..< height:
    for x in 0 ..< s.buf.width:
      s.buf.cells[(s.top + y) * s.buf.width + x] =
        region.cells[y * s.buf.width + x]

proc feed(s: var Sim, data: string) =
  var i = 0
  while i < data.len:
    if data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == '[':
      var j = i + 2
      var params: seq[int] = @[]
      var cur = 0
      var hasNum = false
      while j < data.len and data[j] notin {'m', 'H', 'K', 'A', 'B', 'C', 'D',
          'J', 'r', 'S', 'T'}:
        if data[j] == ';':
          params.add cur
          cur = 0
          hasNum = true
        elif data[j].isDigit:
          cur = cur * 10 + (data[j].ord - '0'.ord)
          hasNum = true
        inc j
      if j >= data.len:
        break
      if hasNum or params.len > 0:
        params.add cur
      case data[j]
      of 'H':
        if params.len >= 2:
          s.cy = params[0] - 1
          s.cx = params[1] - 1
        elif params.len == 1 and params[0] == 0:
          s.cx = 0
          s.cy = 0
        else:
          s.cx = 0
          s.cy = 0
      of 'K':
        for x in s.cx ..< s.buf.width:
          s.buf.cells[s.cy * s.buf.width + x] = Cell(rune: Rune(0x0020))
      of 'm':
        if params.len == 0:
          params.add 0
        s.applySgr(params)
      of 'r':
        if params.len >= 2:
          s.top = params[0] - 1
          s.bottom = params[1] - 1
        else:
          s.top = 0
          s.bottom = 0
        s.cx = 0
        s.cy = 0
      of 'S':
        s.scrollRegion(if params.len >= 1: params[0] else: 1)
      of 'T':
        s.scrollRegion(-(if params.len >= 1: params[0] else: 1))
      else:
        discard
      i = j + 1
    elif data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == 'H':
      s.cx = 0
      s.cy = 0
      i += 2
    else:
      let r = data.runeAtPos(i)
      s.putRune(r)
      i += r.size

proc testBasicDiff =
  var t = initFakeTty()
  var o = t.wr
  var prev = initBuffer(6, 2)
  var next = prev
  next.writeStr(2, 0, "hi", fg(named(ncGreen)))
  diffInto(prev, next, o)
  var sim = Sim(buf: prev, cur: styleDefault())
  sim.feed(cast[string](t.bytes))
  check sim.buf == next, "basic diff replay"
  check sim.cx == 4 and sim.cy == 0, "cursor after run"

proc testProperty =
  randomize(424242)
  for iter in 0 ..< 200:
    let w = rand(3 .. 12)
    let h = rand(2 .. 6)
    var prev = initBuffer(w, h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let r = Rune(ord('a') + rand(0 .. 25))
        let st = if rand(0 .. 2) == 0: fg(named(NamedColor(rand(0 .. 15))))
          else: styleDefault()
        prev.setCell(x, y, Cell(rune: r, style: st))
    var next = initBuffer(w, h)
    let muts = rand(1 .. 8)
    for m in 0 ..< muts:
      let x = rand(0 .. w - 1)
      let y = rand(0 .. h - 1)
      let r = Rune(ord('A') + rand(0 .. 25))
      let st = if rand(0 .. 2) == 0: bg(named(NamedColor(rand(0 .. 15))))
        else: styleDefault()
      next.setCell(x, y, Cell(rune: r, style: st))
    var t1 = initFakeTty()
    var o1 = t1.wr
    o1.flushFull(prev)
    var sim = Sim(buf: prev, cur: styleDefault())
    sim.feed(cast[string](t1.bytes))
    if sim.buf != prev:
      for y in 0 ..< h:
        for x in 0 ..< w:
          let a = sim.buf.cellAt(x, y)
          let b = prev.cellAt(x, y)
          if a != b:
            echo "flush cell ($1,$2) got=$3 fgk=$4 bgk=$5 want=$6 fgk=$7 bgk=$8" % [
              $x, $y, $a.rune, $a.style.fg.kind, $a.style.bg.kind,
              $b.rune, $b.style.fg.kind, $b.style.bg.kind]
      echo "stream: ", strutils.replace($cast[string](t1.bytes), "\x1b", "E")
      check false, "flush replay mismatch at iter " & $iter
    check sim.buf == prev, "flush replay matches prev"
    var t2 = initFakeTty()
    var o2 = t2.wr
    diffInto(prev, next, o2)
    sim.feed(cast[string](t2.bytes))
    if sim.buf != next:
      echo "dstream: ", strutils.replace($cast[string](t2.bytes), "\x1b", "E")
      check false, "diff replay mismatch at iter " & $iter &
        ": got " & $sim.buf.cells & " want " & $next.cells
    check sim.buf == next, "diff replay matches next"

proc rowText(y: int): string =
  repeat(char(ord('a') + y), 10)

proc scrolledPair(offset: int): tuple[prev, next: Buffer] =
  result.prev = initBuffer(12, 6)
  result.next = initBuffer(12, 6)
  for y in 0 ..< 6:
    result.prev.writeStr(0, y, rowText(y), fg(named(ncBlue)))
    result.next.writeStr(0, y, rowText(y + offset), fg(named(ncBlue)))

proc diffBytes(prev, next: Buffer, scrollRegions: bool): seq[byte] =
  var prevCopy = prev
  var nextCopy = next
  var t = initFakeTty()
  var o = t.wr
  o.scrollRegions = scrollRegions
  diffInto(prevCopy, nextCopy, o)
  t.bytes

proc replayMatches(prev, next: Buffer, output: seq[byte]): bool =
  var sim = Sim(buf: prev, cur: styleDefault())
  sim.feed(cast[string](output))
  sim.buf == next

proc testScrollHint =
  block fullWidthScroll:
    var (prev, next) = scrolledPair(2)
    next.hintScroll(initRect(0, 0, 12, 6), 2)
    let plain = diffBytes(prev, next, false)
    let hinted = diffBytes(prev, next, true)
    let text = cast[string](hinted)
    check "\x1b[1;6r\x1b[2S\x1b[r" in text,
      "a full-width hint scrolls the region on the terminal"
    check hinted.len < plain.len, "scrolling beats repainting every row"
    check replayMatches(prev, next, hinted), "scrolled replay matches next"
    check replayMatches(prev, next, plain),
      "a sink without scroll regions ignores the hint"
    check "S" notin cast[string](plain), "no scroll without the capability"
  block partialRegion:
    var (prev, next) = scrolledPair(0)
    next.writeStr(0, 1, rowText(2), fg(named(ncBlue)))
    next.writeStr(0, 2, rowText(3), fg(named(ncBlue)))
    next.writeStr(0, 3, rowText(9), fg(named(ncBlue)))
    next.hintScroll(initRect(0, 1, 12, 3), 1)
    let hinted = diffBytes(prev, next, true)
    check "\x1b[2;4r\x1b[1S\x1b[r" in cast[string](hinted),
      "an inner region scrolls within its own margins"
    check replayMatches(prev, next, hinted), "partial region replay matches"
  block downwardScroll:
    var (prev, next) = scrolledPair(-1)
    next.hintScroll(initRect(0, 0, 12, 6), -1)
    let hinted = diffBytes(prev, next, true)
    check "\x1b[1T" in cast[string](hinted), "negative rows scroll down"
    check replayMatches(prev, next, hinted), "downward replay matches"
  block busyMargin:
    var (prev, next) = scrolledPair(2)
    next.writeStr(11, 0, "|", fg(named(ncRed)))
    next.hintScroll(initRect(0, 0, 10, 6), 2)
    let hinted = diffBytes(prev, next, true)
    check "S" notin cast[string](hinted),
      "content beside the region disables the terminal scroll"
    check replayMatches(prev, next, hinted), "busy margin replay matches"
  block conflictingHints:
    var (prev, next) = scrolledPair(2)
    next.hintScroll(initRect(0, 0, 12, 6), 2)
    next.hintScroll(initRect(0, 0, 12, 3), 1)
    check next.scrollHint.rows == 0, "conflicting hints cancel each other"
    check replayMatches(prev, next, diffBytes(prev, next, true)),
      "cancelled hints still render correctly"
  block consumedHint:
    var (prev, next) = scrolledPair(1)
    next.hintScroll(initRect(0, 0, 12, 6), 1)
    var t = initFakeTty()
    var o = t.wr
    o.scrollRegions = true
    diffInto(prev, next, o)
    check next.scrollHint.rows == 0, "the diff consumes the hint"
    for y in 0 ..< 5:
      check prev.sameRow(next, y), "prev mirrors the scrolled rows"
    check prev.cellAt(0, 5) == defaultCell(),
      "prev mirrors the blank row the terminal exposed"

proc testFirstDifference =
  var a = initBuffer(6, 2)
  var b = a
  check a.firstDifference(b, 0) == 6, "identical rows report the width"
  b.writeStr(3, 1, "x")
  check a.firstDifference(b, 1) == 3, "first changed column is found"
  check a.firstDifference(b, 5) == 0, "invalid rows differ at column zero"
  check a.sameRow(b, 0) and not a.sameRow(b, 1), "sameRow agrees"

proc main =
  testBasicDiff()
  testProperty()
  testScrollHint()
  testFirstDifference()
  echo "diff ok"

main()
