import std/[strutils, times, monotimes, unicode, os]
import he3
import he3/private/writer
import he3/keyparser
import he3/diff
import he3/widgets/paragraph
import he3/agent/[model, transcript]

type Result = object
  name: string
  ms: float
  allocs: int

const rounds = 5

proc allocations(): int =
  ## Heap allocation count so far; zero unless built with -d:nimAllocStats.
  ## The counter fields are private, so the rendered form is parsed.
  let rendered = $getAllocStats()
  let key = "allocCount: "
  let start = rendered.find(key)
  if start < 0:
    return 0
  var stop = start + key.len
  while stop < rendered.len and rendered[stop].isDigit:
    inc stop
  parseInt(rendered[start + key.len ..< stop])

proc measure(name: string, runs: int, body: proc ()): Result =
  ## Times `body` averaged over `runs` invocations, keeping the fastest of
  ## several rounds so scheduler noise cannot masquerade as a regression, and
  ## reports the allocations of one invocation.
  result = Result(name: name, ms: Inf)
  for round in 0 ..< rounds:
    let start = getMonoTime()
    for i in 0 ..< runs:
      body()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1_000_000.0
    result.ms = min(result.ms, elapsed / runs.float)
  let probeStart = allocations()
  let overhead = allocations() - probeStart
  let before = allocations()
  body()
  result.allocs = allocations() - before - overhead

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
  for dir in ["tests/corpora"]:
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
  measure("parser throughput key corpora x50", 10) do ():
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

proc benchStreaming(): Result =
  var deltas: seq[string]
  for index in 0 ..< 2_000:
    if index mod 40 == 39:
      deltas.add "\n\n## Part " & $index & "\n"
    elif index mod 9 == 8:
      deltas.add "\n"
    else:
      deltas.add "token" & $index & " "
  var buffer = initBuffer(100, 30)
  var frame = initFrame(buffer, initRect(0, 0, 100, 30))
  measure("stream 2k markdown deltas with a draw each", 1) do ():
    let chat = initAgentChat()
    chat.apply userMessage("t:user", "go")
    var state: TranscriptState
    state.scroll.anchor = anchorEnd
    for delta in deltas:
      chat.apply messageDelta("t", delta)
      buffer.reset()
      frame.transcript(chat, state)

proc main =
  var results = @[
    benchStreaming(),
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
  let baselinePath = "bench/baseline.txt"
  var baseline: seq[(string, float, int)]
  if fileExists(baselinePath):
    for line in baselinePath.lines:
      let parts = line.split('=')
      if parts.len != 2:
        continue
      let values = parts[1].split(',')
      let allocs = if values.len >= 2: parseInt(values[1].strip) else: -1
      baseline.add (parts[0], parseFloat(values[0].strip), allocs)
  var failed = false
  var matched = 0
  for r in results:
    var line = r.name & ": " & r.ms.formatFloat(ffDecimal, 3) & " ms"
    if defined(nimAllocStats):
      line.add ", " & $r.allocs & " allocs"
    for entry in baseline:
      if entry[0] != r.name:
        continue
      inc matched
      line.add " (" & (r.ms / entry[1]).formatFloat(ffDecimal, 2) &
        "x baseline)"
      if r.ms > entry[1] * 2.0:
        line.add " REGRESSION: > 2x baseline time"
        failed = true
      if defined(nimAllocStats) and entry[2] >= 0 and
          float(r.allocs) > float(entry[2]) * 1.1 + 2:
        line.add " REGRESSION: " & $r.allocs & " allocs > baseline " &
          $entry[2]
        failed = true
    echo line
  if baseline.len == 0:
    echo "no baseline file at " & baselinePath & ", skipping regression check"
  elif matched < results.len:
    echo "baseline check: " & $(results.len - matched) &
      " case(s) missing from " & baselinePath
    quit(1)
  elif failed:
    quit(1)
  else:
    echo "baseline check: ok (" & baselinePath & ")"

main()
