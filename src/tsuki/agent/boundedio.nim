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
    var total = 0
    result.data = newString(int(pathInfo.size))
    while true:
      if total == result.data.len:
        if total >= maxBytes:
          var probe: char
          if file.readBuffer(addr probe, 1) > 0:
            result.data.setLen 0
            result.error = "file exceeds the configured byte limit"
            return
          break
        result.data.setLen(min(maxBytes, max(total * 2, total + 4096)))
      let amount = file.readBuffer(addr result.data[total],
        result.data.len - total)
      if amount <= 0: break
      total += amount
    result.data.setLen(total)
    let after = getFileInfo(file)
    if after.id != openedInfo.id or after.size != openedInfo.size or
        after.lastWriteTime != openedInfo.lastWriteTime:
      result.data.setLen 0
      result.error = "file changed while it was being read"
  except CatchableError:
    result.data.setLen 0
    result.error = "file could not be read"
