## Bounded workspace-confined directory, literal-search, and file-read tools.

import std/[algorithm, json, monotimes, os, strutils, times, unicode]
import ../[boundedio, pathpolicy, types]
import types as tooltypes

const deniedNames = [".env", ".git", ".hg", ".svn", ".ssh", ".npmrc",
  ".pypirc", "credentials", "credentials.json", "id_rsa", "id_ed25519",
  "secrets", "secrets.json"]

func deniedPath(path: string): bool =
  for component in path.split({DirSep, AltSep}):
    let value = component.toLowerAscii
    if value in deniedNames or value.startsWith(".env") or
        value.endsWith(".pem") or
        value.endsWith(".key"):
      return true

proc stopped(policy: ToolHostPolicy): bool =
  not policy.cancelled.isNil and policy.cancelled()

func failure(request: ToolRequest, code: ToolErrorCode,
    message: string): ToolExecutionResult =
  ToolExecutionResult(requestId: request.id, name: request.name,
    errorCode: code, errorMessage: message.safeDisplay(2048))

proc resolved(policy: ToolHostPolicy, request: ToolRequest,
    path: string): PathResolution =
  result = resolveWorkspacePath(policy.workspaceRoot, path)
  if result.error.len == 0 and result.relativePath.deniedPath:
    result.error = "path is denied by the read-only host policy"

proc textFile(path: string, maxBytes: int, content: var string): ToolErrorCode =
  let source = readBoundedRegularFile(path, maxBytes)
  if source.error.len > 0:
    if source.error.contains("configured byte limit"): return toolTooLarge
    if source.error.contains("not a regular file"): return toolNotRegular
    return toolIoError
  content = source.data
  if '\0' in content or validateUtf8(content) >= 0: return toolBinary
  toolOk

proc listDirectory*(policy: ToolHostPolicy, request: ToolRequest,
    path: string): ToolExecutionResult =
  if not policy.enabled: return request.failure(toolDisabled, "tools are disabled")
  if policy.stopped: return request.failure(toolCancelled, "tool was cancelled")
  let target = policy.resolved(request, if path.len > 0: path else: ".")
  if target.error.len > 0:
    return request.failure(toolPathDenied, target.error)
  if not dirExists(target.path):
    return request.failure(toolNotRegular, "path is not a directory")
  try:
    var rows: seq[string]
    for kind, item in walkDir(target.path, relative = true):
      if policy.stopped:
        return request.failure(toolCancelled, "tool was cancelled")
      if item.deniedPath: continue
      inc result.entriesVisited
      if rows.len >= policy.limits.maxDirectoryEntries:
        result.truncated = true
        break
      let label = case kind
        of pcDir: "dir"
        of pcFile:
          let info = getFileInfo(target.path / item, followSymlink = false)
          if info.isSpecial: "special (not read)" else: "file"
        of pcLinkToDir, pcLinkToFile: "symlink (not followed)"
      rows.add item.safeDisplay(4096) & "\t" & label
    rows.sort(system.cmp[string])
    result.requestId = request.id
    result.name = request.name
    result.success = true
    result.errorCode = toolOk
    result.content = rows.join("\n")
    if result.truncated: result.content.add "\n… directory output truncated"
  except CatchableError as problem:
    result = request.failure(toolIoError, problem.msg)

proc searchText*(policy: ToolHostPolicy, request: ToolRequest, query: string,
    startPath = "."): ToolExecutionResult =
  if not policy.enabled: return request.failure(toolDisabled, "tools are disabled")
  if query.len == 0 or query.len > 16 * 1024:
    return request.failure(toolInvalidArguments, "query must not be empty")
  let target = policy.resolved(request, if startPath.len >
      0: startPath else: ".")
  if target.error.len > 0: return request.failure(toolPathDenied, target.error)
  let deadline = getMonoTime() + initDuration(milliseconds = 5_000)
  var pending = @[target.path]
  var rows: seq[string]
  var outputBytes = 0
  while pending.len > 0:
    if policy.stopped:
      return request.failure(toolCancelled, "tool was cancelled")
    if getMonoTime() >= deadline:
      result.truncated = true
      result.errorCode = toolTimedOut
      break
    let path = pending.pop()
    if dirExists(path):
      var children: seq[string]
      try:
        for kind, child in walkDir(path, relative = false):
          if relativePath(child, policy.workspaceRoot).deniedPath: continue
          if kind in {pcLinkToDir, pcLinkToFile}: continue
          children.add child
        children.sort(system.cmp[string], order = SortOrder.Descending)
        pending.add children
      except CatchableError: discard
      continue
    inc result.entriesVisited
    if result.entriesVisited > policy.limits.maxSearchFiles:
      result.truncated = true
      break
    var content: string
    if textFile(path, policy.limits.maxReadBytes, content) != toolOk: continue
    var lineNumber = 0
    for line in content.splitLines:
      inc lineNumber
      if query in line:
        inc result.matches
        let relative = relativePath(path, policy.workspaceRoot).safeDisplay(4096)
        let row = relative & ":" & $lineNumber & ":" &
          line.safeDisplay(4096)
        if result.matches > policy.limits.maxSearchMatches or
            outputBytes + row.len > policy.limits.maxToolOutputBytes:
          result.truncated = true
          break
        rows.add row
        outputBytes += row.len + 1
    if result.truncated: break
  result.requestId = request.id
  result.name = request.name
  result.success = result.errorCode in {toolOk, toolTimedOut}
  if result.errorCode == toolOk: result.errorCode = toolOk
  result.content = rows.join("\n")
  if result.truncated: result.content.add "\n… search output truncated"

proc readFileTool*(policy: ToolHostPolicy, request: ToolRequest, path: string,
    startLine = 1, endLine = 0, lineNumbers = true): ToolExecutionResult =
  if not policy.enabled: return request.failure(toolDisabled, "tools are disabled")
  if startLine < 1 or endLine < 0 or endLine > 0 and endLine < startLine:
    return request.failure(toolInvalidArguments, "invalid line range")
  let target = policy.resolved(request, path)
  if target.error.len > 0: return request.failure(toolPathDenied, target.error)
  var content: string
  let code = textFile(target.path, policy.limits.maxReadBytes, content)
  if code != toolOk:
    let detail = case code
      of toolTooLarge: "file exceeds the read limit"
      of toolBinary: "file is binary or invalid UTF-8"
      of toolNotRegular: "path is not a regular file"
      else: "could not read file"
    return request.failure(code, detail)
  let lastWanted = if endLine > 0: endLine
    else: startLine + policy.limits.maxReadLines - 1
  var number = 0
  var rows: seq[string]
  var outputBytes = 0
  for line in content.splitLines:
    inc number
    if number < startLine: continue
    if number > lastWanted: break
    if policy.stopped:
      return request.failure(toolCancelled, "tool was cancelled")
    let row = if lineNumbers: $number & "\t" & line else: line
    if rows.len >= policy.limits.maxReadLines or
        outputBytes + row.len > policy.limits.maxToolOutputBytes:
      result.truncated = true
      break
    rows.add row.safeDisplay(policy.limits.maxToolOutputBytes - outputBytes)
    outputBytes += row.len + 1
  if endLine == 0 and number > lastWanted:
    result.truncated = true
  result.requestId = request.id
  result.name = request.name
  result.success = true
  result.errorCode = toolOk
  result.content = rows.join("\n")
  if result.truncated: result.content.add "\n… file output truncated"

func onlyKeys(node: JsonNode, allowed: openArray[string]): bool =
  for key in node.keys:
    var known = false
    for value in allowed:
      if key == value:
        known = true
        break
    if not known: return false
  true

proc execute*(policy: ToolHostPolicy,
    request: ToolRequest): ToolExecutionResult =
  ## Validates JSON and dispatches exactly the three Phase 1 read-only tools.
  if request.argumentsJson.len > 1024 * 1024:
    return request.failure(toolInvalidArguments, "tool arguments exceed limit")
  try:
    let args = parseJson(request.argumentsJson)
    if args.kind != JObject:
      return request.failure(toolInvalidArguments,
        "tool arguments must be a JSON object")
    case request.name
    of "list_directory":
      if not args.onlyKeys(["path"]) or not args.hasKey("path") or
          args["path"].kind != JString:
        return request.failure(toolInvalidArguments,
          "list_directory requires only a string path")
      policy.listDirectory(request, args{"path"}.getStr("."))
    of "search_text":
      if not args.onlyKeys(["query", "path"]) or
          not args.hasKey("query") or args["query"].kind != JString or
          args.hasKey("path") and args["path"].kind != JString:
        return request.failure(toolInvalidArguments,
          "search_text requires a string query and optional string path")
      policy.searchText(request, args{"query"}.getStr,
        args{"path"}.getStr("."))
    of "read_file":
      if not args.onlyKeys(["path", "startLine", "endLine", "lineNumbers"]) or
          not args.hasKey("path") or args["path"].kind != JString or
          args.hasKey("startLine") and args["startLine"].kind != JInt or
          args.hasKey("endLine") and args["endLine"].kind != JInt or
          args.hasKey("lineNumbers") and args["lineNumbers"].kind != JBool:
        return request.failure(toolInvalidArguments,
          "read_file arguments do not match its schema")
      if args.hasKey("startLine") and args["startLine"].getInt < 1 or
          args.hasKey("endLine") and args["endLine"].getInt < 1:
        return request.failure(toolInvalidArguments,
          "read_file line numbers must be positive")
      policy.readFileTool(request, args{"path"}.getStr,
        args{"startLine"}.getInt(1), args{"endLine"}.getInt(0),
        args{"lineNumbers"}.getBool(true))
    else:
      request.failure(toolUnknown, "unknown tool: " & request.name.safeDisplay())
  except JsonParsingError:
    request.failure(toolInvalidArguments, "tool arguments are malformed JSON")
  except CatchableError as problem:
    request.failure(toolInvalidArguments, problem.msg)
