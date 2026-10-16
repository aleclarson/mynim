## A themed meter for values with a known range.

type MeterLevels* = object ## Thresholds where a value becomes warning/critical.
  warning*, critical*: float64

proc meter*(c: Context; value, low, high: float64;
            levels = MeterLevels()): Element =
  ## Shows value between low and high, using threshold colors when configured.
  ## Set a label for assistive technology. Equal thresholds disable level colors.
  for number in [value, low, high, levels.warning, levels.critical]:
    if classify(number) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "ui: meter values must be finite")
  if low > high:
    raise newException(ValueError, "ui: meter low must not exceed high")

  let theme = c.theme
  let fraction = if high <= low: 0'f32
    else: float32(min(max((value - low) / (high - low), 0'f64), 1'f64))
  var color = theme.success
  if levels.warning != levels.critical:
    let lowIsBad = levels.critical < levels.warning
    if (not lowIsBad and value >= levels.critical) or
        (lowIsBad and value <= levels.critical):
      color = theme.danger
    elif (not lowIsBad and value >= levels.warning) or
        (lowIsBad and value <= levels.warning):
      color = theme.warning

  let radius = theme.space(1)
  result = c.box().height(theme.space(2)).minWidth(theme.space(20))
    .radius(radius).background(theme.border).clip()
  let node = result.node
  if node != nil:
    node.accessRole = platform.roleMeter
    node.accessRoleSet = true
    node.hasAccessRange = true
    node.accessMin = low
    node.accessMax = high
    node.accessNow = value
  let rtl = c.direction() == Direction.RightToLeft
  discard result.children(proc() =
    discard c.box().absolute()
      .leftPercent((if rtl: 1'f32 - fraction else: 0'f32) * 100)
      .top(0).widthPercent(fraction * 100).heightPercent(100)
      .radius(radius).background(color)
  )
