import std/strutils
import common
import tsuki/tui/private/writer
import tsuki/tui/term

when defined(posix):
  import std/posix
  import pty

proc childNormal() =
  var t: Term
  var o = initOut(cint(1))
  t.enter(o)
  let sz = t.size
  let msg = "SIZE=" & $sz.w & "x" & $sz.h
  t.w.write cast[seq[byte]](msg)
  t.leave()
  quit(0)

when defined(posix):
  proc childSigint() =
    var t: Term
    var o = initOut(cint(1))
    t.enter(o)
    t.w.write cast[seq[byte]]("ENTERED")
    discard posix.raise(SIGINT)
    quit(0)

  proc childSigintKitty() =
    var t: Term
    var o = initOut(cint(1))
    t.enter(o)
    t.setKittyProtocol(true)
    discard posix.raise(SIGINT)
    quit(0)

proc testNormal =
  when defined(posix):
    let r = runOnPty(childNormal)
    check r.exitedCleanly, "child exit 0"
    check "SIZE=" in r.bytes, "size line appeared"
    check "\x1b[?1049h" in r.bytes, "alt screen enabled"
    check "\x1b[?25l" in r.bytes, "cursor hidden"
    check "\x1b[?2004h" in r.bytes, "bracketed paste enabled"
    check "\x1b[?1004h" in r.bytes, "focus events enabled"
    check "\x1b[?1049l" in r.bytes, "alt screen restored"
    check "\x1b[?25h" in r.bytes, "cursor shown"
    check "\x1b[?2004l" in r.bytes, "bracketed paste disabled"
    check "\x1b[?1004l" in r.bytes, "focus events disabled"
  else:
    echo "pty test skipped on this platform"

proc testSigint =
  when defined(posix):
    let r = runOnPty(childSigint)
    check r.termSig == cint(SIGINT), "child died by SIGINT"
    check "\x1b[?1049l" in r.bytes, "restore written by signal handler"
    check "\x1b[?25h" in r.bytes, "cursor shown by signal handler"
    let kitty = runOnPty(childSigintKitty)
    check kitty.termSig == cint(SIGINT), "kitty child died by SIGINT"
    check "\x1b[<u" in kitty.bytes,
      "fatal restoration disables the active kitty keyboard protocol"
  else:
    discard

proc main =
  testNormal()
  testSigint()
  echo "term ok"

main()
