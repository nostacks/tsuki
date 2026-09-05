# Changelog

## Unreleased

- Rendering: he3 cells carry hyperlinks emitted as OSC 8, frames can place
  images through the kitty graphics protocol or iTerm2 inline images with
  once-only transmission and diffed placements, the Markdown engine gained
  nested and ordered lists, six heading levels, strikethrough, autolinks,
  tables with header padding, images, syntax highlighting for fenced code
  and tool output, LaTeX math rendered as Unicode, whole-table layout with
  alignment, terminal reply strings swallowed by the input parser, and image
  placement deferred while scrolling. `/login` and `/logout` were folded
  into `/provider` (Enter signs in, Delete signs out).
- Extracted he3 into its own Nimble package at `packages/he3`. The import
  path is now `he3` (`he3/agent`, `he3/expert`, `he3/protocols/...`) instead
  of `tsuki/tui`, its tests and benchmarks live under the package, the root
  tasks delegate to it, and `doc/he3.md` documents the framework for library
  users.
- Hardened the coding agent: a cancel arriving between the queue pop and
  the first provider call is no longer lost, retries honor `Retry-After`
  and can no longer overflow the backoff shift, retry and Codex waits block
  on condition variables instead of polling, the OpenAI-compatible stream
  reads the usage chunk that follows `finish_reason` (with a two second grace
  when no `[DONE]` arrives), `read_file` only reports truncation for implicit
  ranges, session saves fsync before the atomic rename, and the agent shell
  exits when terminal input reaches end-of-file.
- Sped up the agent core: `safeDisplay` copies clean UTF-8 without
  per-rune allocation, bounded reads fill a presized buffer, SSE buffering
  is linear, Codex pipe output is read in 64 KiB chunks, sessions are
  encoded without a JSON tree, listing decodes only document headers
  (`decodeSessionHeader`, `SessionStore.loadHeader`), and unchanged image
  references are revalidated by size and mtime instead of a header read.
- Rewrote transcript layout: each streamed message keeps an incremental
  Markdown state and per-line row cache, so a delta costs its appended text
  rather than a full reparse (2k-delta stream 627 ms to 92 ms); items cut by
  the top of the viewport now render their visible rows; cached entries are
  matched by item identity and a session reset invalidates them.
- Session picker rows show the local update time instead of epoch
  milliseconds, and model refresh threads reuse finished slots.
- API keys added with `/provider` persist in an owner-only `credentials.json`
  and load on the next start. Key checks and model choices confirm through a
  transient activity-line toast (`toast`, `AgentChat.toast`,
  `controllerConfirmed`); a rejected key reopens the editor with the reason.
- Mouse selection now works on screen cells (`CellSelection`,
  `selectionText`) instead of whole transcript rows, release copies through
  OSC 52 and the host's clipboard tool, and the loading shimmer sweeps fully
  off both ends before wrapping.

- Hardened the he3 runtime: SIGWINCH now wakes a blocked wait through the
  reactor pipe, terminal end-of-file ends `runTui` instead of spinning, the
  fatal-signal restore sequence lives in fixed storage, leaving the terminal
  resets SGR state, and a resize rewrites the screen once from the next frame.
- Fixed input decoding: Ctrl with `\`, `]`, `^`, and `_`, the kitty
  functional-key table (keypad, lock, and media keys), private-use kitty
  codes never becoming text, a device-attributes reply ending the kitty probe
  early, and the escape deadline resolving exactly at 50 ms.
- Made `redrawAt` keep the earliest pending deadline and re-arm later ones,
  fixed timer waits waking a fraction early, and added `TuiApp.apply` for
  host-driven loops.
- Packed `Color` into four bytes (a `Cell` is now 24 bytes instead of 96);
  `name`, `index`, and `rgb` are accessors and `named`, `indexed`, and `rgb`
  the constructors.
- Emit one combined SGR per style transition, written without allocation,
  with incremental color and attribute changes between cells.
- Added allocation-free `graphemeSpans`, `textWidth`, and `openArray` cluster
  writes, a compile-time property table for code points below U+0800, an
  `isSanitized` fast path that skips copying clean text, allocation-free
  overlay compositing, and an O(width) diff row tail scan.
- Enabled DEC synchronized output automatically for terminals that advertise
  it; empty frames write nothing.
- Added hardening tests, benchmark cases for frame writes, overlays, and
  styled diffs, and corrected the kitty corpus codes.

- Named Tsuki's in-repo terminal UI framework he3.
- Added safe plain/rich text and allowlisted ANSI parsing.
- Added complete grapheme storage, configurable width policy, and wide-cell
  invariant repair.
- Added an event-driven reactor with thread-safe posts and exact timers.
- Added scoped fullscreen, inline, and headless application lifecycles.
- Added paired focus-event mode and POSIX suspend/resume restoration.
- Added semantic themes, public composition primitives, standard widgets, and
  a deterministic headless test kit.
- Added the transport-neutral coding-agent model and UI toolkit.
- Added capability-gated optional protocol modules.
- Moved private writer access out of the ordinary facade and ported the small
  examples to automatic lifecycle APIs.
- Consolidated the public examples into hello world, counter, and one complete
  agent chat workflow.
- Added the Phase 1 coding-agent executable with versioned configuration,
  OpenAI-compatible and deterministic mock providers, incremental streaming,
  cancellation/retry, conservative context projection, and dynamic status.
- Added canonical multimodal messages, atomic resumable JSON sessions,
  searchable provider/model and session views, explicit image staging, and a
  bounded Kitty PNG encoder with universal text fallback.
- Added workspace-confined read-only list/search/read tools and a persisted
  multi-round controller tool loop.
- Added OpenRouter with provider-supplied model metadata and automatic model
  discovery for every configured provider.
- Added managed ChatGPT subscription login and model listing through the Codex
  App Server without exposing Codex OAuth credentials to Tsuki.
- Replaced the single slash-completion hint with a keyboard-first recommended
  command popover, including `/login` and `/logout`.
