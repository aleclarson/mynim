## Theme-styled controls built on the stateful bases.

proc themedButton(c: Context; label: string; primary: bool): Element =
  let theme = c.theme
  result = c.buttonBase()
  let wasPressed = result.pressed()
  let wasHovered = result.hovered()
  let grouped = c.segmentedToggles and not primary
  var foreground = theme.text
  if primary:
    foreground = theme.accentText
    result = result.padding(theme.space(1.5), theme.space(3.5))
      .radius(theme.radius)
      .background(if wasPressed: theme.accentPressed
        elif wasHovered: theme.accentHover else: theme.accent)
  elif grouped:
    result = result.gap(theme.space(1.5))
      .padding(theme.space(1), theme.space(3))
      .radius(max(theme.radius - theme.space(0.5), 0'f32))
      .background(if wasPressed: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  else:
    result = result.gap(theme.space(1.5))
      .padding(theme.space(1.5), theme.space(3.5))
      .radius(theme.radius)
      .background(if wasPressed: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: theme.surface)
      .border(1, theme.border)
  if label.len > 0:
    result = result.label(label).children(proc() =
      discard c.text(label).textColor(foreground)
    )

proc button*(c: Context; label: string): Element =
  ## Creates a themed button. Respond to activation with clicked() or onClick().
  c.themedButton(label, primary = false)

proc primaryButton*(c: Context; label: string): Element =
  ## Creates an accent-colored button for the primary action.
  c.themedButton(label, primary = true)

proc checkboxIndicator(c: Context; theme: Theme; checked, mixed,
                       hovered: bool): Element =
  let size = theme.space(4)
  result = c.box().size(size, size).shrink(0)
    .radius(theme.space(1)).center()
  if checked or mixed:
    discard result.background(theme.accent)
    if mixed:
      discard result.children(proc() =
        discard c.box().size(size * 0.5'f32, theme.space(0.5))
          .shrink(0).radius(theme.space(0.25)).background(theme.accentText)
      )
    else:
      discard result.children(proc() =
        discard c.text("✓").textSize(theme.space(2.5))
          .textColor(theme.accentText)
      )
  else:
    discard result.background(theme.background)
      .border(1, theme.border.mix(theme.text, 0.25'f32))
    if hovered:
      discard result.border(1, theme.accent)

proc checkbox*(c: Context; checked: var bool; label: string): Element =
  ## Creates a themed check box with a label.
  if c.checkboxGroup != nil:
    c.checkboxGroup.boxes.add(addr checked)
  let theme = c.theme
  var frameChecked = checked
  result = c.checkboxBase(frameChecked).gap(theme.space(2))
  if result.changed():
    checked = frameChecked
  result = result.label(label)
  let row = result
  result = result.children(proc() =
    discard c.checkboxIndicator(theme, frameChecked, false, row.hovered())
    if label.len > 0:
      discard c.text(label)
  )

proc checkboxGroup*(c: Context; label: string;
                    build: proc() {.closure.}): Element =
  ## Creates a parent check box for checkboxes built in the child closure.
  ## The parent is checked when all children are checked and mixed when some
  ## are checked. Clicking it checks all children, or clears all when checked.
  let theme = c.theme
  result = c.column().gap(theme.space(2)).shrink(0)
  let group = result
  result = result.children(proc() =
    var header = c.row().focusable().shrink(0).gap(theme.space(2))
      .focusRing(false).onClick(proc() = discard)
    let headerNode = header.node
    if headerNode != nil:
      headerNode.activateEnter = false
      headerNode.accessRole = platform.roleCheckBox
      headerNode.accessRoleSet = true
    header = header.label(label)

    let previousGroup = c.checkboxGroup
    let children = CheckboxGroupBuild()
    c.checkboxGroup = children
    try:
      let childGroup = c.column().gap(theme.space(2))
        .paddingStart(theme.space(6)).label(label)
      if childGroup.node != nil:
        childGroup.node.accessRole = platform.roleGroup
        childGroup.node.accessRoleSet = true
      discard childGroup.children(build)
    finally:
      c.checkboxGroup = previousGroup

    var checkedCount = 0
    for box in children.boxes:
      if box[]:
        inc checkedCount
    let allChecked = checkedCount > 0 and checkedCount == children.boxes.len
    let mixed = checkedCount > 0 and not allChecked
    if headerNode != nil:
      if allChecked:
        headerNode.accessExtraStates =
          headerNode.accessExtraStates or platform.accessChecked
      elif mixed:
        headerNode.accessExtraStates =
          headerNode.accessExtraStates or platform.accessMixed

    discard header.children(proc() =
      discard c.checkboxIndicator(theme, allChecked, mixed, header.hovered())
      discard c.text(label)
    )

    if header.clicked():
      for box in children.boxes:
        box[] = not allChecked
      group.markBoundValueChanged()
  )

proc toggle*(c: Context; on: var bool; label: string): Element =
  ## Creates a themed toggle button. Use toggleGroup to join toggles into a
  ## single keyboard stop.
  let theme = c.theme
  var frameOn = on
  result = c.toggleBase(frameOn).gap(theme.space(1.5))
  if result.changed():
    on = frameOn
  result = result.label(label)
  let wasHovered = result.hovered()
  result = result.padding(theme.space(1), theme.space(2)).center()
  if c.segmentedToggles:
    result = result.radius(max(theme.radius - theme.space(0.5), 0'f32))
      .background(if frameOn:
        (if theme.dark: theme.surfacePressed else: theme.background)
      elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  else:
    result = result.radius(theme.radius)
      .background(if frameOn: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: theme.surface)
      .border(1, theme.border)
  if label.len > 0:
    result = result.children(proc() = discard c.text(label))

proc toggleGroup*(c: Context; build: proc() {.closure.}): Element =
  ## Builds toggle buttons as joined segments with one Tab stop.
  let theme = c.theme
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .padding(theme.space(0.5)).gap(theme.space(0.5))
    .radius(theme.radius).background(theme.surface)
    .border(1, theme.border).focusGroup(FocusOrientation.Both)
  let previous = c.segmentedToggles
  c.segmentedToggles = true
  try:
    result = result.children(build)
  finally:
    c.segmentedToggles = previous

proc segment*(c: Context; selected: var int; index: int): Element =
  ## Creates one custom-content radio segment for segmentedBase.
  result = c.radioBase(selected, index).center()
  let node = result.node
  if node != nil:
    node.accessExtraStates = node.accessExtraStates or platform.accessSegment

proc segmentedBase*(c: Context; selected: var int; count: int;
                    build: proc(selected: var int) {.closure.}): Element =
  ## Creates a radio-style segmented group whose segments can have custom
  ## content. Build options with segment() inside build; set the group's
  ## accessible name with label().
  var frameSelection = selected
  if count > 0:
    frameSelection = max(0, min(frameSelection, count - 1))
    selected = frameSelection
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .focusGroup(FocusOrientation.Both, selects = true)
  let track = result
  let node = track.node
  if node != nil:
    node.accessRole = platform.roleRadioGroup
    node.accessRoleSet = true
  let firstChildSlot = c.owner.nodes.len
  if build != nil:
    discard track.children(proc() = build(frameSelection))
  var selectionChanged = false
  for slot in firstChildSlot..<c.owner.nodes.len:
    let child = c.owner.nodes[slot]
    if (child.accessExtraStates and platform.accessSegment) !=
        platform.AccessStates(0) and child.valueChangedInBuild:
      selectionChanged = true
      break
  if selectionChanged:
    selected = frameSelection
    track.markBoundValueChanged()

proc segmented*(c: Context; selected: var int;
                labels: openArray[string]): Element =
  ## Creates a radio-style segmented control whose selected index changes on
  ## click or group arrow navigation. Set its accessible name with label().
  let theme = c.theme
  let segmentLabels = @labels
  var frameSelection = selected
  if segmentLabels.len > 0:
    frameSelection = max(0, min(frameSelection, segmentLabels.high))
    selected = frameSelection
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .padding(theme.space(0.5)).gap(theme.space(0.5))
    .radius(theme.radius).background(theme.surface)
    .border(1, theme.border)
    .focusGroup(FocusOrientation.Both, selects = true)
  let track = result
  let node = track.node
  if node != nil:
    node.accessRole = platform.roleRadioGroup
    node.accessRoleSet = true
  var selectionChanged = false
  result = result.children(proc() =
    for index, label in segmentLabels:
      var segment = c.segment(frameSelection, index)
        .gap(theme.space(1.5)).padding(theme.space(1), theme.space(3))
        .radius(max(theme.radius - theme.space(0.5), 0'f32))
        .center().focusRing(false)
      if segment.changed():
        selectionChanged = true
      let isSelected = frameSelection == index
      segment = segment.label(label).background(if isSelected:
        (if theme.dark: theme.surfacePressed else: theme.background)
      elif segment.hovered(): theme.surfaceHover else: rgba(0, 0, 0, 0))
      if isSelected:
        segment = segment.shadow(0, 1, 2, 0,
          rgba(0, 0, 0, 0.12'f32))
      discard segment.children(proc() = discard c.text(label))
  )
  if selectionChanged:
    selected = frameSelection
    track.markBoundValueChanged()

proc radio*[T](c: Context; selected: var T; value: T;
               label: string): Element =
  ## Creates a themed radio option with a label.
  let theme = c.theme
  var frameSelection = selected
  result = c.radioBase(frameSelection, value).gap(theme.space(2))
  if result.changed():
    selected = frameSelection
  result = result.label(label)
  let row = result
  let isSelected = frameSelection == value
  result = result.children(proc() =
    let size = theme.space(4)
    let indicator = c.box().size(size, size).shrink(0)
      .radius(size / 2).center()
    if isSelected:
      discard indicator.background(theme.accent)
      discard indicator.children(proc() =
        discard c.box().size(theme.space(1.5), theme.space(1.5))
          .shrink(0).radius(theme.space(1)).background(theme.accentText)
      )
    else:
      discard indicator.background(theme.background)
        .border(1, theme.border.mix(theme.text, 0.25'f32))
      if row.hovered():
        discard indicator.border(1, theme.accent)
    if label.len > 0:
      discard c.text(label)
  )

proc switch*(c: Context; on: var bool): Element =
  ## Creates a themed switch track and knob. Set its accessible name with label().
  let theme = c.theme
  var frameOn = on
  result = c.switchBase(frameOn)
  if result.changed():
    on = frameOn
  let height = theme.space(5)
  let inset = theme.space(0.5)
  let node = result.node
  let rightToLeft = node != nil and node.rightToLeft
  let knobAtEnd = frameOn != rightToLeft
  let offColor = theme.border.mix(theme.text, 0.15'f32)
  result = result.size(theme.space(9), height).padding(inset)
    .justify(if knobAtEnd: Align.End else: Align.Start)
    .alignItems(Align.Center).radius(height / 2)
    .background(if frameOn: theme.accent else: offColor)
  result = result.children(proc() =
    discard c.box().size(height - 2 * inset, height - 2 * inset)
      .shrink(0).radius(height / 2).background(rgb(255, 255, 255))
      .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.25'f32))
  )
