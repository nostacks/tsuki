import std/[monotimes, times]
import term
import terminal
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
    kittyQuery = "\x1b[?u\x1b[?2026$p\x1b[c"
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
  fullFlushPending: bool
  inputClosedFlag: bool

proc kittyEnable*(ui: var Ui) =
  ## Marks the terminal as kitty-capable and sends the disambiguate escape
  ## mode. Called by the startup probe and directly by tests.
  ui.term.setKittyProtocol(true)
  ui.w.write kittyEnableSeq.toOpenArrayByte(0, kittyEnableSeq.len - 1)

proc kittyProbe*(ui: var Ui) =
  ## Queries kitty keyboard protocol and synchronized output support and
  ## enables each when the terminal answers. The primary device attributes
  ## reply that follows both queries ends the wait; the probe gives up after
  ## 100 ms otherwise. Skipped without a real terminal.
  when defined(posix):
    if not ui.term.interactive:
      return
    ui.w.write kittyQuery.toOpenArrayByte(0, kittyQuery.len - 1)
    let deadline = getMonoTime() + initDuration(
        milliseconds = kittyProbeTimeoutMs)
    var buf: array[64, byte]
    while true:
      let now = getMonoTime()
      if now >= deadline:
        break
      let remaining = int((deadline - now).inMilliseconds) + 1
      var fds = [TPollfd(fd: cint(0), events: cshort(POLLIN), revents: 0)]
      let r = posix.poll(addr fds[0], Tnfds(1), cint(remaining))
      if r < 0:
        if errno == EINTR:
          continue
        break
      if r == 0:
        break
      let n = posix.read(cint(0), addr buf[0], buf.len)
      if n <= 0:
        break
      ui.state.parse(buf.toOpenArray(0, int(n) - 1), ui.events)
      if ui.state.deviceAttributesSeen:
        break
  if ui.state.kittySupported():
    ui.kittyEnable()
  if ui.state.syncOutputSeen:
    ui.w.syncOutput = ui.state.syncOutputSupported()

proc initUiWith*(o: sink Out, mouse = false, probe = false,
    maxPostedEvents = 4096, mode = tsmFullscreen): Ui =
  ## Enters the terminal through the given sink, optionally probes kitty
  ## support, allocates the double buffer, and returns the UI handle. Tests
  ## pass a fake sink; `initUi` passes the process tty.
  result.w = o
  try:
    result.term.enter(result.w, mouse, mode)
    result.reactor = initReactor(maxPostedEvents)
    when defined(posix):
      result.term.setSignalWakeFd(result.reactor.signalFd)
    if probe:
      result.kittyProbe()
    let sz = result.term.size
    result.lastW = sz.w
    result.lastH = sz.h
    result.front = initBuffer(sz.w, sz.h)
    result.back = initBuffer(sz.w, sz.h)
  except CatchableError:
    try:
      result.term.setSignalWakeFd(-1)
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
  ## drawing into `back`. Synchronized output is enabled only for terminals
  ## that advertise it.
  var output = initOut(cint(1))
  let capabilities = detectCapabilities()
  output.syncOutput = capabilities.synchronizedOutput
  output.scrollRegions = capabilities.scrollRegions
  output.hyperlinks = capabilities.hyperlinks
  output.imageProtocol = if capabilities.kittyGraphics: imageOutKitty
    elif capabilities.itermImages: imageOutIterm
    else: imageOutNone
  initUiWith(output, mouse, probe, maxPostedEvents, mode)

func imageProtocol*(ui: Ui): ImageProtocolOut {.inline.} =
  ## The image transport this session may emit; `imageOutNone` means every
  ## image request draws its text fallback instead.
  ui.w.imageProtocol

proc registerImage*(ui: var Ui, id: uint32, png: string,
    widthPx, heightPx: int) =
  ## Makes PNG bytes available to `Frame.image` placements under `id`. The
  ## data is transmitted lazily with the first frame that shows it.
  ui.w.registerImage(id, png, widthPx, heightPx)

proc forgetImage*(ui: var Ui, id: uint32) =
  ## Frees a registered image on the terminal and in memory.
  ui.w.forgetImage(id)

proc leave*(ui: var Ui) =
  ## Restores the terminal, freeing any inline images first.
  try:
    try:
      ui.w.deleteAllImagesNow()
    except CatchableError:
      discard
    ui.term.setSignalWakeFd(-1)
    ui.term.leave()
  finally:
    if not ui.reactor.isNil:
      ui.reactor.close()
      ui.reactor = nil

func inputClosed*(ui: Ui): bool =
  ## True once terminal input reached end-of-file or failed permanently.
  ## Posted events and timers keep working; keyboard input never returns.
  ui.inputClosedFlag

proc flushFront(ui: var Ui) =
  ui.w.flushFull(ui.front)
  ui.fullFlushPending = false

proc handleResize(ui: var Ui): Event =
  ## Screen contents are undefined after a resize, so the next `render`
  ## rewrites every row; `poll` rewrites the current frame if no render came.
  let sz = ui.term.size
  ui.front.resize(sz.w, sz.h)
  ui.back.resize(sz.w, sz.h)
  ui.lastW = sz.w
  ui.lastH = sz.h
  ui.fullFlushPending = true
  Event(kind: evResize, width: sz.w, height: sz.h)

proc drain(ui: var Ui): Event =
  ## Parses queued bytes and returns the next complete event, evNone when
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
  int(min(((deadline - now).inNanoseconds + 999_999) div 1_000_000,
    int64(high(int32))))

proc readTerminal(ui: var Ui): bool =
  ## End-of-file and permanent errors close input so a dead terminal can
  ## never spin the event loop.
  var buf: array[4096, byte]
  let n = ui.term.readInput(addr buf[0], buf.len)
  if n > 0:
    ui.pending.add buf.toOpenArray(0, n - 1)
    return true
  when defined(posix):
    if n < 0 and (errno == EINTR or errno == EAGAIN):
      return false
  ui.inputClosedFlag = true
  false

proc poll*(ui: var Ui, timeoutMs: int): Event =
  ## Blocks up to `timeoutMs` (negative waits indefinitely) and returns one
  ## event. Resize coalesces into a single evResize. Wake notifications are
  ## handled iteratively so repeated timer/configuration changes cannot grow
  ## the call stack or restart the caller's timeout.
  if ui.reactor.isNil:
    return Event(kind: evNone)
  let hasCallerDeadline = timeoutMs >= 0
  let callerDeadline = if hasCallerDeadline:
    getMonoTime() + initDuration(milliseconds = max(0, timeoutMs))
  else:
    MonoTime()
  if ui.fullFlushPending:
    ui.flushFront()
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
    let wantInput = ui.term.interactive and not ui.inputClosedFlag
    let ready = when defined(posix):
      ui.reactor.waitReady(
        if wantInput: cint(0) else: cint(-1), effectiveTimeout)
    else:
      ui.reactor.waitReady(
        if wantInput: ui.term.inputHandle else: Handle(-1),
        effectiveTimeout)
    case ready
    of rkInput:
      if not ui.readTerminal():
        if ui.inputClosedFlag:
          return Event(kind: evNone)
        continue
      result = ui.drain()
      if result.kind != evNone:
        return
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkWake:
      if ui.term.takeResize():
        return ui.handleResize()
      if ui.reactor.popPosted(result):
        return
      if ui.reactor.popExpired(result):
        return
      ui.reactor.acknowledgeWake()
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkTimeout:
      result = ui.drain()
      if result.kind != evNone or ui.reactor.popExpired(result):
        return
      if hasCallerDeadline and getMonoTime() >= callerDeadline:
        return Event(kind: evNone)
    of rkInterrupted:
      if ui.term.takeResize():
        return ui.handleResize()
      if timeoutMs == 0:
        return Event(kind: evNone)
    of rkClosed:
      return Event(kind: evNone)

proc render*(ui: var Ui) =
  ## Diffs `back` against `front`, writes the changed runs in one syscall,
  ## and swaps the buffers. After a resize the whole frame is rewritten.
  if ui.fullFlushPending:
    ui.w.flushFull(ui.back)
    ui.fullFlushPending = false
  else:
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
