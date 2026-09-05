## Public stateless and explicit-state widget contracts.

import event
import geometry
import render

type
  WidgetId* = distinct uint64

  WidgetEventResult* = enum
    werIgnored
    werConsumed
    werRedraw

  MeasureProc* = proc (available: Size): Size {.closure.}
  WidgetRenderProc* = proc (frame: var Frame) {.closure.}
  WidgetEventProc* = proc (event: Event): WidgetEventResult {.closure.}

  Widget* = object
    ## A lightweight callback contract. The application owns callback state;
    ## rendering a widget does not allocate a retained component node.
    id*: WidgetId
    renderProc*: WidgetRenderProc
    eventProc*: WidgetEventProc
    measureProc*: MeasureProc
    disabled*: bool
    hidden*: bool

  StatefulRenderProc*[S] = proc (state: var S,
    frame: var Frame) {.closure.}
  StatefulEventProc*[S] = proc (state: var S,
    event: Event): WidgetEventResult {.closure.}

  StatefulWidget*[S] = object
    ## A widget contract whose durable state is passed explicitly by its owner.
    id*: WidgetId
    renderProc*: StatefulRenderProc[S]
    eventProc*: StatefulEventProc[S]
    measureProc*: MeasureProc
    disabled*: bool
    hidden*: bool

func widgetId*(value: SomeInteger): WidgetId =
  ## Creates a stable widget identifier supplied by the application.
  WidgetId(uint64(value))

func `==`*(a, b: WidgetId): bool {.inline.} =
  ## Compares stable widget identifiers.
  uint64(a) == uint64(b)

func isValid*(id: WidgetId): bool =
  ## True for nonzero widget identifiers.
  uint64(id) != 0

proc render*(widget: Widget, frame: var Frame) =
  ## Renders a visible widget.
  if not widget.hidden and not widget.renderProc.isNil:
    widget.renderProc(frame)

proc handle*(widget: Widget, event: Event): WidgetEventResult =
  ## Routes an event unless the widget is hidden or disabled.
  if widget.hidden or widget.disabled or widget.eventProc.isNil:
    werIgnored
  else:
    widget.eventProc(event)

proc measure*(widget: Widget, available: Size): Size =
  ## Returns intrinsic size clamped to the available area.
  if widget.hidden:
    return size(0, 0)
  if widget.measureProc.isNil:
    return available
  let desired = widget.measureProc(available)
  size(min(available.width, desired.width),
    min(available.height, desired.height))

proc render*[S](widget: StatefulWidget[S], state: var S,
    frame: var Frame) =
  ## Renders with explicit application-owned state.
  if not widget.hidden and not widget.renderProc.isNil:
    widget.renderProc(state, frame)

proc handle*[S](widget: StatefulWidget[S], state: var S,
    event: Event): WidgetEventResult =
  ## Routes an event with explicit state.
  if widget.hidden or widget.disabled or widget.eventProc.isNil:
    werIgnored
  else:
    widget.eventProc(state, event)
