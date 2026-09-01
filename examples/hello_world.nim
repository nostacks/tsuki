import tsuki/tui

proc update(event: Event): Update =
  if event.isQuit: quitTui() else: unchanged()

proc draw(frame: var Frame) =
  let card = frame.modal(size(46, 7), "tsuki", darkTheme())
  card.text("Hello, world!", darkTheme().accent, align = textCenter)
  card.sub(rect(0, 2, card.rect.width, 1)).text(
    "A fast, tiny, modular coding agent.", align = textCenter)
  card.sub(rect(0, 4, card.rect.width, 1)).text(
    "Esc or Ctrl-Q to leave", darkTheme().muted, align = textCenter)

discard runTui(update, draw)
