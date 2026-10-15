## Theme colors and spacing for native UI elements.

type Theme* = object
  ## Colors and metrics used by widgets and frame content.
  dark*: bool
  background*, surface*, surfaceHover*, surfacePressed*, border*: Color
  text*, textMuted*: Color
  accent*, accentHover*, accentPressed*, accentText*: Color
  danger*, warning*, success*: Color
  selection*, focus*: Color
  inverse*, inverseText*: Color
  scrollbar*: Color
  scrollbarWidth*, radius*, spacing*, fontSize*: float32
  font*: string

proc lightTheme*(): Theme =
  ## Returns the default theme for a light appearance.
  Theme(
    background: rgb(255, 255, 255),
    surface: rgb(244, 244, 245),
    surfaceHover: rgb(233, 233, 236),
    surfacePressed: rgb(221, 221, 225),
    border: rgb(217, 217, 222),
    text: rgb(24, 24, 27),
    textMuted: rgb(113, 113, 122),
    accent: rgb(37, 99, 235),
    accentHover: rgb(29, 78, 216),
    accentPressed: rgb(30, 64, 175),
    accentText: rgb(255, 255, 255),
    danger: rgb(220, 38, 38),
    warning: rgb(217, 119, 6),
    success: rgb(22, 163, 74),
    selection: rgba(37, 99, 235, 0.25'f32),
    focus: rgba(37, 99, 235, 0.55'f32),
    scrollbar: rgba(0, 0, 0, 0.32'f32),
    scrollbarWidth: 6, radius: 6, spacing: 4,
    fontSize: if defined(macosx): 13 else: 14)

proc darkTheme*(): Theme =
  ## Returns the default theme for a dark appearance.
  Theme(
    dark: true,
    background: rgb(24, 24, 27),
    surface: rgb(39, 39, 42),
    surfaceHover: rgb(50, 50, 54),
    surfacePressed: rgb(60, 60, 65),
    border: rgb(63, 63, 70),
    text: rgb(244, 244, 245),
    textMuted: rgb(161, 161, 170),
    accent: rgb(59, 130, 246),
    accentHover: rgb(96, 165, 250),
    accentPressed: rgb(37, 99, 235),
    accentText: rgb(255, 255, 255),
    danger: rgb(239, 68, 68),
    warning: rgb(245, 158, 11),
    success: rgb(34, 197, 94),
    selection: rgba(59, 130, 246, 0.4'f32),
    focus: rgba(96, 165, 250, 0.6'f32),
    scrollbar: rgba(255, 255, 255, 0.35'f32),
    scrollbarWidth: 6, radius: 6, spacing: 4,
    fontSize: if defined(macosx): 13 else: 14)

func space*(theme: Theme; units: float32): float32 =
  ## Returns units of the theme's spacing metric.
  units * (if theme.spacing > 0: theme.spacing else: 4'f32)

proc followPreferences(theme: var Theme; preferences: platform.Preferences) =
  if preferences.accent.a > 0:
    let platformAccent = preferences.accent
    var accent = Color(r: platformAccent.r, g: platformAccent.g,
                       b: platformAccent.b, a: platformAccent.a)
    accent.a = 255
    let black = rgb(0, 0, 0)
    let white = rgb(255, 255, 255)
    theme.accent = accent
    if theme.dark:
      theme.accentHover = accent.mix(white, 0.2'f32)
      theme.accentPressed = accent.mix(black, 0.15'f32)
      theme.selection = accent.alpha(0.4'f32)
      theme.focus = accent.mix(white, 0.2'f32).alpha(0.6'f32)
    else:
      theme.accentHover = accent.mix(black, 0.12'f32)
      theme.accentPressed = accent.mix(black, 0.25'f32)
      theme.selection = accent.alpha(0.25'f32)
      theme.focus = accent.alpha(0.55'f32)
    let luma = 0.2126'f32 * accent.r.float32 +
      0.7152'f32 * accent.g.float32 + 0.0722'f32 * accent.b.float32
    theme.accentText = if luma > 165'f32: rgb(24, 24, 27) else: white

  if preferences.highContrast:
    theme.border = theme.border.mix(theme.text, 0.45'f32)
    theme.textMuted = theme.textMuted.mix(theme.text, 0.4'f32)
    theme.focus.a = 255
    theme.scrollbar = theme.scrollbar.alpha(1.6'f32)

  let scale = preferences.textScale
  if scale > 0 and classify(scale) notin {fcNan, fcInf, fcNegInf} and
      scale != 1:
    theme.fontSize *= scale
