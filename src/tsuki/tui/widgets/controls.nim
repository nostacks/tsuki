## Keyboard-first buttons, choices, selection, sliders, menus, and forms.

import std/[math, strutils]
import ../[event, render, theme, widget]
import display

type
  ButtonState* = object
    pressed*: bool

  ChoiceState* = object
    checked*: bool

  RadioState* = object
    selected*: int

  SelectState* = object
    selected*: int
    open*: bool

  SliderState* = object
    value*: float
    minimum*: float
    maximum*: float
    step*: float

  MenuState* = object
    selected*: int
    open*: bool

  FormField* = object
    id*: WidgetId
    label*: string
    value*: string
    required*: bool
    error*: string

  FormState* = object
    fields*: seq[FormField]
    focused*: int

func activated*(event: Event): bool =
  ## Matches Enter or Space activation without accepting unrelated background
  ## keys. Released keys never activate controls.
  event.kind == evKey and (event.key.isKey(kcEnter) or event.key.isChar(' '))

proc buttonEvent*(state: var ButtonState, event: Event,
    disabled = false): bool =
  ## Activates only from an explicit Enter/Space press.
  if disabled or not event.activated:
    return false
  state.pressed = true
  true

proc button*(frame: Frame, label: string, state = ButtonState(),
    focused = false, disabled = false, primary = false,
    colors = darkTheme()) =
  ## Renders a clearly bounded action with a verb supplied by the host.
  let prefix = if state.pressed: "▸ " else: "  "
  let shown = (prefix & "[ " & label & " ]").truncateCells(
    frame.rect.width, true)
  let buttonStyle = if disabled: colors.disabled
    elif focused: colors.focus
    elif primary: colors.accent
    else: colors.text
  frame.write(0, 0, shown, buttonStyle)

proc checkboxEvent*(state: var ChoiceState, event: Event,
    disabled = false): bool =
  ## Toggles from Enter or Space.
  if disabled or not event.activated: return false
  state.checked = not state.checked
  true

proc checkbox*(frame: Frame, label: string, state: ChoiceState,
    focused = false, disabled = false, colors = darkTheme()) =
  ## Renders checked state with both a glyph and semantic style.
  let marker = if state.checked: "[x] " else: "[ ] "
  let itemStyle = if disabled: colors.disabled
    elif focused: colors.focus else: colors.text
  frame.write(0, 0, (marker & label).truncateCells(frame.rect.width, true),
    itemStyle)

proc toggle*(frame: Frame, label: string, enabled: bool,
    focused = false, disabled = false, colors = darkTheme()) =
  ## Renders a toggle with explicit On/Off text; the label describes ON state.
  let stateLabel = if enabled: "On" else: "Off"
  let itemStyle = if disabled: colors.disabled
    elif focused: colors.focus else: colors.text
  frame.write(0, 0, (label & ": " & stateLabel).truncateCells(
    frame.rect.width, true), itemStyle)

proc radioEvent*(state: var RadioState, event: Event, count: int,
    disabled = false): bool =
  ## Moves with arrows and selects with Space/Enter.
  if disabled or event.kind != evKey or count <= 0: return false
  let before = state.selected
  case event.key.code
  of kcUp, kcLeft: state.selected = (state.selected - 1 + count) mod count
  of kcDown, kcRight: state.selected = (state.selected + 1) mod count
  else:
    if not event.activated: return false
  state.selected != before or event.activated

proc radio*(frame: Frame, labels: openArray[string], state: RadioState,
    focused = false, disabled = false, colors = darkTheme()) =
  ## Renders a vertical radio group with `(o)`/`( )` state cues.
  for index in 0 ..< min(labels.len, frame.rect.height):
    let marker = if index == state.selected: "(o) " else: "( ) "
    let itemStyle = if disabled: colors.disabled
      elif focused and index == state.selected: colors.focus else: colors.text
    frame.write(0, index, (marker & labels[index]).truncateCells(
      frame.rect.width, true), itemStyle)

proc selectEvent*(state: var SelectState, event: Event, count: int,
    disabled = false): bool =
  ## Opens with Enter/Space, moves with arrows, and closes with Escape.
  if disabled or event.kind != evKey or count <= 0: return false
  if event.key.isKey(kcEscape) and state.open:
    state.open = false
    return true
  if event.activated:
    state.open = not state.open
    return true
  if state.open and event.key.code in {kcUp, kcDown, kcHome, kcEnd}:
    case event.key.code
    of kcUp: state.selected = (state.selected - 1 + count) mod count
    of kcDown: state.selected = (state.selected + 1) mod count
    of kcHome: state.selected = 0
    of kcEnd: state.selected = count - 1
    else: discard
    return true
  false

proc select*(frame: Frame, label: string, options: openArray[string],
    state: SelectState, focused = false, disabled = false,
    colors = darkTheme()) =
  ## Renders a labeled select and, when open, its keyboard-navigable options.
  let selected = if options.len == 0: "No options" else:
    options[clamp(state.selected, 0, options.len - 1)]
  let disclosure = if state.open: "▴" else: "▾"
  let itemStyle = if disabled: colors.disabled
    elif focused: colors.focus else: colors.text
  frame.write(0, 0, (label & ": " & selected & " " & disclosure)
    .truncateCells(frame.rect.width, true), itemStyle)
  if state.open:
    for index in 0 ..< min(options.len, max(0, frame.rect.height - 1)):
      let marker = if index == state.selected: "› " else: "  "
      frame.write(0, index + 1, (marker & options[index]).truncateCells(
        frame.rect.width, true),
        if index == state.selected: colors.selection else: colors.text)

func initSliderState*(minimum, maximum: float, value = 0.0,
    step = 1.0): SliderState =
  ## Creates a finite slider range.
  let high = max(minimum, maximum)
  SliderState(value: clamp(value, minimum, high), minimum: minimum,
    maximum: high, step: max(0.000001, abs(step)))

proc sliderEvent*(state: var SliderState, event: Event,
    disabled = false): bool =
  ## Adjusts with arrows, Page Up/Down, Home, and End.
  if disabled or event.kind != evKey: return false
  let before = state.value
  case event.key.code
  of kcLeft, kcDown: state.value -= state.step
  of kcRight, kcUp: state.value += state.step
  of kcPageDown: state.value -= state.step * 10
  of kcPageUp: state.value += state.step * 10
  of kcHome: state.value = state.minimum
  of kcEnd: state.value = state.maximum
  else: return false
  state.value = clamp(state.value, state.minimum, state.maximum)
  state.value != before

proc slider*(frame: Frame, label: string, state: SliderState,
    focused = false, disabled = false, colors = darkTheme()) =
  ## Renders a labeled slider with a stable numeric value.
  let numeric = formatFloat(state.value, ffDecimal, 2).strip(leading = false,
    trailing = true, chars = {'0', '.'})
  let prefix = label & ": "
  let suffix = " " & numeric
  let trackWidth = max(1, frame.rect.width - prefix.cellWidth -
      suffix.cellWidth)
  let fraction = if state.maximum <= state.minimum: 0.0 else:
    (state.value - state.minimum) / (state.maximum - state.minimum)
  let thumb = clamp(int(round(fraction * float(trackWidth - 1))), 0,
    trackWidth - 1)
  let track = repeat("─", thumb) & "●" &
    repeat("─", max(0, trackWidth - thumb - 1))
  let itemStyle = if disabled: colors.disabled
    elif focused: colors.focus else: colors.text
  frame.write(0, 0, prefix, colors.text)
  frame.write(prefix.cellWidth, 0, track, itemStyle)
  frame.write(prefix.cellWidth + trackWidth, 0, suffix, colors.text)

proc menuEvent*(state: var MenuState, event: Event, count: int): bool =
  ## Handles menu navigation; Escape closes and Enter activates the selection.
  if event.kind != evKey or count <= 0: return false
  if event.key.isKey(kcEscape):
    let changed = state.open
    state.open = false
    return changed
  if not state.open and event.activated:
    state.open = true
    return true
  if state.open:
    case event.key.code
    of kcUp: state.selected = (state.selected - 1 + count) mod count
    of kcDown: state.selected = (state.selected + 1) mod count
    of kcHome: state.selected = 0
    of kcEnd: state.selected = count - 1
    else: return event.activated
    return true
  false

proc menu*(frame: Frame, items: openArray[string], state: MenuState,
    focused = false, colors = darkTheme()) =
  ## Renders a visible menu list; selected items carry a marker.
  if not state.open:
    frame.write(0, 0, "Menu ▾", if focused: colors.focus else: colors.text)
    return
  for index in 0 ..< min(items.len, frame.rect.height):
    let selected = index == state.selected
    frame.write(0, index, ((if selected: "› " else: "  ") & items[index])
      .truncateCells(frame.rect.width, true),
      if selected: colors.focus else: colors.text)

proc validate*(state: var FormState): bool =
  ## Validates required fields on submit and records actionable inline errors.
  result = true
  for field in state.fields.mitems:
    field.error.setLen 0
    if field.required and field.value.strip.len == 0:
      field.error = "Enter " & field.label.toLowerAscii & "."
      result = false
  if not result:
    for index, field in state.fields:
      if field.error.len > 0:
        state.focused = index
        break

proc form*(frame: Frame, state: FormState, colors = darkTheme()) =
  ## Renders persistent labels and inline recovery instructions.
  var y = 0
  for index, field in state.fields:
    if y >= frame.rect.height: break
    let selected = index == state.focused
    frame.write(0, y, field.label & ":",
        if selected: colors.accent else: colors.text)
    let labelWidth = min(frame.rect.width, field.label.cellWidth + 2)
    frame.write(labelWidth, y, field.value.truncateCells(
      max(0, frame.rect.width - labelWidth), true),
      if selected: colors.focus else: colors.text)
    inc y
    if field.error.len > 0 and y < frame.rect.height:
      frame.write(2, y, ("× " & field.error).truncateCells(
        max(0, frame.rect.width - 2), true), colors.error)
      inc y
