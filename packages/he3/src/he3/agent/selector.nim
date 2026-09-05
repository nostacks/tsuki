## Searchable keyboard-first model selector and provider sign-in views.

import std/[strutils, unicode]
import ../[event, geometry, graphemes, render, text]
import ../widgets/[display, textarea]
import theme

type
  SelectorCapability* = enum
    selectorUnknown
    selectorUnsupported
    selectorSupported

  SelectorEntry* = object
    providerId*: string
    providerName*: string
    modelId*: string
    displayName*: string
    imageInput*: SelectorCapability
    tools*: SelectorCapability
    reasoningEfforts*: seq[string]
    defaultReasoningEffort*: string
    available*: bool
    reason*: string

  SelectorState* = object
    query*: string
    selected*: int
    selectedProviderId*: string
    selectedModelId*: string
    reasoningProviderId*: string
    reasoningModelId*: string
    reasoningEffort*: string
    reasoningStep*: bool ## Model identity stays fixed until this step finishes.
    cancelled*: bool
    confirmed*: bool

  SelectorOutcomeKind* = enum
    selectorIgnored
    selectorChanged
    selectorConfirmed
    selectorCancelled

  SelectorOutcome* = object
    kind*: SelectorOutcomeKind
    entry*: SelectorEntry
    reasoningEffort*: string

func selectedEffort(state: SelectorState, entry: SelectorEntry): string =
  if state.reasoningProviderId == entry.providerId and
      state.reasoningModelId == entry.modelId and
      state.reasoningEffort in entry.reasoningEfforts:
    state.reasoningEffort
  else: ""

func capabilityLabel(label: string, value: SelectorCapability): string =
  case value
  of selectorSupported: label
  of selectorUnsupported: "no " & label
  of selectorUnknown: label & " ?"

proc dropLastCluster(value: var string) =
  var clusters: seq[string]
  for cluster in value.graphemes: clusters.add cluster
  if clusters.len == 0: return
  value.setLen 0
  for index in 0 ..< clusters.len - 1: value.add clusters[index]

proc filtered*(state: SelectorState,
    entries: openArray[SelectorEntry]): seq[int] =
  let query = state.query.toLowerAscii
  for index, entry in entries:
    if query.len == 0 or entry.providerName.toLowerAscii.contains(query) or
        entry.displayName.toLowerAscii.contains(query) or
        entry.modelId.toLowerAscii.contains(query):
      result.add index

func selectionPosition(state: SelectorState,
    entries: openArray[SelectorEntry], visible: openArray[int]): int =
  if state.selectedProviderId.len > 0 or state.selectedModelId.len > 0:
    for position, index in visible:
      if entries[index].providerId == state.selectedProviderId and
          entries[index].modelId == state.selectedModelId:
        return position
  min(max(0, state.selected), max(0, visible.len - 1))

proc remember(state: var SelectorState, entries: openArray[SelectorEntry],
    visible: openArray[int]) =
  if visible.len == 0:
    state.selected = 0
    return
  state.selected = state.selectionPosition(entries, visible)
  let entry = entries[visible[state.selected]]
  state.selectedProviderId = entry.providerId
  state.selectedModelId = entry.modelId

proc selectorEvent*(state: var SelectorState,
    entries: openArray[SelectorEntry], event: Event): SelectorOutcome =
  if state.reasoningStep:
    if event.kind != evKey: return
    if event.key.isKey(kcEscape):
      state.reasoningStep = false
      return SelectorOutcome(kind: selectorChanged)
    var entryIndex = -1
    for index, entry in entries:
      if entry.providerId == state.selectedProviderId and
          entry.modelId == state.selectedModelId and entry.available:
        entryIndex = index
        break
    # Discovery may refresh while the dialog is open. Never confirm a
    # different model just because it occupies the same list position.
    if entryIndex < 0:
      state.reasoningStep = false
      return SelectorOutcome(kind: selectorChanged)
    let entry = entries[entryIndex]
    let choices = @[""] & entry.reasoningEfforts
    let current = choices.find(state.selectedEffort(entry))
    if event.key.isKey(kcUp) or event.key.isKey(kcDown):
      let step = if event.key.isKey(kcDown): 1 else: -1
      let next = clamp(current + step, 0, choices.high)
      state.reasoningProviderId = entry.providerId
      state.reasoningModelId = entry.modelId
      state.reasoningEffort = choices[next]
      return SelectorOutcome(kind: selectorChanged)
    if event.key.isKey(kcEnter):
      state.confirmed = true
      state.reasoningStep = false
      return SelectorOutcome(kind: selectorConfirmed, entry: entry,
        reasoningEffort: state.selectedEffort(entry))
    return
  var visible = state.filtered(entries)
  state.remember(entries, visible)
  if event.kind != evKey: return
  if event.key.isKey(kcEscape):
    state.cancelled = true
    return SelectorOutcome(kind: selectorCancelled)
  if event.key.isKey(kcUp):
    state.selected = max(0, state.selected - 1)
    state.selectedProviderId = ""
    state.selectedModelId = ""
    state.remember(entries, visible)
    return SelectorOutcome(kind: selectorChanged)
  if event.key.isKey(kcDown):
    state.selected = min(max(0, visible.len - 1), state.selected + 1)
    state.selectedProviderId = ""
    state.selectedModelId = ""
    state.remember(entries, visible)
    return SelectorOutcome(kind: selectorChanged)
  if event.key.isKey(kcEnter):
    if visible.len > 0:
      let entry = entries[visible[min(state.selected, visible.len - 1)]]
      if entry.available:
        state.reasoningStep = true
        return SelectorOutcome(kind: selectorChanged)
    return SelectorOutcome(kind: selectorIgnored)
  if event.key.isKey(kcBackspace):
    if state.query.len > 0:
      state.query.dropLastCluster()
      visible = state.filtered(entries)
      state.remember(entries, visible)
      return SelectorOutcome(kind: selectorChanged)
  if event.key.code == kcChar and event.key.mods == {}:
    state.query.add event.key.char.toUTF8
    state.query = sanitizeText(state.query, plainTextPolicy(maxBytes = 1024))
    visible = state.filtered(entries)
    state.remember(entries, visible)
    return SelectorOutcome(kind: selectorChanged)

type
  ProviderAuthKind* = enum
    providerAuthDevice
    providerAuthApiKey

  ProviderAuthStatus* = enum
    providerAuthUnknown
    providerAuthReady
    providerAuthMissing

  ProviderAuthEntry* = object
    providerId*: string
    providerName*: string
    kind*: ProviderAuthKind
    status*: ProviderAuthStatus
    credentialEnv*: string
    detail*: string

  ProviderAuthOutcomeKind* = enum
    paIgnored
    paChanged
    paDeviceLogin
    paDeviceLogout
    paKeySubmitted
    paCancelled

  ProviderAuthOutcome* = object
    kind*: ProviderAuthOutcomeKind
    entry*: ProviderAuthEntry
    apiKey*: string

  ProviderAuthUi* = object
    query*: string
    selected*: int
    selectedProviderId*: string
    keyEntry*: bool
    keyFor*: string
    keyEditor*: TextareaState
    pending*: bool
    error*: string

func authVisible(state: ProviderAuthUi,
    entries: openArray[ProviderAuthEntry]): seq[int] =
  let query = state.query.toLowerAscii
  for index, entry in entries:
    if query.len == 0 or entry.providerName.toLowerAscii.contains(query):
      result.add index

func authSelection(state: ProviderAuthUi,
    entries: openArray[ProviderAuthEntry], visible: openArray[int]): int =
  if state.selectedProviderId.len > 0:
    for position, index in visible:
      if entries[index].providerId == state.selectedProviderId:
        return position
  min(max(0, state.selected), max(0, visible.len - 1))

func authRemember(state: var ProviderAuthUi,
    entries: openArray[ProviderAuthEntry], visible: openArray[int]) =
  if visible.len == 0:
    state.selected = 0
    return
  state.selected = state.authSelection(entries, visible)
  state.selectedProviderId = entries[visible[state.selected]].providerId

proc providerAuthEvent*(state: var ProviderAuthUi,
    entries: openArray[ProviderAuthEntry], event: Event): ProviderAuthOutcome =
  ## Handles the provider dialog: provider list, search, device sign-in and
  ## sign-out, and the masked API key editor.
  if state.keyEntry:
    # Bracketed paste arrives as evPaste and must reach the editor directly.
    if event.kind == evPaste:
      discard state.keyEditor.textareaEvent(event, submitOnEnter = false)
      return ProviderAuthOutcome(kind: paChanged)
    if event.kind != evKey: return ProviderAuthOutcome(kind: paIgnored)
    if event.key.isKey(kcEscape):
      state.keyEntry = false
      state.error = ""
      state.keyEditor = initTextareaState()
      return ProviderAuthOutcome(kind: paChanged)
    if event.key.isKey(kcEnter):
      let key = state.keyEditor.content.strip()
      if key.len == 0:
        state.error = "Paste or type a key first."
        return ProviderAuthOutcome(kind: paChanged)
      state.keyEntry = false
      state.error = ""
      state.keyEditor = initTextareaState()
      for entry in entries:
        if entry.providerId == state.selectedProviderId:
          state.pending = true
          return ProviderAuthOutcome(kind: paKeySubmitted, entry: entry,
            apiKey: key)
      return ProviderAuthOutcome(kind: paChanged)
    if event.key.isKey(kcTab): return ProviderAuthOutcome(kind: paIgnored)
    discard state.keyEditor.textareaEvent(event, submitOnEnter = false)
    return ProviderAuthOutcome(kind: paChanged)
  if event.kind != evKey: return ProviderAuthOutcome(kind: paIgnored)
  var visible = state.authVisible(entries)
  state.authRemember(entries, visible)
  if event.key.isKey(kcEscape):
    return ProviderAuthOutcome(kind: paCancelled)
  if event.key.isKey(kcUp):
    state.selected = max(0, state.selected - 1)
    state.selectedProviderId = ""
    state.authRemember(entries, visible)
    return ProviderAuthOutcome(kind: paChanged)
  if event.key.isKey(kcDown):
    state.selected = min(max(0, visible.len - 1), state.selected + 1)
    state.selectedProviderId = ""
    state.authRemember(entries, visible)
    return ProviderAuthOutcome(kind: paChanged)
  if event.key.isKey(kcEnter):
    if visible.len > 0:
      let entry = entries[visible[min(state.selected, visible.len - 1)]]
      state.selectedProviderId = entry.providerId
      case entry.kind
      of providerAuthDevice:
        return ProviderAuthOutcome(kind: paDeviceLogin, entry: entry)
      of providerAuthApiKey:
        state.keyEntry = true
        state.keyFor = entry.providerId
        state.error = ""
        state.keyEditor = initTextareaState()
        return ProviderAuthOutcome(kind: paChanged)
    return ProviderAuthOutcome(kind: paIgnored)
  if event.key.isKey(kcDelete):
    if visible.len > 0:
      let entry = entries[visible[min(state.selected, visible.len - 1)]]
      if entry.kind == providerAuthDevice:
        state.selectedProviderId = entry.providerId
        return ProviderAuthOutcome(kind: paDeviceLogout, entry: entry)
    return ProviderAuthOutcome(kind: paIgnored)
  if event.key.isKey(kcBackspace):
    if state.query.len > 0:
      state.query.dropLastCluster()
      visible = state.authVisible(entries)
      state.authRemember(entries, visible)
      return ProviderAuthOutcome(kind: paChanged)
  if event.key.code == kcChar and event.key.mods == {}:
    state.query.add event.key.char.toUTF8
    state.query = sanitizeText(state.query, plainTextPolicy(maxBytes = 1024))
    visible = state.authVisible(entries)
    state.authRemember(entries, visible)
    return ProviderAuthOutcome(kind: paChanged)
  ProviderAuthOutcome(kind: paIgnored)

proc providerAuthPicker*(frame: Frame, entries: openArray[ProviderAuthEntry],
    state: var ProviderAuthUi, colors = agentTheme()) =
  ## Draws the provider dialog: one row per provider with its auth actions,
  ## or the masked API key editor while one is being entered.
  if state.keyEntry:
    var providerName = state.keyFor
    for entry in entries:
      if entry.providerId == state.keyFor:
        providerName = entry.providerName
        break
    frame.write(0, 0, "API key for " & providerName, colors.base.accent)
    if frame.rect.height > 2:
      frame.write(0, 1, ("Enter saves the key for future sessions. " &
        "Esc keeps the current one.").truncateCells(frame.rect.width, true),
        colors.base.muted)
    if frame.rect.height > 3:
      let editor = frame.sub(rect(0, 3, frame.rect.width, 1))
      editor.textarea(state.keyEditor, focused = true, masked = true,
        placeholder = "paste or type the API key", colors = colors.base)
    if state.error.len > 0 and frame.rect.height > 5:
      frame.write(0, 5, sanitizeText(state.error).truncateCells(
        frame.rect.width, true), colors.base.error)
    if frame.rect.height > 0:
      frame.write(0, frame.rect.height - 1,
        "enter save · esc cancel".truncateCells(frame.rect.width, true),
        colors.base.muted)
    return
  frame.write(0, 0, "Providers", colors.base.accent)
  if frame.rect.height > 1:
    frame.write(0, 1, ("Search: " & state.query & "▌").truncateCells(
      frame.rect.width, true), colors.base.focus)
  if state.pending and frame.rect.height > 2:
    frame.write(0, 2, "Checking the key…".truncateCells(frame.rect.width,
      true), colors.base.muted)
  let startRow = 3
  let visible = state.authVisible(entries)
  let selectedPosition = state.authSelection(entries, visible)
  if visible.len == 0 and startRow < frame.rect.height:
    frame.write(0, startRow, "No providers match this search.",
      colors.base.muted)
    return
  let capacity = max(0, frame.rect.height - startRow - 1)
  let first = max(0, min(selectedPosition, visible.len - capacity))
  for row in 0 ..< min(capacity, visible.len - first):
    let position = first + row
    let entry = entries[visible[position]]
    let selected = position == selectedPosition
    let status = case entry.status
      of providerAuthReady: "signed in"
      of providerAuthMissing: "no key"
      of providerAuthUnknown: ""
    let action = case entry.kind
      of providerAuthDevice: "enter to sign in · del to sign out"
      of providerAuthApiKey:
        if entry.status == providerAuthReady: "enter to replace key"
        else: "enter to add API key"
    var label = (if selected: "› " else: "  ") & entry.providerName
    if status.len > 0: label.add " · " & status
    label.add " · " & action
    if selected and entry.detail.len > 0:
      label.add " · " & sanitizeText(entry.detail)
    elif not selected and entry.kind == providerAuthApiKey and
        entry.credentialEnv.len > 0 and entry.status == providerAuthMissing:
      label.add " (or set " & entry.credentialEnv & ")"
    frame.write(0, startRow + row, label.truncateCells(frame.rect.width, true),
      if selected: colors.base.focus else: colors.base.text)
  if frame.rect.height > 0:
    frame.write(0, frame.rect.height - 1,
      ("↑↓ move · enter sign in or add key · del sign out · " &
        "esc cancel").truncateCells(frame.rect.width, true),
      colors.base.muted)

proc modelSelector*(frame: Frame, entries: openArray[SelectorEntry],
    state: SelectorState, loading = false, error = "",
    colors = agentTheme()) =
  ## Draws provider identity and non-color capability labels in a bounded list.
  if state.reasoningStep:
    frame.write(0, 0, "Select reasoning · 2/2", colors.base.accent)
    for entry in entries:
      if entry.providerId != state.selectedProviderId or
          entry.modelId != state.selectedModelId: continue
      frame.write(0, 1, (entry.providerName & " / " & entry.displayName)
        .truncateCells(frame.rect.width, true), colors.base.text)
      let choices = @[""] & entry.reasoningEfforts
      let selected = choices.find(state.selectedEffort(entry))
      let capacity = max(0, frame.rect.height - 4)
      let first = max(0, min(selected, choices.len - capacity))
      for row in 0 ..< min(capacity, choices.len - first):
        let index = first + row
        let label = if index > 0: choices[index]
          else: "default" & (if entry.defaultReasoningEffort.len > 0:
            " (" & entry.defaultReasoningEffort & ")" else: "")
        let prefix = if index == selected: "› " else: "  "
        frame.write(0, row + 3, (prefix & label).truncateCells(
          frame.rect.width, true),
          if index == selected: colors.base.focus else: colors.base.text)
      if entry.reasoningEfforts.len == 0:
        frame.write(0, 2, "Reasoning: not configurable".truncateCells(
          frame.rect.width, true), colors.base.muted)
      break
    if frame.rect.height > 0:
      frame.write(0, frame.rect.height - 1,
        "↑↓ move · enter apply · esc back".truncateCells(
          frame.rect.width, true), colors.base.muted)
    return
  frame.write(0, 0, "Select provider and model · 1/2", colors.base.accent)
  if frame.rect.height > 1:
    frame.write(0, 1, ("Search: " & state.query & "▌").truncateCells(
      frame.rect.width, true), colors.base.focus)
  if error.len > 0 and frame.rect.height > 2:
    frame.write(0, 2, sanitizeText(error).truncateCells(frame.rect.width,
      true), colors.base.error)
  let startRow = if error.len > 0: 4 else: 3
  let visible = state.filtered(entries)
  let selectedPosition = state.selectionPosition(entries, visible)
  if visible.len == 0 and startRow < frame.rect.height:
    frame.write(0, startRow, if loading: "Loading models…"
      else: "No configured models match this search.", colors.base.muted)
    return
  let capacity = max(0, frame.rect.height - startRow - 1)
  let first = max(0, min(selectedPosition, visible.len - capacity))
  for row in 0 ..< min(capacity, visible.len - first):
    let position = first + row
    let entry = entries[visible[position]]
    let selected = position == selectedPosition
    let prefix = if selected: "› " else: "  "
    let unavailable = if entry.available: "" else: " · unavailable"
    let reason = if selected and not entry.available and entry.reason.len > 0:
      " · " & sanitizeText(entry.reason) else: ""
    let label = prefix & entry.providerName & " / " & entry.displayName &
      " · " & capabilityLabel("image", entry.imageInput) & " · " &
      capabilityLabel("tools", entry.tools) & unavailable & reason
    frame.write(0, startRow + row, label.truncateCells(frame.rect.width, true),
      if selected: colors.base.focus else: colors.base.text)
  if frame.rect.height > 0:
    frame.write(0, frame.rect.height - 1,
      "↑↓ move · enter next · esc cancel".truncateCells(
        frame.rect.width, true), colors.base.muted)
