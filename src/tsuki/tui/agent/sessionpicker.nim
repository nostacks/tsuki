## Searchable offline session picker and archive-confirmation presentation.

import std/[strutils, unicode]
import ../[event, graphemes, render, text]
import ../widgets/display
import theme

type
  SessionPickerEntry* = object
    id*: string
    title*: string
    workspace*: string
    updatedLabel*: string
    providerModel*: string
    interrupted*: bool
    corrupt*: bool
    diagnostic*: string

  SessionPickerState* = object
    query*: string
    selected*: int
    archiveArmed*: bool
    archiveId*: string
    renaming*: bool
    renameId*: string
    renameDraft*: string

  SessionPickerOutcomeKind* = enum
    sessionIgnored
    sessionChanged
    sessionResume
    sessionNew
    sessionRename
    sessionArchiveRequested
    sessionCancelled

  SessionPickerOutcome* = object
    kind*: SessionPickerOutcomeKind
    entry*: SessionPickerEntry
    title*: string

proc dropLastCluster(value: var string) =
  var clusters: seq[string]
  for cluster in value.graphemes: clusters.add cluster
  if clusters.len == 0: return
  value.setLen 0
  for index in 0 ..< clusters.len - 1: value.add clusters[index]

proc sessionFiltered(state: SessionPickerState,
    entries: openArray[SessionPickerEntry]): seq[int] =
  let query = state.query.toLowerAscii
  for index, entry in entries:
    if query.len == 0 or entry.title.toLowerAscii.contains(query) or
        entry.id.toLowerAscii.contains(query) or
        entry.workspace.toLowerAscii.contains(query) or
        entry.providerModel.toLowerAscii.contains(query):
      result.add index

proc sessionPickerEvent*(state: var SessionPickerState,
    entries: openArray[SessionPickerEntry],
        event: Event): SessionPickerOutcome =
  let visible = state.sessionFiltered(entries)
  if state.renaming:
    # Bracketed paste appends to the draft like typed characters.
    if event.kind == evPaste:
      state.renameDraft.add sanitizeText(event.text,
        plainTextPolicy(maxBytes = 4096))
      return SessionPickerOutcome(kind: sessionChanged)
  if event.kind != evKey: return
  if state.renaming:
    if event.key.isKey(kcEscape):
      state.renaming = false
      state.renameId.setLen 0
      state.renameDraft.setLen 0
      return SessionPickerOutcome(kind: sessionChanged)
    if event.key.isKey(kcBackspace) and state.renameDraft.len > 0:
      state.renameDraft.dropLastCluster()
      return SessionPickerOutcome(kind: sessionChanged)
    if event.key.isKey(kcEnter) and state.renameDraft.strip().len > 0:
      for entry in entries:
        if entry.id == state.renameId and not entry.corrupt:
          state.renaming = false
          state.renameId.setLen 0
          return SessionPickerOutcome(kind: sessionRename, entry: entry,
            title: state.renameDraft.strip())
      state.renaming = false
      state.renameId.setLen 0
      return SessionPickerOutcome(kind: sessionChanged)
    if event.key.code == kcChar and event.key.mods == {}:
      state.renameDraft.add event.key.char.toUTF8
      state.renameDraft = sanitizeText(state.renameDraft,
        plainTextPolicy(maxBytes = 4096))
      return SessionPickerOutcome(kind: sessionChanged)
    return SessionPickerOutcome(kind: sessionIgnored)
  if event.key.isKey(kcEscape):
    return SessionPickerOutcome(kind: sessionCancelled)
  if event.key.isKey(kcUp):
    state.selected = max(0, state.selected - 1)
    state.archiveArmed = false
    state.archiveId.setLen 0
    return SessionPickerOutcome(kind: sessionChanged)
  if event.key.isKey(kcDown):
    state.selected = min(max(0, visible.len - 1), state.selected + 1)
    state.archiveArmed = false
    state.archiveId.setLen 0
    return SessionPickerOutcome(kind: sessionChanged)
  if event.key.isKey(kcEnter) and visible.len > 0:
    let entry = entries[visible[min(state.selected, visible.len - 1)]]
    if not entry.corrupt:
      return SessionPickerOutcome(kind: sessionResume, entry: entry)
  if event.key.isChar('n', {modCtrl}):
    return SessionPickerOutcome(kind: sessionNew)
  if event.key.isChar('r', {modCtrl}) and visible.len > 0:
    let entry = entries[visible[min(state.selected, visible.len - 1)]]
    if entry.corrupt: return SessionPickerOutcome(kind: sessionIgnored)
    state.renaming = true
    state.renameId = entry.id
    state.renameDraft.setLen 0
    return SessionPickerOutcome(kind: sessionChanged)
  if event.key.isChar('a', {modCtrl}) and visible.len > 0:
    let entry = entries[visible[min(state.selected, visible.len - 1)]]
    if entry.corrupt: return SessionPickerOutcome(kind: sessionIgnored)
    if state.archiveArmed and state.archiveId == entry.id:
      state.archiveArmed = false
      state.archiveId.setLen 0
      return SessionPickerOutcome(kind: sessionArchiveRequested, entry: entry)
    state.archiveArmed = true
    state.archiveId = entry.id
    return SessionPickerOutcome(kind: sessionChanged)
  if event.key.isKey(kcBackspace) and state.query.len > 0:
    state.query.dropLastCluster()
    state.selected = 0
    state.archiveArmed = false
    state.archiveId.setLen 0
    return SessionPickerOutcome(kind: sessionChanged)
  if event.key.code == kcChar and event.key.mods == {}:
    state.query.add event.key.char.toUTF8
    state.query = sanitizeText(state.query, plainTextPolicy(maxBytes = 1024))
    state.selected = 0
    state.archiveArmed = false
    state.archiveId.setLen 0
    return SessionPickerOutcome(kind: sessionChanged)

proc sessionPicker*(frame: Frame, entries: openArray[SessionPickerEntry],
    state: SessionPickerState, colors = agentTheme()) =
  frame.write(0, 0, "Sessions", colors.base.accent)
  if frame.rect.height > 1:
    frame.write(0, 1, ("Search: " & state.query & "▌").truncateCells(
      frame.rect.width, true), colors.base.focus)
  let visible = state.sessionFiltered(entries)
  if visible.len == 0 and frame.rect.height > 3:
    frame.write(0, 3, "No sessions in this workspace.", colors.base.muted)
    frame.write(0, 4, "Press Ctrl-N to create one.", colors.base.muted)
  let selectedPosition = min(state.selected, visible.len - 1)
  let capacity = max(0, frame.rect.height - 5)
  let first = max(0, min(selectedPosition, visible.len - capacity))
  for row in 0 ..< min(capacity, visible.len - first):
    let position = first + row
    let entry = entries[visible[position]]
    let selected = position == selectedPosition
    let marker = if entry.corrupt: "corrupt"
      elif entry.interrupted: "interrupted" else: entry.updatedLabel
    let label = (if selected: "› " else: "  ") & entry.title & " · " &
      entry.providerModel & " · " & marker
    frame.write(0, 3 + row, label.truncateCells(frame.rect.width, true),
      if entry.corrupt: colors.base.error
      elif selected: colors.base.focus else: colors.base.text)
  if state.archiveArmed and frame.rect.height > 1:
    frame.write(0, frame.rect.height - 2,
      "Press Ctrl-A again to archive this session.".truncateCells(
        frame.rect.width, true), colors.base.error)
  elif state.renaming and frame.rect.height > 1:
    frame.write(0, frame.rect.height - 2,
      ("New title: " & state.renameDraft & "▌").truncateCells(
        frame.rect.width, true), colors.base.focus)
  elif visible.len > 0 and frame.rect.height > 1:
    let entry = entries[visible[min(state.selected, visible.len - 1)]]
    if entry.corrupt and entry.diagnostic.len > 0:
      frame.write(0, frame.rect.height - 2,
        sanitizeText(entry.diagnostic).truncateCells(frame.rect.width, true),
        colors.base.error)
  if frame.rect.height > 0:
    frame.write(0, frame.rect.height - 1,
      "enter resume · ctrl-n new · ctrl-r rename · ctrl-a archive · esc cancel"
      .truncateCells(frame.rect.width, true), colors.base.muted)
