import std/[monotimes, times]
import term
import event
import buffer
import diff
import keyparser
import reactor
import private/writer

when defined(posix):
  import std/posix
else:
  import std/winlean

const kittyEnableSeq = "\x1b[>1u"

when defined(posix):
  const
    kittyQuery = "\x1b[?u\x1b[c"
    kittyProbeTimeoutMs = 100

type Ui* = object
  term*: Term
  w*: Out
  front*: Buffer
  back*: Buffer
  state*: ParseState
  pending*: seq[byte]
  events*: seq[Event]
  eventHead: int
  reactor*: Reactor
  lastW: int
  lastH: int

proc kittyEnable*(ui: var Ui) =
  ## Marks the terminal as kitty-capable and sends the disambiguate escape
  ## mode. Called by the startup probe and directly by tests.
  ui.term.setKittyProtocol(true)
  ui.w.write cast[seq[byte]](kittyEnableSeq)

proc kittyProbe*(ui: var Ui) =
  ## Queries kitty keyboard protocol support and enables it when the
  ## terminal answers within 100 ms. Silent on unsupported terminals.
  when defined(posix):
    ui.w.write cast[seq[byte]](kittyQuery)
    let deadline = getMonoTime() + initDuration(
        milliseconds = kittyProbeTimeoutMs)
    var buf: array[64, byte]
    while getMonoTime() < deadline:
      var fds = [TPollfd(fd: cint(0), events: cshort(POLLIN), revents: 0)]
      let r = posix.poll(addr fds[0], Tnfds(1), 10)
      if r > 0 and (fds[0].revents and POLLIN) != 0:
        let n = posix.read(cint(0), addr buf[0], buf.len)
        if n <= 0:
          break
        ui.state.parse(buf.toOpenArray(0, int(n) - 1), ui.events)
      if ui.state.kittySeen:
        break
  if ui.state.kittySupported():
    ui.kittyEnable()

proc initUiWith*(o: sink Out, mouse = false, probe = false,
    maxPostedEvents = 4096, mode = tsmFullscreen): Ui =
  ## Like `initUi` but with a caller-supplied output sink and optional
  ## kitty probe. Used by tests with a fake tty.
  result.w = o
  try:
    result.term.enter(result.w, mouse, mode)
    result.reactor = initReactor(maxPostedEvents)
    if probe:
      result.kittyProbe()
    let sz = result.term.size
    result.lastW = sz.w
    result.lastH = sz.h
    result.front = initBuffer(sz.w, sz.h)
    result.back = initBuffer(sz.w, sz.h)
  except CatchableError:
    try:
      result.term.leave()
    except CatchableError:
      discard
    if not result.reactor.isNil:
      result.reactor.close()
      result.reactor = nil
    raise

proc initUi*(mouse = false, probe = true, maxPostedEvents = 4096,
    mode = tsmFullscreen): Ui =
  ## Enters the terminal, probes kitty support, allocates the double buffer,
  ## and returns the UI handle. Call `poll` in a loop and `render` after
  ## drawing into `back`.
  result.w = initOut(cint(1))
  try:
    result.term.enter(result.w, mouse, mode)
    result.reactor = initReactor(maxPostedEvents)
    if probe:
      result.kittyProbe()
    let sz = result.term.size
    result.lastW = sz.w
    result.lastH = sz.h
    result.front = initBuffer(sz.w, sz.h)
    result.back = initBuffer(sz.w, sz.h)
  except CatchableError:
    try:
      result.term.leave()
    except CatchableError:
      discard
    if not result.reactor.isNil:
      result.reactor.close()
      result.reactor = nil
    raise

proc leave*(ui: var Ui) =
  ## Restores the terminal.
  try:
    ui.term.leave()
  finally:
    if not ui.reactor.isNil:
      ui.reactor.close()
      ui.reactor = nil

proc handleResize(ui: var Ui): Event =
  ## Resizes both buffers preserving content and force-flushes a full frame.
  let sz = ui.term.size
  ui.front.resize(sz.w, sz.h)
  ui.back.resize(sz.w, sz.h)
  ui.w.flushFull(ui.back)
  swap(ui.front, ui.back)
  ui.lastW = sz.w
  ui.lastH = sz.h
  Event(kind: evResize, width: sz.w, height: sz.h)

proc drain(ui: var Ui): Event =
  ## Parsed queued bytes and returns the next complete event, evNone when
  ## the queues are exhausted. Partial sequences resolve on their deadline.
  if ui.pending.len > 0:
    ui.state.parse(ui.pending, ui.events)
    ui.pending.setLen 0
  ui.state.checkDeadline(ui.events, getMonoTime())
  while ui.eventHead < ui.events.len:
    result = move(ui.events[ui.eventHead])
    inc ui.eventHead
    if result.kind != evNone:
      if ui.eventHead >= ui.events.len:
        ui.events.setLen 0
        ui.eventHead = 0
      return
  if ui.eventHead >= ui.events.len:
    ui.events.setLen 0
    ui.eventHead = 0
    result = Event(kind: evNone)

func nearestTimeout(a, b: int): int {.inline.} =
  if a < 0: b
  elif b < 0: a
  else: min(a, b)

func timeoutUntil(deadline, now: MonoTime): int {.inline.} =
  if deadline <= now:
    return 0
  max(1, int(min((deadline - now).inMilliseconds,
    int64(high(int32)))))

proc poll*(ui: var Ui, timeoutMs: int): Event =
  ## Blocks up to `timeoutMs` (negative waits indefinitely) and returns one
  ## event. Resize coalesces into a single evResize with a full rewrite. Wake
  ## notifications are handled iteratively so repeated timer/configuration
  ## changes cannot grow the call stack or restart the caller's timeout.
  if ui.reactor.isNil:
    return Event(kind: evNone)
  let hasCallerDeadline = timeoutMs >= 0
  let callerDeadline = if hasCallerDeadline:
    getMonoTime() + initDuration(milliseconds = max(0, timeoutMs))
  else:
    MonoTime()
  while true:
    if ui.term.takeResize():
      return ui.handleResize()
    result = ui.drain()
    if result.kind != evNone:
      return
    if ui.reactor.popPosted(result):
      return
    if ui.reactor.popExpired(result):
      return

    let now = getMonoTime()
    var effectiveTimeout = if hasCallerDeadline:
      timeoutUntil(callerDeadline, now)
    else:
      -1
    effectiveTimeout = nearestTimeout(effectiveTimeout,
      ui.state.deadlineMs(now))
    effectiveTimeout = nearestTimeout(effectiveTimeout,
      ui.reactor.nextTimerMs(now))
    let ready = when defined(posix):
      ui.reactor.waitReady(
        if ui.term.interactive: cint(0) else: cint(-1), effectiveTimeout)
    else:
      ui.reactor.waitReady(
        if ui.term.interactive: ui.term.inputHandle else: Handle(-1),
        effectiveTimeout)
    case ready
    of rkInput:
      var buf: array[4096, byte]
      let n = ui.term.readInput(addr buf[0], buf.len)
      if n <= 0:
        return Event(kind: evNone)
      ui.pending.add buf.toOpenArray(0, n - 1)
      result = ui.drain()
      if result.kind != evNone:
        return
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkWake:
      if ui.reactor.popPosted(result):
        return
      if ui.reactor.popExpired(result):
        return
      ui.reactor.acknowledgeWake()
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkTimeout:
      result = ui.drain()
      if result.kind == evNone:
        discard ui.reactor.popExpired(result)
      return
    of rkInterrupted:
      if ui.term.takeResize():
        return ui.handleResize()
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkClosed:
      return Event(kind: evNone)

proc render*(ui: var Ui) =
  ## Diffs `back` against `front`, writes the changed runs in one syscall,
  ## and swaps the buffers.
  diffInto(ui.front, ui.back, ui.w)
  swap(ui.front, ui.back)

proc wait*(ui: var Ui): Event =
  ## Blocks until terminal input, resize, a posted event, or a real timer.
  ## With no pending work this performs one indefinite OS wait.
  ui.poll(-1)

proc post*(ui: Ui, event: sink Event): bool =
  ## Posts an event through the UI reactor. `ui.reactor` may also be retained
  ## directly by a worker before the UI starts its wait loop.
  not ui.reactor.isNil and ui.reactor.post(event)

proc setTimer*(ui: Ui, delay: Duration): TimerId =
  ## Schedules a one-shot UI timer.
  ui.reactor.setTimer(delay)

proc cancelTimer*(ui: Ui, id: TimerId): bool =
  ## Cancels a previously scheduled UI timer.
  ui.reactor.cancelTimer(id)
