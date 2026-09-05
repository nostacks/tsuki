# Pre-1.0 TUI migration

The original API exposed `Out`, `Term`, `Ui.front`, `Ui.back`, and manual
`render()` calls from the ordinary facade. New applications should use:

- `runTui(update, draw)` for scoped lifecycle and invalidation;
- `openTui` with `defer: app.close()` for explicit host integration;
- `Frame` methods and public widgets for drawing;
- `post`, `setTimer`, and `cancelTimer` for external work;
- `he3/agent` for coding-agent applications;
- `he3/expert` only for framework code and benchmarks.

Plain strings are now sanitized. If subprocess output intentionally contains
colors, parse it with `parseAnsiText`; never forward raw escape sequences.
Cells now preserve full grapheme clusters in a buffer-owned arena, so code that
inspects `Cell.rune` should use `Buffer.glyphString` when exact text matters.

Legacy low-level modules remain available during the pre-1.0 transition, but
the private writer is no longer re-exported by `he3`.

he3 moved out of the `tsuki` package into `packages/he3`. Replace
`import tsuki/tui` with `import he3`, `tsuki/tui/agent` with `he3/agent`,
`tsuki/tui/expert` with `he3/expert`, and `tsuki/tui/protocols/...` with
`he3/protocols/...`. Install it with
`nimble install "https://github.com/nostacks/tsuki?subdir=packages/he3"` or
add `--path` to `packages/he3/src` in a checkout.
