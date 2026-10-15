## Reading direction and logical horizontal edges.

proc setDirection(nodes: var seq[ElementNode]; slot: int; rightToLeft,
                  explicit: bool) =
  let wasRightToLeft = nodes[slot].rightToLeft
  if explicit:
    nodes[slot].directionSet = true
  if wasRightToLeft == rightToLeft:
    return

  nodes[slot].swapLogical()
  nodes[slot].rightToLeft = rightToLeft
  var child = int(nodes[slot].firstChild)
  while child >= 0:
    let next = int(nodes[child].nextSibling)
    if not nodes[child].directionSet:
      setDirection(nodes, child, rightToLeft, false)
    child = next

proc direction*(c: Context): Direction =
  ## Returns the direction inherited by elements built at the current parent.
  if c == nil:
    return Direction.LeftToRight
  if c.owner != nil and c.owner.inBuild and c.owner.parent >= 0 and
      c.owner.parent < int32(c.owner.nodes.len):
    if c.owner.nodes[int(c.owner.parent)].rightToLeft:
      return Direction.RightToLeft
    return Direction.LeftToRight
  if c.rightToLeft: Direction.RightToLeft else: Direction.LeftToRight

proc direction*(e: Element; value: Direction): Element =
  ## Sets the direction for e and the descendants that inherit from it.
  result = e
  let n = e.node
  if n != nil:
    e.owner.nodes.setDirection(int(e.slot), value == Direction.RightToLeft,
      true)

proc paddingStart*(e: Element; value: float32): Element =
  ## Sets padding at the inline start edge: left in LTR, right in RTL.
  result = e
  let n = e.node
  if n != nil:
    n.pad[n[].startSide] = value
    n.logical = n.logical or logPadStart

proc paddingEnd*(e: Element; value: float32): Element =
  ## Sets padding at the inline end edge: right in LTR, left in RTL.
  result = e
  let n = e.node
  if n != nil:
    n.pad[n[].endSide] = value
    n.logical = n.logical or logPadEnd

proc marginStart*(e: Element; value: float32): Element =
  ## Sets margin at the inline start edge: left in LTR, right in RTL.
  result = e
  let n = e.node
  if n != nil:
    n.margin[n[].startSide] = value
    n.logical = n.logical or logMarginStart

proc marginEnd*(e: Element; value: float32): Element =
  ## Sets margin at the inline end edge: right in LTR, left in RTL.
  result = e
  let n = e.node
  if n != nil:
    n.margin[n[].endSide] = value
    n.logical = n.logical or logMarginEnd

proc borderStartWidth*(e: Element; value: float32): Element =
  ## Sets border width at the inline start edge.
  result = e
  let n = e.node
  if n != nil:
    n.border[n[].startSide] = max(value, 0'f32)
    n.logical = n.logical or logBorderStart

proc borderEndWidth*(e: Element; value: float32): Element =
  ## Sets border width at the inline end edge.
  result = e
  let n = e.node
  if n != nil:
    n.border[n[].endSide] = max(value, 0'f32)
    n.logical = n.logical or logBorderEnd

proc startInset*(e: Element; value: float32): Element =
  ## Sets the inline-start inset, or moves an in-flow element from that edge.
  result = e
  let n = e.node
  if n != nil:
    let side = n[].startSide
    n.inset[side] = pixels(value)
    n.logical = n.logical or logInsetStart

proc endInset*(e: Element; value: float32): Element =
  ## Sets the inline-end inset, or moves an in-flow element from that edge.
  result = e
  let n = e.node
  if n != nil:
    let side = n[].endSide
    n.inset[side] = pixels(value)
    n.logical = n.logical or logInsetEnd

proc startPercent*(e: Element; value: float32): Element =
  ## Sets the inline-start inset as a percentage of the parent's width.
  result = e
  let n = e.node
  if n != nil:
    let side = n[].startSide
    n.inset[side] = percent(value)
    n.logical = n.logical or logInsetStart

proc endPercent*(e: Element; value: float32): Element =
  ## Sets the inline-end inset as a percentage of the parent's width.
  result = e
  let n = e.node
  if n != nil:
    let side = n[].endSide
    n.inset[side] = percent(value)
    n.logical = n.logical or logInsetEnd
