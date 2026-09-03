## Central, conservative Phase 1 resource limits.

type AgentLimits* = object
  requestTimeoutMs*: int
  idleStreamTimeoutMs*: int
  maxResponseBytes*: int
  maxImageBytes*: int
  maxImagePixels*: int64
  maxSessionBytes*: int
  maxToolRounds*: int
  maxToolTimeMs*: int
  maxToolOutputBytes*: int
  maxDirectoryEntries*: int
  maxSearchFiles*: int
  maxSearchMatches*: int
  maxReadBytes*: int
  maxReadLines*: int
  saveDebounceMs*: int
  maxRequestBytes*: int

func phase1Limits*(): AgentLimits =
  ## Returns the fixed Phase 1 bounds used by every product subsystem.
  AgentLimits(
    requestTimeoutMs: 120_000,
    idleStreamTimeoutMs: 30_000,
    maxResponseBytes: 16 * 1024 * 1024,
    maxImageBytes: 8 * 1024 * 1024,
    maxImagePixels: 40_000_000,
    maxSessionBytes: 32 * 1024 * 1024,
    maxToolRounds: 8,
    maxToolTimeMs: 30_000,
    maxToolOutputBytes: 2 * 1024 * 1024,
    maxDirectoryEntries: 1_000,
    maxSearchFiles: 10_000,
    maxSearchMatches: 500,
    maxReadBytes: 1024 * 1024,
    maxReadLines: 10_000,
    saveDebounceMs: 1_000,
    maxRequestBytes: 8 * 1024 * 1024)
