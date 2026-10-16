## Modal dialogs and alerts built on the window overlay layer.

const
  AlertDismissed* = -2
  dialogDismissedSlot = 1'u32 shl 31
  dialogIdentitySalt = 0xD1A1095E8B3C7F21'u64

proc modal*(e: Element): Element =
  ## Keeps keyboard focus, shortcuts, pointers and accessibility in this layer.
  result = e
  let node = e.node
  if node != nil:
    node[].modal = true
    node[].modalScopeIdentity = node[].identity
    e.owner.activeModalIdentity = node[].identity

proc dismissed*(e: Element): bool =
  ## Reports whether this dialog closed in the frame that returned it.
  if e.owner == nil or e.owner.closed or
      e.generation != e.owner.generation:
    return false
  if e.slot == dialogDismissedSlot:
    return true
  let node = e.node
  node != nil and node[].dialogDismissed

proc nextDialogIdentity(c: Context): uint64 =
  let owner = c.owner
  let parentSlot = int(owner.parent)
  if parentSlot < 0 or parentSlot >= owner.nodes.len:
    raise newException(ValueError, "ui: dialog parent is invalid")
  let parentIdentity = owner.nodes[parentSlot].identity
  let ordinal = owner.dialogOrdinals.getOrDefault(parentIdentity)
  owner.dialogOrdinals[parentIdentity] = ordinal + 1
  mixIdentity(parentIdentity, dialogIdentitySalt xor ordinal)

proc dialogBaseImpl(c: Context; open: var bool;
                    dismissOnBackdrop, dismissOnEscape: bool;
                    build: proc(backdrop, panel: Element) {.closure.}): Element =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: dialog must be built in a frame")
  let owner = c.owner
  let identity = c.nextDialogIdentity()
  var state = owner.dialogStates.getOrDefault(identity)
  if state == nil and open:
    state = DialogState()
    owner.dialogStates[identity] = state
  if state != nil:
    state.seenGeneration = owner.generation
    state.dismissOnEscape = dismissOnEscape
    if state.pendingDismiss:
      state.pendingDismiss = false
      open = false
      owner.dialogStates.del(identity)
      if owner.invalidate != nil:
        owner.invalidate()
      return Element(owner: owner, slot: dialogDismissedSlot,
        generation: owner.generation)
  if not open:
    owner.dialogStates.del(identity)
    return

  var panelResult: Element
  var dismissedNow = false
  discard c.overlayLayer(proc(layer: Element) =
    let backdrop = layer.absolute().left(0).top(0).right(0).bottom(0)
      .center().modal().tabStop(false).onClick(proc() = discard)
    let backdropNode = backdrop.node
    if backdropNode != nil:
      backdropNode[].dialogState = state
      backdropNode[].accessHidden = true

    panelResult = c.box().focusable().tabStop(false)
      .onClick(proc() = discard)
    let panelNode = panelResult.node
    if panelNode != nil:
      panelNode[].accessRole = platform.roleDialog
      panelNode[].accessRoleSet = true
    if build != nil:
      build(backdrop, panelResult)
    dismissedNow = dismissOnBackdrop and backdrop.clicked()
    if panelNode != nil:
      panelNode[].dialogDismissed = dismissedNow
  )
  if dismissedNow:
    open = false
    if owner.invalidate != nil:
      owner.invalidate()
  if not open:
    owner.dialogStates.del(identity)
  result = panelResult

proc dialogBase*(c: Context; open: var bool;
                 build: proc(backdrop, panel: Element) {.closure.}): Element =
  ## Builds a custom modal layer while open. Escape or a backdrop click closes it.
  c.dialogBaseImpl(open, dismissOnBackdrop = true, dismissOnEscape = true,
    build)

proc modal*(c: Context; open: var bool;
            build: proc() {.closure.}): Element =
  ## Shows a centered, dimmed dialog. Escape and backdrop clicks close it.
  let theme = c.theme
  result = c.dialogBaseImpl(open, dismissOnBackdrop = true,
    dismissOnEscape = true,
    proc(backdrop, panel: Element) =
      discard backdrop.background(rgba(0, 0, 0, 0.4'f32))
      discard panel.width(theme.space(75)).maxWidthPercent(100)
        .maxHeightPercent(90).padding(theme.space(5)).gap(theme.space(3))
        .radius(theme.space(2.5)).background(theme.background)
        .shadow(0, 10, 30, 0, rgba(0, 0, 0, 0.3'f32))
      if build != nil:
        discard panel.children(build)
  )

proc alertDialog*(c: Context; open: var bool; title, message: string;
                  buttons: varargs[string]): int =
  ## Shows a named alert; its last button is the default. Escape returns AlertDismissed.
  var chosen = -1
  let buttonLabels = @buttons
  let theme = c.theme
  let dialog = c.dialogBaseImpl(open, dismissOnBackdrop = false,
    dismissOnEscape = true,
    proc(backdrop, panel: Element) =
      discard backdrop.background(rgba(0, 0, 0, 0.4'f32))
      let panelNode = panel.node
      if panelNode != nil:
        panelNode[].accessRole = platform.roleAlertDialog
        panelNode[].accessRoleSet = true
        panelNode[].label = title
        panelNode[].accessDescription = message
      discard panel.width(theme.space(75)).maxWidthPercent(100)
        .maxHeightPercent(90).padding(theme.space(5)).gap(theme.space(3))
        .radius(theme.space(2.5)).background(theme.background)
        .shadow(0, 10, 30, 0, rgba(0, 0, 0, 0.3'f32))
      discard panel.children(proc() =
        discard c.text(title).textWeight(700).textSize(theme.fontSize + 1)
        if message.len > 0:
          discard c.text(message).textColor(theme.textMuted)
        discard c.row().gap(theme.space(2)).justify(Align.End)
          .margin(theme.space(2), 0).children(proc() =
            for index, label in buttonLabels:
              var button = if index == buttonLabels.len - 1:
                  c.primaryButton(label)
                else:
                  c.button(label)
              if index == buttonLabels.len - 1:
                button = button.autoFocus()
              if button.clicked():
                chosen = index
          )
      )
  )
  if dialog.dismissed():
    return AlertDismissed
  if chosen >= 0:
    open = false
    if c.owner.invalidate != nil:
      c.owner.invalidate()
  chosen
