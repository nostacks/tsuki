## Tool lifecycle card with bounded, explicitly safe output.

import std/strutils
import ../[ansi_text, geometry, render, style, text]
import ../widgets/display
import model, theme

func toolCue*(status: ToolStatus): string =
  ## Returns a redundant non-color lifecycle cue.
  case status
  of toolPending: "○"
  of toolRunning: "◌"
  of toolSuccess: "✓"
  of toolError: "×"
  of toolCancelled: "–"

proc toolStatusStyle*(status: ToolStatus, colors: AgentTheme): Style =
  ## Lifecycle hue applied only to the actual state, never to tool identity.
  case status
  of toolPending, toolRunning: colors.base.warning
  of toolSuccess: colors.base.success
  of toolError: colors.base.error
  of toolCancelled: colors.base.muted

proc writeToolHeader*(frame: Frame, x, y: int, item: TranscriptItem,
    colors = agentTheme()) =
  ## Draws the one-row tool lifecycle header shared by the tool card and the
  ## transcript: state cue, name, detail, and a disclosure arrow when the
  ## output is collapsible.
  let statusStyle = toolStatusStyle(item.status, colors)
  var cx = x
  template put(value: string, style: Style) =
    if cx < frame.rect.width:
      frame.write(cx, y, value.truncateCells(max(0, frame.rect.width - cx),
        true), style)
    inc cx, value.cellWidth
  put item.status.toolCue, statusStyle
  put " ", colors.base.muted
  if item.background:
    put "background · ", colors.base.muted
  put item.title, colors.base.muted
  if item.detail.len > 0:
    put " · ", colors.base.muted
    put item.detail, colors.base.muted
  if item.content.len > 0:
    put " ", colors.base.muted
    put if item.expanded: "▾" else: "▸", colors.base.muted

proc toolCall*(frame: Frame, item: TranscriptItem, ansi = false,
    colors = agentTheme()) =
  ## Renders one tool item. ANSI is opt-in and parsed through the SGR allowlist.
  if frame.rect.isEmpty: return
  writeToolHeader(frame, 0, 0, item, colors)
  if frame.rect.height <= 1 or not item.expanded: return
  let body = frame.sub(rect(0, 1, frame.rect.width, frame.rect.height - 1))
  if ansi:
    body.richText(parseAnsiText(item.content))
  else:
    let lines = sanitizeText(item.content).splitLines
    for row in 0 ..< min(lines.len, body.rect.height):
      body.write(0, row, lines[row].truncateCells(body.rect.width, true),
        colors.base.code)
