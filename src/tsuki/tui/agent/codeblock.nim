## Safe, scrollable code-block view with optional host highlighting.

import std/strutils
import ../[geometry, graphemes, render, scroll, text]
import ../widgets/display
import theme

type
  CodeHighlighter* = proc (line, language: string): Text {.closure.}

  CodeBlockState* = object
    scroll*: ScrollState
    wrap*: bool
    showLineNumbers*: bool

func sliceCells(value: string, offset, width: int): string =
  var skipped = 0
  var used = 0
  for cluster in value.graphemes:
    let cells = cluster.clusterWidth
    if skipped + cells <= offset:
      inc skipped, cells
    elif used + cells <= width:
      result.add cluster
      inc used, cells
    else:
      break

proc codeBlock*(frame: Frame, source: string, language = "",
    state: var CodeBlockState, highlighter: CodeHighlighter = nil,
    colors = agentTheme()) =
  ## Renders safe source with a language label, line numbers, wrapping or
  ## horizontal scrolling. Copying remains an explicit host action.
  if frame.rect.isEmpty: return
  let safe = sanitizeText(source)
  let lines = safe.splitLines
  let numberWidth = if state.showLineNumbers: max(2, ($max(1, lines.len)).len) + 2
    else: 0
  let bodyWidth = max(1, frame.rect.width - numberWidth)
  if language.len > 0:
    frame.write(0, 0, ("Code · " & sanitizeText(language))
      .truncateCells(frame.rect.width, true), colors.base.muted)
  let headerHeight = if language.len > 0: 1 else: 0
  var maxWidth = 0
  for line in lines: maxWidth = max(maxWidth, line.cellWidth)
  state.scroll.update(bodyWidth, max(0, frame.rect.height - headerHeight),
    if state.wrap: bodyWidth else: maxWidth, lines.len)
  let first = state.scroll.offsetY
  let last = min(lines.len, first + state.scroll.viewportHeight)
  for lineIndex in first ..< last:
    let y = headerHeight + lineIndex - first
    if state.showLineNumbers:
      frame.write(0, y, align($(lineIndex + 1), numberWidth - 2) & " │",
        colors.lineNumber)
    let shown = if state.wrap: lines[lineIndex].truncateCells(bodyWidth, false)
      else: lines[lineIndex].sliceCells(state.scroll.offsetX, bodyWidth)
    if highlighter.isNil:
      frame.write(numberWidth, y, shown, colors.base.code)
    else:
      let rich = highlighter(shown, language)
      let child = frame.sub(rect(numberWidth, y, bodyWidth, 1))
      child.richText(rich, wrap = false)

