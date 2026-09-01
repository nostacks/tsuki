# Real-terminal compatibility evidence

Automated tests and target compilation are not substitutes for observing a
real terminal. This file records both without turning an unchecked box into a
support claim.

Evidence as of 2026-08-29:

| Environment | Automated | Manual | Notes |
|---|---|---|---|
| macOS build host | unit, PTY, headless pass | verified 2026-08-29 (see results) | Current development host; exercised through a real PTY at 80x24, 40x12, and 120x30 |
| Linux | source is POSIX-compatible | not recorded | Native run still required |
| Windows amd64 | source has a native backend | not recorded | Native run still required |
| SSH/tmux/screen | not recorded | not recorded | Compatibility is not yet claimed |

## Agent demo checklist

Build and run the release binary, then record the terminal/version/date before
checking a result.

```sh
nim c --threads:on -d:release --path:src -o:build/agent_chat examples/agent_chat.nim
./build/agent_chat
```

Terminals under test: macOS Terminal, iTerm2, kitty, Alacritty, Windows
Terminal, cmd.exe conhost.

## Checklist

| # | Check | How |
|---|-------|-----|
| 1 | Clean enter | Alt screen starts on the quiet baseline: 月 tsuki welcome, help line, one-row composer below a blank gap, status |
| 2 | Submit | Type text, press Enter; the request appears under a violet `›` cue |
| 3 | Streaming | Thinking (`✻`), plan row, tool rows, and the final response advance across multiple frames |
| 4 | Tool output | Read/code output renders with a `│` rail; patch output renders through the diff view with `+`/`−` cues |
| 5 | Approval gate | The turn pauses on an inline card at the bottom of the transcript with `Reject` selected before any input |
| 6 | Two-Enter confirm | First Enter arms the selected action ("Press Enter again…"); second Enter confirms; arrows change selection and disarm |
| 7 | Escape rejects | Escape while the card is pending rejects without granting authority |
| 8 | Global quit | Ctrl-Q exits immediately, including while approval is pending |
| 9 | Wheel scroll | Wheel scrolls the transcript from any focus; composer, divider, and status stay fixed |
| 10 | Autoscroll | New lines while scrolled to bottom keep the view pinned |
| 11 | Slash commands | `/help` lists commands, `/clear` empties the transcript, `/quit` exits, unknown commands report quietly |
| 12 | Slash completion | Typing `/` shows a `⇥` hint; Tab inserts the candidate; repeating Tab cycles |
| 13 | Wide chars/emoji | Paste CJK and emoji; cursor and wrap stay correct |
| 14 | Multiline paste | Bracketed paste lands in the draft; the composer grows for multiline drafts |
| 15 | Resize | Resize from 40x12 through 120x30; bottom chrome stays anchored, no artifacts or tearing |
| 16 | Idle behavior | After a completed turn the process performs zero wakeups (no spinner timer while idle) |
| 17 | Text selection | Mouse press and drag highlights transcript rows; Ctrl-C copies them and clears the highlight |
| 18 | Activity shimmer | The spinner label shows a bright wave traveling through it, driven by the spinner timer with no extra wakeups |
| 19 | Prompt queue | Submit two prompts quickly; the activity line shows `1 prompt queued`, then dispatches it after the active turn finishes |
| 20 | Background task | Workspace indexing streams through a `background · Index workspace` tool without taking over foreground activity |
| 21 | Clean exit | Terminal restored exactly: alt screen exit, cursor visible, mouse/paste modes off, raw mode off |

## Results

| Terminal/version/date | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| macOS PTY harness, release build, 2026-08-29 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |   |   | ✓ |
| macOS PTY live smoke, 2026-09-01 |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   | ✓ | ✓ | ✓ |
| iTerm2 |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| kitty |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| Alacritty |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| WezTerm |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| Windows Terminal |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| classic Windows console |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| tmux |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |
| SSH |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |   |

The macOS PTY row was observed through a real pseudo-terminal (screen emulation
over raw ANSI), not only in-memory buffers: initial baseline with the tsuki
welcome, streaming turn, inline approval pause with visible `Reject`,
two-Enter approval and Escape rejection, Ctrl-Q restoration (alt-screen exit,
cursor show, mouse/paste disables captured in the exit byte stream), wheel
scrolling, slash commands and Tab completion, CJK/emoji paste, and 120x30
resize with stable bottom chrome. Native GUI-terminal spot checks are still
outstanding.

The 2026-09-01 live smoke submitted two prompts in one active turn, observed
the `1 prompt queued` status, streamed and completed the independent workspace
index, and captured a clean Ctrl-Q terminal restoration.
