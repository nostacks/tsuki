# Changelog

## Unreleased

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
