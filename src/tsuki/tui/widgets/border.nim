import std/unicode
import ../graphemes
import ../render
import ../style

proc border*(f: Frame, style = styleDefault(), title = "", rounded = false) =
  ## Draws a single-line box covering the full frame area. When `rounded` is
  ## true the corners use the rounded box-drawing runes. A non-empty `title`
  ## is written on the top edge starting at x=2, truncated to fit between the
  ## corners. Rects smaller than 2x2 draw nothing.
  if f.rect.width < 2 or f.rect.height < 2:
    return
  let tl = if rounded: Rune(0x256D) else: Rune(0x250C)
  let tr = if rounded: Rune(0x256E) else: Rune(0x2510)
  let bl = if rounded: Rune(0x2570) else: Rune(0x2514)
  let br = if rounded: Rune(0x256F) else: Rune(0x2518)
  let hRun = Rune(0x2500)
  let vRun = Rune(0x2502)
  let w = f.rect.width
  let h = f.rect.height
  f.write(0, 0, $tl, style)
  f.write(w - 1, 0, $tr, style)
  f.write(0, h - 1, $bl, style)
  f.write(w - 1, h - 1, $br, style)
  if w > 2:
    var edge = ""
    for i in 1 ..< w - 1:
      edge.add hRun
    f.write(1, 0, edge, style)
    f.write(1, h - 1, edge, style)
  if h > 2:
    for y in 1 ..< h - 1:
      f.write(0, y, $vRun, style)
      f.write(w - 1, y, $vRun, style)
  if title.len > 0 and w >= 6:
    let maxCells = w - 4
    var text = ""
    var used = 0
    for cluster in title.graphemes:
      let cw = cluster.clusterWidth
      if used + cw > maxCells:
        break
      text.add cluster
      used += cw
    if used > 0:
      f.write(2, 0, text, style)
