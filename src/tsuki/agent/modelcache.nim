## Credential-free, versioned model metadata cache.

import std/[algorithm, json, os]
import boundedio, types

type ModelCacheResult* = object
  models*: seq[ModelDescriptor]
  error*: string

proc encodeModelCache*(models: openArray[ModelDescriptor]): string =
  var values = newJArray()
  for model in models:
    values.add %*{"providerId": $model.providerId, "id": $model.id,
      "displayName": model.displayName,
      "textInput": $model.capabilities.textInput,
      "imageInput": $model.capabilities.imageInput,
      "streaming": $model.capabilities.streaming,
      "tools": $model.capabilities.tools,
      "contextWindow": model.contextWindow,
      "maxOutputTokens": model.maxOutputTokens,
      "reasoningEfforts": model.reasoningEfforts,
      "defaultReasoningEffort": model.defaultReasoningEffort,
      "available": model.available,
      "unavailableReason": model.unavailableReason}
  $(%*{"schemaVersion": 1, "models": values})

func cachedCapability(value: string): CapabilityState =
  case value
  of "capabilitySupported": capabilitySupported
  of "capabilityUnsupported": capabilityUnsupported
  else: capabilityUnknown

proc decodeModelCache*(source: string): ModelCacheResult =
  if source.len > 4 * 1024 * 1024:
    result.error = "model cache exceeds the configured bound"
    return
  try:
    let root = parseJson(source)
    if root{"schemaVersion"}.getInt(0) != 1:
      result.error = "unsupported model cache schema"
      return
    let values = root{"models"}
    if values.isNil or values.kind != JArray:
      result.error = "model cache entries must be an array"
      return
    if values.len > 10_000:
      result.error = "model cache contains too many entries"
      return
    for node in values:
      let id = node{"id"}.getStr.safeDisplay(1024)
      let providerId = node{"providerId"}.getStr.safeId(256)
      if id.len == 0 or providerId.len == 0: continue
      result.models.add ModelDescriptor(providerId: ProviderId(providerId),
        id: ModelId(id), displayName: node{"displayName"}.getStr(id)
        .safeDisplay(1024), capabilities: ModelCapabilities(
        textInput: cachedCapability(node{"textInput"}.getStr),
        imageInput: cachedCapability(node{"imageInput"}.getStr),
        streaming: cachedCapability(node{"streaming"}.getStr),
        tools: cachedCapability(node{"tools"}.getStr)),
        contextWindow: node{"contextWindow"}.getInt(0),
        maxOutputTokens: node{"maxOutputTokens"}.getInt(0),
        available: node{"available"}.getBool(true),
        unavailableReason: node{"unavailableReason"}.getStr.safeDisplay(1024),
        provenance: provenanceCached)
      let efforts = node{"reasoningEfforts"}
      if not efforts.isNil and efforts.kind == JArray:
        for effort in efforts: result.models[^1].addReasoningEffort(effort.getStr)
      let defaultEffort = node{"defaultReasoningEffort"}.getStr
      if defaultEffort in result.models[^1].reasoningEfforts:
        result.models[^1].defaultReasoningEffort = defaultEffort
    result.models.sort(proc (a, b: ModelDescriptor): int =
      result = cmp($a.providerId, $b.providerId)
      if result == 0: result = cmp($a.id, $b.id))
  except CatchableError as failure:
    result.error = "invalid model cache: " & failure.msg.safeDisplay(1024)

proc loadModelCache*(path: string): ModelCacheResult =
  if not fileExists(path): return
  try:
    let source = readBoundedRegularFile(path, 4 * 1024 * 1024)
    if source.error.len > 0:
      result.error = "could not read model cache: " & source.error
      return
    result = decodeModelCache(source.data)
  except CatchableError as failure:
    result.error = "could not read model cache: " & failure.msg.safeDisplay(1024)

proc saveModelCache*(path: string,
    models: openArray[ModelDescriptor]): string =
  try:
    createDir(parentDir(path))
    let temporary = path & ".tmp"
    var file: File
    if not open(file, temporary, fmWrite): return "could not open model cache"
    var opened = true
    try:
      file.write(encodeModelCache(models))
      file.flushFile()
      file.close()
      opened = false
      moveFile(temporary, path)
    except CatchableError:
      if opened: file.close()
      if fileExists(temporary): removeFile(temporary)
      raise
  except CatchableError as failure:
    result = "could not save model cache: " & failure.msg.safeDisplay(1024)
