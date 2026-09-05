import geometry
export geometry

type
  ConstraintKind* = enum
    csFixed
    csFill
    csPercent
    csMinMax
    csRatio
    csIntrinsic
  Constraint* = object
    case kind*: ConstraintKind
    of csFixed:
      n*: int
    of csFill:
      weight*: int
    of csPercent:
      p*: range[0..100]
    of csMinMax:
      minimum*, maximum*, flexWeight*: int
    of csRatio:
      numerator*, denominator*: int
    of csIntrinsic:
      preferred*, intrinsicMin*, intrinsicMax*: int

func fixed*(n: int): Constraint =
  ## A fixed-size constraint.
  Constraint(kind: csFixed, n: max(0, n))

func fill*(weight = 1): Constraint =
  ## A weighted fill constraint.
  Constraint(kind: csFill, weight: max(1, weight))

func percent*(p: range[0..100]): Constraint =
  ## A percentage constraint.
  Constraint(kind: csPercent, p: p)

func minmax*(minimum, maximum: int, weight = 1): Constraint =
  ## A flexible constraint bounded by an inclusive minimum and maximum.
  let minimum = max(0, minimum)
  Constraint(kind: csMinMax, minimum: minimum,
    maximum: max(minimum, maximum), flexWeight: max(1, weight))

func ratio*(numerator, denominator: int): Constraint =
  ## A fraction of the available axis, clamped to its remaining extent.
  Constraint(kind: csRatio, numerator: max(0, numerator),
    denominator: max(1, denominator))

func intrinsic*(preferred: int, minimum = 0,
    maximum = high(int)): Constraint =
  ## A caller-measured preferred size with explicit bounds.
  let minimum = max(0, minimum)
  Constraint(kind: csIntrinsic,
    preferred: clamp(preferred, minimum, max(minimum, maximum)),
    intrinsicMin: minimum, intrinsicMax: max(minimum, maximum))

proc distribute(total: int, constraints: openArray[Constraint],
    result: var openArray[int]) =
  ## Resolves constraint sizes for one axis into `result`. Fixed first,
  ## percent of total, remaining split among fills by weight with remainder
  ## to the last fill.
  var used = 0
  var fillWeight = 0
  var boundedWeight = 0
  var lastFill = -1
  var lastPercent = -1
  for i, c in constraints:
    case c.kind
    of csFixed:
      result[i] = min(max(0, c.n), max(0, total - used))
      used += result[i]
    of csPercent:
      result[i] = min(total * c.p div 100, max(0, total - used))
      used += result[i]
      lastPercent = i
    of csFill:
      fillWeight += c.weight
      lastFill = i
    of csMinMax:
      result[i] = min(c.minimum, max(0, total - used))
      used += result[i]
      boundedWeight += c.flexWeight
    of csRatio:
      result[i] = min(total * c.numerator div c.denominator,
        max(0, total - used))
      used += result[i]
      lastPercent = i
    of csIntrinsic:
      result[i] = min(clamp(c.preferred, c.intrinsicMin, c.intrinsicMax),
        max(0, total - used))
      used += result[i]
  let rest = max(0, total - used)
  var given = 0
  for i, c in constraints:
    if c.kind == csFill:
      result[i] = if fillWeight > 0: rest * c.weight div fillWeight else: 0
      given += result[i]
  var boundedRest = max(0, rest - given)
  var remainingWeight = boundedWeight
  for i, c in constraints:
    if c.kind == csMinMax and boundedRest > 0:
      let capacity = max(0, c.maximum - result[i])
      let share = if remainingWeight > 0:
        boundedRest * c.flexWeight div remainingWeight else: 0
      let extra = min(capacity, share)
      result[i] += extra
      boundedRest -= extra
      remainingWeight -= c.flexWeight
  if lastFill >= 0 and given < rest:
    result[lastFill] += boundedRest
  elif lastFill < 0 and lastPercent >= 0 and boundedRest > 0:
    result[lastPercent] += boundedRest

proc distribute(total: int, constraints: openArray[Constraint]): seq[int] =
  result = newSeq[int](constraints.len)
  distribute(total, constraints, result)

const inlineSplit = 16

proc sizesInto(total: int, constraints: openArray[Constraint],
    small: var array[inlineSplit, int], large: var seq[int]) =
  ## Resolves sizes on the stack for ordinary splits; only unusually long
  ## constraint lists allocate.
  if constraints.len <= inlineSplit:
    distribute(total, constraints, small.toOpenArray(0, constraints.len - 1))
  else:
    large = newSeq[int](constraints.len)
    distribute(total, constraints, large)

proc splitH*(r: Rect, constraints: varargs[Constraint]): seq[Rect] =
  ## Splits `r` horizontally (columns); later rects are zero-width on
  ## overflow, never negative.
  var small: array[inlineSplit, int]
  var large: seq[int]
  sizesInto(r.width, constraints, small, large)
  result = newSeq[Rect](constraints.len)
  var x = r.x
  for i in 0 ..< constraints.len:
    let size = if constraints.len <= inlineSplit: small[i] else: large[i]
    result[i] = Rect(x: x, y: r.y, width: size, height: r.height)
    x += size

proc splitV*(r: Rect, constraints: varargs[Constraint]): seq[Rect] =
  ## Splits `r` vertically (rows); later rects are zero-height on overflow.
  var small: array[inlineSplit, int]
  var large: seq[int]
  sizesInto(r.height, constraints, small, large)
  result = newSeq[Rect](constraints.len)
  var y = r.y
  for i in 0 ..< constraints.len:
    let size = if constraints.len <= inlineSplit: small[i] else: large[i]
    result[i] = Rect(x: r.x, y: y, width: r.width, height: size)
    y += size

func trim*(r: Rect, top, bottom, left, right: int): Rect =
  ## Shrinks `r` by the given edges, clamped to zero size.
  let left = min(max(0, left), r.width)
  let top = min(max(0, top), r.height)
  let right = min(max(0, right), r.width - left)
  let bottom = min(max(0, bottom), r.height - top)
  Rect(x: r.x + left, y: r.y + top,
    width: r.width - left - right, height: r.height - top - bottom)

func bottomLine*(r: Rect, n: int): Rect =
  ## The bottom `n` rows of `r`.
  let n = min(max(0, n), r.height)
  Rect(x: r.x, y: r.y + r.height - n, width: r.width, height: n)

type
  AxisAlign* = enum
    alignStart
    alignCenter
    alignEnd
    alignStretch

  Justify* = enum
    justifyStart
    justifyCenter
    justifyEnd
    justifySpaceBetween

  Breakpoint* = object
    minWidth*: int
    columns*: int

func breakpoint*(minWidth, columns: int): Breakpoint =
  ## Defines a responsive column count beginning at `minWidth`.
  Breakpoint(minWidth: max(0, minWidth), columns: max(1, columns))

func responsiveColumns*(width: int,
    breakpoints: openArray[Breakpoint], fallback = 1): int =
  ## Selects the matching column count independent of breakpoint order.
  result = max(1, fallback)
  var bestWidth = -1
  for candidate in breakpoints:
    if candidate.minWidth <= width and candidate.minWidth > bestWidth:
      bestWidth = candidate.minWidth
      result = candidate.columns

func aligned*(outer: Rect, desired: Size, horizontal = alignStart,
    vertical = alignStart): Rect =
  ## Places a clamped child according to independent axis alignment.
  let width = if horizontal == alignStretch: outer.width
    else: min(outer.width, desired.width)
  let height = if vertical == alignStretch: outer.height
    else: min(outer.height, desired.height)
  let x = case horizontal
    of alignStart, alignStretch: outer.x
    of alignCenter: outer.x + (outer.width - width) div 2
    of alignEnd: outer.x + outer.width - width
  let y = case vertical
    of alignStart, alignStretch: outer.y
    of alignCenter: outer.y + (outer.height - height) div 2
    of alignEnd: outer.y + outer.height - height
  rect(x, y, width, height)

func padded*(r: Rect, padding: Insets): Rect =
  ## Applies nonnegative padding to a layout area.
  r.inset(padding)

func centered*(outer: Rect, desired: Size): Rect =
  ## Centers a clamped desired size inside `outer`.
  let width = min(outer.width, desired.width)
  let height = min(outer.height, desired.height)
  rect(outer.x + (outer.width - width) div 2,
    outer.y + (outer.height - height) div 2, width, height)

proc splitH*(r: Rect, gap: int,
    constraints: openArray[Constraint]): seq[Rect] =
  ## Splits into columns with a fixed gap that never creates negative areas.
  let safeGap = max(0, gap)
  let available = max(0, r.width - safeGap * max(0, constraints.len - 1))
  let sizes = distribute(available, constraints)
  var x = r.x
  for width in sizes:
    result.add rect(x, r.y, width, r.height)
    inc x, width + safeGap

proc splitV*(r: Rect, gap: int,
    constraints: openArray[Constraint]): seq[Rect] =
  ## Splits into rows with a fixed gap that never creates negative areas.
  let safeGap = max(0, gap)
  let available = max(0, r.height - safeGap * max(0, constraints.len - 1))
  let sizes = distribute(available, constraints)
  var y = r.y
  for height in sizes:
    result.add rect(r.x, y, r.width, height)
    inc y, height + safeGap
