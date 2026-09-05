## Deterministic headless frame and event test helpers.

import std/strutils
import buffer, event, geometry, render, style

type
  CellSnapshot* = object
    glyph*: string
    style*: Style
    tail*: bool

  HeadlessTui* = object
    ## In-memory render target with an O(1)-head event driver.
    buffer*: Buffer
    events: seq[Event]
    eventHead: int
    frames*: uint64

func initHeadlessTui*(width = 80, height = 24): HeadlessTui =
  ## Creates a deterministic cell target; no terminal state is touched.
  HeadlessTui(buffer: initBuffer(width, height))

proc resize*(harness: var HeadlessTui, width, height: int) =
  ## Resizes while retaining complete top-left graphemes.
  harness.buffer.resize(width, height)

proc push*(harness: var HeadlessTui, event: sink Event) =
  ## Queues one synthetic event.
  harness.events.add move(event)

proc next*(harness: var HeadlessTui, event: var Event): bool =
  ## Pops one synthetic event in O(1), compacting only at a large boundary.
  if harness.eventHead >= harness.events.len: return false
  event = move(harness.events[harness.eventHead])
  inc harness.eventHead
  if harness.eventHead == harness.events.len:
    harness.events.setLen 0
    harness.eventHead = 0
  elif harness.eventHead >= 1024 and harness.eventHead * 2 >=
      harness.events.len:
    let remaining = harness.events.len - harness.eventHead
    for index in 0 ..< remaining:
      harness.events[index] = move(harness.events[harness.eventHead + index])
    harness.events.setLen remaining
    harness.eventHead = 0
  true

proc draw*(harness: var HeadlessTui,
    callback: proc (frame: var Frame) {.closure.}) =
  ## Clears and renders exactly one semantic frame.
  harness.buffer.reset()
  var frame = initFrame(harness.buffer,
    rect(0, 0, harness.buffer.width, harness.buffer.height))
  callback(frame)
  inc harness.frames

func cells*(harness: HeadlessTui): seq[CellSnapshot] =
  ## Returns semantic cells, including styles and wide-tail markers.
  result = newSeq[CellSnapshot](harness.buffer.cells.len)
  for index, cell in harness.buffer.cells:
    result[index] = CellSnapshot(glyph: harness.buffer.glyphString(cell),
      style: cell.style, tail: cell.wideTail)

func snapshot*(harness: HeadlessTui, trimRight = true): string =
  ## Serializes visible glyphs without ANSI bytes for stable snapshot tests.
  for y in 0 ..< harness.buffer.height:
    var line = ""
    for x in 0 ..< harness.buffer.width:
      let cell = harness.buffer.cellAt(x, y)
      if not cell.wideTail:
        line.add harness.buffer.glyphString(cell)
    if trimRight: line = line.strip(leading = false, trailing = true)
    result.add line
    if y + 1 < harness.buffer.height: result.add '\n'

