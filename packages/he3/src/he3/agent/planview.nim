## Compact agent plan/checklist view.

import ../[geometry, render, style, text]
import ../widgets/display
import model, theme

func planCue(state: PlanItemState): string =
  case state
  of planPending: "○"
  of planActive: "◉"
  of planComplete: "✓"
  of planFailed: "×"

func planStateStyle(state: PlanItemState, colors: AgentTheme): Style =
  case state
  of planPending: colors.base.muted
  of planActive: colors.base.accent
  of planComplete: colors.base.success
  of planFailed: colors.base.error

proc planView*(frame: Frame, items: openArray[PlanItem],
    colors = agentTheme()) =
  ## Draws visible plan rows with symbol-and-text state cues.
  if items.len == 0:
    frame.write(0, 0, "No plan", colors.base.muted)
    return
  for index in 0 ..< min(items.len, frame.rect.height):
    let item = items[index]
    frame.write(0, index, (item.state.planCue & " " & sanitizeText(item.text))
      .truncateCells(frame.rect.width, true),
      item.state.planStateStyle(colors))

proc putSegment(frame: Frame, x: var int, width: int, value: string,
    style: Style) =
  ## Writes one inline segment and advances the pen, clipping at the edge.
  if x < width:
    frame.write(x, 0, value.truncateCells(max(0, width - x), true), style)
  inc x, value.cellWidth

proc planSummary*(frame: Frame, items: openArray[PlanItem],
    colors = agentTheme()) =
  ## Draws one quiet plan row that stays visible at ordinary widths, degrading
  ## to active-step progress on narrow terminals. State cues are never
  ## truncated; only step wording is.
  if frame.rect.isEmpty: return
  if items.len == 0: return
  let width = frame.rect.width
  var complete = 0
  var active = -1
  var fallback = -1
  for index, item in items:
    if item.state in {planComplete, planFailed}: inc complete
    if item.state == planActive: active = index
    if fallback < 0 and item.state notin {planComplete}: fallback = index
  if active < 0: active = fallback
  let label = "plan " & $complete & "/" & $items.len
  var full = ""
  for index, item in items:
    if index > 0: full.add "  "
    full.add item.state.planCue & " " & sanitizeText(item.text)
  var x = 0
  if label.cellWidth + 2 + full.cellWidth <= width:
    frame.putSegment(x, width, label & "  ", colors.base.muted)
    for item in items:
      frame.putSegment(x, width, item.state.planCue, item.state.planStateStyle(colors))
      frame.putSegment(x, width, " ", colors.base.muted)
      frame.putSegment(x, width, sanitizeText(item.text), colors.base.muted)
      frame.putSegment(x, width, "  ", colors.base.muted)
  elif width >= 24:
    frame.putSegment(x, width, label, colors.base.muted)
    frame.putSegment(x, width, "  ", colors.base.muted)
    if active >= 0:
      frame.putSegment(x, width, items[active].state.planCue,
        items[active].state.planStateStyle(colors))
      let step = sanitizeText(items[active].text)
      if step.len > 0:
        frame.putSegment(x, width, " ", colors.base.muted)
        frame.putSegment(x, width, step, colors.base.muted)
  else:
    frame.putSegment(x, width, label.truncateCells(width, true),
      colors.base.muted)
