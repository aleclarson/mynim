## Frame scope and checked handles for elements in the current UI pass.

type
  Context* = ref ContextObj ## Stable context for one window's UI builds.

  ContextObj = object
    owner: ElementOwner

  ElementOwner = ref object
    nodes: seq[ElementNode]
    generation: uint32
    parent: int32
    inBuild: bool
    closed: bool

  Element* = object
    ## A checked 16-byte handle on 64-bit targets; it expires after its build callback.
    owner: ElementOwner
    slot: uint32
    generation: uint32

  ElementNode = object
    parent, firstChild, lastChild, nextSibling: int32
    row: bool

proc newContext*(): Context =
  ## Creates a stable context. Call close when its owner shuts down.
  new(result)
  new(result.owner)

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
  c.owner.nodes.add(ElementNode(parent: c.owner.parent, firstChild: -1,
                                lastChild: -1, nextSibling: -1, row: row))
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
    c.owner.closed = true
    new(c.owner)
  inc c.owner.generation
  c.owner.nodes.setLen(0)
  c.owner.nodes.add(ElementNode(parent: -1, firstChild: -1,
                                lastChild: -1, nextSibling: -1))
  c.owner.parent = 0
  c.owner.inBuild = true
  try:
    if view != nil:
      view(c)
  finally:
    c.owner.inBuild = false
    c.owner.parent = -1

proc close*(c: Context) =
  ## Detaches saved handles and releases frame storage when the context closes.
  if c == nil or c.owner.closed:
    return
  c.owner.closed = true
  c.owner.inBuild = false
  c.owner.parent = -1
  c.owner.nodes.setLen(0)
