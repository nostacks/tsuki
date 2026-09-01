## Reusable scrolling, anchoring, and visible-range calculation.

type
  ScrollAnchor* = enum
    anchorStart
    anchorEnd
    anchorItem

  VisibleRange* = object
    first*: int
    last*: int

  ScrollState* = object
    offsetX*: int
    offsetY*: int
    viewportWidth*: int
    viewportHeight*: int
    contentWidth*: int
    contentHeight*: int
    anchor*: ScrollAnchor
    anchorIndex*: int

func maxOffsetX*(state: ScrollState): int =
  max(0, state.contentWidth - state.viewportWidth)

func maxOffsetY*(state: ScrollState): int =
  max(0, state.contentHeight - state.viewportHeight)

proc clamp*(state: var ScrollState) =
  ## Clamps offsets after content or viewport changes.
  state.offsetX = clamp(state.offsetX, 0, state.maxOffsetX)
  state.offsetY = clamp(state.offsetY, 0, state.maxOffsetY)

func atEnd*(state: ScrollState): bool =
  ## True when the viewport is bottom-anchored.
  state.offsetY >= state.maxOffsetY

proc update*(state: var ScrollState, viewportWidth, viewportHeight,
    contentWidth, contentHeight: int) =
  ## Updates extents while preserving start/end/item anchoring.
  let wasAtEnd = state.atEnd or state.anchor == anchorEnd
  state.viewportWidth = max(0, viewportWidth)
  state.viewportHeight = max(0, viewportHeight)
  state.contentWidth = max(0, contentWidth)
  state.contentHeight = max(0, contentHeight)
  if wasAtEnd:
    state.offsetY = state.maxOffsetY
  elif state.anchor == anchorItem and state.anchorIndex >= 0:
    state.offsetY = min(state.anchorIndex, state.maxOffsetY)
  state.clamp()

proc scrollBy*(state: var ScrollState, dx, dy: int) =
  ## Scrolls by cell deltas and releases end anchoring when moving upward.
  state.offsetX += dx
  state.offsetY += dy
  if dy < 0:
    state.anchor = anchorStart
  elif state.offsetY >= state.maxOffsetY:
    state.anchor = anchorEnd
  state.clamp()

proc ensureVisible*(state: var ScrollState, start, extent: int) =
  ## Scrolls the smallest amount needed to reveal a vertical item range.
  let finish = start + max(1, extent)
  if start < state.offsetY:
    state.offsetY = start
  elif finish > state.offsetY + state.viewportHeight:
    state.offsetY = finish - state.viewportHeight
  state.anchor = anchorItem
  state.anchorIndex = start
  state.clamp()

func visibleRange*(state: ScrollState, itemCount: int,
    overscan = 1): VisibleRange =
  ## Returns a half-open item range for fixed-one-row virtual content.
  let extra = max(0, overscan)
  result.first = clamp(state.offsetY - extra, 0, max(0, itemCount))
  result.last = clamp(state.offsetY + state.viewportHeight + extra,
    result.first, max(0, itemCount))
