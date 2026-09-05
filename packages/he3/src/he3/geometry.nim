## Shared terminal geometry values.

type
  Point* = object
    x*: int
    y*: int

  Size* = object
    width*: int
    height*: int

  Rect* = object
    x*: int
    y*: int
    width*: int
    height*: int

  Insets* = object
    top*: int
    right*: int
    bottom*: int
    left*: int

func point*(x, y: int): Point =
  ## Creates a cell coordinate.
  Point(x: x, y: y)

func size*(width, height: int): Size =
  ## Creates a nonnegative size.
  Size(width: max(0, width), height: max(0, height))

func rect*(x, y, width, height: int): Rect =
  ## Creates a rectangle with nonnegative extent.
  Rect(x: x, y: y, width: max(0, width), height: max(0, height))

func initRect*(x, y, width, height: int): Rect =
  ## Compatibility spelling for `rect`.
  rect(x, y, width, height)

func insets*(all: int): Insets =
  ## Creates equal, nonnegative edge insets.
  let value = max(0, all)
  Insets(top: value, right: value, bottom: value, left: value)

func insets*(vertical, horizontal: int): Insets =
  ## Creates vertical and horizontal edge insets.
  Insets(top: max(0, vertical), right: max(0, horizontal),
    bottom: max(0, vertical), left: max(0, horizontal))

func insets*(top, right, bottom, left: int): Insets =
  ## Creates explicit edge insets.
  Insets(top: max(0, top), right: max(0, right), bottom: max(0, bottom),
    left: max(0, left))

func isEmpty*(value: Rect): bool =
  ## True when the rectangle contains no cells.
  value.width <= 0 or value.height <= 0

func contains*(value: Rect, x, y: int): bool =
  ## True when a coordinate lies inside the half-open rectangle.
  x >= value.x and x < value.x + value.width and y >= value.y and
    y < value.y + value.height

func contains*(value: Rect, position: Point): bool =
  ## True when a point lies inside the rectangle.
  value.contains(position.x, position.y)

func intersection*(a, b: Rect): Rect =
  ## Returns the overlap of two rectangles.
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.width, b.x + b.width)
  let y2 = min(a.y + a.height, b.y + b.height)
  rect(x1, y1, max(0, x2 - x1), max(0, y2 - y1))

func union*(a, b: Rect): Rect =
  ## Returns the smallest rectangle containing both inputs.
  if a.isEmpty: return b
  if b.isEmpty: return a
  let x1 = min(a.x, b.x)
  let y1 = min(a.y, b.y)
  let x2 = max(a.x + a.width, b.x + b.width)
  let y2 = max(a.y + a.height, b.y + b.height)
  rect(x1, y1, x2 - x1, y2 - y1)

func inset*(value: Rect, amount: Insets): Rect =
  ## Shrinks a rectangle by clamped logical edge insets.
  let left = min(amount.left, value.width)
  let top = min(amount.top, value.height)
  let right = min(amount.right, value.width - left)
  let bottom = min(amount.bottom, value.height - top)
  rect(value.x + left, value.y + top,
    value.width - left - right, value.height - top - bottom)

func translate*(value: Rect, dx, dy: int): Rect =
  ## Moves a rectangle without changing its extent.
  rect(value.x + dx, value.y + dy, value.width, value.height)

func clampPoint*(value: Rect, position: Point): Point =
  ## Clamps a point to the nearest cell in a rectangle.
  if value.isEmpty:
    return point(value.x, value.y)
  point(clamp(position.x, value.x, value.x + value.width - 1),
    clamp(position.y, value.y, value.y + value.height - 1))
