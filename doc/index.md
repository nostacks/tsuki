# he3 quick start

he3 is the in-repo terminal UI framework that powers the Tsuki coding agent.
Its public import path is `tsuki/tui`. The framework is kept modular so the
agent's transports, tools, policies, and presentation can evolve independently.

The TUI is immediate-mode: your application owns durable state and redraws a
desired frame only after an event invalidates it. Front/back buffers, terminal
sequences, and teardown belong to the runtime.

## Lifecycle and updates

```nim
import tsuki/tui

var count = 0
discard runTui(
  proc (event: Event): Update =
    if event.kind == evKey and event.key.isChar('+'):
      inc count
      redraw()
    elif event.isQuit:
      quitTui()
    else:
      unchanged(),
  proc (frame: var Frame) =
    frame.write(0, 0, "Counter", darkTheme().accent)
    frame.write(0, 2, $count))
```

`wait()` uses one blocking OS wait when there is no timer, partial input
deadline, or externally posted event. `redraw`, `redrawAt`, and explicit timers
are the only scheduling sources; rendering is capped by `maxFramesPerSecond`.
Fullscreen, inline, and deterministic headless modes are selected with
`tuiOptions(mode = ...)`. A handler can return `suspendTui()` for Ctrl-Z;
POSIX restores the terminal before stopping and re-enters it after resume.
Unsupported and headless hosts terminate the session cleanly.

## Drawing and composition

Every `Frame` is clipped and uses local coordinates. `splitH` and `splitV`
support fixed, weighted fill, percent, ratio, bounded min/max, intrinsic,
padding, and gap composition. Public `Widget`, `FocusState`, `HitMap`,
`OverlayStack`, `ScrollState`, and canvas APIs are enough to build custom
controls without private imports.

The standard library includes text/block/rule/help, lists, virtual lists,
tables, trees, tabs, scrollbars, logs, progress/charts, input/textarea,
buttons and selection controls, forms, split panes, popups, modals, tooltips,
toasts, and command palettes. Interactive widgets expose keyboard operation
and redundant text/symbol cues so meaning does not depend on color alone.
Textarea editing is grapheme-aware, but terminal protocols do not expose a
portable native IME composition API; the framework accepts the committed UTF-8
text delivered by the terminal.

## Safe text

`Frame.write`, buffers, widgets, Markdown, logs, paste, and agent output sanitize
plain text. ESC, BEL, C1, bidi overrides, malformed UTF-8, and terminal control
payloads cannot pass through the plain writer. Use `parseAnsiText` only for
opt-in subprocess formatting; it allowlists SGR styling and turns OSC/other
commands into inert visible labels.

Optional hyperlinks, clipboard writes, synchronized output, and image metadata
live under `tsuki/tui/protocols`. They require advertised capabilities, safe
metadata, size limits, and—where an external effect is involved—an explicit
application decision.

## Agent applications

Import `tsuki/tui/agent` for typed thread-safe events, safe streaming Markdown,
virtualized transcripts, queued prompts, prompt history/completions,
code/diff/tool views, foreground/background tools, plans, status, and two-step
approvals. `AgentChat` owns presentation state, not
model transport, authentication, tools, or authority policy. See
`examples/agent_chat.nim` for an end-to-end mock workflow.

The product-level [agent guide](agent.md) documents provider configuration,
durable sessions, commands, explicit attachments, and the read-only tool
boundary. [Phase 1 architecture decisions](architecture-phase1.md) record the
ownership split, fixed bounds, platform paths, and evidence matrix.

## Examples

There are exactly three maintained examples: `hello_world.nim` introduces the
scoped runtime, `counter.nim` shows a centered solid-canvas app, and
`agent_chat.nim` exercises the complete transport-neutral agent lifecycle.

## Testing and low-level work

`initHeadlessTui` renders semantic cell snapshots without touching a terminal.
The supported framework-author escape hatch is `tsuki/tui/expert`; ordinary
applications should not import private modules or manipulate output sinks.

Run `nimble test`, `nimble fuzz`, `nimble docs`, `nimble bench`, and
`nimble examples`. Performance figures are emitted by the benchmark on the
machine that runs it; this guide does not present local results as universal.
