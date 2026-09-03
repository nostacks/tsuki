## Multiline prompt composer with history, slash-command completion, and
## host-supplied completion data.

import std/[strutils, unicode]
import ../[event, geometry, graphemes, render, text]
import ../widgets/textarea
import theme

type
  SlashCommand* = object
    name*: string
    usage*: string
    description*: string
    recommended*: bool

  PromptResultKind* = enum
    promptIgnored
    promptChanged
    promptSubmit
    promptCancel
    promptCopy

  PromptResult* = object
    kind*: PromptResultKind
    text*: string

  PromptState* = object
    editor*: TextareaState
    completions*: seq[string]
    commands*: seq[SlashCommand]
    completionIndex*: int
    completionDismissed*: bool
    queued*: seq[string]
    queueHead: int

proc setCompletions*(state: var PromptState, values: openArray[string]) =
  ## Replaces host-supplied slash/file/symbol completions with safe labels.
  state.completions.setLen 0
  for value in values: state.completions.add sanitizeText(value)
  state.completionIndex = 0

proc setCommands*(state: var PromptState, values: openArray[SlashCommand]) =
  ## Replaces slash-command metadata used by completion and its popover.
  state.commands.setLen 0
  state.completions.setLen 0
  for value in values:
    let name = sanitizeText(value.name)
    if name.len == 0: continue
    state.commands.add SlashCommand(name: name,
      usage: sanitizeText(value.usage),
      description: sanitizeText(value.description),
      recommended: value.recommended)
    state.completions.add name
  state.completionIndex = 0
  state.completionDismissed = false

proc queuePrompt*(state: var PromptState, value: string,
    maxQueued = 32): bool =
  ## Queues a bounded prompt while a turn is active.
  if state.queued.len - state.queueHead >= max(1, maxQueued): return false
  state.queued.add sanitizeText(value)
  true

func pendingPromptCount*(state: PromptState): int =
  ## Number of prompts waiting behind the active foreground turn.
  max(0, state.queued.len - state.queueHead)

proc popQueued*(state: var PromptState, value: var string): bool =
  ## Pops the oldest queued prompt. Queue sizes are deliberately small.
  if state.queueHead >= state.queued.len: return false
  value = move(state.queued[state.queueHead])
  inc state.queueHead
  if state.queueHead == state.queued.len:
    state.queued.setLen 0
    state.queueHead = 0
  elif state.queueHead >= 32 and state.queueHead * 2 >= state.queued.len:
    let remaining = state.queued.len - state.queueHead
    for index in 0 ..< remaining:
      state.queued[index] = move(state.queued[state.queueHead + index])
    state.queued.setLen remaining
    state.queueHead = 0
  true

func slashWord*(state: PromptState): tuple[word: string, start: int] =
  ## Returns the `/word` under the cursor and its cluster index. The word
  ## starts at the nearest `/` and ends at the cursor or a separator.
  result.start = -1
  var index = 0
  for cluster in state.editor.content.graphemes:
    if index >= state.editor.cursor: break
    if cluster == "/": result.start = index
    elif cluster == " " or cluster == "\n": result.start = -1
    inc index
  if result.start >= 0:
    index = 0
    for cluster in state.editor.content.graphemes:
      if index >= state.editor.cursor: break
      if index >= result.start: result.word.add cluster
      inc index

func matchingCompletions(state: PromptState, word: string): seq[string] =
  for candidate in state.completions:
    if candidate.startsWith(word): result.add candidate

func slashSuggestions*(state: PromptState): seq[SlashCommand] =
  ## Returns bounded command metadata for the leading slash word.
  let (word, start) = state.slashWord
  if start != 0 or word.len == 0 or state.completionDismissed: return
  for command in state.commands:
    if command.name.startsWith(word) and
        (word != "/" or command.recommended):
      result.add command

func suggestionsVisible*(state: PromptState): bool =
  state.slashSuggestions.len > 0

proc dismissSuggestions*(state: var PromptState): bool =
  ## Closes the current popover without changing or submitting the draft.
  if not state.suggestionsVisible: return false
  state.completionDismissed = true
  true

func selectedSuggestion*(state: PromptState): SlashCommand =
  let matches = state.slashSuggestions
  if matches.len > 0:
    result = matches[clamp(state.completionIndex, 0, matches.high)]

func nextCompletion*(state: PromptState): string =
  ## The candidate Tab would insert right now, or "" when none applies.
  let (word, start) = state.slashWord
  if start < 0: return ""
  let suggestions = state.slashSuggestions
  if suggestions.len > 0:
    return suggestions[clamp(state.completionIndex, 0,
      suggestions.high)].name
  let matches = state.matchingCompletions(word)
  if matches.len > 0: matches[0] else: ""

proc insertCompletion(state: var PromptState): bool =
  ## Replaces the `/word` under the cursor with the next matching completion.
  let (word, start) = state.slashWord
  let candidate = state.nextCompletion
  if start < 0 or candidate.len == 0: return false
  var clusters: seq[string]
  for cluster in state.editor.content.graphemes: clusters.add cluster
  var rebuilt = ""
  for index in 0 ..< start: rebuilt.add clusters[index]
  rebuilt.add candidate & " "
  for index in state.editor.cursor ..< clusters.len:
    rebuilt.add clusters[index]
  state.editor.content = rebuilt
  var cursor = start
  for unused in (candidate & " ").graphemes: inc cursor
  state.editor.cursor = cursor
  state.editor.selectionAnchor = -1
  let matches = state.matchingCompletions(word)
  state.completionIndex = max(0, matches.find(candidate))
  state.completionDismissed = false
  true

proc promptEvent*(state: var PromptState, event: Event): PromptResult =
  ## Handles multiline editing. Enter submits; Shift-Enter inserts a newline;
  ## Tab completes the `/word` under the cursor.
  if event.isCancel and state.dismissSuggestions():
    return PromptResult(kind: promptChanged)
  if event.isCancel:
    return PromptResult(kind: promptCancel)
  if event.kind == evKey and event.key.mods == {} and
      event.key.code in {kcUp, kcDown} and state.suggestionsVisible:
    let count = state.slashSuggestions.len
    if event.key.code == kcUp:
      state.completionIndex = (state.completionIndex - 1 + count) mod count
    else:
      state.completionIndex = (state.completionIndex + 1) mod count
    return PromptResult(kind: promptChanged)
  if event.kind == evKey and event.key.isKey(kcTab):
    if state.insertCompletion():
      return PromptResult(kind: promptChanged)
    return PromptResult(kind: promptIgnored)
  if event.kind == evKey and modCtrl in event.key.mods and
      event.key.code in {kcUp, kcDown} and state.editor.history.len > 0:
    if state.editor.historyIndex < 0:
      state.editor.historyIndex = state.editor.history.len
    if event.key.code == kcUp:
      state.editor.historyIndex = max(0, state.editor.historyIndex - 1)
    else:
      state.editor.historyIndex = min(state.editor.history.len,
        state.editor.historyIndex + 1)
    state.editor.content = if state.editor.historyIndex <
        state.editor.history.len:
      state.editor.history[state.editor.historyIndex] else: ""
    state.editor.cursor = 0
    for unused in state.editor.content.graphemes:
      inc state.editor.cursor
    state.editor.selectionAnchor = -1
    return PromptResult(kind: promptChanged)
  if event.kind == evKey and event.key.isKey(kcEnter) and
      state.suggestionsVisible:
    let (word, unused) = state.slashWord
    discard unused
    let selected = state.selectedSuggestion
    if selected.name.len > 0 and selected.name != word and
        state.insertCompletion():
      return PromptResult(kind: promptChanged)
  case state.editor.textareaEvent(event, submitOnEnter = true)
  of taSubmit:
    let submitted = state.editor.content
    if submitted.len == 0: return PromptResult(kind: promptIgnored)
    var history = move(state.editor.history)
    history.add submitted
    let maxUndo = state.editor.maxUndo
    state.editor = initTextareaState(maxUndo = maxUndo)
    state.editor.history = move(history)
    state.editor.historyIndex = state.editor.history.len
    PromptResult(kind: promptSubmit, text: submitted)
  of taCopy:
    PromptResult(kind: promptCopy, text: state.editor.selectedText)
  of taChanged:
    state.completionDismissed = false
    let count = state.slashSuggestions.len
    if count == 0: state.completionIndex = 0
    else: state.completionIndex = clamp(state.completionIndex, 0, count - 1)
    PromptResult(kind: promptChanged)
  of taMoved:
    PromptResult(kind: promptChanged)
  of taIgnored:
    PromptResult(kind: promptIgnored)

proc prompt*(frame: Frame, state: var PromptState, focused = true,
    placeholder = "type a coding request", colors = agentTheme()) =
  ## Draws the composer: a violet leading bar, the multiline editor with a
  ## visible block cursor. Command suggestions are drawn by the shell popover.
  if frame.rect.isEmpty: return
  frame.fill(rect(0, 0, 1, frame.rect.height), Rune(0x258C),
    colors.base.accent)
  let editor = frame.sub(rect(2, 0, max(1, frame.rect.width - 2),
    frame.rect.height))
  editor.textarea(state.editor, focused = focused, placeholder = placeholder,
    colors = colors.base)
