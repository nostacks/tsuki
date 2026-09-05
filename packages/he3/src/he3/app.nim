## Safe, invalidation-driven application lifecycle.

import std/[monotimes, times]
import buffer
import event
import layout
import reactor
import render
import term
import ui
import private/writer

when defined(posix):
  import std/posix as posixapi

type
  TuiMode* = enum
    tmFullscreen
    tmInline
    tmHeadless

  TuiOptions* = object
    ## Runtime configuration. Defaults are fullscreen, 60 FPS, no mouse, and
    ## no implicit animation/tick timer.
    mode*: TuiMode
    mouse*: bool
    probeCapabilities*: bool
    maxFramesPerSecond*: int
    headlessWidth*: int
    headlessHeight*: int
    maxPostedEvents*: int

  TuiResult*[T] = object
    ## Explicit success/error value used for initialization and run failures.
    case ok*: bool
    of true:
      value*: T
    of false:
      error*: string

  UpdateKind* = enum
    ukUnchanged
    ukRedraw
    ukRedrawAt
    ukQuit
    ukSuspend

  Update* = object
    ## Effect requested by an event handler.
    kind*: UpdateKind
    deadline*: MonoTime

  RunStats* = object
    ## Instrumentation useful to headless and idle-efficiency tests.
    waits*: uint64
    wakeups*: uint64
    updateCalls*: uint64
    drawCalls*: uint64
    renderedFrames*: uint64

  DrawProc* = proc (frame: var Frame) {.closure.}
  UpdateProc* = proc (event: Event): Update {.closure.}

  TuiApp* = object
    ## Explicit low-level application handle. Prefer `runTui` for scoped use.
    ui*: Ui
    options*: TuiOptions
    running*: bool
    dirty*: bool
    stats*: RunStats
    lastFrame: MonoTime
    deferredRedraw: TimerId
    deferredDeadline: MonoTime
    laterDeadline: MonoTime

func tuiOptions*(mode = tmFullscreen, mouse = false,
    probeCapabilities = true, maxFramesPerSecond = 60,
    headlessWidth = 80, headlessHeight = 24,
    maxPostedEvents = 4096): TuiOptions =
  ## Creates validated runtime options.
  TuiOptions(mode: mode, mouse: mouse,
    probeCapabilities: probeCapabilities,
    maxFramesPerSecond: max(1, maxFramesPerSecond),
    headlessWidth: max(1, headlessWidth),
    headlessHeight: max(1, headlessHeight),
    maxPostedEvents: max(1, maxPostedEvents))

func unchanged*(): Update =
  ## Requests no rendering work.
  Update(kind: ukUnchanged)

func redraw*(): Update =
  ## Requests one frame at the runtime's frame-rate limit.
  Update(kind: ukRedraw)

func redrawAt*(deadline: MonoTime): Update =
  ## Requests a frame no earlier than an exact monotonic deadline.
  Update(kind: ukRedrawAt, deadline: deadline)

func quitTui*(): Update =
  ## Requests clean terminal restoration and loop termination.
  Update(kind: ukQuit)

func suspendTui*(): Update =
  ## Requests scoped POSIX suspension. Unsupported hosts terminate cleanly.
  Update(kind: ukSuspend)

proc openTui*(options = tuiOptions()): TuiResult[TuiApp] =
  ## Opens a terminal or deterministic headless session. Initialization errors
  ## are returned with context and never leave a partially entered session.
  var app: TuiApp
  app.options = options
  if app.options.maxFramesPerSecond <= 0:
    app.options.maxFramesPerSecond = 60
  if app.options.headlessWidth <= 0:
    app.options.headlessWidth = 80
  if app.options.headlessHeight <= 0:
    app.options.headlessHeight = 24
  try:
    if app.options.mode == tmHeadless:
      app.ui = initUiWith(initFakeOut(), mouse = app.options.mouse,
        probe = false, maxPostedEvents = app.options.maxPostedEvents,
        mode = tsmFullscreen)
      app.ui.front = initBuffer(app.options.headlessWidth,
        app.options.headlessHeight)
      app.ui.back = initBuffer(app.options.headlessWidth,
        app.options.headlessHeight)
    else:
      app.ui = initUi(mouse = app.options.mouse,
        probe = app.options.probeCapabilities,
        maxPostedEvents = app.options.maxPostedEvents,
        mode = if app.options.mode == tmInline: tsmInline else: tsmFullscreen)
    app.running = true
    app.dirty = true
    result = TuiResult[TuiApp](ok: true, value: move(app))
  except CatchableError as failure:
    try:
      app.ui.leave()
    except CatchableError:
      discard
    result = TuiResult[TuiApp](ok: false,
      error: "cannot open TUI: " & failure.msg)

proc close*(app: var TuiApp) =
  ## Restores terminal state and closes wake resources. Repeated calls are safe.
  if not app.running and not app.ui.term.entered:
    return
  app.running = false
  app.ui.leave()

proc suspend*(app: var TuiApp): TuiResult[bool] =
  ## Restores the terminal before POSIX job-control suspension, then creates a
  ## fresh terminal/reactor session after SIGCONT. Application-owned state and
  ## runtime counters remain intact. Headless and non-POSIX hosts close cleanly.
  when not defined(posix):
    app.close()
    return TuiResult[bool](ok: true, value: false)
  else:
    if app.options.mode == tmHeadless or not app.ui.term.interactive:
      app.close()
      return TuiResult[bool](ok: true, value: false)
    app.ui.leave()
    let previous = posixapi.signal(SIGTSTP, SIG_DFL)
    if previous == SIG_ERR:
      app.running = false
      return TuiResult[bool](ok: false,
        error: "cannot install the POSIX suspend disposition")
    discard posixapi.raise(SIGTSTP)
    discard posixapi.signal(SIGTSTP, previous)
    var reopened = openTui(app.options)
    if not reopened.ok:
      app.running = false
      return TuiResult[bool](ok: false,
        error: "cannot resume TUI: " & reopened.error)
    app.ui = move(reopened.value.ui)
    app.running = true
    app.dirty = true
    app.lastFrame = MonoTime()
    app.deferredRedraw = TimerId(0)
    app.deferredDeadline = MonoTime()
    app.laterDeadline = MonoTime()
    TuiResult[bool](ok: true, value: true)

proc scheduleRedraw(app: var TuiApp, deadline: MonoTime)

proc absorbDeferred(app: var TuiApp, event: var Event) =
  ## The framework's own redraw timer becomes `dirty`; hosts never see it.
  if event.kind != evTimer or uint64(app.deferredRedraw) == 0 or
      event.timerId != uint64(app.deferredRedraw):
    return
  app.deferredRedraw = TimerId(0)
  app.dirty = true
  event = Event(kind: evNone)
  if app.laterDeadline != MonoTime():
    let later = app.laterDeadline
    app.laterDeadline = MonoTime()
    app.scheduleRedraw(later)

proc wait*(app: var TuiApp): Event =
  ## Blocks for one real event/deadline. No deadline means one indefinite OS
  ## wait with no periodic framework work. A pending redraw deadline returns
  ## evNone with `dirty` set.
  if not app.running:
    return Event(kind: evNone)
  inc app.stats.waits
  result = app.ui.wait()
  app.absorbDeferred(result)
  if result.kind != evNone:
    inc app.stats.wakeups

proc poll*(app: var TuiApp, timeoutMs: int): Event =
  ## Compatibility/host-integration wait with an explicit timeout.
  if not app.running:
    return Event(kind: evNone)
  inc app.stats.waits
  result = app.ui.poll(timeoutMs)
  app.absorbDeferred(result)
  if result.kind != evNone:
    inc app.stats.wakeups

proc draw*(app: var TuiApp, callback: DrawProc) =
  ## Clears the next frame, supplies its clipped root, diffs, writes at most one
  ## logical frame, swaps buffers, and reuses buffer/arena capacity.
  if not app.running:
    return
  app.ui.back.reset()
  var frame = initFrame(app.ui.back,
    initRect(0, 0, app.ui.back.width, app.ui.back.height))
  inc app.stats.drawCalls
  callback(frame)
  let writesBefore = if app.ui.w.kind == outFake: app.ui.w.fake.writes else: -1
  app.ui.render()
  if writesBefore < 0 or app.ui.w.fake.writes > writesBefore:
    inc app.stats.renderedFrames
  app.lastFrame = getMonoTime()
  app.dirty = false

proc post*(app: TuiApp, event: sink Event): bool =
  ## Posts an event safely from a worker thread. Retain `app.ui.reactor` when
  ## the application handle itself cannot be shared.
  app.ui.post(event)

proc setTimer*(app: TuiApp, delay: Duration): TimerId =
  ## Schedules a one-shot application timer.
  app.ui.setTimer(delay)

proc cancelTimer*(app: TuiApp, id: TimerId): bool =
  ## Cancels an application timer.
  app.ui.cancelTimer(id)

proc scheduleRedraw(app: var TuiApp, deadline: MonoTime) =
  ## Earliest deadline wins; a later one is re-armed after it fires.
  if uint64(app.deferredRedraw) != 0:
    if app.deferredDeadline <= deadline:
      if app.laterDeadline == MonoTime() or deadline < app.laterDeadline:
        app.laterDeadline = deadline
      return
    if app.laterDeadline == MonoTime() or app.deferredDeadline <
        app.laterDeadline:
      app.laterDeadline = app.deferredDeadline
    discard app.cancelTimer(app.deferredRedraw)
  app.deferredRedraw = app.ui.reactor.setTimerAt(deadline)
  app.deferredDeadline = deadline

proc requestRedraw(app: var TuiApp) =
  let frameTime = initDuration(nanoseconds =
    1_000_000_000 div max(1, app.options.maxFramesPerSecond))
  let now = getMonoTime()
  let earliest = app.lastFrame + frameTime
  if app.stats.drawCalls > 0 and now < earliest:
    app.scheduleRedraw(earliest)
  else:
    app.dirty = true

proc apply*(app: var TuiApp, update: Update) =
  ## Applies a handler's requested effect: invalidation with frame pacing,
  ## an exact redraw deadline, quit, or suspend. Host-driven loops that call
  ## `wait` and `draw` themselves use this to get the same pacing as `runTui`.
  case update.kind
  of ukUnchanged:
    discard
  of ukRedraw:
    app.requestRedraw()
  of ukRedrawAt:
    app.scheduleRedraw(update.deadline)
  of ukQuit:
    app.running = false
  of ukSuspend:
    let suspended = app.suspend()
    if not suspended.ok:
      raise newException(IOError, suspended.error)

proc handleEvent(app: var TuiApp, event: Event, update: UpdateProc) =
  if event.kind == evNone:
    return
  inc app.stats.updateCalls
  app.apply(update(event))
  if event.kind == evResize:
    app.dirty = true

proc runTui*(update: UpdateProc, drawCallback: DrawProc,
    options = tuiOptions()): TuiResult[RunStats] =
  ## Runs an event-driven application with automatic scoped cleanup. Posted
  ## bursts are drained in bounded batches and collapse into one invalidation.
  ## A resize always redraws. The loop ends when the handler quits or when an
  ## interactive terminal's input reaches end-of-file.
  var opened = openTui(options)
  if not opened.ok:
    return TuiResult[RunStats](ok: false, error: opened.error)
  var app = move(opened.value)
  try:
    app.draw(drawCallback)
    while app.running:
      var event = app.wait()
      if event.kind == evNone and app.ui.inputClosed:
        break
      app.handleEvent(event, update)
      var drained = 0
      while app.running and drained < 255:
        let extra = app.poll(0)
        if extra.kind == evNone:
          break
        app.handleEvent(extra, update)
        inc drained
      if app.running and app.dirty:
        app.draw(drawCallback)
    app.close()
    TuiResult[RunStats](ok: true, value: app.stats)
  except CatchableError as failure:
    try:
      app.close()
    except CatchableError:
      discard
    TuiResult[RunStats](ok: false, error: "TUI runtime failed: " & failure.msg)

proc runTui*(drawCallback: DrawProc,
    options = tuiOptions()): TuiResult[RunStats] =
  ## Runs a draw-only application until a standard quit key is received.
  runTui(proc (event: Event): Update =
    if event.isQuit: quitTui() else: unchanged(), drawCallback, options)
