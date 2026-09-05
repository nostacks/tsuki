import std/[os, times]
import common
import he3

proc testPostAndBackpressure =
  let r = initReactor(maxQueued = 2)
  check r.post(userEvent("delta", "a")), "first post accepted"
  check r.post(userEvent("delta", "b")), "second post accepted"
  check r.post(userEvent("delta", "latest")), "adjacent delta coalesced at bound"
  check r.pendingCount == 2, "queue remains bounded"
  check r.waitReady(timeoutMs = 100) == rkWake, "post wakes OS wait"
  var event: Event
  check r.popPosted(event) and event.payload == "a", "ordering preserved"
  check r.popPosted(event) and event.payload == "latest", "newest delta retained"
  check not r.popPosted(event), "queue drains completely"
  r.close()
  check not r.post(userEvent("late")), "post after shutdown is rejected"

proc testTimers =
  let r = initReactor()
  let cancelled = r.setTimer(initDuration(milliseconds = 1))
  check r.cancelTimer(cancelled), "timer cancellation accepted"
  check not r.cancelTimer(cancelled), "a timer cannot be cancelled twice"
  discard r.setTimer(initDuration(milliseconds = 2))
  r.acknowledgeWake()
  check r.waitReady(timeoutMs = r.nextTimerMs()) == rkTimeout,
    "reactor sleeps to exact timer deadline"
  var event: Event
  var tries = 0
  while not r.popExpired(event) and tries < 5:
    discard r.waitReady(timeoutMs = 2)
    inc tries
  check event.kind == evTimer, "expired timer becomes typed event"
  check not r.cancelTimer(TimerId(event.timerId)),
    "an expired timer is no longer reported as active"
  r.close()

proc testHeadlessFrames =
  var opened = openTui(tuiOptions(mode = tmHeadless, headlessWidth = 12,
    headlessHeight = 3))
  check opened.ok, "headless app opens"
  var app = move(opened.value)
  app.draw proc (frame: var Frame) =
    frame.write(0, 0, "hello")
  let firstWrites = app.ui.w.fake.writes
  app.draw proc (frame: var Frame) =
    frame.write(0, 0, "hello")
  check app.ui.w.fake.writes == firstWrites,
    "identical automatic frame performs zero writes"
  check app.post(userEvent("work", "done")), "app post accepted"
  check app.wait() == userEvent("work", "done"), "app wait receives posted event"
  discard app.setTimer(initDuration(milliseconds = 1))
  check app.wait().kind == evTimer, "app wait blocks through timer setup wake"
  app.close()

  var suspendable = openTui(tuiOptions(mode = tmHeadless))
  check suspendable.ok, "headless suspend fixture opens"
  var suspendedApp = move(suspendable.value)
  let suspended = suspendedApp.suspend()
  check suspended.ok and not suspended.value and not suspendedApp.running,
    "unsupported headless suspension closes cleanly"

type WaitContext = object
  reactor: Reactor
  ready: ReadyKind

proc waitWorker(context: ptr WaitContext) {.thread.} =
  context.ready = context.reactor.waitReady(timeoutMs = -1)

proc testShutdownRace =
  let reactor = initReactor()
  var context = WaitContext(reactor: reactor)
  var worker: Thread[ptr WaitContext]
  createThread(worker, waitWorker, addr context)
  sleep(5)
  reactor.close()
  joinThread(worker)
  check context.ready in {rkWake, rkClosed},
    "closing wakes and joins an outstanding blocking wait safely"
  check not reactor.post(userEvent("late")),
    "retained worker references reject posts after close"

testPostAndBackpressure()
testTimers()
testHeadlessFrames()
testShutdownRace()
echo "reactor ok"
