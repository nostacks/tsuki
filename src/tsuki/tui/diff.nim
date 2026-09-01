import std/unicode
import style
import buffer
import private/writer
import private/ansi

func isBlank(cell: Cell): bool {.inline.} =
  cell.rune == Rune(0x0020) and cell.glyphLen == 0 and
    not cell.wideTail and cell.style == styleDefault()

proc diffInto*(prev, next: var Buffer, w: var Out) =
  ## Emits the minimal byte stream turning the `prev` frame into `next`:
  ## one cursor move per changed run, style changes inline, trailing blank
  ## runs collapsed into erase-to-end-of-line.
  let def = styleDefault()
  w.frame.setLen 0
  var cur = w.curStyle
  var haveCur = w.curValid
  let wd = min(prev.width, next.width)
  let h = min(prev.height, next.height)
  for y in 0 ..< next.height:
    if y < h and prev.width == next.width and
        prev.rowFingerprint(y) == next.rowFingerprint(y):
      continue
    var x = 0
    while x < next.width:
      if y < h and x < wd and
          prev.sameCell(y * prev.width + x, next, y * next.width + x):
        inc x
        continue
      w.frame.addCursorMove(y + 1, x + 1)
      while x < next.width:
        let c = next.cells[y * next.width + x]
        if y < h and x < wd and
            prev.sameCell(y * prev.width + x, next, y * next.width + x):
          break
        var trailing = 0
        while trailing < next.width - x and
            next.cells[y * next.width +
              (next.width - 1 - trailing)].isBlank:
          inc trailing
        if trailing == next.width - x:
          if cur != def:
            w.frame.addSeq "\x1b[0m"
            cur = def
          w.frame.addSeq "\x1b[K"
          x = next.width
          break
        if c.wideTail:
          inc x
          continue
        if not haveCur or c.style != cur:
          w.frame.addSeq styleDiffToSeq(c.style, w.truecolor)
          cur = c.style
          haveCur = true
        w.frame.appendGlyphBytes(next, c)
        inc x, max(1, c.cellWidth)
  w.curStyle = cur
  w.curValid = true
  w.write w.frame
