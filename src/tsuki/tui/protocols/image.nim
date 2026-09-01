## Optional terminal-image metadata with a mandatory safe text fallback.

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

