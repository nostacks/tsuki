import std/[os, strutils]
import common
import he3/style
import he3/buffer
import he3/layout
import he3/event
import he3/ui

when defined(posix):
  import pty

proc childResize() =
  var ui = initUi()
  ui.back.writeStr(0, 0, "READY", styleDefault())
  ui.render()
  var ev: Event
  while ev.kind != evResize:
    ev = ui.poll(100)
  ui.back.clear(initRect(0, 0, ui.back.width, ui.back.height))
  ui.back.writeStr(0, 0, "RESIZED=" & $ev.width & "x" & $ev.height,
    styleDefault())
  ui.render()
  ui.leave()
  quit(0)

proc testResize =
  when defined(posix):
    let (master, pid) = spawnPty(childResize)
    sleep(300)
    setPtySize(master, 100, 40)
    let r = finishPty(master, pid)
    check r.exitedCleanly, "child exit 0"
    check "RESIZED=100x40" in r.bytes, "resize event with new dims"
    check "READY" in r.bytes, "initial frame present"
  else:
    echo "resize pty test skipped on this platform"

proc main =
  testResize()
  echo "resize ok"

main()
