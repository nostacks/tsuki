when defined(posix):
  import std/[posix, termios]

  const tiocsctty =
    when defined(macosx) or defined(macos) or defined(bsd):
      0x20007461
    else:
      0x540E

  {.passL: "-lutil".}

  proc c_ioctl(fd: cint, request: culong, arg: pointer): cint {.
    importc: "ioctl", header: "<sys/ioctl.h>".}

  proc c_openpty(amaster, aslave: ptr cint, name: cstring, t: ptr Termios,
      ws: pointer): cint {.
    importc: "openpty", header:
      when (defined(macosx) or defined(macos) or defined(bsd)):
        "<util.h>"
      else:
        "<pty.h>".}

  type PtyResult* = object
    bytes*: string
    exitedCleanly*: bool
    termSig*: cint

  const tiocswinsz =
    when defined(macosx) or defined(macos) or defined(bsd):
      0x80087467
    else:
      0x5414

  type WinSize = object
    ws_row: cushort
    ws_col: cushort
    ws_xpixel: cushort
    ws_ypixel: cushort

  proc setPtySize*(master: cint, cols, rows: int) =
    ## Sets the pty window size, delivering SIGWINCH to the child.
    var ws = WinSize(ws_row: cushort(rows), ws_col: cushort(cols))
    if c_ioctl(master, culong(tiocswinsz), addr ws) != 0:
      raise newException(OSError, "TIOCSWINSZ failed")

  proc spawnPty*(child: proc ()): tuple[master: cint, pid: Pid] =
    ## Forks the current process onto a fresh pty running `child` and
    ## returns the master fd and child pid to the caller.
    var slave: cint
    if c_openpty(addr result.master, addr slave, nil, nil, nil) != 0:
      raise newException(OSError, "openpty failed")
    let pid = fork()
    if pid < 0:
      raise newException(OSError, "fork failed")
    if pid == 0:
      discard close(result.master)
      discard dup2(slave, 0)
      discard dup2(slave, 1)
      discard dup2(slave, 2)
      if slave > 2:
        discard close(slave)
      discard setsid()
      discard c_ioctl(0, culong(tiocsctty), nil)
      child()
      quit(0)
    discard close(slave)
    result.pid = pid

  proc finishPty*(master: cint, pid: Pid): PtyResult =
    ## Drains the master fd until the child exits and reports the outcome.
    var buf: array[4096, byte]
    while true:
      let n = read(master, addr buf[0], buf.len)
      if n <= 0:
        break
      for i in 0 ..< int(n):
        result.bytes.add char(buf[i])
    discard close(master)
    var st: cint
    discard waitpid(pid, st, cint(0))
    if WIFEXITED(st):
      result.exitedCleanly = WEXITSTATUS(st) == 0
    elif WIFSIGNALED(st):
      result.termSig = WTERMSIG(st)

  proc runOnPty*(child: proc ()): PtyResult =
    ## Forks the current process onto a fresh pty and runs `child` there.
    ## The parent captures everything the child writes to the pty and
    ## returns it together with the child's exit outcome.
    var master, slave: cint
    if c_openpty(addr master, addr slave, nil, nil, nil) != 0:
      raise newException(OSError, "openpty failed")
    let pid = fork()
    if pid < 0:
      raise newException(OSError, "fork failed")
    if pid == 0:
      discard close(master)
      discard dup2(slave, 0)
      discard dup2(slave, 1)
      discard dup2(slave, 2)
      if slave > 2:
        discard close(slave)
      discard setsid()
      discard c_ioctl(0, culong(tiocsctty), nil)
      child()
      quit(0)
    discard close(slave)
    var buf: array[4096, byte]
    while true:
      let n = read(master, addr buf[0], buf.len)
      if n <= 0:
        break
      for i in 0 ..< int(n):
        result.bytes.add char(buf[i])
    discard close(master)
    var st: cint
    discard waitpid(pid, st, cint(0))
    if WIFEXITED(st):
      result.exitedCleanly = WEXITSTATUS(st) == 0
    elif WIFSIGNALED(st):
      result.termSig = WTERMSIG(st)
