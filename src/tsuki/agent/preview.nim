## Host-side image loading for inline transcript previews.
##
## he3 never reads files itself. The loader built here applies the same
## path policy as attachments, reads a bounded PNG, and hands the bytes to
## the terminal session. Any other source draws its text fallback.

import std/[os, strutils]
import he3/agent as ui
import attachments, limits, pathpolicy

const attachmentSourcePrefix* = "attachment:"
  ## Prefix the bridge puts on attachment sources so the loader can allow an
  ## explicit absolute path there while confining Markdown image references
  ## to the workspace.

proc loadPreviewImage*(workspaceRoot, source: string,
    limits = phase1Limits()): ui.ImageData =
  ## Reads one PNG for preview. Attachment sources may be absolute; other
  ## sources must resolve inside the workspace. Non-PNG files, oversized
  ## files, and policy rejections return an empty result.
  var requested = source
  var resolution: PathResolution
  if source.startsWith(attachmentSourcePrefix):
    requested = source[attachmentSourcePrefix.len ..< source.len]
    resolution = resolveAttachmentPath(workspaceRoot, requested)
  else:
    resolution = resolveWorkspacePath(workspaceRoot, requested)
  if resolution.error.len > 0:
    return
  try:
    let info = getFileInfo(resolution.path, followSymlink = false)
    if info.kind != pcFile or info.isSpecial or info.size <= 0 or
        info.size > limits.maxImageBytes:
      return
    var file: File
    if not open(file, resolution.path, fmRead):
      return
    defer: file.close()
    var data = newString(int(info.size))
    let read = file.readBuffer(addr data[0], data.len)
    if read != data.len:
      return
    var mediaType: string
    var width, height: int
    if imageMetadata(data, mediaType, width, height).len > 0:
      return
    if mediaType != "image/png" or width <= 0 or height <= 0 or
        int64(width) * int64(height) > limits.maxImagePixels:
      return
    result = ui.ImageData(png: data, widthPx: width, heightPx: height)
  except CatchableError:
    result = ui.ImageData()

proc previewLoader*(workspaceRoot: string,
    extra: ui.ImageLoader = nil): ui.ImageLoader =
  ## Builds the loader the agent shell calls for image sources. `extra` may
  ## serve in-memory images first; files are tried afterwards.
  result = proc (source: string): ui.ImageData {.gcsafe.} =
    if not extra.isNil:
      let served = extra(source)
      if served.png.len > 0:
        return served
    loadPreviewImage(workspaceRoot, source)
