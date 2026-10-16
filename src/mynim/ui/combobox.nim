## Filterable single-choice controls for the native UI.

type
  ComboBoxItemParts* = object ## An option row and its current highlight state.
    element*: Element
    isHighlighted*: bool

  ComboBoxBuild = ref object
    values: seq[string]
    items: seq[Element]
    chosenValue: string
    hasChoice, inPopup: bool

  ComboBoxParts* = object ## Input and builder methods for a custom combobox.
    input*: Element
    context: Context
    state: ComboBoxState
    build: ComboBoxBuild

proc comboBoxPartsActive(parts: ComboBoxParts): bool =
  parts.context != nil and parts.context.owner != nil and
    parts.context.owner.inBuild and parts.state != nil and
    parts.input.node != nil

proc comboboxBase*(c: Context; text: var string): ComboBoxParts =
  ## Creates an unstyled editable combobox. Style `input`, build its options
  ## with `popup` and `item`, and read a chosen value after `popup` returns.
  result.input = c.textInputBase(text)
  let inputNode = result.input.node
  if inputNode == nil:
    return
  let identity = inputNode[].identity
  var state = c.owner.comboBoxStates.getOrDefault(identity)
  if state == nil:
    state = ComboBoxState(query: text, lastSelected: text, highlight: -1,
      scroll: newScrollState())
    c.owner.comboBoxStates[identity] = state
  elif state.scroll == nil:
    state.scroll = newScrollState()
  result.build = ComboBoxBuild()
  if state.hasPendingChoice:
    result.build.chosenValue = state.pendingChoice
    result.build.hasChoice = true
    state.pendingChoice.setLen(0)
    state.hasPendingChoice = false
  state.tokenField = false
  state.pendingTokenRemovals = 0
  state.pendingTokenSubmission = false

  inputNode[].comboBoxRoot = true
  inputNode[].comboBoxInput = true
  inputNode[].comboBoxState = state
  inputNode[].accessRole = platform.roleComboBox
  inputNode[].accessRoleSet = true

  if result.input.changed():
    state.query = text
    state.lastSelected = text
    state.open = true
    state.filtering = true
    state.highlight = 0
    state.pointerRevision = c.owner.pointerRevision
  elif text != state.lastSelected:
    state.query = text
    state.lastSelected = text
    state.filtering = false

  if result.input.clicked() and not state.open:
    state.open = true
    state.filtering = false
    state.highlight = -1
    state.pointerRevision = c.owner.pointerRevision
  if not result.input.focused():
    state.open = false
    state.filtering = false
    state.highlight = -1

  result.context = c
  result.state = state

proc isOpen*(parts: ComboBoxParts): bool =
  ## Reports whether this combobox's popup is open in the current frame.
  parts.comboBoxPartsActive() and parts.state.open

proc setOpen*(parts: ComboBoxParts; value: bool) =
  ## Opens or closes the popup. Call before `popup` in the current frame.
  if not parts.comboBoxPartsActive() or parts.state.open == value:
    return
  parts.state.open = value
  parts.state.filtering = false
  parts.state.highlight = -1
  if value:
    parts.state.pointerRevision = parts.context.owner.pointerRevision
  if parts.context.owner.invalidate != nil:
    parts.context.owner.invalidate()

proc filtering*(parts: ComboBoxParts): bool =
  ## Reports whether the user typed since the popup opened.
  parts.comboBoxPartsActive() and parts.state.filtering

proc chosen*(parts: ComboBoxParts): tuple[value: string, ok: bool] =
  ## Returns and consumes the option chosen by click or Enter this frame.
  if not parts.comboBoxPartsActive() or parts.build == nil or
      not parts.build.hasChoice:
    return
  result = (parts.build.chosenValue, true)
  parts.build.chosenValue.setLen(0)
  parts.build.hasChoice = false

proc item*(parts: ComboBoxParts; value: string): ComboBoxItemParts =
  ## Creates a custom option row. Add its content and style it using
  ## `isHighlighted`; the popup keeps keyboard and pointer focus in the input.
  if not parts.comboBoxPartsActive() or parts.build == nil or
      not parts.state.open or not parts.build.inPopup:
    return
  let state = parts.state
  let index = parts.build.values.len
  parts.build.values.add(value)
  result.element = parts.context.buttonBase().tabStop(false)
  let itemNode = result.element.node
  if itemNode == nil:
    return
  itemNode[].accessRole = platform.roleListItem
  itemNode[].accessRoleSet = true
  itemNode[].label = value
  itemNode[].activateEnter = false
  itemNode[].focusTargetSlot = int32(parts.input.slot)
  if parts.context.owner.pointerRevision != state.pointerRevision and
      result.element.hovered():
    state.highlight = index
    state.pointerRevision = parts.context.owner.pointerRevision
  result.isHighlighted = state.highlight == index
  if result.isHighlighted:
    itemNode[].accessExtraStates = itemNode[].accessExtraStates or
      platform.accessChecked
    if state.shownOption != value:
      discard result.element.scrollIntoView()
      state.shownOption = value
  parts.build.items.add(result.element)
  discard result.element.onClick(proc() =
    state.pendingChoice = value
    state.hasPendingChoice = true
    state.open = false
    state.filtering = false
    state.highlight = -1
  )

proc popup*(parts: ComboBoxParts;
            build: proc(panel: Element) {.closure.}): Element =
  ## Shows a popup at least as wide as the input and builds options with
  ## `item`. Returns an empty Element while closed or when no options exist.
  if not parts.comboBoxPartsActive():
    return
  let state = parts.state
  let context = parts.context
  let wasOpen = state.open
  let hadChoice = parts.build.hasChoice
  var popupOpen = state.open
  state.itemIdentities.setLen(0)
  parts.build.values.setLen(0)
  parts.build.items.setLen(0)
  result = context.popoverBase(parts.input, popupOpen, proc(panel: Element) =
    let panelNode = panel.node
    if panelNode != nil:
      panelNode[].accessRole = platform.roleList
      panelNode[].accessRoleSet = true
      panelNode[].accessExtraStates = panelNode[].accessExtraStates or
        platform.accessSelectable
    if build != nil:
      parts.build.inPopup = true
      try:
        build(panel)
      finally:
        parts.build.inPopup = false
  )
  state.open = popupOpen
  if popupOpen:
    let count = parts.build.values.len
    let oldHighlight = state.highlight
    if state.highlight == -2 or state.highlight >= count:
      state.highlight = count - 1
    if count == 0:
      state.highlight = -1
      let panelNode = result.node
      if panelNode != nil:
        panelNode[].accessHidden = true
      result = Element()
    state.options.setLen(0)
    state.visibleOptions.setLen(0)
    for value in parts.build.values:
      state.options.add(value)
      state.visibleOptions.add(value)
    for index, item in parts.build.items:
      let itemNode = item.node
      if itemNode != nil:
        state.itemIdentities.add(itemNode[].identity)
        itemNode[].accessPosInSet = index + 1
        itemNode[].accessSetSize = count
        let textSlot = int(itemNode[].firstChild)
        if textSlot > 0 and textSlot < context.owner.nodes.len and
            context.owner.nodes[textSlot].hasText:
          context.owner.nodes[textSlot].accessHidden = true
        if index == state.highlight:
          itemNode[].accessExtraStates = itemNode[].accessExtraStates or
            platform.accessChecked
    if state.highlight != oldHighlight and
        context.owner.invalidate != nil:
      context.owner.invalidate()
  else:
    state.itemIdentities.setLen(0)

  if wasOpen and not popupOpen and not hadChoice and
      not state.hasPendingChoice:
    state.filtering = false
    state.highlight = -1
  if not popupOpen or parts.build.values.len == 0:
    state.shownOption.setLen(0)

  parts.build.values.setLen(0)
  parts.build.items.setLen(0)

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

proc buildComboBoxPopup(c: Context; anchor: Element; state: ComboBoxState;
                        focusTargetSlot: int32): bool =
  let theme = c.theme
  let popupHasOptions = state.visibleOptions.len > 0
  if not popupHasOptions:
    state.itemIdentities.setLen(0)
  let keepExpanded = state.open and not popupHasOptions
  let wasOpen = state.open
  var popupOpen = state.open and popupHasOptions
  discard c.popoverBase(anchor, popupOpen, proc(panel: Element) =
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
          itemNode[].focusTargetSlot = focusTargetSlot
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
  result = popupOpen or keepExpanded
  if wasOpen and not result and not state.hasPendingChoice:
    state.filtering = false
    state.highlight = -1
  if not result or not popupHasOptions:
    state.shownOption.setLen(0)

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
    if state.highlight == -2 or state.highlight >= state.visibleOptions.len:
      state.highlight = state.visibleOptions.high
    if state.filtering and state.highlight < 0 and
        state.visibleOptions.len > 0:
      state.highlight = 0
    if state.visibleOptions.len == 0:
      state.highlight = -1

    state.open = buildComboBoxPopup(c, field, state, inputSlot)
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

proc chooseAutocomplete(value: string; current: var string;
                        state: ComboBoxState; input: Element) =
  if current != value:
    current = value
    input.markBoundValueChanged()
  state.lastSelected = value
  state.query = value
  state.filtering = false
  state.open = false
  state.highlight = -1
  let client = input.fieldClient()
  if client != nil:
    client.setFieldText(value)
    client.anchor = platform.utf16Len(value)
    client.caret = client.anchor
    client.rebuildFieldLayout()
  let node = input.node
  if node != nil:
    node[].textValue = value

proc autocomplete*(c: Context; value: var string;
                   suggestions: openArray[string]): Element =
  ## Creates a text input with matching suggestions; Enter without a
  ## highlighted suggestion submits the typed value.
  let theme = c.theme
  result = c.textInput(value).padding(theme.space(1.5), theme.space(2.5))
    .radius(theme.radius).background(theme.surface).border(1, theme.border)
    .minWidth(theme.space(20))
  let input = result
  let inputNode = input.node
  if inputNode == nil:
    return
  let identity = inputNode[].identity
  var state = c.owner.comboBoxStates.getOrDefault(identity)
  if state == nil:
    state = ComboBoxState(query: value, lastSelected: value,
      highlight: -1, scroll: newScrollState())
    c.owner.comboBoxStates[identity] = state
  elif state.scroll == nil:
    state.scroll = newScrollState()
  inputNode[].comboBoxRoot = true
  inputNode[].comboBoxInput = true
  inputNode[].comboBoxState = state
  inputNode[].accessRole = platform.roleComboBox
  inputNode[].accessRoleSet = true

  if input.clicked() and not state.open:
    state.open = true
    state.filtering = false
    state.highlight = -1
    state.pointerRevision = c.owner.pointerRevision
  if input.changed():
    state.query = value
    state.lastSelected = value
    state.open = true
    state.filtering = true
    state.highlight = -1
    state.pointerRevision = c.owner.pointerRevision
  elif value != state.lastSelected:
    state.query = value
    state.lastSelected = value
    state.filtering = false

  if not input.focused():
    state.open = false
    state.filtering = false
    state.highlight = -1

  state.options.setLen(0)
  for suggestion in suggestions:
    state.options.add(suggestion)
  state.visibleOptions.setLen(0)
  if state.filtering and state.query.strip().len > 0:
    for suggestion in matchingComboBox(state.options, state.query):
      if unicode.toLower(suggestion) != unicode.toLower(state.query):
        state.visibleOptions.add(suggestion)
  if state.highlight == -2 or state.highlight >= state.visibleOptions.len:
    state.highlight = state.visibleOptions.high
  if state.visibleOptions.len == 0:
    state.highlight = -1

  state.open = buildComboBoxPopup(c, input, state, int32(input.slot))
  if state.hasPendingChoice:
    let choice = state.pendingChoice
    state.hasPendingChoice = false
    state.pendingChoice.setLen(0)
    chooseAutocomplete(choice, value, state, input)

proc setTokenFieldQuery(state: ComboBoxState; input: Element; value: string) =
  state.query = value
  let client = input.fieldClient()
  if client != nil:
    client.setFieldText(value)
    client.anchor = platform.utf16Len(value)
    client.caret = client.anchor
    client.rebuildFieldLayout()
  let node = input.node
  if node != nil:
    node[].textValue = value

proc addToken(tokens: var seq[string]; value: string): bool =
  let token = value.strip()
  if token.len == 0:
    return
  for existing in tokens:
    if existing == token:
      return
  tokens.add(token)
  true

proc tokenField*(c: Context; tokens: var seq[string];
                 suggestions: openArray[string]): Element =
  ## Creates a wrapping token field with remove buttons and optional
  ## suggestions.
  let theme = c.theme
  result = c.row().wrap().alignItems(Align.Center)
    .gap(theme.space(1)).padding(theme.space(1.5), theme.space(2))
    .radius(theme.radius).background(theme.surface).border(1, theme.border)
  let field = result
  let fieldNode = field.node
  if fieldNode == nil:
    return
  fieldNode[].comboBoxRoot = true
  let identity = fieldNode[].identity
  var state = c.owner.comboBoxStates.getOrDefault(identity)
  if state == nil:
    state = ComboBoxState(highlight: -1, scroll: newScrollState(),
      tokenField: true)
    c.owner.comboBoxStates[identity] = state
  elif state.scroll == nil:
    state.scroll = newScrollState()
  state.tokenField = true

  var changedTokens = false
  while state.pendingTokenRemovals > 0 and tokens.len > 0:
    tokens.setLen(tokens.len - 1)
    dec state.pendingTokenRemovals
    changedTokens = true
  if tokens.len == 0:
    state.pendingTokenRemovals = 0
  let tokensAtBuild = tokens
  let hasSuggestions = suggestions.len > 0
  state.tokenCount = tokens.len
  state.options.setLen(0)
  for suggestion in suggestions:
    state.options.add(suggestion)

  var input: Element
  var removeIndex = -1
  var pendingAdds: seq[string]
  discard field.children(proc() =
    var removeButtons: seq[Element]
    for index, token in tokensAtBuild:
      let chip = c.key("token-" & $index).row()
        .alignItems(Align.Center).gap(theme.space(1))
        .padding(theme.space(0.25), 0).paddingStart(theme.space(2))
        .paddingEnd(theme.space(1)).radius(theme.radius)
        .background(theme.surfacePressed).shrink(0)
      discard chip.children(proc() =
        let label = c.text(token).shrink(1)
        if label.node != nil:
          label.node[].textMaxLines = 1
        let remove = c.button("×").size(theme.space(3.5),
          theme.space(3.5)).radius(theme.space(1)).tabStop(false)
          .label("Remove " & token)
        let removeNode = remove.node
        if removeNode != nil:
          let glyphSlot = int(removeNode[].firstChild)
          if glyphSlot > 0 and glyphSlot < c.owner.nodes.len:
            c.owner.nodes[glyphSlot].accessHidden = true
        removeButtons.add(remove)
        if remove.clicked():
          removeIndex = index
      )

    input = c.key("token-field-input").textInput(state.query).grow(1)
      .minWidth(theme.space(20))
    input = input.onSubmit(proc() = state.pendingTokenSubmission = true)
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
    inputNode[].accessRole = if hasSuggestions:
        platform.roleComboBox
      else:
        platform.roleTextField
    inputNode[].accessRoleSet = true
    for button in removeButtons:
      let removeNode = button.node
      if removeNode != nil:
        removeNode[].focusTargetSlot = inputSlot

    if input.clicked() and not state.open:
      state.open = true
      state.filtering = false
      state.highlight = -1
      state.pointerRevision = c.owner.pointerRevision
    if input.changed():
      state.open = true
      state.filtering = true
      state.highlight = -1
      state.pointerRevision = c.owner.pointerRevision

    if not input.focused():
      state.open = false
      state.filtering = false
      state.highlight = -1

    if state.query.contains(','):
      let parts = state.query.split(',')
      for index in 0..<max(parts.len - 1, 0):
        pendingAdds.add(parts[index])
      setTokenFieldQuery(state, input, parts[^1])
    if state.pendingTokenSubmission:
      state.pendingTokenSubmission = false
      pendingAdds.add(state.query)
      setTokenFieldQuery(state, input, "")

    state.visibleOptions.setLen(0)
    if state.filtering and state.query.strip().len > 0:
      for suggestion in matchingComboBox(state.options, state.query):
        var alreadyToken = false
        for token in tokensAtBuild:
          if token == suggestion:
            alreadyToken = true
            break
        if not alreadyToken:
          for pending in pendingAdds:
            if pending.strip() == suggestion:
              alreadyToken = true
              break
        if not alreadyToken:
          state.visibleOptions.add(suggestion)
    if state.highlight == -2 or state.highlight >= state.visibleOptions.len:
      state.highlight = state.visibleOptions.high
    if state.visibleOptions.len == 0:
      state.highlight = -1

    state.open = buildComboBoxPopup(c, field, state, inputSlot)
  )

  if removeIndex >= 0 and removeIndex < tokens.len:
    for index in removeIndex..<tokens.high:
      tokens[index] = tokens[index + 1]
    tokens.setLen(tokens.len - 1)
    changedTokens = true
  for addition in pendingAdds:
    changedTokens = tokens.addToken(addition) or changedTokens
  if state.hasPendingChoice:
    let choice = state.pendingChoice
    state.hasPendingChoice = false
    state.pendingChoice.setLen(0)
    state.open = false
    state.filtering = false
    state.highlight = -1
    changedTokens = tokens.addToken(choice) or changedTokens
    setTokenFieldQuery(state, input, "")
  if changedTokens:
    field.markBoundValueChanged()
  state.tokenCount = tokens.len
