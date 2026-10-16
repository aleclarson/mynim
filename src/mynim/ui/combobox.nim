## Filterable single-choice controls for the native UI.

proc matchingComboBox(options: seq[string]; query: string): seq[string] =
  let needle = unicode.toLower(query.strip())
  if needle.len == 0:
    return options
  var starts, contains: seq[string]
  for option in options:
    let candidate = unicode.toLower(option)
    if candidate.startsWith(needle):
      starts.add(option)
    elif candidate.contains(needle):
      contains.add(option)
  result = starts
  result.add(contains)

proc selectComboBoxText(client: TextFieldClient) =
  if client == nil:
    return
  client.anchor = 0
  client.caret = platform.utf16Len(client.text)
  client.rebuildFieldLayout()

proc chooseComboBox(value: string; selected: var string;
                    state: ComboBoxState; field, input: Element) =
  if selected != value:
    selected = value
    field.markBoundValueChanged()
  state.lastSelected = value
  state.query = value
  state.filtering = false
  state.open = false
  state.highlight = -1
  let client = input.fieldClient()
  if client != nil:
    client.setFieldText(value)
    client.selectComboBoxText()
  let node = input.node
  if node != nil:
    node[].textValue = value

proc combobox*(c: Context; selected: var string;
               options: openArray[string]): Element =
  ## Creates a filterable single-choice field with keyboard and pointer options.
  let theme = c.theme
  result = c.row().gap(theme.space(1)).padding(theme.space(1.5),
    theme.space(2)).alignItems(Align.Center).radius(theme.radius)
    .background(theme.surface).border(1, theme.border)
  let field = result
  let fieldNode = field.node
  if fieldNode == nil:
    return
  fieldNode[].comboBoxRoot = true
  let identity = fieldNode[].identity
  var state = c.owner.comboBoxStates.getOrDefault(identity)
  if state == nil:
    state = ComboBoxState(query: selected, lastSelected: selected,
      highlight: -1, scroll: newScrollState())
    c.owner.comboBoxStates[identity] = state
  elif state.scroll == nil:
    state.scroll = newScrollState()

  if not state.hasPendingChoice and selected != state.lastSelected:
    state.query = selected
    state.lastSelected = selected
    state.filtering = false
  let selectedAtBuild = selected

  state.options.setLen(0)
  for option in options:
    state.options.add(option)

  var inputElement: Element
  discard field.children(proc() =
    let input = c.textInput(state.query).grow(1)
      .minWidth(theme.space(25))
    inputElement = input
    discard input.padding(0).radius(0).background(rgba(0, 0, 0, 0))
      .borderWidth(0)
    let inputNode = input.node
    if inputNode == nil:
      return
    let inputSlot = int32(input.slot)
    let fieldRoot = field.node
    if fieldRoot != nil:
      fieldRoot[].labelTargetSlot = inputSlot
    inputNode[].comboBoxInput = true
    inputNode[].comboBoxState = state
    inputNode[].accessRole = platform.roleComboBox
    inputNode[].accessRoleSet = true

    if input.clicked() and not state.open:
      state.open = true
      state.filtering = false
      state.highlight = -1
      state.pointerRevision = c.owner.pointerRevision
      input.fieldClient().selectComboBoxText()
    if input.changed():
      state.open = true
      state.filtering = true
      state.highlight = 0
      state.pointerRevision = c.owner.pointerRevision

    var arrow = c.button("⌄").padding(theme.space(0.5),
      theme.space(1)).tabStop(false).label("Show options")
    let arrowNode = arrow.node
    if arrowNode != nil:
      arrowNode[].focusTargetSlot = inputSlot
      let glyphSlot = int(arrowNode[].firstChild)
      if glyphSlot > 0 and glyphSlot < c.owner.nodes.len:
        c.owner.nodes[glyphSlot].accessHidden = true
    if arrow.clicked():
      state.open = not state.open
      state.filtering = false
      state.highlight = -1
      if state.open:
        state.pointerRevision = c.owner.pointerRevision
        input.fieldClient().selectComboBoxText()

    if not input.focused():
      state.open = false
      state.filtering = false
      state.highlight = -1

    state.visibleOptions = if state.filtering:
        matchingComboBox(state.options, state.query)
      else:
        state.options
    if state.highlight >= state.visibleOptions.len:
      state.highlight = state.visibleOptions.high
    if state.filtering and state.highlight < 0 and
        state.visibleOptions.len > 0:
      state.highlight = 0
    if state.visibleOptions.len == 0:
      state.highlight = -1

    let popupHasOptions = state.visibleOptions.len > 0
    if not popupHasOptions:
      state.itemIdentities.setLen(0)
    let keepExpanded = state.open and not popupHasOptions
    var popupOpen = state.open and popupHasOptions
    discard c.popoverBase(field, popupOpen, proc(panel: Element) =
      discard panel.padding(theme.space(1)).radius(theme.radius)
        .background(theme.surface).border(1, theme.border)
        .shadow(0, 4, 14, 0, rgba(0, 0, 0, 0.22'f32))
      let list = c.scroll(state.scroll).maxHeight(theme.space(70))
      if list.node != nil:
        list.node[].accessRole = platform.roleList
        list.node[].accessRoleSet = true
        list.node[].accessExtraStates =
          list.node[].accessExtraStates or platform.accessSelectable
      discard list.children(proc() =
        state.itemIdentities.setLen(0)
        var items: seq[Element]
        for value in state.visibleOptions:
          let item = c.button(value).padding(theme.space(1.5),
            theme.space(2.5)).radius(theme.radius).tabStop(false)
          items.add(item)
          let itemNode = item.node
          if itemNode != nil:
            state.itemIdentities.add(itemNode[].identity)
        if state.pointerRevision != c.owner.pointerRevision:
          for index, item in items:
            if item.hovered():
              state.highlight = index
              state.pointerRevision = c.owner.pointerRevision
              break
        for index, item in items:
          let value = state.visibleOptions[index]
          let itemNode = item.node
          if itemNode != nil:
            itemNode[].accessRole = platform.roleListItem
            itemNode[].accessRoleSet = true
            itemNode[].label = value
            itemNode[].accessPosInSet = index + 1
            itemNode[].accessSetSize = state.visibleOptions.len
            itemNode[].focusTargetSlot = inputSlot
            let textSlot = int(itemNode[].firstChild)
            if textSlot > 0 and textSlot < c.owner.nodes.len:
              c.owner.nodes[textSlot].accessHidden = true
            if index == state.highlight:
              itemNode[].accessExtraStates =
                itemNode[].accessExtraStates or platform.accessChecked
              discard item.background(theme.accent).textColor(theme.accentText)
              if state.shownOption != value:
                discard item.scrollIntoView()
                state.shownOption = value
            else:
              discard item.background(rgba(0, 0, 0, 0))
                .textColor(theme.text)
          if item.clicked():
            state.pendingChoice = value
            state.hasPendingChoice = true
            popupOpen = false
      )
    )
    let wasOpen = state.open
    state.open = popupOpen or keepExpanded
    if wasOpen and not state.open and not state.hasPendingChoice:
      state.filtering = false
      state.highlight = -1
    if not state.open or not popupHasOptions:
      state.shownOption.setLen(0)
    if not input.focused() and not state.open and
        state.query != selectedAtBuild:
      state.query = selectedAtBuild
      let client = input.fieldClient()
      if client != nil:
        client.setFieldText(selectedAtBuild)
      let resetNode = input.node
      if resetNode != nil:
        resetNode[].textValue = selectedAtBuild
  )
  if state.hasPendingChoice:
    let choice = state.pendingChoice
    state.hasPendingChoice = false
    state.pendingChoice.setLen(0)
    chooseComboBox(choice, selected, state, field, inputElement)
