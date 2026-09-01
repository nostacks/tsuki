import std/[strutils, unicode, monotimes, times]
import common
import tsuki/tui/event
import tsuki/tui/ui

when defined(posix):
  import std/os as ossleep
  import std/posix
  import pty

func keyName(code: KeyCode): string =
  case code
  of kcEscape: "esc"
  of kcBackspace: "bspace"
  else:
    var n = $code
    n.removePrefix("kc")
    n.toLowerAscii

func eventRepr(e: Event): string =
  result = ""
  case e.kind
  of evNone: result = "none"
  of evPaste: result = "paste:" & e.text
  of evTimer: result = "timer:" & $e.timerId
  of evFocus: result = "focus:" & $e.focused
  of evUser: result = "user:" & e.name & ":" & e.payload
  of evMouse:
    let m = e.mouse
    let actionName = case m.action
      of maPress: "press"
      of maRelease: "release"
      of maDrag: "drag"
      of maMove: "move"
      of maScroll: "scroll"
    result = "mouse:" & actionName & ":" & $m.button & ":" & $m.x & ":" & $m.y
  of evResize: result = "resize"
  of evKey:
    let k = e.key
    var parts: seq[string]
    if modCtrl in k.mods: parts.add "ctrl"
    if modAlt in k.mods: parts.add "alt"
    if modShift in k.mods: parts.add "shift"
    let name = if k.code == kcChar: $k.char else: keyName(k.code)
    result = "key:" & parts.join("+") & (if parts.len > 0: "+" else: "") & name

when defined(posix):
  proc child() =
    var ui = initUi()
    let start = getMonoTime()
    while getMonoTime() < start + initDuration(seconds = 2):
      let ev = ui.poll(20)
      if ev.kind != evNone:
        let line = "EV:" & ev.eventRepr
        discard posix.write(cint(1), addr line[0], line.len)
    ui.leave()
    quit(0)

  proc testStagedChunks =
    let (master, pid) = spawnPty(child)
    ossleep.sleep(300)
    proc send(hexstr: string) =
      var data: seq[byte]
      var i = 0
      while i + 1 < hexstr.len:
        data.add byte(parseHexInt(hexstr[i ..< i + 2]))
        i += 2
      discard posix.write(master, addr data[0], data.len)

    send("1b5b41") # arrow up
    ossleep.sleep(50)
    send("6162") # 'a' 'b'
    ossleep.sleep(50)
    send("1b") # lone ESC, waits past deadline
    ossleep.sleep(300)
    send("78") # 'x' after deadline
    ossleep.sleep(50)
    send("1b5b3230307e68691b5b3230317e") # paste "hi"
    ossleep.sleep(50)
    send("1b5b35") # partial CSI
    ossleep.sleep(10)
    send("7e") # completes pgup
    ossleep.sleep(50)
    send("1b5b3c303b353b354d") # SGR mouse press
    ossleep.sleep(200)
    let r = finishPty(master, pid)
    check r.exitedCleanly, "child exit 0"
    let got = cast[string](r.bytes)
    check "EV:key:up" in got, "arrow event"
    check "EV:key:a" in got, "a event"
    check "EV:key:b" in got, "b event"
    check "EV:key:esc" in got, "lone esc after deadline"
    check "EV:key:x" in got, "x after deadline"
    check "EV:paste:hi" in got, "paste event"
    check "EV:key:pageup" in got, "split sequence completes"
    check "EV:mouse:press:0:4:4" in got, "sgr mouse"

proc main =
  when defined(posix):
    testStagedChunks()
    echo "input ok"
  else:
    echo "input pty test skipped on this platform"

main()
