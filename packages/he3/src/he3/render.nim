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

proc writeRun(f: Frame, x, y: int, run: openArray[char], style: Style) =
  ## Writes a printable ASCII run clipped to the frame.
  if y < 0 or y >= f.rect.height:
    return
  let first = max(0, x)
  let last = min(f.rect.width, x + run.len)
  if first >= last:
    return
  f.buf[].writeAsciiRun(f.rect.x + first, f.rect.y + y,
    run.toOpenArray(first - x, last - 1 - x), style)

proc writeSafe(f: Frame, x, y: int, safe: openArray[char], style: Style) =
  let policy = f.buf[].widthPolicy
  let asciiFast = policy.resolver.isNil
  var cx = x
  var cy = y
  for run in safe.textRuns:
    if run.ascii:
      if asciiFast:
        f.writeRun(cx, cy, safe.toOpenArray(run.a, run.b), style)
        inc cx, run.b - run.a + 1
      else:
        for index in run.a .. run.b:
          let w = clusterWidth(safe.toOpenArray(index, index), policy)
          if w > 0 and cy >= 0 and cy < f.rect.height and cx >= 0 and
              cx + w <= f.rect.width:
            discard f.buf[].writeCluster(f.rect.x + cx, f.rect.y + cy,
              safe.toOpenArray(index, index), w, style)
          inc cx, w
      continue
    if run.a == run.b and safe[run.a] == '\n':
      inc cy
      cx = x
      continue
    if cy < 0 or cy >= f.rect.height:
      continue
    let w = clusterWidth(safe.toOpenArray(run.a, run.b), policy)
    if w == 0:
      continue
    if cx >= 0 and cx + w <= f.rect.width:
      discard f.buf[].writeCluster(f.rect.x + cx, f.rect.y + cy,
        safe.toOpenArray(run.a, run.b), w, style)
    inc cx, w

func toStr(value: openArray[char]): string =
  result = newString(value.len)
  for index, ch in value:
    result[index] = ch

proc write*(f: Frame, x, y: int, s: openArray[char], style: Style,
    policy = plainTextPolicy()) =
  ## Sanitizes and writes a byte range at frame-relative coordinates without
  ## copying already-safe text.
  if y >= f.rect.height or f.rect.isEmpty or s.len == 0:
    return
  if s.isSanitized(policy):
    f.writeSafe(x, y, s, style)
  else:
    let safe = sanitizeText(s.toStr, policy)
    f.writeSafe(x, y, safe.toOpenArray(0, safe.len - 1), style)

proc write*(f: Frame, x, y: int, s: string, style: Style,
    policy = plainTextPolicy()) =
  ## Sanitizes and writes `s` at frame-relative coordinates.
  f.write(x, y, s.toOpenArray(0, s.len - 1), style, policy)

proc writeCluster*(f: Frame, x, y: int, cluster: openArray[char],
    width: int, style: Style) =
  ## Writes one grapheme cluster that the caller has already segmented and
  ## measured with `clusterWidth`, clipping to the frame. Control characters
  ## and unsafe scalars are dropped, so untrusted text stays safe without a
  ## second segmentation pass.
  if width <= 0 or y < 0 or y >= f.rect.height or x < 0 or
      x + width > f.rect.width or cluster.len == 0:
    return
  if cluster.len == 1 and uint8(cluster[0]) < 0x80'u8:
    if width == 1 and cluster[0] >= ' ' and cluster[0] < '\x7F':
      f.buf[].writeAscii(f.rect.x + x, f.rect.y + y, cluster[0], style)
    return
  if not cluster.isSanitized:
    return
  discard f.buf[].writeCluster(f.rect.x + x, f.rect.y + y, cluster, width,
    style)

proc writeAsciiRun*(f: Frame, x, y: int, run: openArray[char],
    style: Style) =
  ## Writes bytes the caller has verified to be printable ASCII, one cell
  ## each, clipped to the frame. Any other byte in `run` is dropped.
  var start = 0
  for index in 0 .. run.len:
    if index < run.len and run[index] >= ' ' and run[index] < '\x7F':
      continue
    if index > start:
      f.writeRun(x + start, y, run.toOpenArray(start, index - 1), style)
    start = index + 1

proc hintScroll*(f: Frame, rows: int) =
  ## Tells the renderer that this frame's rows moved by `rows` since the last
  ## frame (positive is up), so the terminal may scroll instead of repainting.
  f.buf[].hintScroll(f.rect, rows)

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
