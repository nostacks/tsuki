import style
import buffer
import layout
import private/writer

func outsideRegionBlank(b: Buffer, region: Rect): bool =
  for y in region.y ..< region.y + region.height:
    let base = y * b.width
    for x in 0 ..< region.x:
      if not b.cells[base + x].isBlank:
        return false
    for x in region.x + region.width ..< b.width:
      if not b.cells[base + x].isBlank:
        return false
  true

proc applyScrollHint(prev, next: var Buffer, w: var Out, cur: var Style,
    haveCur: var bool) =
  ## Scrolls the hinted rows on the terminal and mirrors the move in `prev`
  ## so the following diff only repaints what the scroll did not cover.
  ## Only full-width row moves exist in the terminal, so the hint applies
  ## when the columns beside the region are blank in the new frame.
  let hint = next.scrollHint
  next.scrollHint = ScrollHint()
  if hint.rows == 0 or not w.scrollRegions:
    return
  if prev.width != next.width or prev.height != next.height:
    return
  let region = intersection(hint.region,
    initRect(0, 0, next.width, next.height))
  if region.isEmpty or abs(hint.rows) >= region.height:
    return
  if not next.outsideRegionBlank(region):
    return
  let def = styleDefault()
  if not haveCur or cur != def:
    w.setStyle(cur, haveCur, def)
  w.frame.addScrollRegion(region.y + 1, region.y + region.height, hint.rows)
  prev.scrollRows(region.y, region.height, hint.rows)
  w.invalidateImages(region)

proc diffInto*(prev, next: var Buffer, w: var Out) =
  ## Emits the minimal byte stream turning the `prev` frame into `next`:
  ## one cursor move per changed run, style changes inline, trailing blank
  ## runs collapsed into an erase-to-end-of-line. An unchanged frame performs
  ## no write at all. A scroll hint on `next` may move rows with a terminal
  ## scroll first when the output sink allows scroll regions. Hyperlinks and
  ## image placements follow the cells when the sink advertises them.
  let def = styleDefault()
  w.beginFrame()
  var cur = w.curStyle
  var haveCur = w.curValid
  applyScrollHint(prev, next, w, cur, haveCur)
  w.removeStaleImages(prev, next.images)
  let sameWidth = prev.width == next.width
  let wd = min(prev.width, next.width)
  let h = min(prev.height, next.height)
  for y in 0 ..< next.height:
    let comparable = y < h
    let contentEnd = next.rowContentEnd(y)
    let prevBase = y * prev.width
    let nextBase = y * next.width
    var x = 0
    if comparable and sameWidth:
      x = prev.firstDifference(next, y)
      if x >= next.width:
        continue
    while x < next.width:
      if comparable and x < wd and sameCellUnchecked(prev,
          prev.cells[prevBase + x], next, next.cells[nextBase + x]):
        inc x
        continue
      w.frame.addCursorMove(y + 1, x + 1)
      while x < next.width:
        if comparable and x < wd and sameCellUnchecked(prev,
            prev.cells[prevBase + x], next, next.cells[nextBase + x]):
          break
        if x >= contentEnd:
          if not haveCur or cur != def:
            w.setStyle(cur, haveCur, def)
          w.closeLink()
          w.frame.addSeq "\x1b[K"
          x = next.width
          break
        let c = next.cells[nextBase + x]
        if c.wideTail:
          inc x
          continue
        if not haveCur or c.style != cur:
          w.setStyle(cur, haveCur, c.style)
        if c.link != 0 or w.hasOpenLink:
          w.setLink(next, c.link)
        w.frame.appendGlyphBytes(next, c)
        inc x, max(1, c.cellWidth)
  w.closeLink()
  w.placeImages(next.images)
  w.curStyle = cur
  w.curValid = true
  w.endFrame()
