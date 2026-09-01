## User preferences shared by widgets and runtimes.

type AccessibilityPreferences* = object
  ## Reduced motion suppresses nonessential animation deadlines. Linear mode
  ## favors reading order and inline output for assistive terminal workflows.
  reducedMotion*: bool
  highContrast*: bool
  noColor*: bool
  linearMode*: bool

func accessibilityPreferences*(reducedMotion = false,
    highContrast = false, noColor = false,
    linearMode = false): AccessibilityPreferences =
  ## Creates explicit accessibility preferences.
  AccessibilityPreferences(reducedMotion: reducedMotion,
    highContrast: highContrast, noColor: noColor, linearMode: linearMode)
