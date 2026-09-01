# Repository instructions

These instructions apply to every automated contributor working in this
repository. `AGENTS.md` is the canonical source; tool-specific instruction
files should reference it instead of duplicating it.

## Project scope

Tsuki is a fast, tiny, modular coding agent written in Nim 2.2+. Its executable
entry point is `src/tsuki.nim`, its in-repo terminal framework, he3, has its
facade at `src/tsuki/tui.nim`, and its transport-neutral agent UI facade is
`src/tsuki/tui/agent.nim`.

he3 owns terminal lifecycle, events, rendering, widgets, and agent UI
state. It does not own model transports, credentials, tool execution, or host
authorization policy. Keep those boundaries explicit within the coding agent.

## Repository map

- `src/tsuki.nim` — coding-agent executable entry point.
- `src/tsuki/` — modular agent and he3 implementation.
- `src/tsuki/tui/private/` — internal terminal and writer details; do not
  expose these through ordinary public APIs.
- `src/tsuki/tui/protocols/` — optional, capability-gated terminal protocols.
- `src/tsuki/tui/agent/` — transport-neutral agent model and views.
- `examples/` — exactly `hello_world.nim`, `counter.nim`, and
  `agent_chat.nim`, plus `nim.cfg`.
- `tests/tui/` — unit, property, headless, and PTY coverage.
- `bench/tui/` — performance checks and their baseline.
- `doc/` — public guide, migration notes, and manual compatibility evidence.

## Working rules

- Read the relevant module and its tests before changing behavior.
- Preserve existing user changes and keep edits scoped to the request.
- Use public facades in examples and ordinary tests. Import `private/` modules
  only when testing or implementing the internals they contain.
- Keep the example set at exactly three files. If an example is renamed, update
  `README.md`, `doc/`, `tsuki.nimble`, and any generated-artifact ignore rule.
- Do not add third-party dependencies without a clear requirement and an
  explicit package-manifest change.
- Do not commit build output, generated API docs, Nim caches, editor state, or
  local environment files.

## Safety invariants

- Terminal entry and restoration must remain paired on success, failure,
  cancellation, signals, and suspend/resume paths.
- Treat terminal input, paste, subprocess output, Markdown, URLs, and model
  output as untrusted. Plain-text paths must never emit raw control sequences.
- Keep optional terminal effects capability-gated. Clipboard writes and other
  external effects require an explicit host decision.
- Preserve grapheme clusters and wide-cell invariants when changing buffers,
  wrapping, clipping, scrolling, or cursor movement.
- Work crossing a thread boundary must use the reactor or typed agent event
  queues. Do not share mutable UI state without the established synchronization
  mechanism.
- Idle applications must block when there is no input, timer, or posted work.
  Avoid periodic polling and unnecessary redraws.
- Never claim platform or terminal compatibility without recorded evidence in
  `doc/manual-test.md`.

## Style

- Follow `nimpretty` with two-space indentation and the existing naming style.
- Prefer small modules, explicit types, early returns, and deterministic tests.
- Public symbols need concise `##` documentation when their purpose or safety
  contract is not obvious.
- Comments should explain invariants or tradeoffs, not restate the code.
- Keep user-facing text plain, concise, and consistent with the examples.

## Validation

Run the smallest relevant check while iterating, then run the release gate:

```sh
nimble test
nimble examples
nimble fuzz
```

For public API or documentation changes, also run:

```sh
nimble docs
nimble check
```

Run `nimble bench` for rendering, parsing, layout, or buffer changes. Benchmark
results are machine-specific; investigate regressions instead of weakening the
baseline without evidence.

The `nimble lint` task formats Nim sources and then verifies the resulting diff,
so use it only when the worktree state is understood. Before handing work back,
check `git status --short`, confirm only intended files changed, and remove
generated artifacts from the working tree.
