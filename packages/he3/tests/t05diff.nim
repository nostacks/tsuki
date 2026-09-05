import std/[random, strutils, unicode]
import common
import he3/style
import he3/buffer
import he3/graphemes
import he3/private/writer
import he3/diff

type Sim = object
  buf: Buffer
  cx: int
  cy: int
  cur: Style

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

proc feed(s: var Sim, data: string) =
  var i = 0
  while i < data.len:
    if data[i] == '\x1b' and i + 1 < data.len and data[i + 1] == '[':
      var j = i + 2
      var params: seq[int] = @[]
      var cur = 0
      var hasNum = false
      while j < data.len and data[j] notin {'m', 'H', 'K', 'A', 'B', 'C', 'D',
          'J'}:
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

proc main =
  testBasicDiff()
  testProperty()
  echo "diff ok"

main()
