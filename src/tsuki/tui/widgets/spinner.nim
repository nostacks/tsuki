type
  SpinnerKind* = enum
    ## Preset animation sets for a spinner.
    spDots
    spBraille
    spBar

  Spinner* = object
    ## Animated spinner cycling through a preset frame set.
    kind*: SpinnerKind
    frame*: int
    frames: seq[string]

const
  dotsFrames = [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
  ]
  brailleFrames = [
    "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"
  ]
  barFrames = [
    "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅",
    "▄", "▃", "▂"
  ]

func initSpinner*(kind: SpinnerKind): Spinner =
  ## Creates a spinner preset at frame 0.
  case kind
  of spDots:
    Spinner(kind: kind, frame: 0, frames: @dotsFrames)
  of spBraille:
    Spinner(kind: kind, frame: 0, frames: @brailleFrames)
  of spBar:
    Spinner(kind: kind, frame: 0, frames: @barFrames)

func current*(s: Spinner): string =
  ## Returns the current frame without advancing.
  s.frames[s.frame]

func next*(s: var Spinner): string =
  ## Returns the current frame and advances, wrapping around.
  result = s.frames[s.frame]
  s.frame = (s.frame + 1) mod s.frames.len
