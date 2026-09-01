## Event-driven timers and thread-safe UI wakeups.

import std/[heapqueue, locks, monotimes, os, sets, times]
import event

when defined(posix):
  import std/posix
else:
  import std/winlean

type
  TimerId* = distinct uint64

  TimerEntry = object
    deadline: MonoTime
    id: TimerId

  ReadyKind* = enum
    rkInput
    rkWake
    rkTimeout
    rkInterrupted
    rkClosed

  Reactor* = ref object
    lock: Lock
    waitersDone: Cond
    activeWaiters: int
    queue: seq[Event]
    queueHead: int
    maxQueued: int
    wakePending: bool
    closed: bool
    nextTimer: uint64
    timers: HeapQueue[TimerEntry]
    activeTimers: HashSet[uint64]
    cancelled: HashSet[uint64]
    when defined(posix):
      readFd: cint
      writeFd: cint
    else:
      wakeEvent: Handle

func `<`(a, b: TimerEntry): bool =
  a.deadline < b.deadline or (a.deadline == b.deadline and
    uint64(a.id) < uint64(b.id))

when not defined(posix):
  proc resetEvent(handle: Handle): cint {.
    stdcall, dynlib: "kernel32", importc: "ResetEvent".}

proc initReactor*(maxQueued = 4096): Reactor =
  ## Creates a reactor. It owns one coalescing OS wake primitive and creates no
  ## timer or polling deadline by default.
  new(result)
  initLock(result.lock)
  initCond(result.waitersDone)
  result.maxQueued = max(1, maxQueued)
  result.timers = initHeapQueue[TimerEntry]()
  result.activeTimers = initHashSet[uint64]()
  result.cancelled = initHashSet[uint64]()
  when defined(posix):
    var fds: array[2, cint]
    if posix.pipe(fds) != 0:
      deinitLock(result.lock)
      raiseOSError(osLastError())
    result.readFd = fds[0]
    result.writeFd = fds[1]
    for fd in [result.readFd, result.writeFd]:
      let flags = fcntl(fd, F_GETFL)
      if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
        discard posix.close(result.readFd)
        discard posix.close(result.writeFd)
        deinitLock(result.lock)
        raiseOSError(osLastError())
  else:
    result.wakeEvent = createEvent(nil, 1, 0, nil)
    if result.wakeEvent == 0:
      deinitLock(result.lock)
      raiseOSError(osLastError())

proc signalWake(reactor: Reactor) =
  if reactor.wakePending or reactor.closed:
    return
  reactor.wakePending = true
  when defined(posix):
    var value = byte(1)
    let written = posix.write(reactor.writeFd, addr value, 1)
    if written < 0 and errno != EAGAIN and errno != EWOULDBLOCK:
      reactor.wakePending = false
  else:
    if setEvent(reactor.wakeEvent) == 0:
      reactor.wakePending = false

proc consumeWake(reactor: Reactor) =
  when defined(posix):
    var bytes: array[64, byte]
    while true:
      let count = posix.read(reactor.readFd, addr bytes[0], bytes.len)
      if count <= 0:
        break
  else:
    discard resetEvent(reactor.wakeEvent)
  reactor.wakePending = false

proc post*(reactor: Reactor, posted: sink Event): bool =
  ## Posts from any thread. The first queued item emits one OS wake; further
  ## items coalesce behind it. At the bound, adjacent user events with the same
  ## name replace the newest value; other events are rejected for backpressure.
  if reactor.isNil:
    return false
  acquire(reactor.lock)
  defer: release(reactor.lock)
  if reactor.closed:
    return false
  let queued = reactor.queue.len - reactor.queueHead
  if queued >= reactor.maxQueued:
    if posted.kind == evUser and reactor.queue.len > reactor.queueHead and
        reactor.queue[^1].kind == evUser and
        reactor.queue[^1].name == posted.name:
      reactor.queue[^1] = posted
      return true
    return false
  reactor.queue.add posted
  reactor.signalWake()
  true

proc popPosted*(reactor: Reactor, posted: var Event): bool =
  ## Pops one queued event in O(1), returning false when no event is available.
  if reactor.isNil:
    return false
  acquire(reactor.lock)
  defer: release(reactor.lock)
  if reactor.queueHead >= reactor.queue.len:
    if reactor.wakePending:
      reactor.consumeWake()
    return false
  posted = move(reactor.queue[reactor.queueHead])
  inc reactor.queueHead
  if reactor.queueHead >= reactor.queue.len:
    reactor.queue.setLen 0
    reactor.queueHead = 0
    reactor.consumeWake()
  elif reactor.queueHead >= 1024 and reactor.queueHead * 2 >= reactor.queue.len:
    let remaining = reactor.queue.len - reactor.queueHead
    for i in 0 ..< remaining:
      reactor.queue[i] = move(reactor.queue[reactor.queueHead + i])
    reactor.queue.setLen remaining
    reactor.queueHead = 0
  true

proc pendingCount*(reactor: Reactor): int =
  ## Returns the current posted-event count.
  if reactor.isNil:
    return 0
  acquire(reactor.lock)
  result = reactor.queue.len - reactor.queueHead
  release(reactor.lock)

proc setTimerAt*(reactor: Reactor, deadline: MonoTime): TimerId =
  ## Schedules a one-shot timer and wakes a waiter so it can adopt the earlier
  ## deadline. Timer IDs are unique within the reactor.
  if reactor.isNil:
    return TimerId(0)
  acquire(reactor.lock)
  defer: release(reactor.lock)
  if reactor.closed:
    return TimerId(0)
  inc reactor.nextTimer
  result = TimerId(reactor.nextTimer)
  reactor.timers.push TimerEntry(deadline: deadline, id: result)
  reactor.activeTimers.incl uint64(result)
  reactor.signalWake()

proc setTimer*(reactor: Reactor, delay: Duration): TimerId =
  ## Schedules a one-shot timer relative to the monotonic clock.
  reactor.setTimerAt(getMonoTime() + delay)

proc cancelTimer*(reactor: Reactor, id: TimerId): bool =
  ## Cancels a timer lazily in O(1); heap cleanup remains O(log n).
  if reactor.isNil or uint64(id) == 0:
    return false
  acquire(reactor.lock)
  defer: release(reactor.lock)
  if reactor.closed or uint64(id) notin reactor.activeTimers:
    return false
  reactor.activeTimers.excl uint64(id)
  reactor.cancelled.incl uint64(id)
  reactor.signalWake()
  true

proc discardCancelled(reactor: Reactor) =
  while reactor.timers.len > 0 and
      uint64(reactor.timers[0].id) in reactor.cancelled:
    let entry = reactor.timers.pop()
    reactor.cancelled.excl uint64(entry.id)

proc nextTimerMs*(reactor: Reactor, now = getMonoTime()): int =
  ## Returns milliseconds to the nearest timer, or -1 for no deadline.
  if reactor.isNil:
    return -1
  acquire(reactor.lock)
  defer: release(reactor.lock)
  reactor.discardCancelled()
  if reactor.timers.len == 0:
    return -1
  if reactor.timers[0].deadline <= now:
    return 0
  let remaining = (reactor.timers[0].deadline - now).inMilliseconds
  max(1, int(min(remaining, int64(high(int32)))))

proc popExpired*(reactor: Reactor, fired: var Event,
    now = getMonoTime()): bool =
  ## Coalesces cancellation cleanup and pops one expired timer event.
  if reactor.isNil:
    return false
  acquire(reactor.lock)
  defer: release(reactor.lock)
  reactor.discardCancelled()
  if reactor.timers.len == 0 or reactor.timers[0].deadline > now:
    return false
  let entry = reactor.timers.pop()
  reactor.activeTimers.excl uint64(entry.id)
  fired = Event(kind: evTimer, timerId: uint64(entry.id))
  true

when defined(posix):
  func wakeFd*(reactor: Reactor): cint =
    ## Returns the POSIX wake descriptor for host-loop integration.
    reactor.readFd

when defined(posix):
  type InputWaitHandle* = cint
else:
  type InputWaitHandle* = Handle

proc waitReady*(reactor: Reactor,
    inputFd: InputWaitHandle = InputWaitHandle(-1),
    timeoutMs = -1): ReadyKind =
  ## Performs one blocking OS wait. A negative timeout means indefinitely.
  if reactor.isNil:
    return rkClosed
  acquire(reactor.lock)
  let closed = reactor.closed
  let queued = reactor.queueHead < reactor.queue.len
  if not closed and not queued:
    inc reactor.activeWaiters
  release(reactor.lock)
  if closed:
    return rkClosed
  if queued:
    return rkWake
  defer:
    acquire(reactor.lock)
    dec reactor.activeWaiters
    if reactor.activeWaiters == 0:
      signal(reactor.waitersDone)
    release(reactor.lock)
  when defined(posix):
    var fds: array[2, TPollfd]
    var count = 1
    fds[0] = TPollfd(fd: reactor.readFd, events: cshort(POLLIN), revents: 0)
    if inputFd >= 0:
      fds[1] = TPollfd(fd: inputFd, events: cshort(POLLIN), revents: 0)
      count = 2
    let ready = posix.poll(addr fds[0], Tnfds(count), cint(timeoutMs))
    if ready == 0:
      return rkTimeout
    if ready < 0:
      if errno == EINTR: return rkInterrupted
      raiseOSError(osLastError())
    if (fds[0].revents and POLLIN) != 0:
      return rkWake
    if count == 2 and (fds[1].revents and POLLIN) != 0:
      return rkInput
    rkInterrupted
  else:
    let timeout = if timeoutMs < 0: DWORD(INFINITE) else: DWORD(timeoutMs)
    var handles: WOHandleArray
    handles[0] = reactor.wakeEvent
    var count = 1
    if inputFd != Handle(-1) and inputFd != 0:
      handles[1] = inputFd
      count = 2
    let ready = waitForMultipleObjects(DWORD(count), addr handles, 0, timeout)
    if ready == DWORD(WAIT_OBJECT_0): rkWake
    elif count == 2 and ready == DWORD(WAIT_OBJECT_0 + 1): rkInput
    elif ready == DWORD(WAIT_TIMEOUT): rkTimeout
    else: rkInterrupted

proc acknowledgeWake*(reactor: Reactor) =
  ## Clears a timer/configuration wake after the owner has recomputed state.
  if reactor.isNil:
    return
  acquire(reactor.lock)
  if reactor.queueHead >= reactor.queue.len and reactor.wakePending:
    reactor.consumeWake()
  release(reactor.lock)

proc close*(reactor: Reactor) =
  ## Wakes waiters and closes the reactor. Repeated calls are safe.
  if reactor.isNil:
    return
  acquire(reactor.lock)
  if reactor.closed:
    release(reactor.lock)
    return
  reactor.signalWake()
  reactor.closed = true
  while reactor.activeWaiters > 0:
    wait(reactor.waitersDone, reactor.lock)
  release(reactor.lock)
  when defined(posix):
    discard posix.close(reactor.readFd)
    discard posix.close(reactor.writeFd)
    reactor.readFd = -1
    reactor.writeFd = -1
  else:
    discard closeHandle(reactor.wakeEvent)
    reactor.wakeEvent = 0
  # Keep the lock valid for retained worker references: a post racing shutdown
  # must observe `closed` and return false instead of touching destroyed state.
