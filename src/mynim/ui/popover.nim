## Stateful anchored popovers.

proc popoverBase*(c: Context; anchor: Element; open: var bool;
                  build: proc(panel: Element) {.closure.}): Element =
  ## Shows a panel below anchor, or above when there is not enough room.
  ## Escape and presses outside the panel and anchor set open to false.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError,
      "ui: popover must be built in a frame")
  if anchor.owner != c.owner or anchor.generation != c.owner.generation or
      int(anchor.slot) <= 0 or int(anchor.slot) >= c.owner.nodes.len:
    raise newException(ValueError,
      "ui: popover anchor must belong to the current frame")

  let anchorNode = addr c.owner.nodes[int(anchor.slot)]
  anchorNode[].popoverAnchor = true
  let identity = anchorNode[].identity
  var state = c.owner.popoverStates.getOrDefault(identity)
  if state == nil:
    state = PopoverState(anchorIdentity: identity)
    c.owner.popoverStates[identity] = state
  if state.pendingDismiss:
    state.pendingDismiss = false
    state.open = false
    open = false
  else:
    state.open = open
  if not state.open:
    return

  let gap = c.theme.space(1)
  result = c.overlay(anchor, proc(panel: Element) =
    let node = panel.node
    if node != nil:
      node[].popoverState = state
      node[].accessRole = platform.rolePopup
      node[].accessRoleSet = true
      node[].overlayGap = gap
    if build != nil:
      build(panel)
  )

proc popover*(c: Context; anchor: Element; open: var bool;
              build: proc(panel: Element) {.closure.}): Element =
  ## Shows a themed panel below anchor and closes it on Escape or outside press.
  let theme = c.theme
  result = c.popoverBase(anchor, open, proc(panel: Element) =
    discard panel.padding(theme.space(2)).radius(theme.radius)
      .background(theme.background).border(1, theme.border)
      .shadow(0, 4, 14, 0, rgba(0, 0, 0, 0.22'f32))
    if build != nil:
      build(panel)
  )
