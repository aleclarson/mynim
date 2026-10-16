## Scrollable trees of selectable sections and items.

proc newSidebarState*(selected = ""): SidebarState =
  ## Creates persistent Sidebar selection, scrolling, and type-ahead state.
  new(result)
  result.selected = selected
  result.scrollState = newScrollState()
  result.itemHandles = initTable[string, Handle]()

proc newSidebarSectionState*(open = false): SidebarSectionState =
  ## Creates persistent expansion state for a collapsible Sidebar section.
  SidebarSectionState(open: open)

proc sidebarEntryIndex(state: SidebarState; id: string): int =
  for index, entry in state.entries:
    if entry.id == id:
      return index
  -1

proc sidebarEntryAtFocus(state: SidebarState; slot: int): int =
  for index, entry in state.entries:
    if entry.slot == slot:
      return index
  -1

proc sidebarChoose(state: SidebarState; id: string): bool =
  if state == nil or state.selected == id:
    return false
  state.selected = id
  state.pendingChanged = true
  true

proc sidebarKey(state: SidebarState; key: platform.Key;
                mods: platform.Modifiers; focusSlot: var int): bool =
  if state == nil or mods != platform.Modifiers(0) or
      state.entries.len == 0:
    return false
  var current = state.sidebarEntryAtFocus(focusSlot)
  if current < 0:
    current = state.sidebarEntryIndex(state.selected)
  var target = -1
  case key
  of platform.keyDown:
    target = if current < 0: 0 else: min(current + 1, state.entries.high)
  of platform.keyUp:
    target = if current < 0: state.entries.high else: max(current - 1, 0)
  of platform.keyHome:
    target = 0
  of platform.keyEnd:
    target = state.entries.high
  else:
    return false
  let entry = state.entries[target]
  discard state.sidebarChoose(entry.id)
  focusSlot = entry.slot
  true

proc sidebarTypeSelect(state: SidebarState; text, currentId: string;
                       c: Context): bool =
  if state == nil or text.len == 0 or state.entries.len == 0:
    return false
  let now = getMonoTime()
  if state.typedLabel.len > 0 and
      (now - state.typedAt).inMilliseconds > 1_000:
    state.typedLabel.setLen(0)
  let continued = state.typedLabel.len > 0
  let lowerText = unicode.toLower(text)
  let repeated = text.runeLen == 1 and state.typedLabel.runeLen == 1 and
    unicode.toLower(state.typedLabel) == lowerText
  var query = state.typedLabel & text
  var start = state.sidebarEntryIndex(currentId)
  if start < 0:
    start = state.sidebarEntryIndex(state.selected)
  if repeated:
    query = text
    inc start
  elif not continued:
    inc start
  if start < 0:
    start = 0
  state.typedLabel = query
  state.typedAt = now
  let prefix = unicode.toLower(query)
  for distance in 0..<state.entries.len:
    let index = (start + distance) mod state.entries.len
    let entry = state.entries[index]
    if unicode.toLower(entry.label).startsWith(prefix):
      discard state.sidebarChoose(entry.id)
      var handle = entry.handle
      handle.focus(c)
      return true
  true

proc sidebar*(c: Context; state: SidebarState;
             build: proc() {.closure.}): Element =
  ## Creates a scrollable Sidebar tree. Set state.selected to the chosen ID.
  ## The Sidebar is one Tab stop; use sidebarSection and sidebarItem inside.
  if state == nil:
    raise newException(ValueError, "ui: Sidebar state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: Sidebar must be built in a frame")
  let theme = c.theme
  state.entries.setLen(0)
  let previousSidebar = c.sidebarBuild
  result = c.scroll(state.scrollState).gap(theme.space(0.5'f32))
    .padding(theme.space(2.5'f32)).background(theme.surface).shrink(0)
  let buildState = SidebarBuild(state: state)
  c.sidebarBuild = buildState
  let rootNode = result.node
  if rootNode != nil:
    rootNode[].accessRole = platform.roleTree
    rootNode[].accessRoleSet = true
    rootNode[].accessExtraStates = rootNode[].accessExtraStates or
      platform.accessSelectable
    rootNode[].focusGroupSet = true
    rootNode[].focusOrientation = FocusOrientation.Vertical
    rootNode[].keyHandler = proc(key: platform.Key;
        mods: platform.Modifiers; focusSlot: var int): bool =
      state.sidebarKey(key, mods, focusSlot)
  try:
    discard result.children(proc() =
      if build != nil:
        build()
    )
  finally:
    c.sidebarBuild = previousSidebar
  if rootNode != nil:
    let selected = state.sidebarEntryIndex(state.selected)
    if selected >= 0:
      let slot = state.entries[selected].slot
      if slot > 0 and slot < c.owner.nodes.len:
        rootNode[].activeDescendantIdentity = c.owner.nodes[slot].identity
    if state.pendingChanged:
      result.markBoundValueChanged()
      state.pendingChanged = false

proc sidebarSection*(c: Context; title: string;
                     state: SidebarSectionState;
                     build: proc() {.closure.}): Element =
  ## Adds a Sidebar section that the user can collapse when state is non-nil.
  if c == nil or c.owner == nil or not c.owner.inBuild or
      c.sidebarBuild == nil:
    raise newException(ValueError,
      "ui: Sidebar section must be built inside a Sidebar")
  let sidebar = c.sidebarBuild
  let theme = c.theme
  let shown = state == nil or state.open
  let parent = int(c.owner.parent)
  let above = parent > 0 and parent < c.owner.nodes.len and
    c.owner.nodes[parent].childCount > 0
  result = c.column().gap(theme.space(0.5'f32)).shrink(0)
  if above:
    result = result.margin(theme.space(3'f32), 0, 0, 0)
  let section = result
  if state != nil:
    discard section.focusable().tabStop(false)
  let sectionNode = section.node
  if sectionNode != nil:
    sectionNode[].accessRole = platform.roleTreeItem
    sectionNode[].accessRoleSet = true
    sectionNode[].accessLevel = sidebar.depth + 1
    sectionNode[].label = title
    if state != nil:
      sectionNode[].accessExtraStates = sectionNode[].accessExtraStates or
        platform.accessExpandable
      if state.open:
        sectionNode[].accessExtraStates = sectionNode[].accessExtraStates or
          platform.accessExpanded
      sectionNode[].accessExtraActions = platform.actionExpand
      sectionNode[].treeAccessAction = proc(
          action: platform.AccessActionKind): bool =
        case action
        of platform.accessExpand:
          if state.open:
            return false
          state.open = true
        of platform.accessCollapse:
          if not state.open:
            return false
          state.open = false
        else:
          return false
        true
  discard section.children(proc() =
    var header = c.row().alignItems(Align.Center)
      .padding(theme.space(1'f32), theme.space(2'f32))
      .radius(theme.radius).shrink(0)
    let headerNode = header.node
    if state != nil:
      header = header.onClick(proc() = state.open = not state.open)
        .tabStop(false)
    if headerNode != nil:
      headerNode[].accessHidden = true
    discard header.children(proc() =
      let heading = c.text(title).textSize(theme.fontSize - 1)
        .textWeight(600).textColor(theme.textMuted).grow(1).minWidth(0)
      if heading.node != nil:
        heading.node[].textMaxLines = 1
        heading.node[].accessHidden = true
      if state != nil and (header.hovered() or header.focused()):
        let arrow = c.text(if shown: "⌄"
          elif c.rightToLeft: "‹" else: "›").textColor(theme.textMuted)
        if arrow.node != nil:
          arrow.node[].accessHidden = true
    )
    if shown:
      inc sidebar.depth
      try:
        if build != nil:
          build()
      finally:
        dec sidebar.depth
  )

proc sidebarSection*(c: Context; title: string;
                     build: proc() {.closure.}): Element =
  ## Adds a permanently open named group to the current Sidebar.
  c.sidebarSection(title, nil, build)

proc collectSidebarLabel(owner: ElementOwner; slot: int; primarySeen: var bool;
                         label: var string) =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return
  var child = int(owner.nodes[slot].firstChild)
  while child > 0 and child < owner.nodes.len:
    let current = owner.nodes[child]
    if current.hasText and not current.accessHidden and
        not current.textOverlay and current.textValue.len > 0:
      if primarySeen:
        if label.len > 0:
          label.add " "
        label.add current.textValue
      else:
        primarySeen = true
    owner.collectSidebarLabel(child, primarySeen, label)
    child = int(current.nextSibling)

proc sidebarItem*(c: Context; id, label: string; icon: Svg = nil;
                  buildAccessory: proc() {.closure.} = nil): Element =
  ## Adds a selectable item to a Sidebar; buildAccessory may add a badge.
  if c == nil or c.owner == nil or not c.owner.inBuild or
      c.sidebarBuild == nil:
    raise newException(ValueError,
      "ui: Sidebar item must be built inside a Sidebar")
  if id.len == 0:
    raise newException(ValueError, "ui: Sidebar item ID cannot be empty")
  let sidebar = c.sidebarBuild
  let state = sidebar.state
  if state.sidebarEntryIndex(id) >= 0:
    raise newException(ValueError, "ui: Sidebar item IDs must be unique")
  let theme = c.theme
  discard c.key(id)
  result = c.row().alignItems(Align.Center).gap(theme.space(2'f32))
    .padding(theme.space(1.5'f32), theme.space(2'f32))
    .radius(theme.radius).shrink(0).focusable()
    .onClick(proc() = discard state.sidebarChoose(id))
  let row = result
  let node = row.node
  if node != nil:
    node[].accessRole = platform.roleTreeItem
    node[].accessRoleSet = true
    node[].accessLevel = sidebar.depth + 1
    node[].label = label
    node[].accessExtraStates = node[].accessExtraStates or
      platform.accessSelectable
    if state.selected == id:
      node[].accessExtraStates = node[].accessExtraStates or
        platform.accessSelected or platform.accessChecked
    node[].treeAccessFocus = proc() = discard state.sidebarChoose(id)
    node[].textInputHandler = proc(text: string) =
      discard state.sidebarTypeSelect(text, id, c)
    var handle = state.itemHandles.getOrDefault(id)
    discard row.bindHandle(handle)
    state.itemHandles[id] = handle
    state.entries.add(SidebarEntry(id: id, label: label,
      slot: int(row.slot), handle: handle))
    let chosen = state.selected == id
    if chosen:
      discard row.background(if row.focused(): theme.accent
        else: theme.surfacePressed)
        .textColor(if row.focused(): theme.accentText else: theme.text)
    elif row.hovered():
      discard row.background(theme.surfaceHover)
    if chosen and row.focusVisible():
      discard row.focusRing()
  discard row.children(proc() =
    if icon != nil:
      discard c.icon(icon).size(theme.space(4'f32), theme.space(4'f32))
        .shrink(0)
    let name = c.text(label).grow(1).minWidth(0)
    if name.node != nil:
      name.node[].textMaxLines = 1
    if buildAccessory != nil:
      buildAccessory()
  )
  var accessibleLabel = label
  var primarySeen = label.len == 0
  c.owner.collectSidebarLabel(int(row.slot), primarySeen, accessibleLabel)
  if int(row.slot) < c.owner.nodes.len:
    c.owner.nodes[int(row.slot)].label = accessibleLabel
