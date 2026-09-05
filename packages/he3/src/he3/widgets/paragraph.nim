import ../graphemes
import ../render
import ../text

type
  Piece = object
    ## One byte range of the source placed on a wrapped row, preceded by a
    ## single space when `spaced` is set.
    a: int
    b: int
    spaced: bool

  Wrapped = object
    ## Wrapped rows as ranges into a flat piece list; row `i` owns pieces
    ## `rowStarts[i] ..< rowStarts[i + 1]` (or to the end for the last row).
    pieces: seq[Piece]
    rowStarts: seq[int]

func rowCount(wrapped: Wrapped): int {.inline.} =
  wrapped.rowStarts.len

func rowEnd(wrapped: Wrapped, row: int): int {.inline.} =
  if row + 1 < wrapped.rowStarts.len: wrapped.rowStarts[row + 1]
  else: wrapped.pieces.len

func wrapLine(wrapped: var Wrapped, text: openArray[char], lineA, lineB: int,
    width: int) =
  var curW = 0
  var curLen = 0
  var sawWord = false
  wrapped.rowStarts.add wrapped.pieces.len
  template newRow() =
    wrapped.rowStarts.add wrapped.pieces.len
    curW = 0
    curLen = 0
  var i = lineA
  while i < lineB:
    if text[i] == ' ':
      inc i
      continue
    var j = i
    while j < lineB and text[j] != ' ':
      inc j
    sawWord = true
    let ww = textWidth(text.toOpenArray(i, j - 1))
    if curW > 0 and curW + 1 + ww <= width:
      wrapped.pieces.add Piece(a: i, b: j - 1, spaced: true)
      inc curW, 1 + ww
      inc curLen, 1 + j - i
      i = j
      continue
    if curW > 0:
      newRow()
    for cluster in text.toOpenArray(i, j - 1).graphemeSpans:
      let a = i + cluster.a
      let b = i + cluster.b
      let w = clusterWidth(text.toOpenArray(a, b))
      if curW + w > width:
        if curW > 0:
          newRow()
        if w > width:
          continue
      if curLen > 0 and wrapped.pieces.len > wrapped.rowStarts[^1] and
          wrapped.pieces[^1].b + 1 == a:
        wrapped.pieces[^1].b = b
      else:
        wrapped.pieces.add Piece(a: a, b: b)
      inc curW, w
      inc curLen, b - a + 1
    i = j
  if curLen == 0 and sawWord:
    wrapped.rowStarts.setLen(wrapped.rowStarts.len - 1)

proc paragraph*(f: Frame, text: string, scroll = 0, wrap = true) =
  ## Renders `text` into `f.rect` with greedy word wrapping. When `wrap` is
  ## true, lines break at spaces to fit the rect width, words wider than the
  ## rect are hard split at cell boundaries with grapheme clusters kept
  ## atomic, and runs of consecutive spaces collapse to one; `scroll` hides
  ## the last `scroll` wrapped lines so `scroll = 0` shows the bottom. When
  ## `wrap` is false, each explicit newline separated logical line is kept
  ## verbatim and `scroll` skips the first `scroll` lines. Output clips at
  ## the frame edges without ellipsis or scrollbar.
  if f.rect.width <= 0 or f.rect.height <= 0:
    return
  let sc = max(0, scroll)
  if not wrap:
    var y = 0
    var lineIndex = 0
    var lineA = 0
    while lineA <= text.len and y < f.rect.height:
      var lineB = lineA
      while lineB < text.len and text[lineB] != '\n':
        inc lineB
      if lineIndex >= sc:
        f.write(0, y, text.toOpenArray(lineA, lineB - 1), f.style)
        inc y
      inc lineIndex
      lineA = lineB + 1
    return
  var wrapped: Wrapped
  var lineA = 0
  while lineA <= text.len:
    var lineB = lineA
    while lineB < text.len and text[lineB] != '\n':
      inc lineB
    wrapped.wrapLine(text, lineA, lineB, f.rect.width)
    lineA = lineB + 1
  let avail = wrapped.rowCount - sc
  if avail <= 0:
    return
  let start = max(0, avail - f.rect.height)
  var rowText = ""
  for row in start ..< avail:
    rowText.setLen 0
    for index in wrapped.rowStarts[row] ..< wrapped.rowEnd(row):
      let piece = wrapped.pieces[index]
      if piece.spaced:
        rowText.add ' '
      rowText.addChars text.toOpenArray(piece.a, piece.b)
    f.write(0, row - start, rowText)
