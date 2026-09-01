# Tsuki

Tsuki is a fast, tiny, modular coding agent written in Nim.

> [!WARNING]
> Tsuki is in pre-alpha and under active development. he3, its terminal UI, is
> the only part considered ready today. Work is focused on a minimal working
> agent, and major changes are expected until that prototype is complete.

The current `agent_chat` example demonstrates the interface with mock events.
It is not a working coding agent yet.

## he3

he3 is the terminal UI framework built for Tsuki. It handles terminal setup and
restoration, input, Unicode-safe drawing, layouts, widgets, and screen updates.
It uses an immediate-mode API backed by retained front and back buffers: the
application redraws the desired frame, then he3 diffs it against the previous
one.

he3 is fast and lightweight: zero third-party runtime dependencies, no idle
polling, and sub-millisecond frame rendering in local release benchmarks.

The long-term goal is for he3 to become a standard TUI framework for the Nim
ecosystem. Its current import path is `tsuki/tui`.

### Quick start

```nim
import tsuki/tui

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

Agent views are available from `tsuki/tui/agent`. Model and tool workers can
post typed events from other threads without coupling he3 to a provider.

## Install

Tsuki requires Nim 2.2 or newer. Install the current pre-alpha from GitHub:

```sh
nimble install https://github.com/nostacks/tsuki
```

To build a checkout locally:

```sh
nimble build
```

## Examples

The repository keeps three public examples:

1. [`hello_world.nim`](examples/hello_world.nim): a minimal he3 application.
2. [`counter.nim`](examples/counter.nim): state, keyboard input, styling, and a
   testable draw function.
3. [`agent_chat.nim`](examples/agent_chat.nim): a mock coding-agent interface
   with streamed output, queued prompts, plans, tools, approvals, and
   background work.

Compile all examples without running the interactive programs:

```sh
nimble examples
```

## Development

```sh
nimble test       # debug and release test suites
nimble examples   # compile every public example
nimble fuzz       # bounded deterministic property tests
nimble bench      # release benchmarks
nimble docs       # generate API docs under doc/htmldocs
```

Read the [he3 guide](doc/index.md), review the
[terminal compatibility record](doc/manual-test.md), or see the
[pre-1.0 migration notes](doc/migration.md).

## Platform support

he3 includes POSIX and Windows terminal backends. The
[compatibility record](doc/manual-test.md) separates automated checks from
manual terminal testing. Platforms without recorded tests are not presented as
verified.

## License

Tsuki is available under the [MIT License](LICENSE).
