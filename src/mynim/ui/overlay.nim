## Anchored UI overlays above the window's regular content.

proc overlay*(c: Context; anchor: Element;
              build: proc(panel: Element) {.closure.}): Element =
  ## Builds panel above the window content, aligned to anchor's start edge.
  ## It opens below the anchor when there is room, otherwise above it.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: overlay must be built in a frame")
  if anchor.owner != c.owner or anchor.generation != c.owner.generation or
      int(anchor.slot) <= 0 or int(anchor.slot) >= c.owner.nodes.len:
    raise newException(ValueError,
      "ui: overlay anchor must belong to the current frame")

  let owner = c.owner
  let anchorNode = owner.nodes[int(anchor.slot)]
  let previousParent = owner.parent
  owner.parent = 0
  try:
    let panel = c.box().absolute()
    result = panel
    let node = panel.node
    if node != nil:
      node[].overlayAnchorIdentity = anchorNode.identity
      node[].rightToLeft = anchorNode.rightToLeft
    if build != nil:
      discard panel.children(proc() = build(panel))
  finally:
    owner.parent = previousParent
