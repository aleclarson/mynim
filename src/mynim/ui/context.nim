## Frame scope and checked handles for elements in the current UI pass.

type
  Context* = ref ContextObj ## Stable context for one window's UI builds.

  ContextObj = object
    owner: ElementOwner

  ElementOwner = ref object
    nodes: seq[ElementNode]
    natural: seq[NaturalSize]
    rectScratch: seq[Rect]
    flexSizes, flexBases, flexMin, flexMax, flexFactors: seq[float32]
    generation: uint32
    parent: int32
    inBuild: bool
    hasFrame: bool
    closed: bool

  UiLengthKind = enum
    lengthAuto, lengthPixels, lengthPercent

  UiLength = object
    value: float32
    kind: UiLengthKind

  NaturalSize = object
    w, h: float32

  Element* = object
    ## A checked 16-byte handle on 64-bit targets; it expires after its build callback.
    owner: ElementOwner
    slot: uint32
    generation: uint32

  ElementNode = object
    parent, firstChild, lastChild, nextSibling: int32
    row: bool
    hasText: bool
    textValue: string
    textStyle: textStack.Style
    textColor: Color
    shapedText: textStack.Layout
    clickHandler: proc() {.closure.}
    width, height, minW, minH, maxW, maxH, basis: UiLength
    grow, shrink: float32
    pad, margin: array[4, float32]
    gapX, gapY: float32
    justify, align, selfAlign: Align
    background, borderColor: Color
    radius, border: array[4, float32]
    borderStyle: BorderStyle

  LayoutResult* = object
    ## Snapshot bounds calculated from a completed build.
    root*: Rect
    owner: ElementOwner
    generation: uint32
    rects: seq[Rect]

proc newContext*(): Context =
  ## Creates a stable context. Call close when its owner shuts down.
  new(result)
  new(result.owner)

proc retire(owner: ElementOwner) =
  owner.closed = true
  owner.inBuild = false
  owner.hasFrame = false
  owner.parent = -1
  owner.nodes = @[]
  owner.natural = @[]
  owner.rectScratch = @[]
  owner.flexSizes = @[]
  owner.flexBases = @[]
  owner.flexMin = @[]
  owner.flexMax = @[]
  owner.flexFactors = @[]

proc node(e: Element): ptr ElementNode =
  if e.owner == nil or e.owner.closed or not e.owner.inBuild or
      e.generation != e.owner.generation or int(e.slot) >= e.owner.nodes.len:
    return nil
  addr e.owner.nodes[int(e.slot)]

proc valid*(e: Element): bool =
  ## Reports whether e belongs to the active build callback.
  e.node != nil

proc newElement(c: Context; row: bool): Element =
  if c == nil or c.owner.closed or not c.owner.inBuild or c.owner.parent < 0:
    raise newException(ValueError, "ui: element created outside a frame build")
  if int64(c.owner.nodes.len) > int64(high(int32)):
    raise newException(ValueError, "ui: too many elements in one frame")

  let slot = uint32(c.owner.nodes.len)
  let node = ElementNode(parent: c.owner.parent, firstChild: -1,
                         lastChild: -1, nextSibling: -1, row: row,
                         shrink: 1, justify: Align.Start,
                         align: if row: Align.Center else: Align.Auto,
                         selfAlign: Align.Auto)
  c.owner.nodes.add(node)
  let p = int(c.owner.parent)
  if c.owner.nodes[p].lastChild >= 0:
    c.owner.nodes[int(c.owner.nodes[p].lastChild)].nextSibling = int32(slot)
  else:
    c.owner.nodes[p].firstChild = int32(slot)
  c.owner.nodes[p].lastChild = int32(slot)
  result = Element(owner: c.owner, slot: slot,
                   generation: c.owner.generation)

proc box*(c: Context): Element =
  ## Adds a box container to the current parent.
  c.newElement(false)

proc row*(c: Context): Element =
  ## Adds a row container to the current parent.
  c.newElement(true)

proc column*(c: Context): Element =
  ## Adds a column container to the current parent.
  c.newElement(false)

proc text*(c: Context; value: string): Element =
  ## Adds a text element using the system UI font at its natural size.
  result = c.newElement(false)
  let n = result.node
  if n != nil:
    n.hasText = true
    n.textValue = value
    n.textColor = rgb(0, 0, 0)

proc children*(e: Element; build: proc() {.closure.}): Element =
  ## Builds children with e as their parent for the duration of build.
  result = e
  if e.node == nil or build == nil:
    return
  let owner = e.owner
  let previous = owner.parent
  owner.parent = int32(e.slot)
  try:
    build()
  finally:
    owner.parent = previous

proc build*(c: Context; view: proc(c: Context) {.closure.}) =
  ## Runs one view build pass. Elements made in view expire when it returns.
  if c == nil or c.owner.closed:
    raise newException(ValueError, "ui: cannot build with a closed context")
  if c.owner.inBuild:
    raise newException(ValueError, "ui: nested frame build")
  if c.owner.generation == high(uint32):
    c.owner.retire()
    new(c.owner)
  inc c.owner.generation
  c.owner.nodes.setLen(0)
  c.owner.nodes.add(ElementNode(parent: -1, firstChild: -1,
                                lastChild: -1, nextSibling: -1,
                                shrink: 1, justify: Align.Start,
                                align: Align.Auto, selfAlign: Align.Auto))
  c.owner.parent = 0
  c.owner.inBuild = true
  c.owner.hasFrame = false
  var built = false
  try:
    if view != nil:
      view(c)
    built = true
  finally:
    c.owner.inBuild = false
    c.owner.parent = -1
    c.owner.hasFrame = built

proc close*(c: Context) =
  ## Detaches saved handles and releases frame storage when the context closes.
  if c == nil or c.owner.closed:
    return
  c.owner.retire()
