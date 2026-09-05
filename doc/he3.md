# he3 library guide

he3 is the terminal UI framework inside Tsuki. This guide is for people who
want to build their own terminal program on it. The [quick start](index.md)
is a shorter tour, [migration notes](migration.md) cover the pre-1.0 API
changes, and `nimble docs` generates the per-symbol API reference under
`doc/htmldocs`.

Contents:

1. [What he3 is](#what-he3-is)
2. [Getting started](#getting-started)
3. [The runtime model](#the-runtime-model)
4. [Events](#events)
5. [Drawing with frames](#drawing-with-frames)
6. [Safe text](#safe-text)
7. [Styles and themes](#styles-and-themes)
8. [Layout](#layout)
9. [Widgets](#widgets)
10. [Custom widgets](#custom-widgets)
11. [Host loops, timers, and worker threads](#host-loops-timers-and-worker-threads)
12. [Terminal capabilities and protocols](#terminal-capabilities-and-protocols)
13. [Testing without a terminal](#testing-without-a-terminal)
14. [The expert facade](#the-expert-facade)
15. [Depending on he3 from another project](#depending-on-he3-from-another-project)
16. [Multiple packages in one repository](#multiple-packages-in-one-repository)

## What he3 is

he3 is an immediate-mode terminal UI runtime with retained double buffers.
Your program owns all durable state. When an event arrives you update that
state and tell the runtime whether the screen changed. When the runtime decides
to draw, it hands you a clipped `Frame`, you paint the whole desired screen
into it, and he3 diffs the result against the previous frame and writes only
the changed cells. Nothing you draw is retained between frames except the
buffers themselves.

The framework owns:

- terminal entry and restoration, including signals, suspend, and exit hooks;
- keyboard, mouse, paste, focus, resize, and timer events;
- Unicode-safe cell buffers, diffing, and terminal output;
- layout helpers, a widget library, and focus/pointer/overlay bookkeeping;
- a deterministic headless mode for tests.

The framework does not own model transports, credentials, tool execution, or
authorization policy. Those belong to the host program, which is why the
Tsuki agent lives beside he3 rather than inside it.

There are no third-party runtime dependencies. Idle programs block in one OS
wait. There is no periodic polling and no redraw without a request.

## Getting started

he3 requires Nim 2.2 or newer and must be compiled with `--threads:on`. Its
public import path is `he3`; everything an ordinary program needs is
re-exported from that one module.

```nim
import he3

proc update(event: Event): Update =
  if event.isQuit: quitTui() else: unchanged()

proc draw(frame: var Frame) =
  frame.text("Hello, world!", align = textCenter)

discard runTui(update, draw)
```

Build and run it from a checkout of this repository:

```sh
nim c -r --threads:on --path:packages/he3/src hello.nim
```

See [Depending on he3 from another project](#depending-on-he3-from-another-project)
for the options outside this repository.

The repository keeps exactly three examples: `examples/hello_world.nim`,
`examples/counter.nim`, and `examples/agent_chat.nim`. The counter is the best
template for a small program because it separates a pure update function and
a pure draw function from the runtime, which keeps both testable.

## The runtime model

`runTui(update, draw, options)` opens the terminal, draws once, and then loops:
wait for one event, call `update`, drain any burst of further events, and draw
again only when something asked for it. It returns a `TuiResult[RunStats]`.
The `ok` field says whether the session ran; `error` carries a message when
opening or running the terminal failed. The terminal is always restored before
the call returns, including on exceptions.

A draw-only overload, `runTui(draw, options)`, quits on the standard quit keys
and is enough for static screens.

### Updates

An `update` handler returns an `Update` that describes the effect it wants:

| Constructor | Effect |
|---|---|
| `unchanged()` | Nothing to draw. The loop goes back to sleep. |
| `redraw()` | Draw one frame, paced by `maxFramesPerSecond`. |
| `redrawAt(deadline)` | Draw no earlier than a monotonic deadline. Earliest pending deadline fires first, later ones are re-armed. |
| `quitTui()` | Restore the terminal and leave the loop. |
| `suspendTui()` | Restore the terminal, stop the process with SIGTSTP, and re-enter after resume. Non-POSIX and headless hosts terminate cleanly instead. |

A resize always redraws. When an interactive terminal's input reaches
end-of-file the loop ends on its own.

### Options

`tuiOptions` creates validated runtime settings:

| Field | Default | Meaning |
|---|---|---|
| `mode` | `tmFullscreen` | `tmFullscreen` uses the alternate screen, `tmInline` draws in the normal screen, `tmHeadless` renders into memory only. |
| `mouse` | `false` | Enables SGR mouse tracking. |
| `probeCapabilities` | `true` | Sends startup queries for the kitty keyboard protocol and synchronized output. |
| `maxFramesPerSecond` | `60` | Caps how often `redraw()` produces a frame. |
| `headlessWidth`, `headlessHeight` | `80`, `24` | Viewport used by `tmHeadless`. |
| `maxPostedEvents` | `4096` | Bound of the cross-thread event queue. |

```nim
import he3

let options = tuiOptions(mode = tmInline, mouse = true,
  maxFramesPerSecond = 30)
discard runTui(proc (frame: var Frame) = frame.text("inline"), options)
```

### Scheduling rules

- The only scheduling sources are `redraw`, `redrawAt`, application timers,
  posted events, and terminal input. There is no implicit tick.
- Bursts of posted events are drained in bounded batches and collapse into one
  frame.
- `RunStats` counts waits, wakeups, update calls, draw calls, and frames that
  actually wrote bytes. Headless tests use it to prove that idle loops sleep.

## Events

Terminal replies that are strings rather than keys (APC, OSC, DCS, PM, and
SOS, such as a graphics acknowledgement or a clipboard answer) are consumed
by the parser and never surface as typed text. An introducer that is never
terminated resolves at the deadline as its Alt key, so legacy Alt-] input
still works.

`Event` is an object variant. `kind` selects the payload:

| Kind | Payload | Source |
|---|---|---|
| `evKey` | `key: Key` | Keyboard, including the kitty protocol. |
| `evMouse` | `mouse: MouseEvent` | SGR mouse tracking when `mouse = true`. |
| `evResize` | `width`, `height` | Terminal size change. |
| `evPaste` | `text` | Bracketed paste, delivered as one sanitized string. |
| `evTimer` | `timerId` | An application timer created with `setTimer`. |
| `evFocus` | `focused` | Terminal focus in/out. |
| `evUser` | `name`, `payload` | Events posted by the application, usually from another thread. |
| `evNone` | none | Returned by host loops when a wait ended without an event. |

`Key` has a `code: KeyCode`, a `char: Rune` for `kcChar`, a `mods` set
(`modShift`, `modCtrl`, `modAlt`, `modSuper`, and others), and a `released`
flag for terminals that report key release.

Matching helpers keep handlers short:

```nim
import he3

proc update(event: Event): Update =
  if event.isQuit: return quitTui()
  if event.isSuspend: return suspendTui()
  if event.kind == evKey:
    if event.key.isChar('s', {modCtrl}): return redraw()
    if event.key.isKey(kcF5): return redraw()
    if event.key.isKey(kcUp, {modShift}): return redraw()
  if event.isClick(): return redraw()
  if event.wheelDelta != 0: return redraw()
  unchanged()
```

- `isQuit` matches Escape, Ctrl-C, and Ctrl-Q. `isCancel` matches Escape and
  Ctrl-C. `isSubmit` matches an unmodified Enter. `isSuspend` matches Ctrl-Z.
- `isChar` and `isKey` compare the exact modifier set and ignore releases.
- `isClick`, `isDrag`, `isHover`, and `isMouse` match mouse actions.
  `wheelDelta` returns `+1` for wheel up or left, `-1` for down or right.
- `MouseClickTracker.isDoubleClick` recognizes two presses at the same cell
  within a bounded interval. The tracker is small application-owned state.
- `userEvent(name, payload)` builds an `evUser` for posting.

## Drawing with frames

The draw callback receives a `Frame`. A frame is a clipped window into the
back buffer with its own local coordinate system and a base style. Every
coordinate you pass is relative to the frame's `rect` and anything outside it
is silently dropped, so drawing code never has to bounds check.

| Call | Purpose |
|---|---|
| `frame.sub(rect, style)` | A nested frame translated by and clipped to the parent. |
| `frame.write(x, y, text, style)` | Sanitizes and writes a string or a byte range (`openArray[char]`) without copying safe text. Newlines start a new row. |
| `frame.write(x, y, richText)` | Writes a `Text` value with per-span styles. |
| `frame.hintScroll(rows)` | Tells the renderer this frame's rows moved by `rows` since the last frame (positive is up). The diff may scroll the terminal region instead of repainting it; drawing is unaffected. |
| `frame.fill(rect, rune, style)` | Fills a rectangle with one rune. |
| `frame.clear(rect, style)` | Fills with spaces. `clearAll` clears the whole frame. |
| `frame.tint(rect, style)` | Restyles cells without changing glyphs. |

```nim
import he3

proc draw(frame: var Frame) =
  let colors = darkTheme()
  frame.clear(rect(0, 0, frame.rect.width, frame.rect.height),
    colors.background)
  let panes = frame.rect.splitV(fixed(1), fill(), fixed(1))
  frame.sub(panes[0]).text("Title", colors.accent, align = textCenter)
  let body = frame.sub(panes[1]).block("Body", colors.border, rounded = true)
  body.paragraph("Frames clip for you. Write anywhere and only the visible " &
    "cells reach the terminal.")
  frame.sub(panes[2]).help([("Esc", "quit"), ("Ctrl-Z", "suspend")], colors)
```

Frames are cheap values. Building one per widget per frame is the intended
pattern; no allocation or retained node is created.

Wide characters, combining marks, emoji sequences, and other grapheme clusters
occupy the right number of cells and are never split. A cluster that does not
fit at the right edge is dropped rather than truncated mid-cluster. The width
of ambiguous East Asian characters follows the buffer's `WidthPolicy`.

## Safe text

Every string that reaches a buffer is sanitized first. The default policy,
`plainTextPolicy`, keeps newlines and tabs and replaces every other terminal
control, C1 control, bidi override, and malformed UTF-8 byte with U+FFFD. It
also bounds the accepted byte and code point counts. This applies to
`Frame.write`, every widget, paste events, and log views, so untrusted input
cannot inject escape sequences.

Other policies change the representation, not the guarantee:

- `escapedControlPolicy` shows controls as visible symbols.
- `replacementPolicy` replaces every unsafe or invalid code point.
- `parsedAnsiPolicy` marks input for the opt-in ANSI parser below. Plain write
  paths still treat it as replacement.

`sanitizeText(input, policy)` and `isSanitized(input, policy)` are available
when you need to clean a string once and keep it.

Subprocess output that intentionally carries colors goes through
`parseAnsiText`. It allowlists SGR styling and turns every other escape (OSC,
cursor movement, clipboard, title, images) into an inert visible label. The
result is a `Text` value:

```nim
import he3

proc draw(frame: var Frame) =
  let styled = parseAnsiText("\e[1;32mpassed\e[0m 12 tests")
  frame.richText(styled, wrap = true)
```

`Text` is a sequence of `Line`s, each a sequence of `Span`s carrying a
string, a `Style`, and an optional `Hyperlink`. A `Line` may also carry an
`ImageRef`: views that can show images resolve its `source` through the host
and draw the line's spans as the caption or fallback. Build text with
`initText`, `initLine`, `initSpan`, and `add`. `richText` wraps at grapheme
boundaries, respects explicit lines, and attaches span hyperlinks to the cells
it writes; `paragraph` does greedy word wrapping for plain strings.

The agent toolkit under `he3/agent` builds on this: `parseMarkdown` and the
streaming `MarkdownState` cover headings, emphasis, strikethrough, code,
links, autolinks, images, nested and ordered lists, task lists, quotes,
rules, tables, and math; `highlightLine` tokenizes one source line per
language with block-comment state carried between lines; `renderMath` turns
LaTeX into Unicode text. Every construct is decided from one line plus the
block state before it, so streamed output equals one-shot parsing.

Grapheme utilities for measuring and clipping your own strings: `cellWidth`,
`truncateCells` (clips at cluster boundaries and appends a single ellipsis),
`writeFit` (writes the fitting prefix of a byte range straight into a frame),
`textWidth`, `clusterWidth`, and `graphemeSpans`. All of them measure
without allocating; the `graphemes` iterator copies each cluster and is for
convenience, not hot paths.

## Styles and themes

A `Style` is a foreground `Color`, a background `Color`, and a set of
attributes. Colors are four-byte values built with `named(ncRed)`,
`indexed(208)`, or `rgb(180, 142, 255)`; a default `Color()` means the
terminal default. Style builders chain:

```nim
import he3

let heading = fg(rgb(180, 142, 255)).bold
let selected = fg(named(ncBrightWhite)).withBg(rgb(94, 61, 153))
let subtle = styleDefault().dimmed.italic
```

Attributes are `attrBold`, `attrDim`, `attrItalic`, `attrUnderline`,
`attrBlink`, `attrReverse`, and `attrStrikethrough`. `withAttrs` and
`withoutAttrs` edit the set directly.

`downgrade(style, depth)` maps any color to a `ColorDepth` (`colorTrue`,
`color256`, `color16`, `colorNone`) without touching attributes, so a program
can keep one true-color palette and degrade it for the terminal it lands on.

A `Theme` is a set of semantic roles: `background`, `text`, `muted`,
`accent`, `border`, `selection`, `error`, `warning`, `success`, `code`,
`diffAdd`, `diffRemove`, `focus`, and `disabled`. Widgets take a theme through
their `colors` parameter and never borrow a color from an unrelated role.
Built-in themes are `darkTheme`, `lightTheme`, `monochromeTheme`,
`noColorTheme`, and `highContrastTheme`; `theme(kind)` selects one by
`ThemeKind`, and `downgrade(theme, depth)` degrades every role consistently.

Status is always redundant in widget text: a selected row has a marker as well
as a style, a log line has a level cue as well as a color. Keep that habit in
your own widgets so monochrome and no-color themes stay usable.

## Layout

`Rect`, `Size`, `Point`, and `Insets` are plain value types with helpers:
`contains`, `intersection`, `union`, `inset`, `translate`, `clampPoint`,
`isEmpty`, `trim`, and `bottomLine`.

`splitH` and `splitV` divide a rectangle into columns or rows using
constraints:

| Constraint | Meaning |
|---|---|
| `fixed(n)` | Exactly `n` cells, clamped to what remains. |
| `fill(weight)` | Share of the space left after fixed sizes, by weight. |
| `percent(p)` | `p` percent of the whole axis. |
| `ratio(num, den)` | A fraction of the whole axis. |
| `minmax(lo, hi, weight)` | At least `lo`, grows toward `hi` with leftover space. |
| `intrinsic(preferred, lo, hi)` | A measured size with explicit bounds. |

Sizes are resolved fixed first, then percent and ratio, then fills, then
bounded growth. Later rectangles become zero-sized on overflow, never negative.
An overload with a `gap` argument inserts fixed spacing between children.

```nim
import he3

proc draw(frame: var Frame) =
  let columns = frame.rect.splitH(1, [minmax(20, 32), fill()])
  let sidebar = frame.sub(columns[0])
  let main = frame.sub(columns[1])
  sidebar.text("Sidebar")
  let card = main.rect.centered(size(40, 8))
  main.sub(card).block("Centered", rounded = true).text("40 by 8")
```

Placement helpers: `centered(outer, desired)`, `aligned(outer, desired,
horizontal, vertical)` with `AxisAlign` values, and `padded(rect, insets)`.
`breakpoint` and `responsiveColumns` choose a column count from the current
width so one draw function can adapt to narrow and wide terminals.

## Widgets

Widgets are plain procedures that draw into a frame. They follow one
convention:

- A drawing proc is named after the widget, takes the `Frame` first, and
  fills the frame's rect. It never allocates a retained component.
- Widgets with durable state take a state object that the application owns
  and passes in, for example `ListState` or `TextareaState`.
- Keyboard behavior lives in a matching `xxxEvent(state, event, ...)` proc
  that mutates the state and reports whether anything changed. Call it from
  `update`, and draw from `draw`.
- Colored widgets accept `colors = darkTheme()`.

```nim
import he3

const items = ["Build", "Test", "Bench", "Docs"]
var list = initListState()

proc update(event: Event): Update =
  if event.isQuit: return quitTui()
  if list.listEvent(event, items.len): redraw() else: unchanged()

proc draw(frame: var Frame) =
  let inner = frame.block("Tasks", darkTheme().border, rounded = true)
  inner.list(items, list, focused = true)

discard runTui(update, draw)
```

### Catalog

Display (`widgets/display`, `widgets/border`, `widgets/paragraph`):

| Widget | Notes |
|---|---|
| `text` | One line with `textStart`, `textCenter`, or `textEnd` alignment and optional ellipsis. |
| `richText` | Styled `Text` with wrapping and scrolling. |
| `paragraph` | Greedy word wrapping for plain strings with a scroll offset. |
| `border`, `block` | A frame border with optional title; `block` returns the inset frame. |
| `rule` | A horizontal rule with an optional label. |
| `help` | Key and description pairs for a footer. |
| `spacer` | Occupies layout space without drawing. |

Data (`widgets/data`):

| Widget | State | Notes |
|---|---|---|
| `list` | `ListState` | Virtualized rows, arrows, page keys, Home, End. |
| `table` | `TableState` | Columns from `tableColumn`; width zero shares remaining room. |
| `tree` | `TreeState` | Caller-flattened rows with expand and collapse. |
| `tabs` | `TabsState` | Horizontally scrollable tabs. |
| `breadcrumb` | none | Path segments with separators. |
| `scrollbar` | `ScrollState` | Proportional thumb with arrows. |

Controls (`widgets/controls`):

| Widget | State | Notes |
|---|---|---|
| `button` | `ButtonState` | Enter or Space activates; `activated(event)` is the shared test. |
| `checkbox`, `toggle` | `ChoiceState` | Glyph plus style for the checked state. |
| `radio` | `RadioState` | One choice among labels. |
| `select` | `SelectState` | A dropdown that opens in place. |
| `slider` | `SliderState` | Numeric range with a step; `initSliderState` validates bounds. |
| `menu` | `MenuState` | Keyboard menu. |
| `form` | `FormState` | Labeled fields with `validate` for required values. |

Text input (`widgets/editor`, `widgets/textarea`):

| Widget | State | Notes |
|---|---|---|
| `editor` | `EditorState` | Single line with history. `editorKey` returns `eaConsumed`, `eaIgnored`, or `eaSubmit`. |
| `textarea` | `TextareaState` | Multiline with selection, undo and redo, paste, masking, and read-only mode. `textareaEvent` returns a `TextareaAction`; `taCopy` leaves the clipboard decision to the host. |

Feedback (`widgets/feedback`, `widgets/spinner`):

| Widget | State | Notes |
|---|---|---|
| `progress` | none | Gauge with a numeric percentage. |
| `sparkline`, `chart` | none | Numeric series in cells. |
| `logView` | `LogViewState` | Bounded ring of sanitized lines that follows new output. |
| `Spinner` | `Spinner` | `initSpinner`, `next`, `current`; `spinnerShouldAnimate` honors reduced motion. |

Composition (`widgets/composition`, `widgets/scrollview`):

| Widget | State | Notes |
|---|---|---|
| `splitPane` | `SplitPaneState` | Two panes and a keyboard-resizable divider. `splitAreas` resolves the rects. |
| `popup`, `modal` | none | Return a clipped inner frame placed near an anchor or centered. |
| `tooltip` | none | Short text near an anchor; returns its hit area. |
| `toast` | none | Status cue plus message. |
| `commandPalette` | `CommandPaletteState` | Searchable command list; `paletteMatches` filters. |
| `scrollView` | `ScrollState` | Calls back with offsets so you draw only the viewport. |

Compatibility modules such as `widgets/list` and `widgets/modal` re-export the
grouped modules above so older import paths keep working.

Spinners and other animation should schedule their next frame with
`redrawAt` or an application timer only while visible, and should stop when
`AccessibilityPreferences.reducedMotion` is set.

## Custom widgets

The public building blocks are enough to write a control without touching
private modules.

`Widget` and `StatefulWidget[S]` are callback contracts: a render proc, an
event proc that returns `werIgnored`, `werConsumed`, or `werRedraw`, an
optional measure proc, and `disabled` and `hidden` flags. Identify widgets
with `widgetId(n)`; zero is invalid.

`FocusState` tracks keyboard focus across an immediate-mode frame. Register
every focusable widget in reading order while drawing, then finish the frame
so focus lands somewhere valid:

```nim
import he3

var focus: FocusState

proc draw(frame: var Frame) =
  focus.beginFrame()
  let rows = frame.rect.splitV(fixed(1), fixed(1), fixed(1))
  for index, row in rows:
    let id = widgetId(index + 1)
    focus.register(id, row)
    frame.sub(row).button("Action " & $(index + 1),
      focused = focus.current == id)
  focus.finishFrame()

proc update(event: Event): Update =
  if event.isQuit: return quitTui()
  if event.kind == evKey and event.key.isKey(kcTab):
    discard focus.move(focusForward)
    return redraw()
  if event.kind == evKey and event.key.isKey(kcDown):
    discard focus.move(focusDown)
    return redraw()
  unchanged()

discard runTui(update, draw)
```

`move` accepts `focusForward`, `focusBackward`, `focusUp`, `focusDown`,
`focusLeading`, and `focusTrailing`; directional moves pick the nearest widget
by geometry. `pushScope` and `popScope` trap focus inside a modal and restore
the trigger afterward.

`HitMap` does the same for the pointer. Call `beginFrame`, `register` each
target with an optional parent and layer, then `hitTest(point)` or
`route(mouseEvent)` to get the target and its parent chain for bubbling.
`capture` and `releaseCapture` keep drags attached to one widget.

`OverlayStack` orders popups, menus, tooltips, modals, and toasts. `push`
replaces a layer with the same id, `top` returns the highest layer, and
`blocksBackground` says whether a modal should swallow background input.
`placePopup` picks a position below or above an anchor that stays inside the
viewport.

`ScrollState` holds offsets, viewport and content extents, and an anchor.
`update` preserves end anchoring when content grows, `scrollBy` moves,
`ensureVisible` reveals an item, and `visibleRange` gives the item window for
virtualized rendering. The `scrollView` widget wires it to a viewport
callback.

The `canvas` module draws points, lines, and outlines with Unicode or ASCII
glyphs when you need shapes rather than text.

## Host loops, timers, and worker threads

`runTui` is the recommended entry point, but a host can drive the runtime
itself with `openTui`, `wait` or `poll`, `apply`, `draw`, and `close`. This
is how Tsuki's agent shell integrates. The pieces give the same pacing as
`runTui` as long as `apply` is used for every `Update`.

```nim
import std/[os, times]
import he3

type Shared = object
  reactor: Reactor

proc worker(shared: ptr Shared) {.thread.} =
  for tick in 1 .. 5:
    sleep(300)
    discard shared.reactor.post(userEvent("tick", $tick))

proc main() =
  var opened = openTui()
  if not opened.ok:
    quit(opened.error)
  var app = move(opened.value)
  defer: app.close()
  var shared = Shared(reactor: app.ui.reactor)
  var thread: Thread[ptr Shared]
  createThread(thread, worker, addr shared)
  var latest = "waiting"
  let heartbeat = app.setTimer(initDuration(seconds = 2))
  app.draw proc (frame: var Frame) = frame.text(latest)
  while app.running:
    let event = app.wait()
    if event.kind == evNone and app.ui.inputClosed:
      break
    case event.kind
    of evUser:
      latest = "tick " & event.payload
      app.apply(redraw())
    of evTimer:
      if event.timerId == uint64(heartbeat):
        latest = "heartbeat"
        app.apply(redraw())
    of evResize:
      app.apply(redraw())
    else:
      if event.isQuit:
        app.apply(quitTui())
    if app.running and app.dirty:
      app.draw proc (frame: var Frame) = frame.text(latest)
  joinThread(thread)

main()
```

Rules for this mode:

- `wait` blocks until one event or deadline. It returns `evNone` with `dirty`
  set when a redraw deadline fired. `poll(timeoutMs)` is the bounded variant
  for hosts that already have their own loop.
- `post` is safe from any thread. Retain `app.ui.reactor` for workers rather
  than the application handle. The first queued event wakes the UI thread and
  further events coalesce behind it. At the queue bound, adjacent user events
  with the same name replace each other; other events are rejected so the
  producer can apply backpressure.
- `setTimer(delay)` returns a `TimerId` that later arrives as an `evTimer`.
  `cancelTimer` cancels it. Timer ids belong to the session that created them;
  after `suspend` returns a new session, re-create them.
- Cross-thread work must go through the reactor queue or the typed agent
  event queues. Never mutate UI state from another thread.
- The `Backend` adapter type exists for hosts that are not a terminal. It
  bundles capabilities with write, wait, size, and close callbacks.

## Terminal capabilities and protocols

`detectCapabilities()` reads non-authoritative hints from `TERM`,
`COLORTERM`, `TERM_PROGRAM`, `NO_COLOR`, and the locale and returns a
conservative `TerminalCapabilities` value without blocking probes. It reports
color depth, kitty keyboard support, SGR mouse, focus events, synchronized
output, scroll regions, hyperlinks, clipboard, image protocols, Unicode, and
the width policy. `monochromeCapabilities()` is the deterministic lowest
profile. With `probeCapabilities` on, startup also sends a DECRQM query for
synchronized output (mode 2026) alongside the kitty keyboard query, and a
terminal's answer overrides the environment guess.

Cells can carry hyperlinks and frames can reserve image boxes; both are
capability-gated and travel through the ordinary diff:

- `Frame.link(uri)` interns a URI for the frame and `linkCells` attaches it
  to cells. When the terminal advertises hyperlinks the diff wraps exactly
  those cells in OSC 8, closing the link before any unlinked cell, erase, or
  frame end. URIs containing control bytes are never emitted.
- `Frame.image(x, y, cols, rows, imageId)` blanks a cell box and records a
  placement. The host registers PNG bytes with `Ui.registerImage` and frees
  them with `forgetImage`. With the kitty graphics protocol the data is
  transmitted once and each placement is a small command with a cropped
  source rectangle when an edge cuts the box; with iTerm2 inline images the
  payload accompanies each fully visible placement. Placements are diffed
  like cells: nothing is re-sent for an unchanged frame, moved or dropped
  boxes are deleted before the cell diff repaints beneath them, and a full
  repaint deletes and re-places everything. `Out.deferPlacements` lets a host
  skip new placements while content is moving; the agent shell sets it while
  the transcript offset changes and clears it 150 ms after the last change,
  so a fast scroll deletes stale images but places each image once at rest.
  Multiplexers disable images.
- Sixel is detected but not emitted; it would need a pixel decoder.

Optional protocols live under `he3/protocols` and are not part of the
main facade. Each one requires an advertised capability and returns bytes or a
safe fallback rather than writing to the terminal itself:

- `hyperlink.encodeHyperlink` emits OSC 8 only for a `safeUri` and a
  terminal that advertises links. The label is always sanitized.
- `clipboard.encodeClipboardWrite` emits OSC 52 only when the caller passes
  `explicitlyAllowed = true`, the terminal advertises the protocol, and the
  payload stays within the byte limit. Copying is an external effect, so the
  decision must be the application's.
- `image` chooses a protocol, validates a PNG payload against bounds, and
  encodes kitty graphics chunks together with a mandatory alt text fallback.
- `syncoutput` returns the synchronized output markers, which the runtime
  already wraps around every frame on terminals that support them.
- Scroll regions (`DECSTBM` with `SU`/`SD`) are used only for a frame that
  carries a scroll hint, and only when every cell beside the hinted rows is
  blank, so nothing outside the region can move. The transcript view hints
  its own scrolling; the diff repaints whatever the scroll did not cover.

Everything else is plain cells. When a capability is false the framework never
emits the protocol.

## Testing without a terminal

Two tools make he3 programs testable in CI.

`HeadlessTui` renders into a buffer and exposes semantic cells. It never
touches the terminal:

```nim
import std/strutils
import he3

proc draw(frame: var Frame) =
  frame.text("Hello", darkTheme().accent, align = textCenter)

var harness = initHeadlessTui(20, 3)
harness.draw(draw)
let rows = harness.snapshot().split('\n')
doAssert rows[0].strip == "Hello"
for cell in harness.cells:
  if cell.glyph == "H":
    doAssert cell.style == darkTheme().accent
```

`snapshot` serializes glyphs without any ANSI bytes, which makes it stable for
golden tests. `cells` includes styles and wide-cell tail markers. `push` and
`next` queue synthetic events for driving pure update functions.

`runTui` and `openTui` accept `tuiOptions(mode = tmHeadless)` for
whole-program tests. The returned `RunStats` proves scheduling behavior, for
example that an idle program performed one wait and one draw.

Keep `update` and `draw` free of terminal calls, as `examples/counter.nim`
does, and both become ordinary unit-testable procedures.

Package checks, run inside `packages/he3`: `nimble test` runs the debug and
release suites, `nimble fuzz` runs bounded property tests, `nimble bench`
runs the rendering benchmarks against `bench/baseline.txt`, and
`nimble docs` builds the API reference. The repository root runs the same
tasks plus `nimble examples`, which compiles the three examples.

## The expert facade

`he3/expert` re-exports the buffer, diff, render, terminal session, low
level `Ui`, and the output writer. It is for framework authors, benchmarks,
and hosts that need to manipulate output sinks directly. Ordinary programs
should not import it, and nothing under `he3/private` is public API.

## Depending on he3 from another project

he3 is its own Nimble package in `packages/he3` of the Tsuki repository. Its
package name and import path are both `he3`.

1. Install it with Nimble. The `subdir` query points Nimble at the package
   inside the repository:

   ```sh
   nimble install "https://github.com/nostacks/tsuki?subdir=packages/he3"
   ```

   In your own `.nimble` file:

   ```nim
   requires "https://github.com/nostacks/tsuki?subdir=packages/he3"
   ```

2. Point the compiler at a checkout. This is what the root package, the
   examples, and the tests in this repository do:

   ```
   --path:"/path/to/tsuki/packages/he3/src"
   --threads:on
   ```

Both routes give the same modules: `he3` for the framework, `he3/agent` for
the agent views, `he3/protocols/...` for optional protocols, and
`he3/expert` for low-level work.

## Multiple packages in one repository

Nim has no direct counterpart to a Rust workspace with a `crates/` directory.
The pieces that exist:

- A Nimble package is a directory containing exactly one `.nimble` file. The
  package name must match its main module, so `he3.nimble` exposes
  `src/he3.nim` and `src/he3/...`. Nimble refuses a directory with two
  manifests.
- Nimble installs a package from a subdirectory of a repository with the
  `subdir` query, both on the command line and in `requires`.
- For local work across sibling packages, a plain `--path` in `nim.cfg` or a
  `<module>.nim.cfg` next to the main module is the simplest link and needs
  no Nimble resolution. `nimble develop` and `atlas link` are the tool-managed
  alternatives.
- A `requires` on a subdirectory URL makes Nimble clone the repository to
  read the dependency's manifest. It resolves against what is published, not
  the checkout it runs in, so a root package cannot require a sibling that
  only exists locally.

The ecosystem convention is still one package per repository. Monorepos are
uncommon, and when they exist they use one directory per package, each with
its own `.nimble`, `src`, and `tests`.

This repository uses that layout:

```
tsuki/
  tsuki.nimble              binary package, reaches he3 with --path
  src/tsuki.nim
  src/tsuki.nim.cfg         --path:"../packages/he3/src"
  src/tsuki/...
  tests/                    product tests
  examples/                 the three public examples
  packages/he3/
    he3.nimble              library package, srcDir = "src"
    src/he3.nim             facade
    src/he3/...             modules, private/, protocols/, agent/
    tests/                  he3 test suite and corpora
    bench/                  benchmarks and baseline.txt
```

The root manifest does not `requires` he3. The binary reaches it through the
compiler path in `src/tsuki.nim.cfg`, which works for a checkout and for
`nimble install` of the root URL because Nimble builds inside the full clone.
The root Nimble tasks run the product checks and then delegate to the
same-named task in `packages/he3`.
