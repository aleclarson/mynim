## A compact spin button with repeatable increment and decrement controls.

proc stepperChevron(data: string): Svg =
  let parsed = parseSvg(data)
  if parsed.error.len > 0:
    raise newException(ValueError, "ui: could not parse stepper chevron SVG")
  parsed.svg

let stepperUpChevron = stepperChevron("""
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16" viewBox="0 0 24 16">
  <path d="M6 10 12 4 18 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
""")

let stepperDownChevron = stepperChevron("""
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16" viewBox="0 0 24 16">
  <path d="M6 6 12 12 18 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
""")

proc applyStepperRepeats(e: Element; identity: uint64; direction: int;
                         value: var float64) =
  let owner = e.owner
  let node = e.node
  if owner == nil or node == nil:
    return

  var state = owner.stepperRepeats.getOrDefault(identity)
  if not state.initialized or state.direction != int8(direction):
    state = StepperRepeat(started: owner.frameNow,
      direction: int8(direction), initialized: true)

  let elapsed = (owner.frameNow - state.started).inNanoseconds
  var due = 1'i64
  if elapsed > 400_000_000'i64:
    due += (elapsed - 400_000_000'i64) div 80_000_000'i64
  let additional = due - state.repeats
  if additional > 0:
    let low = node[].sliderLow
    let high = node[].sliderHigh
    let step = node[].sliderStep
    let delta = float64(direction) * step
    let first = snapSliderValue(value + delta, low, high, step)
    var next = first
    if additional > 1:
      let range = high - low
      let amount = min(range, step * float64(additional - 1))
      if amount >= range:
        next = if direction > 0: high else: low
      else:
        next = snapSliderValue(first + float64(direction) * amount,
          low, high, step)
    if next != value:
      value = next
      node[].sliderValue = next
      e.markBoundValueChanged()
    state.repeats = due

  let canContinue = if direction > 0: value < node[].sliderHigh
    else: value > node[].sliderLow
  if canContinue:
    owner.animating = true
    owner.otherAnimating = true
    owner.stepperRepeats[identity] = state
  else:
    owner.stepperRepeats.del(identity)

proc stepper*(c: Context; value: var float64; low, high, step: float64): Element =
  ## Creates a spin button. Up/Down and the direction-aware horizontal arrows
  ## change the value; Home and End select the range endpoints. Holding either
  ## arrow repeats after a short delay. Label it for assistive technology.
  if classify(step) in {fcNan, fcInf, fcNegInf} or step <= 0:
    raise newException(ValueError, "ui: stepper step must be finite and positive")
  var frameValue = value
  result = c.sliderBase(frameValue, low, high).step(step)
  let root = result.node
  if root == nil:
    return
  let identity = root[].identity
  root[].stepper = true
  root[].accessRole = platform.roleStepper
  root[].accessRoleSet = true

  let theme = c.theme
  result = result.width(theme.space(5)).height(theme.space(7))
    .shrink(0).radius(theme.radius).border(1, theme.border)
    .background(theme.surface).clip()
  let control = result
  var arrows: array[2, Element]
  discard control.children(proc() =
    for index, up in [true, false]:
      let canStep = if up: frameValue < high else: frameValue > low
      var arrow = c.box().fillWidth().height(theme.space(3.5))
        .shrink(0).center()
      arrows[index] = arrow
      let hovered = arrow.hovered()
      let pressed = arrow.pressed()
      discard arrow.background(
        if pressed: theme.surfacePressed
        elif hovered: theme.surfaceHover
        else: rgba(0, 0, 0, 0)
      )
      discard arrow.children(proc() =
        discard c.svg(if up: stepperUpChevron else: stepperDownChevron)
          .size(theme.space(2.5), theme.space(2))
          .svgColor(if canStep: theme.text else: theme.textMuted.alpha(0.5'f32))
      )
  )

  let upPressed = arrows[0].pressed()
  let downPressed = arrows[1].pressed()
  if upPressed and not downPressed:
    control.applyStepperRepeats(identity, 1, frameValue)
  elif downPressed and not upPressed:
    control.applyStepperRepeats(identity, -1, frameValue)
  else:
    c.owner.stepperRepeats.del(identity)
  if control.changed():
    value = frameValue
