## A pair of accessible slider thumbs that set a bounded interval.

proc rangeSliderThumb(c: Context; parent: Element; value: var float64;
                      rangeLow, rangeHigh, clampLow, clampHigh,
                      keyStep, snapStep: float64; handle: int8;
                      held: bool;
                      fraction, centerY, knobWidth, knobHeight: float32;
                      theme: Theme): Element =
  result = c.box().absolute().focusable()
  let grow = 1'f32 + 0.35'f32 * result.animate("range-slider-held",
    if held: 1'f32 else: 0'f32, initDuration(milliseconds = 150))
  let grownWidth = knobWidth * grow
  let grownHeight = knobHeight * grow
  result = result.leftPercent(fraction * 100)
    .top(centerY - grownHeight / 2).size(grownWidth, grownHeight)
    .margin(0, 0, 0, -grownWidth / 2).radius(grownHeight / 2)
    .background(theme.background).border(2, theme.border)
    .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.18'f32))
  let node = result.node
  if node == nil:
    return
  node[].slider = true
  node[].rangeSliderThumb = true
  node[].rangeSliderHandle = handle
  node[].sliderLow = rangeLow
  node[].sliderHigh = rangeHigh
  node[].sliderStep = keyStep
  node[].sliderClampLow = clampLow
  node[].sliderClampHigh = clampHigh
  node[].accessRole = platform.roleSlider
  node[].accessRoleSet = true
  node[].label = if handle == 0: "minimum" else: "maximum"

  if c.owner.pendingSliderValues.hasKey(node[].identity):
    let pending = c.owner.pendingSliderValues[node[].identity]
    let snapped = pending.snapSliderValue(rangeLow, rangeHigh, snapStep)
    let next = min(max(snapped, clampLow), clampHigh)
    if next != value:
      value = next
      parent.markBoundValueChanged()
  node[].sliderValue = value

proc rangeSlider*(c: Context; lower, upper: var float64;
                   rangeLow, rangeHigh: float64;
                   step = 0'f64): Element =
  ## Creates two slider thumbs for a bounded interval. Label the group; its
  ## thumbs are exposed as “minimum” and “maximum”. A positive step snaps
  ## pointer, keyboard, and accessibility changes to multiples from rangeLow.
  if classify(rangeLow) in {fcNan, fcInf, fcNegInf} or
      classify(rangeHigh) in {fcNan, fcInf, fcNegInf} or
      classify(lower) in {fcNan, fcInf, fcNegInf} or
      classify(upper) in {fcNan, fcInf, fcNegInf} or
      classify(step) in {fcNan, fcInf, fcNegInf} or
      rangeLow > rangeHigh or step < 0 or
      classify(rangeHigh - rangeLow) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError,
      "ui: range slider values and range must be finite and ordered")

  let first = min(lower, upper)
  let last = max(lower, upper)
  var frameLow = min(max(first, rangeLow), rangeHigh)
  var frameHigh = min(max(last, rangeLow), rangeHigh)
  let keyStep = if step > 0: step else: (rangeHigh - rangeLow) / 100
  let ticks = sliderTickCount(rangeLow, rangeHigh, step)
  let theme = c.theme
  let knobWidth = theme.space(5)
  let knobHeight = theme.space(4)
  let height = theme.space(if ticks > 0: 7 else: 5)
  let centerY = theme.space(2.5)
  let trackHeight = theme.space(1.5)
  let tickHeight = theme.space(1.5)

  result = c.box().height(height).minWidth(theme.space(25))
    .paddingX(knobWidth / 2).shrink(0)
  let root = result.node
  if root == nil:
    return
  root[].rangeSlider = true
  root[].accessRole = platform.roleGroup
  root[].accessRoleSet = true
  root[].sliderLow = rangeLow
  root[].sliderHigh = rangeHigh
  let identity = root[].identity
  let activeHandle = c.owner.rangeSliderDrags.getOrDefault(identity, -1'i8)

  let rtl = c.direction() == Direction.RightToLeft
  let lowFraction = if rangeHigh > rangeLow:
      float32((frameLow - rangeLow) / (rangeHigh - rangeLow))
    else:
      0'f32
  let highFraction = if rangeHigh > rangeLow:
      float32((frameHigh - rangeLow) / (rangeHigh - rangeLow))
    else:
      0'f32
  let visualLow = if rtl: 1'f32 - lowFraction else: lowFraction
  let visualHigh = if rtl: 1'f32 - highFraction else: highFraction
  let fillStart = min(visualLow, visualHigh)
  let fillWidth = max(visualLow, visualHigh) - fillStart

  let group = result
  discard group.children(proc() =
    discard c.box().absolute().left(0).right(0)
      .top(centerY - trackHeight / 2).height(trackHeight)
      .radius(trackHeight / 2).background(theme.border)
    discard c.box().absolute().leftPercent(fillStart * 100)
      .top(centerY - trackHeight / 2).widthPercent(fillWidth * 100)
      .height(trackHeight).radius(trackHeight / 2)
      .background(theme.accent)
    for index in 0..<ticks:
      let fraction = if ticks > 1:
          float32(index) / float32(ticks - 1)
        else:
          0'f32
      let position = if rtl: 1'f32 - fraction else: fraction
      discard c.box().absolute().leftPercent(position * 100)
        .top(centerY + knobHeight / 2 + theme.space(1))
        .size(1, tickHeight).margin(0, 0, 0, -0.5'f32)
        .background(theme.textMuted.alpha(0.6'f32))
    discard c.rangeSliderThumb(group, frameLow, rangeLow, rangeHigh,
      rangeLow, frameHigh, keyStep, step, 0, activeHandle == 0, visualLow,
      centerY, knobWidth, knobHeight, theme)
    discard c.rangeSliderThumb(group, frameHigh, rangeLow, rangeHigh,
      frameLow, rangeHigh, keyStep, step, 1, activeHandle == 1, visualHigh,
      centerY, knobWidth, knobHeight, theme)
  )

  lower = frameLow
  upper = frameHigh
