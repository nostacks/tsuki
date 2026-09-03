## Optional terminal-image metadata with a mandatory safe text fallback.

import std/base64
import ../[terminal, text]

type
  ImageProtocol* = enum
    imageCells
    imageKitty
    imageSixel
    imageIterm

  ImageRequest* = object
    protocol*: ImageProtocol
    altText*: string
    mediaType*: string
    widthCells*: int
    heightCells*: int
    maxBytes*: int

  KittyImageEncoding* = object
    accepted*: bool
    controls*: seq[string]
    clearControl*: string
    error*: string

  ImagePlacementState* = object
    imageId*: uint32
    placementId*: uint32
    widthCells*: int
    heightCells*: int
    visible*: bool
    generation*: uint64

func chooseImageProtocol*(capabilities: TerminalCapabilities): ImageProtocol =
  ## Selects an advertised protocol, otherwise the ordinary cell fallback.
  if capabilities.kittyGraphics: imageKitty
  elif capabilities.sixelGraphics: imageSixel
  elif capabilities.itermImages: imageIterm
  else: imageCells

func imageRequest*(altText: string, capabilities: TerminalCapabilities,
    mediaType = "image/png", widthCells = 0, heightCells = 0,
    maxBytes = 4_194_304): ImageRequest =
  ## Creates bounded metadata. Binary transport is deliberately host-supplied
  ## so importing this module cannot decode files or perform external effects.
  ImageRequest(protocol: capabilities.chooseImageProtocol,
    altText: sanitizeText(altText, plainTextPolicy(maxBytes = 4096)),
    mediaType: sanitizeText(mediaType, plainTextPolicy(maxBytes = 128)),
    widthCells: max(0, widthCells), heightCells: max(0, heightCells),
    maxBytes: max(0, maxBytes))

proc encodeKittyImage*(data: string, request: ImageRequest,
    capabilities: TerminalCapabilities, imageId, placementId: uint32,
    explicit: bool, chunkBytes = 3072): KittyImageEncoding =
  ## Encodes a bounded PNG into isolated Kitty controls after explicit intent.
  ## Untrusted names and alt text are never interpolated into protocol bytes.
  if not explicit:
    result.error = "image preview requires explicit host intent"
    return
  if not capabilities.kittyGraphics or request.protocol != imageKitty:
    result.error = "Kitty graphics are not advertised by this terminal"
    return
  if request.mediaType != "image/png":
    result.error = "Phase 1 Kitty preview accepts PNG data only"
    return
  if data.len == 0 or data.len > request.maxBytes:
    result.error = "image payload is empty or exceeds the configured bound"
    return
  if imageId == 0 or placementId == 0:
    result.error = "image and placement IDs must be non-zero"
    return
  let encoded = base64.encode(data)
  let size = max(4, chunkBytes - chunkBytes mod 4)
  var offset = 0
  var first = true
  while offset < encoded.len:
    let stop = min(encoded.len, offset + size)
    let more = stop < encoded.len
    var command = "\e_G"
    if first:
      command.add "a=T,f=100,q=2,i=" & $imageId & ",p=" & $placementId
      if request.widthCells > 0: command.add ",c=" & $request.widthCells
      if request.heightCells > 0: command.add ",r=" & $request.heightCells
      first = false
    command.add ",m=" & (if more: "1" else: "0") & ";"
    command.add encoded[offset ..< stop]
    command.add "\e\\"
    result.controls.add command
    offset = stop
  result.clearControl = "\e_Ga=d,d=i,i=" & $imageId & ",p=" &
    $placementId & "\e\\"
  result.accepted = true

proc place*(state: var ImagePlacementState, imageId, placementId: uint32,
    widthCells, heightCells: int) =
  state.imageId = imageId
  state.placementId = placementId
  state.widthCells = max(0, widthCells)
  state.heightCells = max(0, heightCells)
  state.visible = imageId != 0 and placementId != 0
  inc state.generation

proc invalidate*(state: var ImagePlacementState) =
  ## Invalidates one placement on resize, scroll, switch, suspend, or exit.
  state.visible = false
  inc state.generation

proc needsRedraw*(state: ImagePlacementState,
    renderedGeneration: uint64): bool =
  state.visible and state.generation != renderedGeneration
