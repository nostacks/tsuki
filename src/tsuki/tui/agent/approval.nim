## Deliberate, keyboard-first approval UX. Decisions are reports, not grants.
## The approval renders inline at the bottom of the transcript flow: symbol
## cues and indentation carry the structure, with no dialog or backdrop.

import ../[event, geometry, render, style, text]
import ../widgets/display
import model, theme

type
  ApprovalDecision* = enum
    approvalNone
    approvalReject
    approvalOnce
    approvalAlways
    approvalEdit

  ApprovalState* = object
    selected*: ApprovalDecision
    armed*: bool

func initApprovalState*(): ApprovalState =
  ## The safe default is selected before the first approval frame is drawn.
  ApprovalState(selected: approvalReject)

func approvalOptions(request: ApprovalRequest): seq[ApprovalDecision] =
  result = @[approvalReject, approvalOnce]
  if request.allowAlways: result.add approvalAlways
  result.add approvalEdit

func approvalLabel(decision: ApprovalDecision): string =
  case decision
  of approvalNone: ""
  of approvalReject: "Reject"
  of approvalOnce: "Approve once"
  of approvalAlways: "Always allow"
  of approvalEdit: "Edit request"

func riskLabel(risk: AgentRisk): string =
  ($risk)[4 .. ^1]

func riskStyle(risk: AgentRisk, colors: AgentTheme): Style =
  ## Error color is reserved for destructive risk; other risks warn.
  if risk == riskDestructive: colors.base.error else: colors.base.warning

proc approvalEvent*(state: var ApprovalState, request: ApprovalRequest,
    event: Event): ApprovalDecision =
  ## Arrow keys select. The first Enter arms a choice; a second Enter confirms.
  ## Any navigation disarms it, preventing a background key from approving.
  ## Escape rejects without granting authority.
  let options = request.approvalOptions
  if state.selected == approvalNone: state.selected = approvalReject
  if event.kind != evKey or event.key.released: return approvalNone
  if event.key.isKey(kcEscape):
    state.armed = false
    return approvalReject
  var index = options.find(state.selected)
  case event.key.code
  of kcLeft, kcUp:
    index = (index - 1 + options.len) mod options.len
    state.selected = options[index]
    state.armed = false
  of kcRight, kcDown, kcTab:
    index = (index + 1) mod options.len
    state.selected = options[index]
    state.armed = false
  of kcEnter:
    if state.armed:
      state.armed = false
      return state.selected
    state.armed = true
  else:
    state.armed = false
  approvalNone

func approvalRowCount*(request: ApprovalRequest, armed: bool): int =
  ## Deterministic row count of the inline card at any terminal width.
  result = 1 # risk header
  if request.command.len > 0: inc result
  if request.explanation.len > 0: inc result
  inc result, min(request.paths.len, 3)
  inc result # choices
  if armed: inc result

proc approvalInline*(frame: Frame, request: ApprovalRequest,
    state: ApprovalState, colors = agentTheme()) =
  ## Draws the inline approval card. Bodies align two cells after the leading
  ## `!` cue, matching the transcript's stable inner edge.
  if frame.rect.isEmpty: return
  let selected = if state.selected == approvalNone: approvalReject
    else: state.selected
  let alert = riskStyle(request.risk, colors)
  let bodyX = 2
  let width = frame.rect.width
  var y = 0
  template row(value: string, style: Style) =
    if y < frame.rect.height:
      frame.write(bodyX, y, value.truncateCells(max(0, width - bodyX), true),
        style)
    inc y
  frame.write(0, 0, ("! Approval required · " & riskLabel(request.risk))
    .truncateCells(max(0, width - 2), true), alert)
  inc y
  if request.command.len > 0:
    row sanitizeText(request.command), colors.base.text
  if request.explanation.len > 0:
    row sanitizeText(request.explanation), colors.base.muted
  for path in request.paths[0 ..< min(request.paths.len, 3)]:
    row sanitizeText(path), colors.base.muted
  var x = bodyX
  for decision in request.approvalOptions:
    let isSelected = decision == selected
    let label = (if isSelected: "[" else: " ") & decision.approvalLabel &
      (if isSelected: "]" else: " ")
    if x < width:
      frame.write(x, y, label.truncateCells(max(0, width - x), true),
        if isSelected: colors.base.focus else: colors.base.muted)
    inc x, label.cellWidth + 1
    if x >= width: break
  inc y
  if state.armed:
    row "Press Enter again to confirm: " & selected.approvalLabel,
      colors.base.warning
