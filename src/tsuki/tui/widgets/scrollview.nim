## Generic scroll viewport adapter.

import ../[render, scroll]

type ScrollRenderProc* = proc (viewport: Frame, offsetX,
  offsetY: int) {.closure.}

proc scrollView*(frame: Frame, state: var ScrollState, contentWidth,
    contentHeight: int, draw: ScrollRenderProc) =
  ## Updates shared scroll state and asks the host to draw only this viewport.
  ## The callback receives logical offsets, avoiding an allocated retained tree.
  state.update(frame.rect.width, frame.rect.height, contentWidth, contentHeight)
  if not draw.isNil:
    draw(frame, state.offsetX, state.offsetY)
