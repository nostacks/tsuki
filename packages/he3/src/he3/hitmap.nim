## Layer-aware pointer hit regions and mouse capture.

import event
import geometry
import widget

type
  HitRegion* = object
    id*: WidgetId
    area*: Rect
    parent*: WidgetId
    layer*: int
    passThrough*: bool
    order: int

  HitMap* = object
    regions*: seq[HitRegion]
    captured*: WidgetId
    nextOrder: int

proc beginFrame*(map: var HitMap) =
  ## Clears frame-local hit regions while retaining valid mouse capture.
  map.regions.setLen 0
  map.nextOrder = 0

proc register*(map: var HitMap, id: WidgetId, area: Rect,
    parent = WidgetId(0), layer = 0, passThrough = false) =
  ## Registers a pointer target. Later regions win within the same layer.
  if not id.isValid or area.isEmpty:
    return
  map.regions.add HitRegion(id: id, area: area, parent: parent, layer: layer,
    passThrough: passThrough, order: map.nextOrder)
  inc map.nextOrder

func regionFor(map: HitMap, id: WidgetId): int =
  for index, region in map.regions:
    if region.id == id:
      return index
  -1

func hitTest*(map: HitMap, position: Point): WidgetId =
  ## Returns the topmost non-pass-through target at a cell.
  var bestLayer = low(int)
  var bestOrder = low(int)
  for region in map.regions:
    if region.passThrough or not region.area.contains(position):
      continue
    if region.layer > bestLayer or
        (region.layer == bestLayer and region.order > bestOrder):
      bestLayer = region.layer
      bestOrder = region.order
      result = region.id

proc capture*(map: var HitMap, id: WidgetId): bool =
  ## Captures subsequent drag/release events for a registered widget.
  if map.regionFor(id) < 0:
    return false
  map.captured = id
  true

proc releaseCapture*(map: var HitMap) =
  ## Releases pointer capture.
  map.captured = WidgetId(0)

func route*(map: HitMap, event: MouseEvent): seq[WidgetId] =
  ## Returns target then parent chain for bubbling. A captured target wins.
  var current = if map.captured.isValid: map.captured else:
    map.hitTest(point(event.x, event.y))
  var guard = 0
  while current.isValid and guard <= map.regions.len:
    result.add current
    let index = map.regionFor(current)
    if index < 0:
      break
    current = map.regions[index].parent
    inc guard
