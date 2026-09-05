## Atomic per-user file session persistence and corruption recovery.

import std/[algorithm, os, sets, strutils, sysrand]
import ../[boundedio, config, limits, types]
import schema

when defined(windows):
  import std/winlean
else:
  import std/posix

type
  SessionDiagnostic* = object
    path*: string
    message*: string

  SessionListResult* = object
    sessions*: seq[SessionHeader]
    diagnostics*: seq[SessionDiagnostic]

  SessionStore* = object
    paths*: PlatformPaths
    limits*: AgentLimits

proc initSessionStore*(paths = platformPaths(),
    limits = phase1Limits()): SessionStore =
  SessionStore(paths: paths, limits: limits)

proc generateSessionId*(): SessionId =
  ## Uses OS entropy; IDs are opaque, stable, and filename-safe.
  let bytes = urandom(16)
  var value = "s-"
  const hex = "0123456789abcdef"
  for item in bytes:
    value.add hex[int(item shr 4)]
    value.add hex[int(item and 0x0f)]
  SessionId(value)

func validSessionId(id: SessionId): bool =
  let value = $id
  value.len in 3 .. 128 and value.safeId(128) == value and
    '/' notin value and '\\' notin value and value notin [".", ".."]

proc ensureDirectories(store: SessionStore) =
  createDir(store.paths.dataDir)
  createDir(store.paths.sessionsDir)
  createDir(store.paths.archivedDir)
  createDir(store.paths.cacheDir)

func sessionPath(store: SessionStore, id: SessionId,
    archived = false): string =
  let directory = if archived: store.paths.archivedDir
    else: store.paths.sessionsDir
  directory / ($id & ".json")

proc syncToDisk(file: File) =
  ## The rename is only atomic against a crash once the new bytes are stable.
  when defined(windows):
    discard flushFileBuffers(Handle(getOsFileHandle(file)))
  else:
    discard fsync(cint(getFileHandle(file)))

proc save*(store: SessionStore, session: Session): string =
  ## Writes and syncs a sibling temporary document before one atomic rename.
  if not session.id.validSessionId: return "invalid session ID"
  let encoded = session.encodeSession
  if encoded.len > store.limits.maxSessionBytes:
    return "session exceeds the configured size bound"
  try:
    store.ensureDirectories()
    let target = store.sessionPath(session.id, session.archived)
    let temporary = target & ".tmp-" & $generateSessionId()
    var file: File
    if not open(file, temporary, fmWrite):
      return "could not open session temporary file"
    var open = true
    try:
      file.write(encoded)
      file.flushFile()
      file.syncToDisk()
      file.close()
      open = false
      moveFile(temporary, target)
    except CatchableError:
      if open: file.close()
      if fileExists(temporary): removeFile(temporary)
      raise
  except CatchableError as failure:
    result = "could not save session: " & failure.msg.safeDisplay(1024)

proc load*(store: SessionStore, id: SessionId,
    archived = false): SessionDecodeResult =
  if not id.validSessionId:
    return SessionDecodeResult(error: "invalid session ID")
  let path = store.sessionPath(id, archived)
  try:
    if not fileExists(path):
      return SessionDecodeResult(error: "session does not exist: " & path)
    let source = readBoundedRegularFile(path, store.limits.maxSessionBytes)
    if source.error.len > 0:
      return SessionDecodeResult(error: source.error & ": " & path)
    result = decodeSession(source.data, store.limits)
    if result.error.len > 0: result.error.add " (" & path & ")"
  except CatchableError as failure:
    result.error = "could not load session: " &
      failure.msg.safeDisplay(1024) & " (" & path & ")"

proc loadHeader*(store: SessionStore, id: SessionId,
    archived = false): SessionHeaderResult =
  ## Reads one session's listing fields without decoding its messages.
  if not id.validSessionId:
    return SessionHeaderResult(error: "invalid session ID")
  let path = store.sessionPath(id, archived)
  try:
    if not fileExists(path):
      return SessionHeaderResult(error: "session does not exist: " & path)
    let source = readBoundedRegularFile(path, store.limits.maxSessionBytes)
    if source.error.len > 0:
      return SessionHeaderResult(error: source.error & ": " & path)
    result = decodeSessionHeader(source.data, store.limits)
    if result.error.len > 0: result.error.add " (" & path & ")"
  except CatchableError as failure:
    result.error = "could not load session: " &
      failure.msg.safeDisplay(1024) & " (" & path & ")"

proc scanDirectory(store: SessionStore, directory: string, archived: bool,
    workspaceRoot: string, seen: var HashSet[string],
    output: var SessionListResult) =
  if not dirExists(directory): return
  var visited = 0
  for kind, path in walkDir(directory, relative = false):
    if kind != pcFile or not path.endsWith(".json"): continue
    inc visited
    if visited > 10_000:
      output.diagnostics.add SessionDiagnostic(path: directory,
        message: "session scan stopped at the 10,000-file bound")
      break
    try:
      let source = readBoundedRegularFile(path, store.limits.maxSessionBytes)
      if source.error.len > 0:
        output.diagnostics.add SessionDiagnostic(path: path,
          message: source.error)
        continue
      let decoded = decodeSessionHeader(source.data, store.limits)
      if decoded.error.len > 0:
        output.diagnostics.add SessionDiagnostic(path: path,
          message: decoded.error.safeDisplay(1024))
      elif splitFile(path).name != $decoded.header.id:
        output.diagnostics.add SessionDiagnostic(path: path,
          message: "session ID does not match its filename")
      elif $decoded.header.id in seen:
        output.diagnostics.add SessionDiagnostic(path: path,
          message: "duplicate session ID")
      elif workspaceRoot.len == 0 or
          decoded.header.workspaceRoot == normalizedPath(workspaceRoot):
        seen.incl $decoded.header.id
        var item = decoded.header
        item.archived = archived
        output.sessions.add item
    except CatchableError as failure:
      output.diagnostics.add SessionDiagnostic(path: path,
        message: failure.msg.safeDisplay(1024))

proc list*(store: SessionStore, workspaceRoot = "",
    includeArchived = false): SessionListResult =
  ## Rebuilds the index from independent documents; corruption stays local.
  ## Only document headers are decoded, so the cost is bounded by file
  ## size, not by transcript structure.
  var seen = initHashSet[string]()
  store.scanDirectory(store.paths.sessionsDir, false, workspaceRoot, seen,
    result)
  if includeArchived:
    store.scanDirectory(store.paths.archivedDir, true, workspaceRoot, seen,
      result)
  result.sessions.sort(proc (a, b: SessionHeader): int =
    result = cmp(b.updatedAtMs, a.updatedAtMs)
    if result == 0: result = cmp($a.id, $b.id))
  result.diagnostics.sort(proc (a, b: SessionDiagnostic): int =
    cmp(a.path, b.path))

proc rename*(store: SessionStore, id: SessionId, title: string): string =
  var loaded = store.load(id)
  if loaded.error.len > 0: return loaded.error
  loaded.session.title = title.safeDisplay(4096).replace("\n", " ").strip()
  if loaded.session.title.len == 0: return "session title must not be empty"
  loaded.session.updatedAtMs = unixTimeMs()
  store.save(loaded.session)

proc archive*(store: SessionStore, id: SessionId): string =
  ## Moves a valid active session to recoverable archived storage.
  var loaded = store.load(id)
  if loaded.error.len > 0: return loaded.error
  try:
    store.ensureDirectories()
    loaded.session.archived = true
    loaded.session.updatedAtMs = unixTimeMs()
    let saveError = store.save(loaded.session)
    if saveError.len > 0: return saveError
    removeFile(store.sessionPath(id, false))
  except CatchableError as failure:
    result = "could not archive session: " & failure.msg.safeDisplay(1024)

proc permanentDelete*(store: SessionStore, id: SessionId,
    exactConfirmation: string): string =
  ## Permanently deletes only when the caller supplies the exact opaque ID.
  if exactConfirmation != $id:
    return "permanent deletion requires the exact session ID"
  if not id.validSessionId: return "invalid session ID"
  let active = store.sessionPath(id, false)
  let archived = store.sessionPath(id, true)
  try:
    if fileExists(active): removeFile(active)
    elif fileExists(archived): removeFile(archived)
    else: return "session does not exist"
  except CatchableError as failure:
    result = "could not delete session: " & failure.msg.safeDisplay(1024)
