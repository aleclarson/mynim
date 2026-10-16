## Determinate and indeterminate progress bars.

proc progress*(c: Context; value: float64; reverse = false): Element =
  ## Fills from zero to value in [0, 1]. A negative value shows activity.
  ## `reverse` fills from the direction's opposite end; label the bar for access.
  if classify(value) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: progress value must be finite")

  let theme = c.theme
  let radius = theme.space(0.75)
  result = c.box().fillWidth().height(theme.space(1.5))
    .radius(radius).background(theme.border).clip()
  let node = result.node
  if node != nil:
    node.accessRole = platform.roleProgress
    node.accessRoleSet = true
    node.hasAccessRange = true
    node.accessMin = 0
    node.accessMax = 1
    node.accessNow = value

  let fromRight = reverse != (c.direction() == Direction.RightToLeft)
  discard result.children(proc() =
    let bar = c.box().absolute()
    if value >= 0:
      let fraction = min(max(value, 0'f64), 1'f64).float32
      discard bar.leftPercent((if fromRight: 1'f32 - fraction else: 0'f32) * 100)
        .top(0).widthPercent(fraction * 100).heightPercent(100)
        .radius(radius).background(theme.accent)
    else:
      let phase = if c.owner.reduceMotion: 0.5'f32
        else: bar.keyframes("indeterminate-progress", [
          Keyframe(value: 0'f32),
          Keyframe(at: initDuration(milliseconds = 1400), value: 1'f32)
        ], KeyframeOptions(repeat: RepeatForever))
      let offset = if fromRight: 1'f32 - phase * 1.3'f32
        else: -0.3'f32 + phase * 1.3'f32
      discard bar.leftPercent(offset * 100).top(0)
        .widthPercent(30).heightPercent(100)
        .radius(radius).background(theme.accent)
  )
