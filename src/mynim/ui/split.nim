## Resizable horizontal and vertical pane pairs.

proc fitSplit(value, total, minPane: float32): float32 =
  if total > 0:
    result = min(value, total - 1 - minPane)
  else:
    result = value
  result = max(result, minPane)

proc splitBase(c: Context; size: var float32;
               first, second: proc() {.closure.};
               vertical, inPercent: bool): Element =
  let theme = c.theme
  let minPane = theme.space(10)
  let grip = theme.space(1.5)
  let step = theme.space(2.5)
  let sizePtr = addr size
  if inPercent and classify(sizePtr[]) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError,
      "ui: split percentage must be finite")

  result = if vertical: c.column().alignItems(Align.Stretch)
    else: c.row().alignItems(Align.Stretch)
  let root = result
  let rootNode = root.node
  if rootNode == nil:
    return
  rootNode[].splitPane = true
  rootNode[].splitVertical = vertical
  let identity = rootNode[].identity
  c.owner.trackedBounds.incl(identity)

  let previousBounds = c.owner.lastBounds.getOrDefault(identity)
  let previousTotal = if vertical: previousBounds.h else: previousBounds.w
  let shareValue = if inPercent:
      min(max(sizePtr[], 0'f32), 100'f32) / 100
    else:
      0'f32
  let initialSize = if inPercent: minPane
    else: max(float32(sizePtr[]), minPane)
  let maxSize = if previousTotal > 0:
      max(previousTotal - 1 - minPane, minPane)
    else:
      initialSize
  var shown = float32(sizePtr[])
  if previousTotal > 0:
    if inPercent:
      shown = fitSplit(shareValue * (previousTotal - 1), previousTotal,
        minPane)
    elif sizePtr[] > minPane:
      shown = fitSplit(float32(sizePtr[]), previousTotal, minPane)
  elif inPercent:
    shown = minPane

  template setLength(e: Element; value: float32) =
    if vertical:
      discard e.height(value)
    else:
      discard e.width(value)

  template setMinLength(e: Element; value: float32) =
    if vertical:
      discard e.minHeight(value)
    else:
      discard e.minWidth(value)

  discard root.children(proc() =
    let inner = if vertical:
        c.column().grow(1).minHeight(0).alignItems(Align.Stretch)
      else:
        c.row().grow(1).minWidth(0).alignItems(Align.Stretch)
    discard inner.children(proc() =
      let firstPane = c.box().shrink(1).clip()
      setMinLength(firstPane, if inPercent: minPane
        else: min(float32(sizePtr[]), minPane))
      discard firstPane.children(first)

      let divider = c.box().shrink(0).background(theme.border)
      let dividerNode = divider.node
      if dividerNode != nil:
        dividerNode[].splitDivider = true
      setLength(divider, 1)

      let secondPane = c.box().grow(1).shrink(1).clip()
      setMinLength(secondPane, minPane)
      discard secondPane.children(second)

      var frameSize = float64(shown)
      var handle = c.sliderBase(frameSize, float64(minPane),
        float64(maxSize)).step(float64(step)).absolute().focusRing()
      let handleNode = handle.node
      if handleNode == nil:
        return
      handleNode[].splitHandle = true
      handleNode[].splitVertical = vertical
      handleNode[].accessRole = platform.roleSplitter
      handleNode[].accessRoleSet = true
      handle = handle.label("Divider")

      if vertical:
        discard handle.left(0).right(0).top(0).height(grip).vertical()
      else:
        discard handle.top(0).bottom(0).startInset(0).width(grip)

      discard divider.background(if handle.pressed() or handle.hovered():
        theme.accent else: theme.border)
      if handle.changed():
        if inPercent:
          if previousTotal > 1:
            let fitted = fitSplit(float32(frameSize), previousTotal, minPane)
            sizePtr[] = fitted * 100 / (previousTotal - 1)
        else:
          sizePtr[] = float32(frameSize)
        root.markBoundValueChanged()

      if inPercent:
        let share = min(max(sizePtr[], 0'f32), 100'f32) / 100
        discard firstPane.basisPercent(share * 100)
        discard firstPane.grow(share)
        discard secondPane.basisPercent((1 - share) * 100)
        discard secondPane.grow(1 - share)
      else:
        setLength(firstPane, float32(frameSize))
    )
  )

proc split*(c: Context; size: var float32;
            first, second: proc() {.closure.}): Element =
  ## Places first and second side by side, separated by a draggable divider.
  ## Size is the first pane's width; in right-to-left layouts it is on the right.
  c.splitBase(size, first, second, vertical = false, inPercent = false)

proc splitVertical*(c: Context; size: var float32;
                    first, second: proc() {.closure.}): Element =
  ## Places first above second, with size setting the first pane's height.
  c.splitBase(size, first, second, vertical = true, inPercent = false)

proc splitPercent*(c: Context; percent: var float32;
                   first, second: proc() {.closure.}): Element =
  ## Places first and second side by side, with percent of available space for
  ## first. The finite value is clamped to 0 through 100 for layout. Dragging
  ## the divider or moving it with the keyboard updates percent.
  c.splitBase(percent, first, second, vertical = false, inPercent = true)

proc splitVerticalPercent*(c: Context; percent: var float32;
                           first, second: proc() {.closure.}): Element =
  ## Places first above second, with percent of available space for first.
  ## The finite value is clamped to 0 through 100 for layout. Dragging the
  ## divider or moving it with the keyboard updates percent.
  c.splitBase(percent, first, second, vertical = true, inPercent = true)
