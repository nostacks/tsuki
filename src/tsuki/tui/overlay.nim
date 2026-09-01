## Popup/modal layer placement and interaction blocking.

import geometry
import widget

type
  OverlayKind* = enum
    overlayPopup
    overlayTooltip
    overlayMenu
    overlayModal
    overlayToast

  OverlayLayer* = object
    id*: WidgetId
    kind*: OverlayKind
    area*: Rect
    anchor*: Rect
    modal*: bool
    passThrough*: bool
    zIndex*: int

  OverlayStack* = object
    layers*: seq[OverlayLayer]

func placePopup*(viewport, anchor: Rect, desired: Size,
    gap = 1): Rect =
  ## Places below/leading first, flips above when needed, then clamps to the
  ## viewport. The result remains usable on tiny terminals.
  let width = min(viewport.width, max(1, desired.width))
  let height = min(viewport.height, max(1, desired.height))
  var x = anchor.x
  var y = anchor.y + anchor.height + max(0, gap)
  if y + height > viewport.y + viewport.height:
    y = anchor.y - max(0, gap) - height
  x = clamp(x, viewport.x, max(viewport.x, viewport.x + viewport.width - width))
  y = clamp(y, viewport.y,
    max(viewport.y, viewport.y + viewport.height - height))
  rect(x, y, width, height)

proc push*(stack: var OverlayStack, layer: sink OverlayLayer) =
  ## Adds or replaces a stable overlay layer.
  for index, existing in stack.layers:
    if existing.id == layer.id:
      stack.layers[index] = layer
      return
  stack.layers.add layer

proc close*(stack: var OverlayStack, id: WidgetId): bool =
  ## Removes one overlay while preserving other layer order.
  for index, layer in stack.layers:
    if layer.id == id:
      stack.layers.delete(index)
      return true
  false

func top*(stack: OverlayStack): OverlayLayer =
  ## Returns the highest z-index layer, or a default empty layer.
  var best = low(int)
  for layer in stack.layers:
    if layer.zIndex >= best:
      best = layer.zIndex
      result = layer

func blocksBackground*(stack: OverlayStack): bool =
  ## True when any visible modal must trap focus and pointer input.
  for layer in stack.layers:
    if layer.modal:
      return true
  false
