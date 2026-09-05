## Public backend adapter contract for host and test integrations.

import event
import geometry
import terminal

type
  BackendError* = object
    operation*: string
    message*: string

  BackendWriteProc* = proc (bytes: openArray[byte]): bool {.closure.}
  BackendWaitProc* = proc (timeoutMs: int, event: var Event): bool {.closure.}
  BackendSizeProc* = proc (): Size {.closure.}
  BackendCloseProc* = proc () {.closure.}

  Backend* = object
    ## Callback adapter for specialized hosts. Ordinary applications use the
    ## built-in terminal/headless backends through `openTui`.
    capabilities*: TerminalCapabilities
    writeProc*: BackendWriteProc
    waitProc*: BackendWaitProc
    sizeProc*: BackendSizeProc
    closeProc*: BackendCloseProc
    closed*: bool

proc write*(backend: var Backend, bytes: openArray[byte]): bool =
  ## Writes one logical frame or returns false when unavailable.
  not backend.closed and not backend.writeProc.isNil and
    backend.writeProc(bytes)

proc wait*(backend: var Backend, timeoutMs: int,
    event: var Event): bool =
  ## Waits through the host adapter; negative timeout means indefinite.
  not backend.closed and not backend.waitProc.isNil and
    backend.waitProc(timeoutMs, event)

proc size*(backend: Backend): Size =
  ## Returns the current host viewport or zero size when unavailable.
  if backend.closed or backend.sizeProc.isNil: size(0, 0)
  else: backend.sizeProc()

proc close*(backend: var Backend) =
  ## Closes the adapter once.
  if backend.closed: return
  backend.closed = true
  if not backend.closeProc.isNil: backend.closeProc()
