## Inline text editing for labels and list/table rows.

const editableRenameDelay = initDuration(milliseconds = 500)

proc editableRow(owner: ElementOwner; slot: int): tuple[state: ListState,
    row: int, identity: uint64] =
  var current = slot
  while current > 0 and current < owner.nodes.len:
    let node = owner.nodes[current]
    if node.listState != nil and node.listRowIndex >= 0:
      result.state = node.listState
      result.row = node.listRowIndex
      break
    current = int(node.parent)
  if result.state == nil:
    return
  current = slot
  while current > 0 and current < owner.nodes.len:
    let node = owner.nodes[current]
    if node.listState == result.state and node.listRowIndex == -1:
      result.identity = node.identity
    current = int(node.parent)

proc requestEditableFocus(owner: ElementOwner; identity: uint64) =
  if owner == nil or identity == 0:
    return
  for index, request in owner.focusRequests:
    if request.handleIdentity == 0:
      owner.focusRequests[index] = HandleFocusRequest(identity: identity)
      return
  owner.focusRequests.add(HandleFocusRequest(identity: identity))

proc editableReturnFocus(owner: ElementOwner; slot: int): uint64 =
  let row = owner.editableRow(slot)
  if row.identity != 0:
    return row.identity
  owner.nodes[slot].identity

proc editableText*(c: Context; value: var string): Element =
  ## Shows text in place and edits it after a double click or Enter.
  if c == nil or c.owner == nil or not c.owner.inBuild:
    return
  result = c.row().alignItems(Align.Center).minWidth(0)
  let outer = result.node
  if outer == nil:
    return
  let identity = outer[].identity
  var state = c.owner.editableTextStates.getOrDefault(identity)
  if state == nil:
    new(state)
    c.owner.editableTextStates[identity] = state
  let row = c.owner.editableRow(int(result.slot))
  var startEditing = state.requestInputFocus
  state.requestInputFocus = false
  if row.state != nil:
    row.state.editablesNow = true
    if row.state.editAsked:
      let matches = if row.state.editKeyValid:
          row.state.rowKey != nil and row.state.rowKey(row.row) == row.state.editKey
        else:
          row.state.editRow == row.row
      if matches:
        row.state.editAsked = false
        startEditing = true

    if row.state.lastClickGeneration == c.owner.generation and
        row.state.lastClickRow == row.row:
      if row.state.lastClickCount >= 2:
        state.renameDeadline = MonoTime()
      elif (row.state.selectedRow == row.row or
          (row.state.multiSelectionEnabled and row.state.isSelected(row.row))) and
          result.hovered():
        state.renameDeadline = c.owner.frameNow + editableRenameDelay
        c.after(editableRenameDelay)
    if state.renameDeadline != MonoTime() and
        c.owner.frameNow >= state.renameDeadline:
      state.renameDeadline = MonoTime()
      startEditing = true
    if row.state.selectedRow != row.row and
        not (row.state.multiSelectionEnabled and row.state.isSelected(row.row)):
      state.renameDeadline = MonoTime()
  else:
    discard result.focusable().onClick(proc() = discard)
    if outer != nil:
      outer[].activateEnter = false
    discard result.onShortcut(0, platform.keyEnter, proc() =
      if not state.editing:
        state.requestInputFocus = true
    )
    if not state.editing and result.doubleClicked():
      startEditing = true

  if startEditing and not state.editing:
    state.editing = true
    state.fresh = true
    state.draft = value
    state.commitPending = false
    state.cancelPending = false
    state.renameDeadline = MonoTime()

  if not state.editing:
    let shownValue = value
    discard result.children(proc() =
      let label = c.text(shownValue)
      if label.node != nil:
        label.node[].textNoWrap = true
    )
    return

  var input: Element
  discard result.children(proc() =
    let pad = c.theme.space(0.5)
    input = c.textInputBase(state.draft).grow().minWidth(c.theme.space(10))
      .padding(pad, pad * 2).margin(-pad - 1, -pad * 2 - 1)
      .radius(c.theme.space(1)).background(c.theme.background)
      .border(1, c.theme.accent).textColor(c.theme.text)
    discard input.onSubmit(proc() = state.commitPending = true)
    discard input.onShortcut(0, platform.keyEscape, proc() =
      state.cancelPending = true
    )
  )
  let inputNode = input.node
  if inputNode == nil:
    return
  let inputIdentity = inputNode[].identity
  let client = c.owner.textInputClients.getOrDefault(inputIdentity)
  if state.fresh:
    state.fresh = false
    c.owner.requestEditableFocus(inputIdentity)
    if client of TextFieldClient:
      let textClient = TextFieldClient(client)
      var selectionEnd = platform.utf16Len(state.draft)
      let dot = state.draft.rfind('.')
      if dot > 0:
        selectionEnd = platform.utf16Len(state.draft[0 ..< dot])
      textClient.anchor = 0
      textClient.caret = selectionEnd
  elif state.cancelPending:
    state.cancelPending = false
    state.commitPending = false
    state.editing = false
    state.requestFocus = true
  elif state.commitPending or input.submitted():
    state.commitPending = false
    state.editing = false
    if state.draft != value:
      value = state.draft
      outer[].changed = true
    state.requestFocus = true
  elif c.owner.focusIdentity != inputIdentity:
    state.editing = false
    if state.draft != value:
      value = state.draft
      outer[].changed = true

  if state.requestFocus:
    state.requestFocus = false
    c.owner.requestEditableFocus(c.owner.editableReturnFocus(int(result.slot)))
