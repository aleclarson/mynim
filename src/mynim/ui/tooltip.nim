## Timed hover and keyboard-focus tooltips.

const
  tooltipDelay = initDuration(milliseconds = 600)
  tooltipWarm = initDuration(milliseconds = 400)

proc tooltipDepth(owner: ElementOwner; slot: int): int =
  var current = slot
  while current > 0 and current < owner.nodes.len:
    inc result
    current = int(owner.nodes[current].parent)

proc tooltip*(e: Element; value: string): Element =
  ## Shows value above e after a short hover, or immediately on keyboard focus.
  ## Escape or activating e hides the tooltip until the pointer and focus leave.
  result = e
  let node = e.node
  if node == nil:
    return
  node.tooltipText = value
  node.tooltipEnabled = value.len > 0
  node.tooltipBuild = nil
  if value.len > 0 and node.accessDescription.len == 0:
    node.accessDescription = value

proc tooltipBase*(c: Context; anchor: Element;
                  build: proc(tip: Element) {.closure.}): Element =
  ## Registers a custom tooltip builder on anchor, with the standard timing.
  result = anchor
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild or
      anchor.owner != c.owner:
    return
  let node = anchor.node
  if node == nil:
    return
  node.tooltipText.setLen(0)
  node.tooltipEnabled = build != nil
  node.tooltipBuild = build

proc buildTooltips(c: Context) =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  let owner = c.owner
  let now = owner.frameNow
  var hoverSlot = -1
  var focusSlot = -1
  var hoverDepth = -1
  var focusDepth = -1
  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    if not node.tooltipEnabled or owner.effectivelyDisabled(slot):
      continue
    let depth = owner.tooltipDepth(slot)
    if node.hovered and depth > hoverDepth:
      hoverSlot = slot
      hoverDepth = depth
    if node.focused and node.focusVisible and depth > focusDepth:
      focusSlot = slot
      focusDepth = depth

  var state = addr owner.tooltips
  let hoverId = if hoverSlot >= 0: owner.nodes[hoverSlot].identity else: 0'u64
  let focusId = if focusSlot >= 0: owner.nodes[focusSlot].identity else: 0'u64
  if state.hover != hoverId:
    state.hover = hoverId
    state.hoverSince = now
  if state.focus != focusId:
    state.focus = focusId
    state.focusSince = now
  if state.shown != 0:
    state.lastShown = now
  if state.dismissed != hoverId and state.dismissed != focusId:
    state.dismissed = 0
  if hoverSlot >= 0 and
      (owner.nodes[hoverSlot].pressed or owner.nodes[hoverSlot].clicked):
    state.dismissed = hoverId
  if focusSlot >= 0 and
      (owner.nodes[focusSlot].pressed or owner.nodes[focusSlot].clicked):
    state.dismissed = focusId
  if state.dismissed == hoverId:
    hoverSlot = -1
  if state.dismissed == focusId:
    focusSlot = -1

  state.shown = 0
  var shownSlot = -1
  let focusWins = focusSlot >= 0 and
    (hoverSlot < 0 or state.focusSince >= state.hoverSince)
  if focusWins:
    shownSlot = focusSlot
  elif hoverSlot >= 0:
    if now - state.hoverSince >= tooltipDelay or
        (state.lastShown != MonoTime() and
         state.hoverSince - state.lastShown <= tooltipWarm):
      shownSlot = hoverSlot
    else:
      owner.animating = true

  if shownSlot < 0:
    return
  state.shown = owner.nodes[shownSlot].identity
  let value = owner.nodes[shownSlot].tooltipText
  let buildTip = owner.nodes[shownSlot].tooltipBuild
  let previousParent = owner.parent
  owner.parent = int32(shownSlot)
  try:
    let overlay = c.row().absolute().left(0).right(0)
      .bottomPercent(100).justify(Align.Center)
    let overlayNode = overlay.node
    if overlayNode != nil:
      overlayNode.tooltipOverlay = true
      overlayNode.passThrough = true
      overlayNode.tooltipGap = c.theme.space(1.5)
    if buildTip != nil:
      discard overlay.children(proc() =
        let tip = c.box()
        let tipNode = tip.node
        if tipNode != nil:
          tipNode[].accessRole = platform.roleTooltip
          tipNode[].accessRoleSet = true
        buildTip(tip)
      )
    else:
      discard overlay.children(proc() =
        let tip = c.box().maxWidth(c.theme.space(80))
          .padding(c.theme.space(1.25), c.theme.space(2))
          .background(c.theme.text).textColor(c.theme.background)
          .radius(c.theme.space(1.25))
          .shadow(0, 2, 8, 0, rgba(0, 0, 0, 0.2'f32))
        let tipNode = tip.node
        if tipNode != nil:
          tipNode[].accessRole = platform.roleTooltip
          tipNode[].accessRoleSet = true
        discard tip.children(proc() =
          let label = c.text(value).maxWidth(c.theme.space(80))
          let labelNode = label.node
          if labelNode != nil:
            labelNode[].textStyle.size = max(c.theme.fontSize - 1, 1'f32)
        )
      )
  finally:
    owner.parent = previousParent
