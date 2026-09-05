import std/strutils
import ../graphemes
import ../render

func wordWidth(word: string): int =
  for cluster in word.graphemes:
    result += cluster.clusterWidth

func wrapLine(rows: var seq[string], line: string, width: int) =
  var cur = ""
  var curW = 0
  var sawWord = false
  for word in line.split(' '):
    if word.len == 0:
      continue
    sawWord = true
    let ww = wordWidth(word)
    if curW > 0 and curW + 1 + ww <= width:
      cur.add ' '
      cur.add word
      inc curW, 1 + ww
      continue
    if curW > 0:
      rows.add cur
      cur = ""
      curW = 0
    for cluster in word.graphemes:
      let w = cluster.clusterWidth
      if curW + w > width:
        if curW > 0:
          rows.add cur
          cur = ""
          curW = 0
        if w > width:
          continue
      cur.add cluster
      inc curW, w
  if cur.len > 0:
    rows.add cur
  elif not sawWord:
    rows.add ""

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
    let lines = text.split('\n')
    var y = 0
    for i in sc ..< min(lines.len, sc + f.rect.height):
      f.write(0, y, lines[i])
      inc y
    return
  var rows: seq[string]
  for line in text.split('\n'):
    wrapLine(rows, line, f.rect.width)
  let avail = rows.len - sc
  if avail <= 0:
    return
  let start = max(0, avail - f.rect.height)
  for i in start ..< avail:
    f.write(0, i - start, rows[i])
