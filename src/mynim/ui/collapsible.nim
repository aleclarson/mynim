## Animated disclosure and accordion controls.

type
  CollapsibleParts* = object ## Trigger and animated panel of a disclosure.
    triggerElement: Element
    context: Context
    open: bool
    progressValue: float32

proc trigger*(parts: CollapsibleParts): Element =
  ## Returns the disclosure trigger so its contents and style can be set.
  parts.triggerElement

proc progress*(parts: CollapsibleParts): float32 =
  ## Reports the panel's opening progress, from zero to one.
  parts.progressValue

proc lastBounds(e: Element): Rect =
  let node = e.node
  if node != nil:
    result = e.owner.lastBounds.getOrDefault(node.identity)

proc panel*(parts: CollapsibleParts;
            build: proc() {.closure.}): Element =
  ## Builds the panel while open or animating closed, returning its content.
  if parts.context == nil or
      (not parts.open and parts.progressValue == 0):
    return
  let clip = parts.context.column().shrink(0).clipY()
  var inner: Element
  discard clip.children(proc() =
    inner = parts.context.column().shrink(0)
    discard inner.children(build)
  )
  result = inner
  let node = inner.node
  if node != nil:
    inner.owner.trackedBounds.incl(node.identity)
  if parts.progressValue < 1:
    discard clip.height(parts.progressValue * inner.lastBounds().h)

proc collapsibleBase*(c: Context; open: var bool): CollapsibleParts =
  ## Creates a disclosure trigger without a look and its animated panel.
  let trigger = c.buttonBase()
  let node = trigger.node
  var progress = if open: 1'f32 else: 0'f32
  if node != nil:
    node.accessRole = platform.roleDisclosure
    node.accessRoleSet = true
    if node.clicked:
      open = not open
      trigger.markBoundValueChanged()
    if open:
      node.accessExtraStates =
        node.accessExtraStates or platform.accessExpanded
    progress = trigger.animate("open", if open: 1'f32 else: 0'f32,
      initDuration(milliseconds = 200))
  CollapsibleParts(triggerElement: trigger, context: c, open: open,
    progressValue: progress)

proc collapsible*(c: Context; label: string; open: var bool;
                  build: proc() {.closure.}): Element =
  ## Creates a disclosure with an animated arrow and panel.
  let theme = c.theme
  result = c.column().shrink(0)
  let root = result
  var frameOpen = open
  discard root.children(proc() =
    let parts = c.collapsibleBase(frameOpen)
    let trigger = parts.trigger().alignSelf(Align.Start)
      .alignItems(Align.Center).gap(theme.space(1))
      .padding(theme.space(1), 0).paddingStart(theme.space(0.5))
      .paddingEnd(theme.space(2)).radius(theme.radius).label(label)
    if trigger.hovered():
      discard trigger.background(theme.surfaceHover)
    discard trigger.children(proc() =
      let arrow = if parts.progress >= 0.5'f32: "⌄"
        elif c.rightToLeft: "‹" else: "›"
      discard c.text(arrow).textColor(theme.textMuted)
      discard c.text(label)
    )
    if trigger.changed():
      root.markBoundValueChanged()
    discard parts.panel(build).padding(theme.space(1), 0)
      .paddingStart(theme.space(5.5)).gap(theme.space(2))
  )
  open = frameOpen

proc accordionKey(state: AccordionBuild; owner: ElementOwner;
                  key: platform.Key; mods: platform.Modifiers;
                  focusSlot: var int): bool =
  if state == nil or owner == nil or mods != platform.Modifiers(0) or
      focusSlot <= 0 or focusSlot >= owner.nodes.len or state.last.len == 0:
    return false
  let identity = owner.nodes[focusSlot].identity
  var at = -1
  for index, header in state.last:
    if header == identity:
      at = index
      break
  if at < 0:
    return false
  var target = -1
  case key
  of platform.keyDown:
    target = min(at + 1, state.last.high)
  of platform.keyUp:
    target = max(at - 1, 0)
  of platform.keyHome:
    target = 0
  of platform.keyEnd:
    target = state.last.high
  else:
    return false
  let targetIdentity = state.last[target]
  if not owner.idSlots.hasKey(targetIdentity):
    return false
  focusSlot = owner.idSlots[targetIdentity]
  true

proc accordion*(c: Context; build: proc() {.closure.}): Element =
  ## Creates a bordered group of independently open AccordionItems.
  let theme = c.theme
  result = c.column().radius(theme.radius).border(1, theme.border).clip()
  let node = result.node
  if node == nil:
    return
  let identity = node.identity
  var state: AccordionBuild
  new(state)
  state.last = c.accordionHeaders.getOrDefault(identity)
  let previous = c.accordion
  c.accordion = state
  try:
    discard result.children(build)
  finally:
    c.accordion = previous
  c.accordionHeaders[identity] = state.headers
  node.keyHandler = proc(key: platform.Key; mods: platform.Modifiers;
                         focusSlot: var int): bool =
    state.accordionKey(c.owner, key, mods, focusSlot)

proc accordionItem*(c: Context; title: string; open: var bool;
                    build: proc() {.closure.}): Element =
  ## Adds an independently expandable section to an Accordion.
  let theme = c.theme
  result = c.column().shrink(0)
  let item = result
  let state = c.accordion
  if state != nil and state.headers.len > 0:
    discard item.borderWidth(1, 0, 0, 0).borderColor(theme.border)
  var frameOpen = open
  discard item.children(proc() =
    let parts = c.collapsibleBase(frameOpen)
    let trigger = parts.trigger().alignItems(Align.Center)
      .gap(theme.space(2)).padding(theme.space(2.5), theme.space(3))
      .label(title)
    if trigger.node != nil and state != nil:
      state.headers.add(trigger.node.identity)
    if trigger.hovered():
      discard trigger.background(theme.surfaceHover)
    discard trigger.children(proc() =
      discard c.text(title).grow(1).textWeight(500)
      let arrow = if parts.progress >= 0.5'f32: "⌄"
        elif c.rightToLeft: "‹" else: "›"
      discard c.text(arrow).textColor(theme.textMuted)
    )
    if trigger.changed():
      item.markBoundValueChanged()
    discard parts.panel(build).padding(0, theme.space(3),
      theme.space(3), theme.space(3))
      .gap(theme.space(2))
  )
  open = frameOpen
