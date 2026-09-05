## Cell canvas drawing with Unicode and ASCII fallbacks.

import geometry
import render
import style

type CanvasMode* = enum
  canvasUnicode
  canvasAscii

proc point*(frame: Frame, position: Point, style = styleDefault(),
    mode = canvasUnicode) =
  ## Draws one canvas point.
  frame.write(position.x, position.y,
    if mode == canvasUnicode: "•" else: "*", style)

proc line*(frame: Frame, start, finish: Point, style = styleDefault(),
    mode = canvasUnicode) =
  ## Draws a clipped integer Bresenham line.
  var x0 = start.x
  var y0 = start.y
  let dx = abs(finish.x - x0)
  let sx = if x0 < finish.x: 1 else: -1
  let dy = -abs(finish.y - y0)
  let sy = if y0 < finish.y: 1 else: -1
  var error = dx + dy
  while true:
    frame.point(point(x0, y0), style, mode)
    if x0 == finish.x and y0 == finish.y:
      break
    let twice = error * 2
    if twice >= dy:
      error += dy
      x0 += sx
    if twice <= dx:
      error += dx
      y0 += sy

proc rectOutline*(frame: Frame, area: Rect, style = styleDefault(),
    mode = canvasUnicode) =
  ## Draws a rectangle outline with a documented ASCII fallback.
  if area.isEmpty:
    return
  let horizontal = if mode == canvasUnicode: "─" else: "-"
  let vertical = if mode == canvasUnicode: "│" else: "|"
  let corner = if mode == canvasUnicode: "┼" else: "+"
  for x in area.x ..< area.x + area.width:
    frame.write(x, area.y, horizontal, style)
    if area.height > 1:
      frame.write(x, area.y + area.height - 1, horizontal, style)
  for y in area.y ..< area.y + area.height:
    frame.write(area.x, y, vertical, style)
    if area.width > 1:
      frame.write(area.x + area.width - 1, y, vertical, style)
  frame.write(area.x, area.y, corner, style)
  if area.width > 1: frame.write(area.x + area.width - 1, area.y, corner, style)
  if area.height > 1: frame.write(area.x, area.y + area.height - 1, corner, style)
  if area.width > 1 and area.height > 1:
    frame.write(area.x + area.width - 1, area.y + area.height - 1,
      corner, style)
