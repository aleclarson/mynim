## A bounded numeric field with keyboard and button stepping.

proc formattedNumberInput(value: float64; decimals: int): string =
  formatFloat(value, ffDecimal, decimals)

proc numberInputDecimals(step: float64): int =
  for decimals in 0..15:
    try:
      if parseFloat(formatFloat(step, ffDecimal, decimals)) == step:
        return decimals
    except ValueError:
      discard
  15

proc roundedNumberInput(value: float64; decimals: int): float64 =
  result = value
  try:
    result = parseFloat(formattedNumberInput(value, decimals))
  except ValueError:
    discard

proc boundedNumberInput(value, low, high: float64;
                        decimals: int): float64 =
  if value <= low:
    return low
  if value >= high:
    return high
  result = value
  result = roundedNumberInput(result, decimals)
  result = min(max(result, low), high)

proc setNumberInputValue(value: var float64; state: NumberInputState;
                         row: Element; nextValue, low, high: float64;
                         decimals: int; rewriteText: bool) =
  let next = boundedNumberInput(nextValue, low, high, decimals)
  if next == value:
    if rewriteText:
      state.text = formattedNumberInput(value, decimals)
    return
  value = next
  state.lastValue = next
  state.hasPendingValue = false
  if rewriteText:
    state.text = formattedNumberInput(next, decimals)
  row.markBoundValueChanged()

proc numberInput*(c: Context; value: var float64; low, high,
                  step: float64): Element =
  ## Creates a text field constrained to a range, with Up/Down and step buttons.
  if classify(low) in {fcNan, fcInf, fcNegInf} or
      classify(high) in {fcNan, fcInf, fcNegInf} or
      classify(value) in {fcNan, fcInf, fcNegInf} or
      classify(step) in {fcNan, fcInf, fcNegInf} or
      low > high or step <= 0 or
      classify(high - low) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError,
      "ui: number input values and range must be finite and ordered")

  let theme = c.theme
  let decimals = numberInputDecimals(step)
  let valuePtr = addr value
  result = c.row().gap(theme.space(1)).shrink(0)
    .alignItems(Align.Center)
  let row = result
  let rowNode = row.node
  if rowNode == nil:
    return
  rowNode[].numberInput = true
  let identity = rowNode[].identity
  let owner = c.owner
  var state = owner.numberInputStates.getOrDefault(identity)
  if state == nil:
    new(state)
    state.text = formattedNumberInput(value, decimals)
    state.lastValue = value
    owner.numberInputStates[identity] = state
  if state.hasPendingValue:
    value = state.pendingValue
    state.lastValue = value
    state.hasPendingValue = false
    row.markBoundValueChanged()
  elif state.lastValue != value:
    state.text = formattedNumberInput(value, decimals)
    state.lastValue = value

  discard row.children(proc() =
    let input = c.textInput(state.text).width(theme.space(20))
    let inputNode = input.node
    if inputNode == nil:
      return
    row.node[].labelTargetSlot = int32(input.slot)
    inputNode[].accessRole = platform.roleStepper
    inputNode[].accessRoleSet = true
    inputNode[].hasAccessRange = true
    inputNode[].accessMin = low
    inputNode[].accessMax = high
    inputNode[].accessNow = valuePtr[]
    inputNode[].accessStep = step

    inputNode[].accessStepHandler = proc(delta: float64) =
      let base = if state.hasPendingValue: state.pendingValue
        else: state.lastValue
      let next = boundedNumberInput(base + delta, low, high, decimals)
      if next != base:
        state.pendingValue = next
        state.hasPendingValue = true
        state.text = formattedNumberInput(next, decimals)

    if input.changed():
      try:
        let parsed = parseFloat(state.text.strip())
        if classify(parsed) notin {fcNan, fcInf, fcNegInf} and
            parsed >= low and parsed <= high:
          setNumberInputValue(valuePtr[], state, row, parsed, low, high,
            decimals, false)
      except ValueError:
        discard
    if not input.focused():
      state.text = formattedNumberInput(valuePtr[], decimals)
      state.lastValue = valuePtr[]

    for (delta, label) in [(-1'f64, "Decrease"), (1'f64, "Increase")]:
      let buttonGlyph = if delta < 0: "−" else: "+"
      let isDisabled = if delta < 0: valuePtr[] <= low
        else: valuePtr[] >= high
      var button = c.buttonBase().padding(theme.space(1), theme.space(2))
        .radius(theme.radius).label(label)
      let buttonNode = button.node
      if buttonNode != nil:
        buttonNode[].disabled = isDisabled
      let pressed = button.pressed()
      let hovered = button.hovered()
      discard button.background(if pressed: theme.surfacePressed
        elif hovered: theme.surfaceHover else: theme.surface)
        .border(1, theme.border)
      discard button.children(proc() =
        let symbol = c.text(buttonGlyph).textColor(theme.text)
        let symbolNode = symbol.node
        if symbolNode != nil:
          symbolNode[].accessHidden = true
      )
      if button.clicked():
        setNumberInputValue(valuePtr[], state, row, valuePtr[] + delta * step,
          low, high, decimals, true)
  )
