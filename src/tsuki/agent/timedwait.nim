## Bounded condition-variable waits so worker threads never poll.

import std/locks

when defined(windows):
  proc sleepConditionVariableCS(cond: pointer, lock: pointer,
      milliseconds: int32): int32 {.stdcall, dynlib: "kernel32",
      importc: "SleepConditionVariableCS".}

  proc timedWait*(cond: var Cond, lock: var Lock, timeoutMs: int): bool =
    ## Waits while holding `lock`. False means the timeout elapsed first.
    sleepConditionVariableCS(addr cond, addr lock,
      int32(clamp(timeoutMs, 0, int(high(int32))))) != 0
else:
  import std/posix

  proc timedWait*(cond: var Cond, lock: var Lock, timeoutMs: int): bool =
    ## Waits while holding `lock`. False means the timeout elapsed first.
    var deadline: Timespec
    discard clock_gettime(CLOCK_REALTIME, deadline)
    let ms = max(0, timeoutMs)
    var seconds = int64(clong(deadline.tv_sec)) + int64(ms div 1000)
    var nanos = int64(deadline.tv_nsec) + int64(ms mod 1000) * 1_000_000
    if nanos >= 1_000_000_000:
      inc seconds
      nanos -= 1_000_000_000
    deadline.tv_sec = Time(clong(seconds))
    deadline.tv_nsec = int(nanos)
    pthread_cond_timedwait(cast[ptr Pthread_cond](addr cond),
      cast[ptr Pthread_mutex](addr lock), addr deadline) == 0
