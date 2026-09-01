import std/unicode
import style
import buffer
import layout
import graphemes
import text

type Frame* = object
  rect*: Rect
  style*: Style
  buf: ptr Buffer

func initFrame*(b: var Buffer, r: Rect, style = styleDefault()): Frame =
  ## Creates a frame scoped to `r` writing into `b`. Coordinates passed to
  ## frame methods are relative to the frame rect and clip silently.
  Frame(rect: r, style: style, buf: addr b)

func sub*(f: Frame, r: Rect, style = styleDefault()): Frame =
  ## Returns a nested frame translated by `f.rect` and clipped to it.
  let abs = Rect(x: f.rect.x + r.x, y: f.rect.y + r.y,
    width: r.width, height: r.height)
  let clipped = intersection(abs, f.rect)
  initFrame(f.buf[], clipped, style)

proc write*(f: Frame, x, y: int, s: string, style: Style,
    policy = plainTextPolicy()) =
  ## Sanitizes and writes `s` at frame-relative coordinates.
  let safe = sanitizeText(s, policy)
  var cx = x
  var cy = y
  for cluster in safe.graphemes:
    if cluster == "\n":
      inc cy
      cx = x
      continue
    let w = cluster.clusterWidth
    if w == 0:
      continue
    if cy < 0 or cy >= f.rect.height:
      inc cx, w
      continue
    if cx < 0 or cx + w > f.rect.width:
      inc cx, w
      continue
    let gx = f.rect.x + cx
    let gy = f.rect.y + cy
    discard f.buf[].writeCluster(gx, gy, cluster, style)
    inc cx, w

proc write*(f: Frame, x, y: int, s: string) =
  ## Writes `s` using the frame's base style.
  f.write(x, y, s, f.style)

proc write*(f: Frame, x, y: int, value: Text) =
  ## Renders versioned rich text, preserving explicit logical lines.
  var cy = y
  for line in value.lines:
    var cx = x
    for span in line.spans:
      let safe = sanitizeText(span.text)
      for cluster in safe.graphemes:
        let width = cluster.clusterWidth(f.buf[].widthPolicy)
        if cy >= 0 and cy < f.rect.height and cx >= 0 and
            cx + width <= f.rect.width:
          discard f.buf[].writeCluster(f.rect.x + cx, f.rect.y + cy,
            cluster, span.style)
        inc cx, width
    inc cy
    if cy >= f.rect.height:
      break

proc fill*(f: Frame, r: Rect, rune: Rune, style: Style) =
  ## Fills the frame-relative rect with the rune.
  let abs = Rect(x: f.rect.x + r.x, y: f.rect.y + r.y,
    width: r.width, height: r.height)
  let clipped = intersection(abs, f.rect)
  if not clipped.isEmpty:
    f.buf[].fill(clipped, rune, style)

proc tint*(f: Frame, r: Rect, style: Style) =
  ## Restyles cells in the frame-relative rect without changing glyphs.
  let abs = Rect(x: f.rect.x + r.x, y: f.rect.y + r.y,
    width: r.width, height: r.height)
  f.buf[].restyle(abs, style)

proc clear*(f: Frame, r: Rect, style = styleDefault()) =
  ## Clears the frame-relative rect to blank cells.
  f.fill(r, Rune(0x0020), style)

proc clearAll*(f: Frame) =
  ## Clears the whole frame.
  f.clear(initRect(0, 0, f.rect.width, f.rect.height))
