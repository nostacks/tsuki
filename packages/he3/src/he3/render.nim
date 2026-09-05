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

func widthPolicy*(f: Frame): WidthPolicy {.inline.} =
  ## Returns the width policy of the underlying buffer.
  f.buf[].widthPolicy

proc writeSafe(f: Frame, x, y: int, safe: openArray[char], style: Style) =
  let policy = f.buf[].widthPolicy
  var cx = x
  var cy = y
  for span in safe.graphemeSpans:
    if span.len == 1 and safe[span.a] == '\n':
      inc cy
      cx = x
      continue
    if cy < 0 or cy >= f.rect.height:
      continue
    let w = clusterWidth(safe.toOpenArray(span.a, span.b), policy)
    if w == 0:
      continue
    if cx >= 0 and cx + w <= f.rect.width:
      discard f.buf[].writeCluster(f.rect.x + cx, f.rect.y + cy,
        safe.toOpenArray(span.a, span.b), w, style)
    inc cx, w

proc write*(f: Frame, x, y: int, s: string, style: Style,
    policy = plainTextPolicy()) =
  ## Sanitizes and writes `s` at frame-relative coordinates.
  if y >= f.rect.height or f.rect.isEmpty:
    return
  if s.isSanitized(policy):
    f.writeSafe(x, y, s.toOpenArray(0, s.len - 1), style)
  else:
    let safe = sanitizeText(s, policy)
    f.writeSafe(x, y, safe.toOpenArray(0, safe.len - 1), style)

proc write*(f: Frame, x, y: int, s: string) =
  ## Writes `s` using the frame's base style.
  f.write(x, y, s, f.style)

proc write*(f: Frame, x, y: int, value: Text) =
  ## Renders versioned rich text, preserving explicit logical lines.
  let policy = f.buf[].widthPolicy
  var cy = y
  for line in value.lines:
    if cy >= f.rect.height:
      break
    var cx = x
    if cy >= 0:
      for span in line.spans:
        template render(safe: openArray[char]) =
          for cluster in safe.graphemeSpans:
            let width = clusterWidth(safe.toOpenArray(cluster.a, cluster.b),
              policy)
            if cx >= 0 and cx + width <= f.rect.width:
              discard f.buf[].writeCluster(f.rect.x + cx, f.rect.y + cy,
                safe.toOpenArray(cluster.a, cluster.b), width, span.style)
            inc cx, width
        if span.text.isSanitized:
          render(span.text.toOpenArray(0, span.text.len - 1))
        else:
          let safe = sanitizeText(span.text)
          render(safe.toOpenArray(0, safe.len - 1))
    inc cy

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
  f.buf[].restyle(intersection(abs, f.rect), style)

proc clear*(f: Frame, r: Rect, style = styleDefault()) =
  ## Clears the frame-relative rect to blank cells.
  f.fill(r, Rune(0x0020), style)

proc clearAll*(f: Frame) =
  ## Clears the whole frame.
  f.clear(initRect(0, 0, f.rect.width, f.rect.height))
