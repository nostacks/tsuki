import std/[strutils, times, monotimes, unicode, os]
import tsuki/tui
import tsuki/tui/private/writer
import tsuki/tui/keyparser
import tsuki/tui/diff
import tsuki/tui/widgets/paragraph
import tsuki/tui/agent/[model, transcript]

type Result = object
  name: string
  ms: float

proc measure(name: string, runs: int, body: proc ()): Result =
  ## Times `body` averaged over `runs` invocations.
  let start = getMonoTime()
  for i in 0 ..< runs:
    body()
  let elapsed = (getMonoTime() - start).inNanoseconds.float / 1_000_000.0
  Result(name: name, ms: elapsed / runs.float)

func filledBuffer(w, h: int): Buffer =
  result = initBuffer(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.setCell(x, y, Cell(rune: Rune(ord('a') + (x + y) mod 26),
        style: fg(named(ncRed))))

proc benchDiff(): Result =
  var next = filledBuffer(200, 60)
  var prev = initBuffer(200, 60)
  var o = initFakeOut()
  o.flushFull(prev)
  o.frame.setLen 0
  measure("diff+serialize 200x60 full change", 50) do ():
    o.fake.bytes.setLen 0
    diffInto(prev, next, o)
    o.frame.setLen 0

proc benchNoChange(): Result =
  var b = filledBuffer(200, 60)
  var o = initFakeOut()
  o.flushFull(b)
  o.frame.setLen 0
  measure("no-change frame diff", 200) do ():
    diffInto(b, b, o)
    o.frame.setLen 0

proc benchSparseChange(): Result =
  var previous = filledBuffer(200, 60)
  var next = previous
  for index in 0 ..< 120:
    let x = (index * 37) mod 200
    let y = (index * 17) mod 60
    next.setCell(x, y, Cell(rune: Rune(ord('Z')), style: fg(named(ncGreen))))
  var output = initFakeOut()
  measure("diff+serialize 200x60 one-percent change", 100) do ():
    output.fake.bytes.setLen 0
    diffInto(previous, next, output)
    output.frame.setLen 0

proc benchParagraph(): Result =
  var text = ""
  let words = ["alpha", "beta", "gamma", "delta", "epsilon", "你好世界", "zeta"]
  while text.len < 10_000:
    for w in words:
      text.add w & " "
  var b = initBuffer(100, 40)
  var f = initFrame(b, initRect(0, 0, 100, 40))
  measure("paragraph wrap 10k chars", 50) do ():
    f.paragraph(text)

proc benchParser(): Result =
  var corpus: seq[seq[byte]]
  for dir in ["tests/tui/corpora"]:
    for path in walkDirRec(dir):
      if not path.endsWith(".txt"):
        continue
      for line in path.lines:
        let parts = line.split('|')
        if parts.len != 3:
          continue
        var chunk: seq[byte]
        for c in parts[1].split('/'):
          var i = 0
          while i + 1 < c.len:
            chunk.add byte(parseHexInt(c[i ..< i + 2]))
            i += 2
        corpus.add chunk
  var st: ParseState
  var events: seq[Event]
  if corpus.len == 0:
    echo "parser bench: no corpus loaded"
  measure("parser throughput full corpus x50 (x$1)" % $corpus.len, 10) do ():
    for i in 0 ..< 50:
      for chunk in corpus:
        keyparser.parse(st, chunk, events)
        st.checkDeadline(events, getMonoTime() + initDuration(seconds = 1))
      events.setLen 0

proc benchFrameWrite(): Result =
  var b = initBuffer(120, 40)
  var f = initFrame(b, initRect(0, 0, 120, 40))
  let ascii = "The quick brown fox jumps over the lazy dog 0123456789 " &
    "and keeps running across the terminal width without stopping."
  measure("frame write 40 ascii rows", 200) do ():
    for y in 0 ..< 40:
      f.write(0, y, ascii, fg(named(ncBlue)))

proc benchFrameWriteCjk(): Result =
  var b = initBuffer(120, 40)
  var f = initFrame(b, initRect(0, 0, 120, 40))
  let mixed = "終端 émoji 👨‍👩‍👧 한국어 テキスト ascii mix 你好世界 " &
    "ünïcödé wide narrow"
  measure("frame write 40 mixed-script rows", 200) do ():
    for y in 0 ..< 40:
      f.write(0, y, mixed, fg(named(ncBlue)))

proc benchOverlay(): Result =
  var destination = filledBuffer(200, 60)
  var popup = initBuffer(60, 20)
  for y in 0 ..< 20:
    popup.writeStr(0, y, "popup row é 你好 " & $y, bg(named(ncBlue)))
  measure("overlay 60x20 popup onto 200x60", 200) do ():
    destination.overlay(popup, 70, 20)

proc benchStyledDiff(): Result =
  var previous = initBuffer(200, 60)
  var next = initBuffer(200, 60)
  for y in 0 ..< 60:
    for x in 0 ..< 200:
      let color = rgb((x * 7) mod 256, (y * 11) mod 256, (x + y) mod 256)
      next.setCell(x, y, Cell(rune: Rune(ord('a') + (x + y) mod 26),
        style: fg(color).withBg(indexed((x + y) mod 256))))
  var output = initFakeOut()
  output.truecolor = true
  measure("diff+serialize 200x60 per-cell styles", 50) do ():
    output.fake.bytes.setLen 0
    diffInto(previous, next, output)

proc benchTranscript(): Result =
  let chat = initAgentChat(maxHistoryItems = 100_000)
  chat.items = newSeq[TranscriptItem](100_000)
  for index in 0 ..< chat.items.len:
    chat.items[index] = TranscriptItem(id: $index, kind: transcriptMessage,
      role: roleAssistant, content: "message " & $index,
      expanded: true, version: 1)
  var state: TranscriptState
  state.scroll.anchor = anchorEnd
  var buffer = initBuffer(100, 30)
  var frame = initFrame(buffer, initRect(0, 0, 100, 30))
  frame.transcript(chat, state)
  measure("warm visible page from 100k transcript items", 100) do ():
    buffer.reset()
    frame.transcript(chat, state)

proc main =
  var results = @[
    benchDiff(),
    benchNoChange(),
    benchSparseChange(),
    benchParagraph(),
    benchParser(),
    benchFrameWrite(),
    benchFrameWriteCjk(),
    benchOverlay(),
    benchStyledDiff(),
    benchTranscript(),
  ]
  for r in results:
    echo r.name & ": " & r.ms.formatFloat(ffDecimal, 3) & " ms"

  let baselinePath = "bench/tui/baseline.txt"
  if fileExists(baselinePath):
    for line in baselinePath.lines:
      let parts = line.split('=')
      if parts.len != 2:
        continue
      for r in results:
        if r.name == parts[0]:
          let best = parseFloat(parts[1])
          if r.ms > best * 2.0:
            echo "REGRESSION: " & r.name & " " & $r.ms & " ms > 2x baseline " &
              $best & " ms"
            quit(1)
    echo "baseline check: ok (" & baselinePath & ")"
  else:
    echo "no baseline file at " & baselinePath & ", skipping regression check"

main()
