## An animated activity indicator with an unknown completion time.

proc buildSpinnerFrames(): array[12, Svg] =
  for lead in 0..<12:
    var data = """<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">"""
    for spoke in 0..<12:
      let age = (lead - spoke + 12) mod 12
      let alpha = 1.0 - float64(age) / 12.0 * 0.85
      data.add("<path d=\"M50 28 L50 4\" transform=\"rotate(" &
        $(spoke * 30) & " 50 50)\" fill=\"none\" stroke=\"currentColor\" " &
        "stroke-width=\"9\" stroke-linecap=\"round\" stroke-opacity=\"" &
        formatFloat(alpha, ffDecimal, 3) & "\"/>")
    data.add("</svg>")
    let parsed = parseSvg(data)
    if parsed.error.len > 0:
      raise newException(ValueError, "ui: could not parse spinner SVG")
    result[lead] = parsed.svg

let spinnerFrames = buildSpinnerFrames()
let spinnerEpoch = getMonoTime()

proc spinner*(c: Context): Element =
  ## Creates an unknown-length progress indicator. It uses the muted text
  ## color by default; call `svgColor` on the result to choose another color.
  ## Reduced motion keeps a static spoke pattern.
  let theme = c.theme
  let frame = if c.owner.reduceMotion: 0 else:
      int(((c.owner.frameNow - spinnerEpoch).inMilliseconds div 75) mod 12)
  result = c.svg(spinnerFrames[frame])
    .size(theme.fontSize * 1.25'f32, theme.fontSize * 1.25'f32)
    .shrink(0).svgColor(theme.textMuted)
  let node = result.node
  if node != nil:
    node.accessRole = platform.roleProgress
    node.accessRoleSet = true
    node.hasAccessRange = true
    node.accessMin = 0
    node.accessMax = 1
    node.accessNow = -1
  if not c.owner.reduceMotion:
    c.owner.animating = true
