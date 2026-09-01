## Split panes, popups, modals, tooltips, toasts, and command palettes.

import std/[strutils, unicode]
import ../[event, geometry, graphemes, layout, overlay, render, theme]
import display

type
  SplitOrientation* = enum
    splitHorizontal
    splitVertical

  SplitPaneState* = object
    orientation*: SplitOrientation
    firstSize*: int
    minFirst*: int
    minSecond*: int
    dragging*: bool

  CommandPaletteState* = object
    query*: string
    selected*: int
    open*: bool

  ToastKind* = enum
    toastInfo
    toastSuccess
    toastWarning
    toastError

func splitAreas*(area: Rect, state: var SplitPaneState): tuple[first,
    divider, second: Rect] =
  ## Resolves two non-overlapping panes and a one-cell divider at any size.
  if state.orientation == splitHorizontal:
    let available = max(0, area.width - 1)
    let low = min(max(0, state.minFirst), available)
    let high = max(low, available - max(0, state.minSecond))
    state.firstSize = clamp(state.firstSize, low, high)
    result.first = rect(area.x, area.y, state.firstSize, area.height)
    result.divider = rect(area.x + state.firstSize, area.y,
      min(1, area.width), area.height)
    result.second = rect(area.x + state.firstSize + min(1, area.width), area.y,
      max(0, available - state.firstSize), area.height)
  else:
    let available = max(0, area.height - 1)
    let low = min(max(0, state.minFirst), available)
    let high = max(low, available - max(0, state.minSecond))
    state.firstSize = clamp(state.firstSize, low, high)
    result.first = rect(area.x, area.y, area.width, state.firstSize)
    result.divider = rect(area.x, area.y + state.firstSize, area.width,
      min(1, area.height))
    result.second = rect(area.x, area.y + state.firstSize + min(1, area.height),
      area.width, max(0, available - state.firstSize))

proc splitPaneEvent*(state: var SplitPaneState, event: Event,
    focused = true): bool =
  ## Resizes from arrows while the divider is focused.
  if not focused or event.kind != evKey: return false
  let before = state.firstSize
  if state.orientation == splitHorizontal:
    case event.key.code
    of kcLeft: dec state.firstSize
    of kcRight: inc state.firstSize
    else: return false
  else:
    case event.key.code
    of kcUp: dec state.firstSize
    of kcDown: inc state.firstSize
    else: return false
  state.firstSize != before

proc splitPane*(frame: Frame, state: var SplitPaneState,
    focused = false, colors = darkTheme()): tuple[first, second: Frame] =
  ## Draws a keyboard-visible divider and returns its two child frames.
  let areas = splitAreas(rect(0, 0, frame.rect.width, frame.rect.height), state)
  let dividerStyle = if focused: colors.focus else: colors.border
  if state.orientation == splitHorizontal:
    for y in 0 ..< areas.divider.height:
      frame.write(areas.divider.x, areas.divider.y + y, "│", dividerStyle)
  else:
    for x in 0 ..< areas.divider.width:
      frame.write(areas.divider.x + x, areas.divider.y, "─", dividerStyle)
  result.first = frame.sub(areas.first)
  result.second = frame.sub(areas.second)

proc popup*(frame: Frame, anchor: Rect, desired: Size, title = "",
    colors = darkTheme()): Frame =
  ## Places and draws a viewport-clamped popup.
  let area = placePopup(rect(0, 0, frame.rect.width, frame.rect.height),
    anchor, desired)
  let layer = frame.sub(area, colors.background)
  layer.clearAll()
  layer.block(title, colors.border, rounded = true)

proc modal*(frame: Frame, desired: Size, title = "",
    colors = darkTheme()): Frame =
  ## Draws a centered modal. Focus trapping and background blocking are owned by
  ## `FocusState.pushScope` and `OverlayStack`.
  let area = centered(rect(0, 0, frame.rect.width, frame.rect.height), desired)
  let layer = frame.sub(area, colors.background)
  layer.clearAll()
  layer.block(title, colors.focus, rounded = true)

proc tooltip*(frame: Frame, anchor: Rect, message: string,
    colors = darkTheme()): Rect =
  ## Draws concise supplemental text near an anchor and returns its hit area.
  let desired = size(min(frame.rect.width, message.cellWidth + 2), 3)
  result = placePopup(rect(0, 0, frame.rect.width, frame.rect.height),
    anchor, desired)
  let layer = frame.sub(result, colors.background)
  layer.clearAll()
  let inner = layer.block(style = colors.border, rounded = true)
  inner.text(message, colors.text, ellipsis = true)

proc toast*(frame: Frame, message: string, kind = toastInfo,
    colors = darkTheme()) =
  ## Draws a status cue plus message. Error/action toasts are expected to remain
  ## until the host receives an explicit dismissal.
  let cue = case kind
    of toastInfo: "i"
    of toastSuccess: "✓"
    of toastWarning: "!"
    of toastError: "×"
  let toastStyle = case kind
    of toastInfo: colors.text
    of toastSuccess: colors.success
    of toastWarning: colors.warning
    of toastError: colors.error
  frame.write(0, 0, (cue & " " & message).truncateCells(
    frame.rect.width, true), toastStyle)

func paletteMatches*(state: CommandPaletteState,
    commands: openArray[string]): seq[int] =
  ## Returns case-insensitive substring matches in original command order.
  let query = state.query.toLowerAscii
  for index, command in commands:
    if query.len == 0 or query in command.toLowerAscii:
      result.add index

proc commandPaletteEvent*(state: var CommandPaletteState, event: Event,
    commandCount: int): bool =
  ## Handles query input, arrows, Backspace, and Escape. Enter is left for the
  ## host to invoke the selected command deliberately.
  if event.kind == evPaste:
    state.query.add event.text
    state.selected = 0
    return true
  if event.kind != evKey: return false
  if event.key.isKey(kcEscape):
    state.open = false
    return true
  case event.key.code
  of kcChar:
    if modCtrl notin event.key.mods:
      state.query.add $event.key.char
      state.selected = 0
      return true
  of kcBackspace:
    if state.query.len > 0:
      var clusters: seq[string]
      for cluster in state.query.graphemes:
        clusters.add cluster
      state.query.setLen(0)
      for index in 0 ..< max(0, clusters.len - 1):
        state.query.add clusters[index]
      state.selected = 0
      return true
  of kcUp:
    state.selected = max(0, state.selected - 1)
    return true
  of kcDown:
    state.selected = min(max(0, commandCount - 1), state.selected + 1)
    return true
  else: discard
  false

proc commandPalette*(frame: Frame, commands: openArray[string],
    state: var CommandPaletteState, colors = darkTheme()) =
  ## Renders a centered searchable command palette with persistent `Command`
  ## label rather than relying on placeholder text.
  if not state.open: return
  let area = centered(rect(0, 0, frame.rect.width, frame.rect.height),
    size(min(72, frame.rect.width), min(12, frame.rect.height)))
  let layer = frame.sub(area, colors.background)
  layer.clearAll()
  let inner = layer.block("Commands", colors.focus, rounded = true)
  inner.write(0, 0, "Command: " & state.query, colors.text)
  let matches = state.paletteMatches(commands)
  state.selected = clamp(state.selected, 0, max(0, matches.len - 1))
  if matches.len == 0:
    inner.write(0, 2, "No matching commands. Clear the search to see all commands.",
      colors.muted)
  else:
    for row in 0 ..< min(matches.len, max(0, inner.rect.height - 2)):
      let selected = row == state.selected
      inner.write(0, row + 2,
        ((if selected: "› " else: "  ") & commands[matches[row]])
        .truncateCells(inner.rect.width, true),
        if selected: colors.focus else: colors.text)
