## UI elements built above the window's regular content.

proc overlayLayer(c: Context; logicalOwner, modalScope: uint64;
                 rightToLeft: bool;
                 build: proc(panel: Element) {.closure.}): Element =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: overlay must be built in a frame")
  let owner = c.owner
  let previousParent = owner.parent
  owner.parent = 0
  try:
    let root = c.box().absolute()
    result = root
    let node = root.node
    if node != nil:
      node[].overlayOwnerIdentity = logicalOwner
      node[].modalScopeIdentity = modalScope
      node[].rightToLeft = rightToLeft
    if build != nil:
      discard root.children(proc() = build(root))
  finally:
    owner.parent = previousParent

proc overlayLayer(c: Context;
                  build: proc(panel: Element) {.closure.}): Element =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: overlay must be built in a frame")
  let owner = c.owner
  let parentSlot = int(owner.parent)
  if parentSlot < 0 or parentSlot >= owner.nodes.len:
    raise newException(ValueError, "ui: overlay parent is invalid")
  let parent = owner.nodes[parentSlot]
  c.overlayLayer(parent.identity, parent.modalScopeIdentity,
    parent.rightToLeft, build)

proc overlay*(c: Context; anchor: Element;
              build: proc(panel: Element) {.closure.}): Element =
  ## Builds a panel on the window overlay layer, positioned from anchor.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: overlay must be built in a frame")
  if anchor.owner != c.owner or anchor.generation != c.owner.generation or
      int(anchor.slot) <= 0 or int(anchor.slot) >= c.owner.nodes.len:
    raise newException(ValueError,
      "ui: overlay anchor must belong to the current frame")

  let anchorNode = c.owner.nodes[int(anchor.slot)]
  result = c.overlayLayer(anchorNode.identity, anchorNode.modalScopeIdentity,
    anchorNode.rightToLeft, build)
  let node = result.node
  if node != nil:
    node[].overlayAnchorIdentity = anchorNode.identity
