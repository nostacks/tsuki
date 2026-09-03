## Shared lexical confinement and conservative symlink policy.

import std/[os, strutils]
import types

type PathResolution* = object
  path*: string
  relativePath*: string
  error*: string
  external*: bool

func comparable(path: string): string =
  when defined(windows): path.toLowerAscii
  else: path

func inside(root, candidate: string): bool =
  let base = root.comparable
  let value = candidate.comparable
  let prefix = if base.endsWith($DirSep): base else: base & $DirSep
  value == base or value.startsWith(prefix)

proc containsSymlink(root, candidate: string): bool =
  if not inside(root, candidate): return true
  if symlinkExists(root): return true
  var current = root
  let relative = relativePath(candidate, root)
  if relative in ["", "."]: return symlinkExists(root)
  for component in relative.split({DirSep, AltSep}):
    if component.len == 0: continue
    current = current / component
    if symlinkExists(current): return true

proc resolveWorkspacePath*(workspaceRoot, requested: string,
    allowAbsolute = false, requireExists = true,
    rejectSymlinks = true): PathResolution =
  ## Resolves against one workspace and rejects traversal and every symlink.
  if workspaceRoot.len == 0:
    result.error = "workspace root is empty"
    return
  if requested.len == 0 or '\0' in requested:
    result.error = "path is empty or contains NUL"
    return
  try:
    let root = normalizedPath(absolutePath(workspaceRoot))
    if isAbsolute(requested) and not allowAbsolute:
      result.error = "absolute paths are not allowed"
      return
    let candidate = normalizedPath(if isAbsolute(requested): requested
      else: root / requested)
    if not inside(root, candidate):
      result.error = "path escapes the workspace"
      return
    if rejectSymlinks and root.containsSymlink(candidate):
      result.error = "symlink paths are not allowed"
      return
    if requireExists and not fileExists(candidate) and not dirExists(candidate):
      result.error = "path does not exist"
      return
    result.path = candidate
    result.relativePath = relativePath(candidate, root)
  except CatchableError as failure:
    result.error = "could not resolve path: " & failure.msg.safeDisplay(1024)

proc resolveAttachmentPath*(workspaceRoot, requested: string): PathResolution =
  ## Allows an explicit absolute attachment while visibly marking it external.
  result = resolveWorkspacePath(workspaceRoot, requested,
    allowAbsolute = true, requireExists = true, rejectSymlinks = true)
  if result.error.len == 0: return
  if not isAbsolute(requested): return
  try:
    let root = normalizedPath(absolutePath(workspaceRoot))
    let candidate = normalizedPath(absolutePath(requested))
    var current = when defined(windows): splitDrive(candidate).head
      else: $DirSep
    var hasSymlink = false
    for component in candidate.split({DirSep, AltSep}):
      if component.len == 0 or component.endsWith(":"): continue
      current = current / component
      if symlinkExists(current):
        hasSymlink = true
        break
    if hasSymlink:
      result.error = "symlink attachments are not allowed"
      return
    if not fileExists(candidate):
      result.error = "attachment does not exist"
      return
    let external = not inside(root, candidate)
    result = PathResolution(path: candidate,
      relativePath: if external: candidate else: relativePath(candidate, root),
      external: external)
  except CatchableError as failure:
    result.error = "could not resolve attachment: " &
      failure.msg.safeDisplay(1024)
