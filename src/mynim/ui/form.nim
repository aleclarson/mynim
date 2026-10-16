## Labels, descriptions, and grouped controls for native forms.

proc findFieldControl(owner: ElementOwner; slot: int): int =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return -1
  var child = int(owner.nodes[slot].firstChild)
  while child > 0 and child < owner.nodes.len:
    let node = owner.nodes[child]
    if node.accessRoleSet and node.accessRole in {
        platform.roleRadioGroup, platform.roleToolbar, platform.roleList,
        platform.roleTable, platform.roleTree, platform.roleTabList}:
      return child
    if node.focusable or node.clickHandler != nil or node.textClient != nil:
      return child
    result = owner.findFieldControl(child)
    if result > 0:
      return
    child = int(node.nextSibling)
  result = -1

proc hasFieldText(owner: ElementOwner; slot: int): bool =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return false
  if owner.nodes[slot].hasText and not owner.nodes[slot].textOverlay and
      owner.nodes[slot].textValue.len > 0:
    return true
  var child = int(owner.nodes[slot].firstChild)
  while child > 0 and child < owner.nodes.len:
    if owner.hasFieldText(child):
      return true
    child = int(owner.nodes[child].nextSibling)

proc fieldFocusTarget(owner: ElementOwner; slot: int): int =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return -1
  let node = owner.nodes[slot]
  if node.focusable or node.clickHandler != nil or node.textClient != nil:
    return slot
  var first = -1
  var selected = -1
  var pending = @[slot]
  while pending.len > 0:
    let current = pending.pop()
    var child = int(owner.nodes[current].firstChild)
    var children: seq[int]
    while child > 0 and child < owner.nodes.len:
      children.add(child)
      child = int(owner.nodes[child].nextSibling)
    for index in 0 ..< children.len:
      pending.add(children[children.high - index])
    if current == slot:
      continue
    let candidate = owner.nodes[current]
    if candidate.focusable or candidate.clickHandler != nil or
        candidate.textClient != nil:
      if first < 0:
        first = current
      if (candidate.accessExtraStates and platform.accessChecked) !=
          platform.AccessStates(0):
        selected = current
  if selected > 0: selected else: first

proc hideFieldLabel(owner: ElementOwner; slot, target: int) =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return
  var pending = @[slot]
  while pending.len > 0:
    let current = pending.pop()
    owner.nodes[current].accessHidden = true
    if target > 0:
      owner.nodes[current].labelTargetSlot = int32(target)
    var child = int(owner.nodes[current].firstChild)
    while child > 0 and child < owner.nodes.len:
      pending.add(child)
      child = int(owner.nodes[child].nextSibling)

proc form*(c: Context; build: proc() {.closure.}): Element =
  ## Builds fields in a column, aligning their labels beside their controls.
  result = c.column().gap(c.theme.space(3))
  let node = result.node
  if node == nil:
    return
  node[].formContainer = true
  let previousDepth = c.formDepth
  inc c.formDepth
  try:
    discard result.children(build)
  finally:
    c.formDepth = previousDepth

proc field*(c: Context; label: string;
            build: proc() {.closure.}): Element =
  ## Adds a labeled control, placing its label above or beside it in a Form.
  let inForm = c.formDepth > 0
  let theme = c.theme
  result = if inForm:
      c.row().gap(theme.space(3)).alignItems(Align.Start)
    else:
      c.column().gap(theme.space(1.5))
  if result.node == nil:
    return
  var labelElement: Element
  var contentElement: Element
  discard result.children(proc() =
    if inForm:
      labelElement = c.row().justify(Align.End).shrink(0)
      let labelNode = labelElement.node
      if labelNode != nil:
        labelNode[].formLabel = true
        labelNode[].accessHidden = true
      discard labelElement.children(proc() =
        discard c.text(label)
      )
    else:
      labelElement = c.text(label).textWeight(500)
      let labelNode = labelElement.node
      if labelNode != nil:
        labelNode[].accessHidden = true

    contentElement = c.column().gap(theme.space(1.5))
    if inForm:
      discard contentElement.grow(1).minWidth(0)
    if build != nil:
      discard contentElement.children(build)
  )

  let fieldNode = result.node
  let contentNode = contentElement.node
  let labelNode = labelElement.node
  if fieldNode == nil or contentNode == nil or labelNode == nil:
    return
  fieldNode[].formField = inForm
  fieldNode[].fieldLabelSlot = int32(labelElement.slot)
  fieldNode[].fieldContentSlot = int32(contentElement.slot)
  if inForm:
    # The field row owns the label wrapper; the text itself remains hidden
    # from the access tree while it names the control.
    labelNode[].accessHidden = true
  let controlSlot = findFieldControl(c.owner, int(contentElement.slot))
  if controlSlot <= 0:
    return
  fieldNode[].fieldControlSlot = int32(controlSlot)

  let control = addr c.owner.nodes[controlSlot]
  let selfNames = control[].label.len > 0 or
    (control[].clickHandler != nil and
      hasFieldText(c.owner, controlSlot))
  if selfNames:
    fieldNode[].accessRole = platform.roleGroup
    fieldNode[].accessRoleSet = true
    fieldNode[].label = label
  elif control[].label.len == 0:
    control[].label = label

  if c.owner.effectivelyDisabled(controlSlot) and
      not c.owner.effectivelyDisabled(int(labelElement.slot)):
    let labelNode = addr c.owner.nodes[int(labelElement.slot)]
    labelNode[].opacity = 0.5'f32
    labelNode[].opacitySet = true

  let focusTarget = fieldFocusTarget(c.owner, controlSlot)
  hideFieldLabel(c.owner, int(labelElement.slot), focusTarget)

proc fieldset*(c: Context; legend: string;
               build: proc() {.closure.}): Element =
  ## Groups related fields under a legend; labels still align inside a Form.
  let theme = c.theme
  let parentSlot = int(c.owner.parent)
  let hasPrevious = parentSlot >= 0 and
    parentSlot < c.owner.nodes.len and
    c.owner.nodes[parentSlot].childCount > 0
  result = c.column().gap(theme.space(3)).shrink(0)
  let group = result.node
  if group == nil:
    return
  group[].accessRole = platform.roleGroup
  group[].accessRoleSet = true
  group[].label = legend
  if hasPrevious:
    discard result.margin(theme.space(3), 0, 0, 0)
  discard result.children(proc() =
    let title = c.text(legend).textWeight(600)
    let titleNode = title.node
    if titleNode != nil:
      titleNode[].accessHidden = true
    if build != nil:
      build()
  )

proc disabled*(e: Element; value = true): Element =
  ## Disables this element and all controls inside it.
  result = e
  let node = e.node
  if node != nil:
    node[].disabled = value

proc isDisabled*(e: Element): bool =
  ## Reports whether this element or one of its ancestors is disabled.
  let node = e.node
  node != nil and e.owner.effectivelyDisabled(int(e.slot))

proc appendAccessDescription(node: ptr ElementNode; value: string;
                             first = false) =
  if node == nil or value.len == 0:
    return
  if node[].accessDescription.len == 0:
    node[].accessDescription = value
  elif first:
    node[].accessDescription = value & "\n" & node[].accessDescription
  else:
    node[].accessDescription.add("\n" & value)

proc fieldMessage(e: Element; value: string; color: Color): Element =
  result = e
  let node = e.node
  if node == nil or value.len == 0 or node[].fieldContentSlot <= 0:
    return
  let c = e.owner.activeContext
  if c == nil:
    return
  let content = Element(owner: e.owner,
    slot: uint32(node[].fieldContentSlot), generation: e.generation)
  discard content.children(proc() =
    let message = c.text(value)
      .textColor(color).textSize(c.theme.fontSize - 1)
    let messageNode = message.node
    if messageNode != nil:
      messageNode[].accessHidden = true
  )

proc description*(e: Element; value: string): Element =
  ## Adds help text below a Field and its description to the control.
  let c = if e.owner == nil: nil else: e.owner.activeContext
  if c == nil:
    return e
  result = e.fieldMessage(value, c.theme.textMuted)
  let field = result.node
  if field == nil:
    return
  let controlSlot = int(field[].fieldControlSlot)
  if controlSlot > 0 and controlSlot < e.owner.nodes.len:
    appendAccessDescription(addr e.owner.nodes[controlSlot], value)
  else:
    appendAccessDescription(field, value)

proc error*(e: Element; message: string): Element =
  ## Shows an error below a Field and marks its control invalid.
  let c = if e.owner == nil: nil else: e.owner.activeContext
  if c == nil:
    return e
  result = e.fieldMessage(message, c.theme.danger)
  let field = result.node
  if field == nil or message.len == 0:
    return
  let controlSlot = int(field[].fieldControlSlot)
  if controlSlot > 0 and controlSlot < e.owner.nodes.len:
    let control = addr e.owner.nodes[controlSlot]
    control[].invalid = true
    control[].accessExtraStates =
      control[].accessExtraStates or platform.accessInvalid
    appendAccessDescription(control, message, first = true)
  else:
    appendAccessDescription(field, message, first = true)
