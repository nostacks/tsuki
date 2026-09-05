## Provider API keys persisted in an owner-only file outside the config.

import std/[json, os]
import boundedio, types

const
  credentialsSchemaVersion = 1
  maxCredentialsBytes = 64 * 1024
  maxStoredKeyBytes = 4096

type
  StoredCredential* = object
    providerId*: ProviderId
    apiKey*: string

  CredentialsLoadResult* = object
    entries*: seq[StoredCredential]
    error*: string

proc encodeCredentials*(entries: openArray[StoredCredential]): string =
  var providers = newJObject()
  for entry in entries:
    if $entry.providerId == "" or entry.apiKey.len == 0: continue
    providers[$entry.providerId] = %*{"apiKey": entry.apiKey}
  $(%*{"schemaVersion": credentialsSchemaVersion, "providers": providers})

proc decodeCredentials*(source: string): CredentialsLoadResult =
  if source.len > maxCredentialsBytes:
    result.error = "credentials file exceeds the configured bound"
    return
  try:
    let root = parseJson(source)
    if root{"schemaVersion"}.getInt(0) != credentialsSchemaVersion:
      result.error = "unsupported credentials schema"
      return
    let providers = root{"providers"}
    if providers.isNil or providers.kind != JObject:
      result.error = "credentials providers must be an object"
      return
    for key, node in providers:
      let providerId = key.safeId(256)
      let apiKey = node{"apiKey"}.getStr
      if providerId.len == 0 or apiKey.len == 0 or
          apiKey.len > maxStoredKeyBytes:
        continue
      result.entries.add StoredCredential(providerId: ProviderId(providerId),
        apiKey: apiKey)
  except CatchableError as failure:
    result.error = "invalid credentials file: " &
      failure.msg.safeDisplay(1024)

proc loadCredentials*(path: string): CredentialsLoadResult =
  ## Reads stored keys; a missing file is not an error.
  if not fileExists(path): return
  try:
    let source = readBoundedRegularFile(path, maxCredentialsBytes)
    if source.error.len > 0:
      result.error = "could not read credentials: " & source.error
      return
    result = decodeCredentials(source.data)
  except CatchableError as failure:
    result.error = "could not read credentials: " &
      failure.msg.safeDisplay(1024)

proc saveCredentials*(path: string,
    entries: openArray[StoredCredential]): string =
  ## Writes the file with owner-only permissions through an atomic rename.
  ## Returns an error message, or "" on success.
  try:
    createDir(parentDir(path))
    let temporary = path & ".tmp"
    var file: File
    if not open(file, temporary, fmWrite):
      return "could not open the credentials file"
    var opened = true
    try:
      setFilePermissions(temporary, {fpUserRead, fpUserWrite})
      file.write(encodeCredentials(entries))
      file.flushFile()
      file.close()
      opened = false
      moveFile(temporary, path)
    except CatchableError:
      if opened: file.close()
      if fileExists(temporary): removeFile(temporary)
      raise
  except CatchableError as failure:
    result = "could not save credentials: " & failure.msg.safeDisplay(1024)
