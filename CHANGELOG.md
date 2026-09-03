# Changelog

## Unreleased

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
