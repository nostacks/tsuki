## Deterministic keyboard focus registration and navigation.

import geometry
import widget

type
  FocusDirection* = enum
    focusForward
    focusBackward
    focusUp
    focusDown
    focusLeading
    focusTrailing

  FocusEntry* = object
    id*: WidgetId
    area*: Rect
    scope*: WidgetId
    disabled*: bool
    hidden*: bool

  FocusState* = object
    ## Rebuilt registration order plus stable current focus.
    current*: WidgetId
    entries*: seq[FocusEntry]
    activeScope*: WidgetId
    restoreStack*: seq[WidgetId]

proc beginFrame*(state: var FocusState) =
  ## Starts focus registration for a new immediate-mode frame.
  state.entries.setLen 0

proc register*(state: var FocusState, id: WidgetId, area: Rect,
    disabled = false, hidden = false, scope = WidgetId(0)) =
  ## Registers one focusable widget in reading/tab order.
  if id.isValid:
    state.entries.add FocusEntry(id: id, area: area, scope: scope,
      disabled: disabled, hidden: hidden)

func eligible(state: FocusState, entry: FocusEntry): bool =
  not entry.disabled and not entry.hidden and not entry.area.isEmpty and
    (not state.activeScope.isValid or entry.scope == state.activeScope)

func indexOf(state: FocusState, id: WidgetId): int =
  for index, entry in state.entries:
    if entry.id == id and state.eligible(entry):
      return index
  -1

proc finishFrame*(state: var FocusState) =
  ## Moves focus safely when the focused widget was hidden, disabled, removed,
  ## or left the active scope.
  if state.indexOf(state.current) >= 0:
    return
  state.current = WidgetId(0)
  for entry in state.entries:
    if state.eligible(entry):
      state.current = entry.id
      break

proc focus*(state: var FocusState, id: WidgetId): bool =
  ## Focuses an eligible registered widget.
  if state.indexOf(id) < 0:
    return false
  state.current = id
  true

proc moveLinear(state: var FocusState, delta: int): bool =
  var eligibleIndices: seq[int]
  for index, entry in state.entries:
    if state.eligible(entry):
      eligibleIndices.add index
  if eligibleIndices.len == 0:
    state.current = WidgetId(0)
    return false
  var position = 0
  for index, entryIndex in eligibleIndices:
    if state.entries[entryIndex].id == state.current:
      position = index
      break
  position = (position + delta + eligibleIndices.len) mod eligibleIndices.len
  state.current = state.entries[eligibleIndices[position]].id
  true

func center(area: Rect): Point =
  point(area.x + area.width div 2, area.y + area.height div 2)

proc moveDirectional(state: var FocusState, direction: FocusDirection): bool =
  let currentIndex = state.indexOf(state.current)
  if currentIndex < 0:
    return state.moveLinear(1)
  let origin = state.entries[currentIndex].area.center
  var best = high(int)
  var bestId = WidgetId(0)
  for entry in state.entries:
    if entry.id == state.current or not state.eligible(entry):
      continue
    let target = entry.area.center
    let dx = target.x - origin.x
    let dy = target.y - origin.y
    let inDirection = case direction
      of focusUp: dy < 0
      of focusDown: dy > 0
      of focusLeading: dx < 0
      of focusTrailing: dx > 0
      else: false
    if not inDirection:
      continue
    let primary = if direction in {focusUp, focusDown}: abs(dy) else: abs(dx)
    let secondary = if direction in {focusUp, focusDown}: abs(dx) else: abs(dy)
    let score = primary * 1024 + secondary
    if score < best:
      best = score
      bestId = entry.id
  if bestId.isValid:
    state.current = bestId
    return true
  false

proc move*(state: var FocusState, direction: FocusDirection): bool =
  ## Moves focus in tab order or by nearest directional geometry.
  case direction
  of focusForward: state.moveLinear(1)
  of focusBackward: state.moveLinear(-1)
  else: state.moveDirectional(direction)

proc pushScope*(state: var FocusState, scope: WidgetId) =
  ## Activates a modal focus scope and remembers the prior focused widget.
  state.restoreStack.add state.current
  state.activeScope = scope
  state.current = WidgetId(0)
  state.finishFrame()

proc popScope*(state: var FocusState) =
  ## Leaves a modal scope and restores its trigger when still eligible.
  state.activeScope = WidgetId(0)
  let previous = if state.restoreStack.len > 0: state.restoreStack.pop()
    else: WidgetId(0)
  if not state.focus(previous):
    state.finishFrame()
