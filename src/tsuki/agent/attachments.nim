## Explicit image attachment parsing, signature inspection, and change checks.

import std/[os, strutils, sysrand, times]
import limits, pathpolicy, types

type AttachmentResult* = object
  attachment*: ImageReference
  error*: string
  warning*: string

proc generateAttachmentId(): AttachmentId =
  const hex = "0123456789abcdef"
  var value = "a-"
  for item in urandom(16):
    value.add hex[int(item shr 4)]
    value.add hex[int(item and 0x0f)]
  AttachmentId(value)

func be16(data: string, offset: int): int =
  (ord(data[offset]) shl 8) or ord(data[offset + 1])

func be32(data: string, offset: int): int =
  (ord(data[offset]) shl 24) or (ord(data[offset + 1]) shl 16) or
    (ord(data[offset + 2]) shl 8) or ord(data[offset + 3])

func le16(data: string, offset: int): int =
  ord(data[offset]) or (ord(data[offset + 1]) shl 8)

proc imageMetadata(data: string, mediaType: var string,
    width, height: var int): string =
  if data.len >= 24 and data[0 ..< 8] == "\x89PNG\r\n\x1a\n":
    mediaType = "image/png"
    width = data.be32(16)
    height = data.be32(20)
    return
  if data.len >= 10 and data[0 ..< 6] in ["GIF87a", "GIF89a"]:
    mediaType = "image/gif"
    width = data.le16(6)
    height = data.le16(8)
    return
  if data.len >= 4 and data[0 ..< 2] == "\xff\xd8":
    var offset = 2
    while offset + 8 < data.len:
      if data[offset] != '\xff': inc offset; continue
      while offset < data.len and data[offset] == '\xff': inc offset
      if offset >= data.len: break
      let marker = ord(data[offset]); inc offset
      if marker in {0xD8, 0xD9}: continue
      if offset + 2 > data.len: break
      let length = data.be16(offset)
      if length < 2 or offset + length > data.len: break
      if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} and length >= 7:
        height = data.be16(offset + 3)
        width = data.be16(offset + 5)
        mediaType = "image/jpeg"
        return
      offset += length
    return "JPEG dimensions were not found in the bounded header"
  "unsupported or corrupt image signature"

proc inspectAttachment*(workspaceRoot, requested: string, altText = "",
    id = AttachmentId(""), limits = phase1Limits()): AttachmentResult =
  ## Reads bounded headers only after explicit path resolution and confinement.
  let path = resolveAttachmentPath(workspaceRoot, requested)
  if path.error.len > 0:
    result.error = path.error
    return
  try:
    let info = getFileInfo(path.path, followSymlink = false)
    if info.kind != pcFile or info.isSpecial:
      result.error = "attachment is not a regular file"
      return
    if info.size <= 0 or info.size > limits.maxImageBytes:
      result.error = "attachment exceeds the configured image byte limit"
      return
    var file: File
    if not open(file, path.path, fmRead):
      result.error = "attachment is unreadable"
      return
    defer: file.close()
    let openedInfo = getFileInfo(file)
    if openedInfo.kind != pcFile or openedInfo.isSpecial or
        openedInfo.id != info.id:
      result.error = "attachment changed before it could be inspected"
      return
    let headerBytes = min(int(info.size), 1024 * 1024)
    var header = newString(headerBytes)
    let read = file.readBuffer(addr header[0], headerBytes)
    header.setLen(max(0, read))
    var mediaType: string
    var width, height: int
    let metadataError = imageMetadata(header, mediaType, width, height)
    if metadataError.len > 0:
      result.error = metadataError
      return
    if width <= 0 or height <= 0 or int64(width) * int64(height) >
        limits.maxImagePixels:
      result.error = "attachment dimensions exceed the configured pixel limit"
      return
    let after = getFileInfo(file)
    if after.id != openedInfo.id or after.size != openedInfo.size or
        after.lastWriteTime != openedInfo.lastWriteTime:
      result.error = "attachment changed while it was being inspected"
      return
    let attachmentId = if $id != "": id else: generateAttachmentId()
    result.attachment = ImageReference(id: attachmentId,
      path: if path.external: path.path else: path.relativePath,
      location: if path.external: attachmentExternalAbsolute
        else: attachmentWorkspaceRelative,
      displayName: extractFilename(path.path).safeDisplay(1024),
      mediaType: mediaType, sizeBytes: info.size, width: width, height: height,
      modifiedAtMs: info.lastWriteTime.toUnix * 1000,
      altText: altText.safeDisplay(4096), state: attachmentReady)
    if path.external:
      result.warning = "This attachment is outside the workspace and is " &
        "stored as an explicit absolute reference."
  except CatchableError as failure:
    result.error = "could not inspect attachment: " &
      failure.msg.safeDisplay(1024)

proc validateUnchanged*(workspaceRoot: string,
    image: ImageReference, limits = phase1Limits()): AttachmentResult =
  let requested = if image.location == attachmentWorkspaceRelative:
    workspaceRoot / image.path else: image.path
  result = inspectAttachment(workspaceRoot, requested, image.altText,
    image.id, limits)
  let changed = result.attachment.sizeBytes != image.sizeBytes or
    result.attachment.modifiedAtMs != image.modifiedAtMs or
    result.attachment.width != image.width or
    result.attachment.height != image.height
  if result.error.len == 0 and changed:
    result.attachment.state = attachmentChanged
    result.error = "attachment changed after it was staged"

proc refreshImageReference(workspaceRoot: string, image: var ImageReference,
    limits: AgentLimits): bool =
  let previous = image
  let checked = validateUnchanged(workspaceRoot, image, limits)
  if checked.error.len == 0:
    image = checked.attachment
    if previous.state == attachmentSent:
      image.state = attachmentSent
    elif previous.state == attachmentSending:
      image.state = attachmentFailed
  elif checked.attachment.state == attachmentChanged:
    image.state = attachmentChanged
  else:
    let path = if image.location == attachmentWorkspaceRelative:
      workspaceRoot / image.path else: image.path
    image.state = if not fileExists(path): attachmentMissing
      else: attachmentFailed
  image.state != previous.state or image.sizeBytes != previous.sizeBytes or
    image.modifiedAtMs != previous.modifiedAtMs

proc refreshAttachmentReferences*(session: var Session,
    limits = phase1Limits()): bool =
  ## Revalidates staged and historical references after resume.
  for image in session.stagedAttachments.mitems:
    let changed = refreshImageReference(session.workspaceRoot, image, limits)
    result = changed or result
  for message in session.messages.mitems:
    for part in message.parts.mitems:
      if part.kind == contentImageReference:
        let changed = refreshImageReference(session.workspaceRoot, part.image,
          limits)
        result = changed or result

proc parseAttachArgument*(command: string): string =
  ## Parses `/attach` arguments with whitespace and one matching quote pair.
  let split = command.find({' ', '\t'})
  if split < 0: return
  result = command[split + 1 .. ^1].strip()
  if result.len >= 2 and result[0] in {'\'', '"'} and
      result[^1] == result[0]:
    result = result[1 .. ^2]
