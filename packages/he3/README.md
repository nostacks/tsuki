# he3

he3 is a fast, tiny terminal UI framework. It handles
terminal setup and restoration, input, Unicode-safe drawing, layouts, widgets,
and screen updates with an immediate-mode API backed by retained front and
back buffers. It has no third-party runtime dependencies and never polls while
idle.

```nim
import he3

proc update(event: Event): Update =
  if event.isQuit: quitTui() else: unchanged()

proc draw(frame: var Frame) =
  frame.text("Hello, world!", align = textCenter)

discard runTui(update, draw)
```

Compile with threads enabled:

```sh
nim c -r --threads:on app.nim
```

## Install

he3 lives in the Tsuki repository as its own package:

```sh
nimble install "https://github.com/nostacks/tsuki?subdir=packages/he3"
```

Or in a `.nimble` file:

```nim
requires "https://github.com/nostacks/tsuki?subdir=packages/he3"
```

## Documentation

The [library guide](../../doc/he3.md) covers the runtime model, events,
drawing, layout, widgets, threads, protocols, and testing. Agent views for
coding-agent applications are exported from `he3/agent`. `nimble docs` writes
the API reference to `build/htmldocs`.

## Development

```sh
nimble test    # debug and release test suites
nimble fuzz    # bounded deterministic property tests
nimble bench   # release benchmarks against bench/baseline.txt
nimble docs    # API reference
```

The repository root's `AGENTS.md` records the safety invariants and the
compatibility evidence process that apply to every change here.
