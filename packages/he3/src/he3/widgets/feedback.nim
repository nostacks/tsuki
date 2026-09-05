## Progress, gauges, charts, and bounded virtual log output.

import std/[math, strutils]
import ../[accessibility, geometry, render, scroll, text, theme]
import display

type
  LogLevel* = enum
    logInfo
    logSuccess
    logWarning
    logError

  LogEntry* = object
    level*: LogLevel
    message*: string

  LogViewState* = object
    entries*: seq[LogEntry]
    head*: int
    count*: int
    capacity*: int
    scroll*: ScrollState
    follow*: bool

proc progress*(frame: Frame, value: float, label = "",
    colors = darkTheme()) =
  ## Renders a clamped gauge with a numeric percentage so meaning never
  ## depends on fill color alone.
  if frame.rect.width <= 0 or frame.rect.height <= 0:
    return
  let normalized = case classify(value)
    of fcNan, fcNegInf: 0.0
    of fcInf: 1.0
    else: clamp(value, 0.0, 1.0)
  let percent = int(round(normalized * 100.0))
  let suffix = " " & $percent & "%"
  let prefix = if label.len > 0: label & " " else: ""
  let barWidth = max(0, frame.rect.width - prefix.cellWidth - suffix.cellWidth)
  let filled = int(round(normalized * float(barWidth)))
  var x = 0
  if prefix.len > 0:
    frame.write(x, 0, prefix, colors.text)
    inc x, prefix.cellWidth
  if barWidth > 0:
    frame.write(x, 0, repeat("█", filled), colors.accent)
    frame.write(x + filled, 0, repeat("░", barWidth - filled), colors.border)
    inc x, barWidth
  frame.write(x, 0, suffix, colors.text)

proc sparkline*(frame: Frame, values: openArray[float],
    colors = darkTheme(), ascii = false) =
  ## Draws the newest values using block levels or a documented ASCII fallback.
  if values.len == 0 or frame.rect.width <= 0:
    frame.write(0, 0, "No data", colors.muted)
    return
  var minimum = Inf
  var maximum = NegInf
  for value in values:
    if classify(value) notin {fcNan, fcInf, fcNegInf}:
      minimum = min(minimum, value)
      maximum = max(maximum, value)
  if minimum == Inf:
    frame.write(0, 0, "No data", colors.muted)
    return
  let levels = if ascii: ".:-=+*#@" else: "▁▂▃▄▅▆▇█"
  let first = max(0, values.len - frame.rect.width)
  var output = ""
  for index in first ..< values.len:
    if classify(values[index]) in {fcNan, fcInf, fcNegInf}:
      output.add(if ascii: "?" else: "·")
      continue
    let normalized = if maximum <= minimum: 0.5 else:
      clamp((values[index] - minimum) / (maximum - minimum), 0.0, 1.0)
    let level = clamp(int(round(normalized * 7.0)), 0, 7)
    if ascii: output.add levels[level]
    else:
      let byteIndex = level * 3
      output.add levels[byteIndex ..< byteIndex + 3]
  frame.write(0, 0, output, colors.accent)

proc chart*(frame: Frame, series: openArray[seq[float]],
    labels: openArray[string] = [], colors = darkTheme(), ascii = false) =
  ## Stacks compact sparkline series with optional labels.
  for index in 0 ..< min(series.len, frame.rect.height):
    let label = if index < labels.len: labels[index] else: ""
    let labelWidth = min(16, label.cellWidth)
    if labelWidth > 0:
      frame.write(0, index, label.truncateCells(labelWidth, true), colors.muted)
    let inner = frame.sub(rect(labelWidth + (if labelWidth > 0: 1 else: 0),
      index, max(0, frame.rect.width - labelWidth -
      (if labelWidth > 0: 1 else: 0)), 1))
    inner.sparkline(series[index], colors, ascii)

func initLogViewState*(capacity = 10_000): LogViewState =
  ## Creates a bounded ring-backed log view following new output.
  LogViewState(capacity: max(1, capacity), follow: true,
    scroll: ScrollState(anchor: anchorEnd))

proc add*(state: var LogViewState, message: string,
    level = logInfo, policy = plainTextPolicy(maxBytes = 65_536)) =
  ## Appends sanitized output in O(1), overwriting the oldest entry at capacity.
  let entry = LogEntry(level: level, message: sanitizeText(message, policy))
  if state.entries.len < state.capacity:
    state.entries.add entry
    inc state.count
  else:
    state.entries[state.head] = entry
    state.head = (state.head + 1) mod state.capacity
  if state.follow:
    state.scroll.anchor = anchorEnd

func logAt(state: LogViewState, index: int): LogEntry =
  if index < 0 or index >= state.count or state.entries.len == 0:
    return LogEntry()
  state.entries[(state.head + index) mod state.entries.len]

proc logView*(frame: Frame, state: var LogViewState,
    colors = darkTheme()) =
  ## Renders only the visible ring window; level text/icons remain meaningful
  ## in monochrome and no-color modes.
  state.scroll.anchor = if state.follow: anchorEnd else: anchorStart
  state.scroll.update(frame.rect.width, frame.rect.height,
    frame.rect.width, state.count)
  let visible = state.scroll.visibleRange(state.count, overscan = 0)
  for index in visible.first ..< visible.last:
    let entry = state.logAt(index)
    let cue = case entry.level
      of logInfo: "i"
      of logSuccess: "✓"
      of logWarning: "!"
      of logError: "×"
    let rowStyle = case entry.level
      of logInfo: colors.text
      of logSuccess: colors.success
      of logWarning: colors.warning
      of logError: colors.error
    frame.write(0, index - state.scroll.offsetY,
      (cue & " " & entry.message).truncateCells(frame.rect.width, true),
      rowStyle)

func spinnerShouldAnimate*(preferences: AccessibilityPreferences,
    visible = true): bool =
  ## True only when a visible spinner may schedule a motion deadline.
  visible and not preferences.reducedMotion
