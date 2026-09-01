# Pre-1.0 TUI migration

The original API exposed `Out`, `Term`, `Ui.front`, `Ui.back`, and manual
`render()` calls from the ordinary facade. New applications should use:

- `runTui(update, draw)` for scoped lifecycle and invalidation;
- `openTui` with `defer: app.close()` for explicit host integration;
- `Frame` methods and public widgets for drawing;
- `post`, `setTimer`, and `cancelTimer` for external work;
- `tsuki/tui/agent` for coding-agent applications;
- `tsuki/tui/expert` only for framework code and benchmarks.

Plain strings are now sanitized. If subprocess output intentionally contains
colors, parse it with `parseAnsiText`; never forward raw escape sequences.
Cells now preserve full grapheme clusters in a buffer-owned arena, so code that
inspects `Cell.rune` should use `Buffer.glyphString` when exact text matters.

Legacy low-level modules remain available during the pre-1.0 transition, but
the private writer is no longer re-exported by `tsuki/tui`.
