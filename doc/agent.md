# Tsuki agent guide

Tsuki starts in the current directory, resumes the most recently updated
session for that workspace, and opens promptly even when its provider is
offline. Use `tsuki --help` for CLI options. Without credentials, run
`/provider` to sign in with ChatGPT or paste an API key for the session.

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
and make sure `codex` is on `PATH`, then run `/login`. Tsuki asks the supported
Codex App Server for a device URL and one-time code; if device auth is not
available, it falls back to the managed browser flow. Complete the flow in a
browser while Tsuki waits. `/logout` signs out through the same managed API.

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

## Commands and keyboard use

- Typing `/` opens a recommended-command popover. Up/Down moves, Tab or Enter
  completes the selected command, and Escape closes the popover without
  exiting. Submitting an exact command runs it.
- `/new`, `/sessions`, `/resume <id>`, `/rename <title>` manage sessions.
- `/provider` opens the sign-in dialog: ChatGPT device sign-in, or a masked
  in-memory API key field for key-based providers. `/model` is the only place
  models are chosen. Ctrl-O opens the model dialog too.
- `/login` and `/logout` manage the ChatGPT Codex subscription account.
- `/attach <path>` explicitly stages an image; `/detach [name]` removes it.
- `/retry` creates a linked new attempt without deleting partial output.
- `/help` lists commands; `/quit` saves, cancels, restores the terminal, and
  exits. `/clear` is deliberately non-destructive and points to `/new`.
- Ctrl-C cancels a foreground turn. Enter confirms selector choices; Escape
  closes overlays. All actions are keyboard reachable and capability labels
  contain text rather than color-only meaning.

## Attachments

Tsuki checks the file signature, byte size, dimensions/pixel count, regular
file type, and symlink policy before staging. Workspace files are stored as
relative references. An explicitly supplied external absolute path remains an
absolute reference and produces a visible warning. The file is checked again
and read only when the user submits.

PNG, JPEG, and GIF signatures are accepted by the Phase 1 request adapter.
Models that explicitly reject image input are blocked; unknown support produces
a warning and remains provider-dependent. Headless, monochrome, Sixel, iTerm,
and unverified Kitty sessions use a meaningful text attachment card. A bounded
Kitty PNG encoder exists, but the executable does not claim inline preview
until placement/scroll/resize/suspend/cleanup behavior has manual evidence in
`manual-test.md`.

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
