# Tsuki agent guide

Tsuki starts in the current directory, resumes the most recently updated
session for that workspace, and opens promptly even when its provider is
offline. Use `tsuki --help` for CLI options. Without credentials, run
`/provider` to sign in with ChatGPT or paste an API key. Keys added this way
are kept in `credentials.json` under the data directory with owner-only
permissions, and they take precedence over the provider's environment variable.

When conversation content extends beyond the viewport, its top and bottom
edges show clickable `↑ Scroll to top` and `↓ Scroll to bottom` controls for
the corresponding hidden content. Scrolling to the bottom resumes following
new output. Press Tab to focus the transcript, then Home or End to jump with
the keyboard. Narrow terminals use shorter labels; transcript regions under
three rows tall keep their space for content and support wheel and keyboard
scrolling.

## Provider configuration

The default config path is `~/.config/tsuki/config.json` on POSIX. With no
config file, Tsuki registers OpenAI, OpenRouter, and ChatGPT (Codex
subscription) providers. A minimal OpenAI-compatible configuration is:

```json
{
  "schemaVersion": 1,
  "defaultProvider": "openai",
  "defaultModel": "your-model-id",
  "providers": [
    {
      "id": "openai",
      "kind": "openai_compatible",
      "displayName": "OpenAI",
      "baseUrl": "https://api.openai.com/v1",
      "credentialEnv": "OPENAI_API_KEY",
      "toolsEnabled": true,
      "models": [
        {
          "id": "your-model-id",
          "displayName": "Your model",
          "textInput": true,
          "imageInput": "unknown",
          "streaming": true,
          "tools": "unknown",
          "contextWindow": 0,
          "maxOutputTokens": 0
        }
      ]
    }
  ]
}
```

Set the referenced environment variable before launching. Do not put an API
key in `baseUrl`, a slash command, or a session. Plain HTTP is rejected except
for loopback development endpoints. Redirects are disabled, so an
authorization header cannot cross origins.

Configured and cached models appear immediately. Credentialed providers
refresh `/models` on a bounded background worker; successful metadata is
merged into the open selector and written to a credential-free cache. Static
models remain usable when discovery is offline.

For a configured reasoning model, add `"reasoningEfforts": ["low", "high"]`
and optionally `"defaultReasoningEffort": "low"` to its model object, using
only levels supported by that provider and model. Codex and OpenRouter expose
these choices through discovery when their catalogs include effort metadata.
The provider default leaves the request's effort unset; explicit selections
are saved with the session. Requests use Codex's `effort`, Chat Completions'
`reasoning_effort`, or OpenRouter's `reasoning.effort` field. See the
[Codex App Server documentation](https://learn.chatgpt.com/docs/app-server),
[OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model),
and [OpenRouter reasoning documentation](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).

### OpenRouter

The built-in OpenRouter provider uses `https://openrouter.ai/api/v1` and reads
`OPENROUTER_API_KEY`. No static model list is required: Tsuki requests
OpenRouter's model catalog and maps its names, input modalities, tool support,
context windows, and output limits into the selector. To add it to an existing
config file, include:

```json
{
  "id": "openrouter",
  "kind": "openrouter",
  "displayName": "OpenRouter",
  "baseUrl": "https://openrouter.ai/api/v1",
  "credentialEnv": "OPENROUTER_API_KEY",
  "toolsEnabled": true
}
```

### ChatGPT Codex subscription

The `codex_app_server` provider supports ChatGPT subscription sign-in without
asking Tsuki to store, copy, or parse OAuth credentials. Install the Codex CLI
and make sure `codex` is on `PATH`, then run `/provider` and press Enter on
the ChatGPT entry. Tsuki asks the supported Codex App Server for a device URL
and one-time code; if device auth is not available, it falls back to the
managed browser flow. Complete the flow in a browser while Tsuki waits.
Pressing Delete on the same entry signs out through the same managed API.

```json
{
  "id": "chatgpt",
  "kind": "codex_app_server",
  "displayName": "ChatGPT (Codex subscription)",
  "toolsEnabled": false
}
```

Codex persists and refreshes its own tokens. Tsuki does not read Codex's auth
cache. After sign-in, and on later starts, Tsuki pages through `model/list` so
the selector reflects the models supplied by the installed Codex provider.
Turns use an ephemeral Codex thread with `approvalPolicy: never`, a read-only
sandbox, and local tool network access disabled. A developer instruction also
prohibits MCP, app, connector, browser, and other external tool calls. Codex may
run its own local read-only inspection commands; Tsuki does not implement an
approval-escalation path for this adapter. `toolsEnabled: false` prevents a
second, duplicate Tsuki tool loop. Keep side-effecting integrations disabled in
the Codex profile used with Tsuki; their authority is managed by Codex rather
than Tsuki's native tool host.

`nimble testProviderLocal` runs the opt-in loopback HTTP transport fixture. It
uses a synthetic credential and never contacts a public service.

Precedence is CLI, `TSUKI_PROVIDER`/`TSUKI_MODEL`/`TSUKI_DATA_DIR`, user config,
then safe defaults. `TSUKI_CONFIG` chooses another config path. Config parsing
failures open an offline shell with the exact safe path and diagnostic.

## Sessions and recovery

POSIX sessions live under `~/.local/share/tsuki/sessions`; archived sessions
live beside them under `archived`. Each document contains canonical messages,
ordered text/image/tool parts, model identity, timestamps, usage, and terminal
turn state. It never contains resolved credentials or image bytes.

Writes use a flushed sibling temporary file and atomic rename. Streaming saves
are debounced to one second; user messages, tools, model changes, and terminal
states force checkpoints. A turn that was active during a crash loads as
interrupted and is never silently sent again. Corrupt or future-version files
are skipped with their path while valid sessions remain available.

Staged attachment references are saved with the session. On resume, Tsuki
rechecks them and shows missing, changed, or failed state without making the
rest of the conversation unreadable.

## Chat mode

`/chat` switches the current session to chat mode, and `tsuki --chat` starts
in it. Chat mode is for questions, conversation, and planning: Tsuki sends no
tools, names no workspace in its instruction, and never reads the directory.
Its instruction asks the model for direct answers, and for plans that clarify
the goal, weigh options, recommend one, and end with concrete steps. The
status bar shows `◌ chat` in place of the directory name, the composer
placeholder changes to match, and the session picker marks chat sessions.

`/agent` returns to the workspace with the read-only tools. The mode is saved
with the session, so a resumed chat session stays in chat mode, and `/new` or
`/clear` keeps the current mode. `--mode agent` or `--mode chat` sets the mode
explicitly when starting or resuming. Explicitly staged images (`/attach`)
still work in either mode, and modes cannot change during an active turn.

## Commands and keyboard use

- Typing `/` opens a recommended-command popover. Up/Down moves, Tab or Enter
  completes the selected command, and Escape closes the popover without
  exiting. Submitting an exact command runs it.
- The mouse wheel, PageUp, and PageDown scroll the transcript while the
  composer keeps focus; Tab moves focus to the transcript so the arrow keys,
  Home, and End scroll it too. A failure inside the shell restores the
  terminal and prints the reason instead of leaving the screen behind.
- `/new`, `/sessions`, `/resume <id>`, `/rename <title>` manage sessions.
- `/chat` talks or plans without reading the workspace; `/agent` returns to
  the workspace with read-only tools. See [Chat mode](#chat-mode).
- `/provider` opens the provider dialog: Enter starts ChatGPT device sign-in
  or opens a masked API key field for key-based providers, and Delete signs
  out of a ChatGPT entry. A rejected key reopens the field with
  the reason; an accepted key closes the dialog and confirms on the activity
  line. `/model` is the only place models are chosen, and a confirmed choice
  shows the same way. Ctrl-O opens the model dialog too.
- In `/model`, Up/Down selects a model and Enter opens a second step for
  reasoning. Up/Down selects a supported level or the provider default;
  Enter applies both choices. Escape returns to model selection, then closes
  the dialog. Models without effort metadata offer only the default and show
  "Reasoning: not configurable".
- The bottom status bar groups the directory name (`⌂`), model (`◇`), and
  reasoning (`✦`) on the left, using muted, bold, and accent styling. A
  non-agent mode (`◌ chat`) leads the group in accent styling.
  Routine provider, agent-mode, and ready labels are omitted; offline, saving,
  and exhausted request limits stay explicit. Context usage sits on the right.
  The provider default is labeled `default`. A green-to-amber-to-red
  meter includes a position marker and percentage. Wide terminals also show used/total tokens;
  narrower terminals keep the percentage visible. Unknown capacity shows `?`.
  Usage estimates update during requests and yield to reported token usage
  when available, including Codex's token-usage notifications.
- Dragging with the mouse selects screen cells like a terminal. Releasing the
  button copies the selected text through OSC 52 when the terminal supports it
  and through the platform clipboard tool (`pbcopy`, `wl-copy`, `xclip`,
  `xsel`, or `clip`) when one is installed.
- `/attach <path>` explicitly stages an image; `/detach [name]` removes it.
- `/retry` creates a linked new attempt without deleting partial output.
- `/help` lists commands; `/quit` saves, cancels, restores the terminal, and
  exits. `/clear` starts a fresh session, clearing the conversation and model
  context. The previous session remains available in `/sessions`.
- Escape cancels a foreground turn and keeps the app open when idle. It closes
  overlays and command suggestions first, and rejects pending approvals.
  Ctrl-C cancels a foreground turn; pressing it twice exits. Enter confirms
  selector choices. All actions are keyboard reachable and capability labels
  contain text rather than color-only meaning.

## Attachments

Tsuki checks the file signature, byte size, dimensions/pixel count, regular
file type, and symlink policy before staging. Workspace files are stored as
relative references. An explicitly supplied external absolute path remains an
absolute reference and produces a visible warning. The file is checked again
and read only when the user submits.

PNG, JPEG, and GIF signatures are accepted by the Phase 1 request adapter.
Models that explicitly reject image input are blocked; unknown support produces
a warning and remains provider-dependent.

Inline previews: on terminals that advertise the kitty graphics protocol
(kitty, Ghostty, WezTerm) or iTerm2 inline images, PNG attachments and
Markdown images in assistant replies render inline in the transcript with a
caption underneath; every other terminal, and any non-PNG file, shows the
caption alone. Attachment previews may reference an explicit absolute path
because the user staged it; Markdown image references are confined to the
workspace by the same path policy as tools. Images are loaded once, kept in a
bounded registry, transmitted to the terminal once, and re-placed as the
transcript scrolls. While the transcript is moving, images are removed and
placed again only once it has rested for 150 ms, which keeps fast wheel
scrolling cheap for the terminal. Set `TSUKI_IMAGES=off` to disable inline
images entirely and keep the captions. Placement, scroll, resize, and cleanup
behavior has been exercised through a pseudo-terminal only; see
`manual-test.md` for what has and has not been observed in a real emulator.

## Rendering

Assistant replies render through he3's incremental Markdown engine while
they stream. Supported constructs: six heading levels, bold, italic, bold
italic, strikethrough, inline code, links and bare URLs (emitted as OSC 8
hyperlinks on terminals that support them), nested bullet, ordered, and task
lists, block quotes, rules, tables laid out as a whole with a header row,
alignment from the separator, and columns padded to their widest cell, images,
fenced code with syntax highlighting for common languages, and LaTeX math.
Inline `$...$` and display `$$` blocks render as Unicode text: Greek letters,
operators, relations, sub- and superscripts, vulgar fractions, radicals,
blackboard and script alphabets, accents, and simple matrices, with readable
ASCII fallbacks for everything else. Tool output tagged with a language is
highlighted the same way, and unified diffs keep their add and remove cues.

## Read-only tools and security boundary

The native Tsuki tool host performs a non-recursive directory list, bounded literal search,
and bounded regular UTF-8 file read. It rejects absolute tool paths, traversal,
symlinks, binary/special files, oversized input, and explicit secret-like paths
such as `.env`, private keys, and credential files. Searches skip version
control metadata and never invoke a shell.

This denylist is defense in depth, not a complete secret scanner. The user is
still responsible for selecting an appropriate workspace and provider. The
native tool loop does not write files, execute commands, mutate Git, install
packages, browse the network, or persist an “always allow” policy. The Codex
App Server provider is a separate managed runtime: it may execute inspection
commands, but Tsuki requests a read-only sandbox, denies local tool network
access, supplies a no-external-tools developer policy, and never implements or
accepts an approval escalation for it.
