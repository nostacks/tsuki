## Bounded regular-file reads for untrusted config, cache, and session data.

import std/os

type BoundedFileRead* = object
  data*: string
  error*: string

proc readBoundedRegularFile*(path: string, maxBytes: int): BoundedFileRead =
  if maxBytes < 0:
    result.error = "file byte limit is invalid"
    return
  try:
    let pathInfo = getFileInfo(path, followSymlink = false)
    if pathInfo.kind != pcFile or pathInfo.isSpecial:
      result.error = "path is not a regular file"
      return
    if pathInfo.size < 0 or pathInfo.size > maxBytes:
      result.error = "file exceeds the configured byte limit"
      return
    var file: File
    if not open(file, path, fmRead):
      result.error = "file is unreadable"
      return
    defer: file.close()
    let openedInfo = getFileInfo(file)
    if openedInfo.kind != pcFile or openedInfo.isSpecial or
        openedInfo.id != pathInfo.id:
      result.error = "file changed before it could be read"
      return
    var buffer = newString(if maxBytes == 0: 1
      else: min(64 * 1024, maxBytes))
    while true:
      let amount = file.readBuffer(addr buffer[0], buffer.len)
      if amount <= 0: break
      if amount > maxBytes - min(maxBytes, result.data.len):
        result.data.setLen 0
        result.error = "file exceeds the configured byte limit"
        return
      result.data.add buffer[0 ..< amount]
    let after = getFileInfo(file)
    if after.id != openedInfo.id or after.size != openedInfo.size or
        after.lastWriteTime != openedInfo.lastWriteTime:
      result.data.setLen 0
      result.error = "file changed while it was being read"
  except CatchableError:
    result.data.setLen 0
    result.error = "file could not be read"
