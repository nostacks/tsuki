## A small centered counter on a solid light-gray terminal canvas.

import tsuki/tui

type CounterTheme = object
  background: Style
  text: Style
  muted: Style
  control: Style

func counterTheme(): CounterTheme =
  ## A compact neutral palette. Every role paints the same canvas color so the
  ## background remains solid even on terminals that reset styles per cell.
  let canvas = rgb(232, 234, 238)
  CounterTheme(
    background: bg(canvas).withFg(rgb(31, 34, 42)),
    text: fg(rgb(31, 34, 42)).withBg(canvas).bold,
    muted: fg(rgb(87, 93, 109)).withBg(canvas),
    control: fg(rgb(91, 45, 155)).withBg(canvas).bold)

proc updateCounter*(event: Event, value: var int): Update =
  ## Arrow keys and familiar character shortcuts operate the counter.
  if event.isQuit:
    return quitTui()
  if event.kind != evKey or event.key.released:
    return unchanged()
  case event.key.code
  of kcUp, kcRight, kcEnter:
    if value < high(int): inc value
    redraw()
  of kcDown, kcLeft:
    if value > low(int): dec value
    redraw()
  of kcChar:
    case event.key.char.int
    of ord('+'), ord('='):
      if value < high(int): inc value
      redraw()
    of ord('-'), ord('_'):
      if value > low(int): dec value
      redraw()
    of ord('r'), ord('R'):
      value = 0
      redraw()
    else:
      unchanged()
  else:
    unchanged()

proc drawCounter*(frame: var Frame, value: int) =
  ## Centers one compact vertical group and progressively removes secondary
  ## guidance when the terminal is too small to show it comfortably.
  let colors = counterTheme()
  frame.clear(rect(0, 0, frame.rect.width, frame.rect.height),
    colors.background)

  let centerY = frame.rect.height div 2
  if frame.rect.height >= 7:
    frame.sub(rect(0, centerY - 3, frame.rect.width, 1)).text(
      "COUNTER", colors.muted, align = textCenter, ellipsis = true)
  frame.sub(rect(0, max(0, centerY - 1), frame.rect.width, 1)).text(
    $value, colors.text, align = textCenter, ellipsis = true)

  if frame.rect.height >= 3:
    let controls = if frame.rect.width >= 34:
      "← / −  decrease     increase  + / →"
    else:
      "− / ←     + / →"
    frame.sub(rect(0, min(frame.rect.height - 1, centerY + 1),
      frame.rect.width, 1)).text(controls, colors.control,
      align = textCenter, ellipsis = true)

  if frame.rect.height >= 7:
    let help = if frame.rect.width >= 22: "R reset  ·  Esc quit"
      else: "R reset · Esc"
    frame.sub(rect(0, min(frame.rect.height - 1, centerY + 3),
      frame.rect.width, 1)).text(help, colors.muted,
      align = textCenter, ellipsis = true)

when isMainModule:
  var value = 0

  proc update(event: Event): Update =
    updateCounter(event, value)

  proc draw(frame: var Frame) =
    frame.drawCounter(value)

  discard runTui(update, draw)
