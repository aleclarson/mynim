## Resizable horizontal and vertical pane pairs.

proc splitBase(c: Context; size: var float32;
               first, second: proc() {.closure.};
               vertical: bool): Element =
  let theme = c.theme
  let minPane = theme.space(10)
  let grip = theme.space(1.5)
  let step = theme.space(2.5)
  let sizePtr = addr size
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
  let initialSize = max(float32(sizePtr[]), minPane)
  let maxSize = if previousTotal > 0:
      max(previousTotal - 1 - minPane, minPane)
    else:
      initialSize
  var frameSize = float64(sizePtr[])

  discard root.children(proc() =
    let inner = if vertical:
        c.column().grow(1).minHeight(0).alignItems(Align.Stretch)
      else:
        c.row().grow(1).minWidth(0).alignItems(Align.Stretch)
    discard inner.children(proc() =
      let firstPane = c.box().shrink(0).clip()
      discard firstPane.children(first)

      let divider = c.box().shrink(0).background(theme.border)
      if vertical:
        discard divider.height(1)
      else:
        discard divider.width(1)

      let secondPane = c.box().grow(1).shrink(1).clip()
      if vertical:
        discard secondPane.minHeight(0)
      else:
        discard secondPane.minWidth(0)
      discard secondPane.children(second)

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
        discard divider.widthPercent(100)
          .top(0)
        discard handle.left(0).right(0)
          .top(frameSize.float32 - (grip - 1) / 2).height(grip)
          .vertical()
      else:
        discard divider.heightPercent(100)
        discard handle.top(0).bottom(0)
          .startInset(frameSize.float32 - (grip - 1) / 2).width(grip)

      discard divider.background(if handle.pressed() or handle.hovered():
        theme.accent else: theme.border)
      if handle.changed():
        sizePtr[] = float32(frameSize)
        root.markBoundValueChanged()
      if vertical:
        discard firstPane.height(float32(frameSize))
      else:
        discard firstPane.width(float32(frameSize))
    )
  )

proc split*(c: Context; size: var float32;
            first, second: proc() {.closure.}): Element =
  ## Places first and second side by side, separated by a draggable divider.
  ## Size is the first pane's width; in right-to-left layouts it is on the right.
  c.splitBase(size, first, second, vertical = false)

proc splitVertical*(c: Context; size: var float32;
                    first, second: proc() {.closure.}): Element =
  ## Places first above second, with size setting the first pane's height.
  c.splitBase(size, first, second, vertical = true)
