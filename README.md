# Tsuki

Tsuki is a fast, tiny, modular coding agent written in Nim.

> [!WARNING]
> Tsuki is in pre-alpha and under active development. The Phase 1 agent is a
> deliberately bounded vertical slice, provider and terminal compatibility is
> claimed only where the manual record has evidence.

## he3

he3 is the terminal UI framework built for Tsuki. It handles terminal setup and
restoration, input, Unicode-safe drawing, layouts, widgets, and screen updates.
It uses an immediate-mode API backed by retained front and back buffers: the
application redraws the desired frame, then he3 diffs it against the previous
one.

he3 is fast and lightweight: zero third-party runtime dependencies, no idle
polling, and sub-millisecond frame rendering in local release benchmarks.

The long-term goal is for he3 to become a standard TUI framework for the Nim
ecosystem. It is its own Nimble package under [`packages/he3`](packages/he3)
and its import path is `he3`.

### Quick start

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

Install he3 on its own with the `subdir` query:

```sh
nimble install "https://github.com/nostacks/tsuki?subdir=packages/he3"
```

Agent views are available from `he3/agent`. Model and tool workers can
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

Start without credentials and add a key in the app:

```sh
./build/tsuki --new
```

Chat or plan without reading the current directory, or switch with `/chat`
and `/agent` inside the app:

```sh
./build/tsuki --chat
```
## Examples

The repository keeps three public examples:

1. [`hello_world.nim`](examples/hello_world.nim): a minimal he3 application.
2. [`counter.nim`](examples/counter.nim): state, keyboard input, styling, and a
   testable draw function.
3. [`agent_chat.nim`](examples/agent_chat.nim): the public mock provider and
   real session/controller/TUI integration.

Compile all examples without running the interactive programs:

```sh
nimble examples
```

## Development

```sh
nimble test       # product tests, then the he3 debug and release suites
nimble examples   # compile every public example
nimble fuzz       # bounded deterministic property tests
nimble bench      # release benchmarks
nimble docs       # generate API docs under doc/htmldocs
```

The same `test`, `fuzz`, `bench`, and `docs` tasks can be run directly inside
`packages/he3`.

Read the [he3 quick start](doc/index.md) or the full
[he3 library guide](doc/he3.md), review the
[terminal compatibility record](doc/manual-test.md), or see the
[pre-1.0 migration notes](doc/migration.md).

## Platform support

he3 includes POSIX and Windows terminal backends. The
[compatibility record](doc/manual-test.md) separates automated checks from
manual terminal testing. Platforms without recorded tests are not presented as
verified.

## License

Tsuki is available under the [MIT License](LICENSE).
