import style
import buffer
import private/writer

proc diffInto*(prev, next: var Buffer, w: var Out) =
  ## Emits the minimal byte stream turning the `prev` frame into `next`:
  ## one cursor move per changed run, style changes inline, trailing blank
  ## runs collapsed into an erase-to-end-of-line. An unchanged frame performs
  ## no write at all.
  let def = styleDefault()
  w.beginFrame()
  var cur = w.curStyle
  var haveCur = w.curValid
  let sameWidth = prev.width == next.width
  let wd = min(prev.width, next.width)
  let h = min(prev.height, next.height)
  for y in 0 ..< next.height:
    let comparable = y < h
    if comparable and sameWidth and prev.sameRow(next, y):
      continue
    let contentEnd = next.rowContentEnd(y)
    let prevBase = y * prev.width
    let nextBase = y * next.width
    var x = 0
    while x < next.width:
      if comparable and x < wd and
          prev.sameCell(prevBase + x, next, nextBase + x):
        inc x
        continue
      w.frame.addCursorMove(y + 1, x + 1)
      while x < next.width:
        if comparable and x < wd and
            prev.sameCell(prevBase + x, next, nextBase + x):
          break
        if x >= contentEnd:
          if not haveCur or cur != def:
            w.setStyle(cur, haveCur, def)
          w.frame.addSeq "\x1b[K"
          x = next.width
          break
        let c = next.cells[nextBase + x]
        if c.wideTail:
          inc x
          continue
        if not haveCur or c.style != cur:
          w.setStyle(cur, haveCur, c.style)
        w.frame.appendGlyphBytes(next, c)
        inc x, max(1, c.cellWidth)
  w.curStyle = cur
  w.curValid = true
  w.endFrame()
