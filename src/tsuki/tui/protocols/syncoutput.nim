## Capability-gated synchronized terminal output markers.

import ../terminal

func beginSynchronizedOutput*(capabilities: TerminalCapabilities): string =
  ## Returns the DEC synchronized-output begin marker or an empty fallback.
  if capabilities.synchronizedOutput: "\e[?2026h" else: ""

func endSynchronizedOutput*(capabilities: TerminalCapabilities): string =
  ## Returns the matching end marker or an empty fallback.
  if capabilities.synchronizedOutput: "\e[?2026l" else: ""

