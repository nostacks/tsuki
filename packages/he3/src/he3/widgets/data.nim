## Lists, tables, trees, tabs, breadcrumbs, and scrollbars.

import std/strutils
import ../[event, geometry, render, scroll, style, theme]
import display

type
  ListState* = object
    selected*: int
    scroll*: ScrollState

  TableColumn* = object
    title*: string
    width*: int
    minWidth*: int
    align*: TextAlign

  TableState* = object
    selectedRow*: int
    scroll*: ScrollState

  TreeRow* = object
    id*: uint64
    label*: string
    depth*: int
    hasChildren*: bool
    expanded*: bool

  TreeState* = object
    selected*: int
    rows*: seq[TreeRow]
    expandedIds*: seq[uint64]
    scroll*: ScrollState

  TabsState* = object
    selected*: int
    scrollOffset*: int

func initListState*(): ListState =
  ## Creates a start-selected list.
  ListState(selected: 0)

proc listEvent*(state: var ListState, event: Event,
    itemCount: int): bool =
  ## Handles arrows, page movement, Home, and End.
  if event.kind != evKey or itemCount <= 0:
    return false
  let previous = state.selected
  case event.key.code
  of kcUp: dec state.selected
  of kcDown: inc state.selected
  of kcPageUp: state.selected -= max(1, state.scroll.viewportHeight)
  of kcPageDown: state.selected += max(1, state.scroll.viewportHeight)
  of kcHome: state.selected = 0
  of kcEnd: state.selected = itemCount - 1
  else: return false
  state.selected = clamp(state.selected, 0, itemCount - 1)
  state.scroll.ensureVisible(state.selected, 1)
  state.selected != previous

proc list*(frame: Frame, items: openArray[string], state: var ListState,
    focused = true, disabled = false, colors = darkTheme()) =
  ## Renders only visible rows. Selection uses both a marker and style so its
  ## meaning survives no-color/high-contrast themes.
  state.scroll.update(frame.rect.width, frame.rect.height,
    frame.rect.width, items.len)
  if items.len == 0:
    frame.write(0, 0, "No items", colors.muted)
    return
  state.selected = clamp(state.selected, 0, items.len - 1)
  state.scroll.ensureVisible(state.selected, 1)
  let visible = state.scroll.visibleRange(items.len, overscan = 0)
  for index in visible.first ..< visible.last:
    let y = index - state.scroll.offsetY
    if y < 0 or y >= frame.rect.height:
      continue
    let selected = index == state.selected
    let marker = if selected: "› " else: "  "
    let rowStyle = if disabled: colors.disabled
      elif selected and focused: colors.focus
      elif selected: colors.selection
      else: colors.text
    frame.write(0, y, marker & items[index].truncateCells(
      max(0, frame.rect.width - 2), true), rowStyle)

func tableColumn*(title: string, width = 0, minWidth = 3,
    align = textStart): TableColumn =
  ## Defines a table column. Width zero shares remaining room.
  TableColumn(title: title, width: max(0, width),
    minWidth: max(1, minWidth), align: align)

proc columnWidths(columns: openArray[TableColumn], available: int): seq[int] =
  result = newSeq[int](columns.len)
  let separators = max(0, columns.len - 1)
  var fixedWidth = separators
  var flexible = 0
  for index, column in columns:
    if column.width > 0:
      result[index] = column.width
      fixedWidth += column.width
    else:
      inc flexible
      fixedWidth += column.minWidth
  var extra = max(0, available - fixedWidth)
  for index, column in columns:
    if column.width == 0:
      result[index] = column.minWidth
      if flexible > 0:
        let share = extra div flexible
        result[index] += share
        extra -= share
        dec flexible
  # Clamp deterministically from trailing columns on tiny terminals.
  var used = separators
  for index in 0 ..< result.len:
    result[index] = min(result[index], max(0, available - used))
    used += result[index]

proc drawCell(frame: Frame, x, y, width: int, value: string,
    align: TextAlign, cellStyle: Style) =
  if width <= 0:
    return
  let shown = value.truncateCells(width, true)
  let offset = case align
    of textStart: 0
    of textCenter: max(0, (width - shown.cellWidth) div 2)
    of textEnd: max(0, width - shown.cellWidth)
  frame.write(x + offset, y, shown, cellStyle)

proc table*(frame: Frame, columns: openArray[TableColumn],
    rows: openArray[seq[string]], state: var TableState,
    focused = true, colors = darkTheme()) =
  ## Renders one header plus the visible row window in O(columns × viewport).
  if columns.len == 0 or frame.rect.isEmpty:
    return
  let widths = columnWidths(columns, frame.rect.width)
  var x = 0
  for columnIndex, column in columns:
    frame.drawCell(x, 0, widths[columnIndex], column.title,
      column.align, colors.accent)
    x += widths[columnIndex]
    if columnIndex + 1 < columns.len and x < frame.rect.width:
      frame.write(x, 0, "│", colors.border)
      inc x
  let bodyHeight = max(0, frame.rect.height - 1)
  state.scroll.update(frame.rect.width, bodyHeight, frame.rect.width, rows.len)
  if rows.len == 0:
    if bodyHeight > 0: frame.write(0, 1, "No rows", colors.muted)
    return
  state.selectedRow = clamp(state.selectedRow, 0, rows.len - 1)
  state.scroll.ensureVisible(state.selectedRow, 1)
  let visible = state.scroll.visibleRange(rows.len, overscan = 0)
  for rowIndex in visible.first ..< visible.last:
    let y = 1 + rowIndex - state.scroll.offsetY
    if y < 1 or y >= frame.rect.height: continue
    let selected = rowIndex == state.selectedRow
    let rowStyle = if selected and focused: colors.focus
      elif selected: colors.selection else: colors.text
    x = 0
    for columnIndex, column in columns:
      let value = if columnIndex < rows[rowIndex].len:
        rows[rowIndex][columnIndex] else: ""
      frame.drawCell(x, y, widths[columnIndex], value, column.align, rowStyle)
      x += widths[columnIndex]
      if columnIndex + 1 < columns.len and x < frame.rect.width:
        frame.write(x, y, "│", colors.border)
        inc x

func isExpanded(state: TreeState, id: uint64): bool =
  id in state.expandedIds

proc toggle*(state: var TreeState, id: uint64) =
  ## Toggles expansion state for a stable tree item ID.
  for index, value in state.expandedIds:
    if value == id:
      state.expandedIds.delete(index)
      return
  state.expandedIds.add id

proc treeEvent*(state: var TreeState, event: Event): bool =
  ## Handles selection and left/right collapse/expand behavior.
  if event.kind != evKey or state.rows.len == 0:
    return false
  case event.key.code
  of kcUp: state.selected = max(0, state.selected - 1)
  of kcDown: state.selected = min(state.rows.len - 1, state.selected + 1)
  of kcRight:
    let row = state.rows[state.selected]
    if row.hasChildren and not state.isExpanded(row.id): state.toggle(row.id)
  of kcLeft:
    let row = state.rows[state.selected]
    if row.hasChildren and state.isExpanded(row.id): state.toggle(row.id)
  else: return false
  state.scroll.ensureVisible(state.selected, 1)
  true

proc tree*(frame: Frame, state: var TreeState, focused = true,
    colors = darkTheme()) =
  ## Renders a caller-flattened tree model. Disclosure arrows make hidden
  ## children discoverable without relying on color.
  state.scroll.update(frame.rect.width, frame.rect.height,
    frame.rect.width, state.rows.len)
  if state.rows.len == 0:
    frame.write(0, 0, "No items", colors.muted)
    return
  state.selected = clamp(state.selected, 0, state.rows.len - 1)
  state.scroll.ensureVisible(state.selected, 1)
  let visible = state.scroll.visibleRange(state.rows.len, overscan = 0)
  for index in visible.first ..< visible.last:
    let row = state.rows[index]
    let prefix = if row.hasChildren:
      (if row.expanded or state.isExpanded(row.id): "▾ " else: "▸ ")
    else: "  "
    let indent = repeat("  ", max(0, row.depth))
    let selected = index == state.selected
    let rowStyle = if selected and focused: colors.focus
      elif selected: colors.selection else: colors.text
    frame.write(0, index - state.scroll.offsetY,
      (indent & prefix & row.label).truncateCells(frame.rect.width, true),
      rowStyle)

proc tabsEvent*(state: var TabsState, event: Event, count: int): bool =
  ## Handles left/right/Home/End tab selection.
  if event.kind != evKey or count <= 0: return false
  let before = state.selected
  case event.key.code
  of kcLeft: state.selected = (state.selected - 1 + count) mod count
  of kcRight: state.selected = (state.selected + 1) mod count
  of kcHome: state.selected = 0
  of kcEnd: state.selected = count - 1
  else: return false
  state.selected != before

proc tabs*(frame: Frame, labels: openArray[string], state: var TabsState,
    focused = true, colors = darkTheme()) =
  ## Renders horizontally scrollable tabs with a selected marker.
  if labels.len == 0 or frame.rect.width <= 0: return
  state.selected = clamp(state.selected, 0, labels.len - 1)
  var x = -state.scrollOffset
  for index, label in labels:
    let shown = " " & label & " "
    let width = shown.cellWidth
    if index == state.selected:
      if x < 0: state.scrollOffset = max(0, state.scrollOffset + x)
      elif x + width > frame.rect.width:
        state.scrollOffset += x + width - frame.rect.width
      x = -state.scrollOffset
      for prior in 0 ..< index:
        x += labels[prior].cellWidth + 3
    if x + width > 0 and x < frame.rect.width:
      let marker = if index == state.selected: "▔" else: " "
      let itemStyle = if index == state.selected and focused: colors.focus
        elif index == state.selected: colors.selection else: colors.muted
      frame.write(x, 0, shown, itemStyle)
      if frame.rect.height > 1:
        frame.write(x, 1, repeat(marker, width), itemStyle)
    x += width + 1

proc breadcrumb*(frame: Frame, parts: openArray[string],
    colors = darkTheme()) =
  ## Renders a leading-to-trailing path with explicit separators.
  var x = 0
  for index, part in parts:
    if index > 0:
      frame.write(x, 0, " › ", colors.muted)
      inc x, 3
    let shown = part.truncateCells(max(0, frame.rect.width - x), true)
    frame.write(x, 0, shown,
      if index + 1 == parts.len: colors.text else: colors.accent)
    inc x, shown.cellWidth
    if x >= frame.rect.width: break

proc scrollbar*(frame: Frame, state: ScrollState, vertical = true,
    colors = darkTheme()) =
  ## Renders a proportional scrollbar with arrows as redundant affordances.
  let viewport = if vertical: state.viewportHeight else: state.viewportWidth
  let content = if vertical: state.contentHeight else: state.contentWidth
  let offset = if vertical: state.offsetY else: state.offsetX
  let length = if vertical: frame.rect.height else: frame.rect.width
  if length <= 0 or content <= viewport:
    return
  let track = max(1, length - 2)
  let thumb = max(1, track * viewport div max(1, content))
  let travel = max(0, track - thumb)
  let start = if content <= viewport: 0 else:
    travel * offset div max(1, content - viewport)
  if vertical:
    frame.write(0, 0, "▲", colors.muted)
    frame.write(0, length - 1, "▼", colors.muted)
    for y in 0 ..< track:
      frame.write(0, 1 + y, if y >= start and y < start +
        thumb: "█" else: "│",
        if y >= start and y < start + thumb: colors.accent else: colors.border)
  else:
    frame.write(0, 0, "◀", colors.muted)
    frame.write(length - 1, 0, "▶", colors.muted)
    for x in 0 ..< track:
      frame.write(1 + x, 0, if x >= start and x < start +
        thumb: "█" else: "─",
        if x >= start and x < start + thumb: colors.accent else: colors.border)
