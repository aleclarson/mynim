## Declarative trees with caller-owned item and expansion state.

proc newTreeState*(): TreeState =
  ## Creates persistent focus and navigation state for a Tree.
  new(result)

proc newTreeItemState*(key: string; open = false): TreeItemState =
  ## Creates a tree item's stable identity and expansion state.
  if key.len == 0:
    raise newException(ValueError, "ui: tree item key cannot be empty")
  TreeItemState(key: key, open: open)

proc treeRowIndex(state: TreeState; key: string): int =
  for index, row in state.rows:
    if row.item.key == key:
      return index
  -1

proc treeFocusRow(state: TreeState; slot: int): int =
  for index, row in state.rows:
    if row.slot == slot or row.arrowSlot == slot:
      return index
  -1

proc closeTreeActive(state: TreeState; row: int): bool =
  let active = state.treeRowIndex(state.activeKey)
  if active <= row:
    return
  var ancestor = active
  while ancestor >= 0:
    if ancestor == row:
      state.activeKey = state.rows[row].item.key
      return true
    ancestor = state.rows[ancestor].parent

proc treeAction(state: TreeState; row: int;
                action: platform.AccessActionKind): bool =
  if row < 0 or row >= state.rows.len or not state.rows[row].branch:
    return false
  let item = state.rows[row].item
  case action
  of platform.accessExpand:
    if item.open:
      return false
    item.open = true
  of platform.accessCollapse:
    if not item.open:
      return false
    item.open = false
    discard state.closeTreeActive(row)
  else:
    return false
  true

proc treeKey(state: TreeState; key: platform.Key;
             mods: platform.Modifiers; focusSlot: var int): bool =
  if state == nil or mods != platform.Modifiers(0) or state.rows.len == 0:
    return false
  var row = state.treeFocusRow(focusSlot)
  if row >= 0:
    state.activeKey = state.rows[row].item.key
  else:
    row = state.treeRowIndex(state.activeKey)
  if key == platform.keyUp or key == platform.keyDown:
    let next = if row < 0:
        (if key == platform.keyDown: 0 else: state.rows.high)
      else:
        row + (if key == platform.keyDown: 1 else: -1)
    if next < 0 or next >= state.rows.len:
      return false
    state.activeKey = state.rows[next].item.key
    focusSlot = state.rows[next].slot
    return true
  if row < 0:
    return false
  let current = state.rows[row]
  let forward = if state.rightToLeft: platform.keyLeft else: platform.keyRight
  let backward = if state.rightToLeft: platform.keyRight else: platform.keyLeft
  if key == forward:
    if current.branch and not current.item.open:
      current.item.open = true
      return true
    if current.branch and current.item.open and row + 1 < state.rows.len and
        state.rows[row + 1].parent == row:
      state.activeKey = state.rows[row + 1].item.key
      focusSlot = state.rows[row + 1].slot
      return true
  elif key == backward:
    if current.branch and current.item.open:
      current.item.open = false
      if state.closeTreeActive(row):
        focusSlot = current.slot
      return true
    if current.parent >= 0:
      state.activeKey = state.rows[current.parent].item.key
      focusSlot = state.rows[current.parent].slot
      return true

proc tree*(c: Context; state: TreeState;
           build: proc() {.closure.}): Element =
  ## Builds a declarative, keyboard-navigable tree.
  if state == nil:
    raise newException(ValueError, "ui: tree state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: tree must be built in a frame")
  state.rows.setLen(0)
  state.parents.setLen(0)
  state.depth = 0
  state.rightToLeft = c.rightToLeft
  let previousTree = c.treeState
  c.treeState = state
  try:
    result = c.column()
    if result.node != nil:
      result.node.accessRole = platform.roleTree
      result.node.accessRoleSet = true
      result.node.keyHandler = proc(key: platform.Key;
          mods: platform.Modifiers; focusSlot: var int): bool =
        state.treeKey(key, mods, focusSlot)
    discard result.children(proc() =
      if build != nil:
        build()
    )
    if state.treeRowIndex(state.activeKey) < 0:
      state.activeKey = ""
  finally:
    c.treeState = previousTree

proc treeItem*(c: Context; item: TreeItemState; label: string;
               buildChildren: proc() {.closure.} = nil;
               selected = false): Element =
  ## Adds an item, using selected to expose and style the caller's selection.
  if c == nil or c.owner == nil or not c.owner.inBuild or c.treeState == nil:
    raise newException(ValueError, "ui: tree item must be built inside a Tree")
  if item == nil or item.key.len == 0:
    raise newException(ValueError, "ui: tree item needs a stable non-empty key")
  let state = c.treeState
  if state.treeRowIndex(item.key) >= 0:
    raise newException(ValueError, "ui: tree item keys must be unique")
  let parent = if state.parents.len > 0: state.parents[^1] else: -1
  let index = state.rows.len
  let branch = buildChildren != nil
  state.rows.add(TreeRow(item: item, depth: state.depth,
    parent: parent, branch: branch))

  let theme = c.theme
  let row = c.row().height(theme.space(7)).gap(theme.space(0.5))
    .alignItems(Align.Center).padding(0, theme.space(2))
    .paddingStart(theme.space(1 + 4 * float32(state.depth)))
    .shrink(0).focusable()
  state.rows[index].slot = int(row.slot)
  if row.node != nil:
    row.node.accessRole = platform.roleTreeItem
    row.node.accessRoleSet = true
    row.node.accessLevel = state.depth + 1
    row.node.label = label
    row.node.treeAccessFocus = proc() = state.activeKey = item.key
    if selected:
      row.node.accessExtraStates = row.node.accessExtraStates or
        platform.accessSelectable
      row.node.accessExtraStates = row.node.accessExtraStates or
        platform.accessSelected
    if branch:
      row.node.accessExtraStates = row.node.accessExtraStates or
        platform.accessExpandable
      if item.open:
        row.node.accessExtraStates = row.node.accessExtraStates or
          platform.accessExpanded
      row.node.accessExtraActions = platform.actionExpand
      row.node.treeAccessAction = proc(action: platform.AccessActionKind): bool =
        state.treeAction(index, action)
  if selected:
    discard row.background(theme.accent).textColor(theme.accentText)
  discard row.onClick(proc() = state.activeKey = item.key)
  discard row.children(proc() =
    let arrow = c.box().size(theme.space(4), theme.space(4)).shrink(0)
      .focusRing(false)
    if branch:
      if arrow.node != nil:
        arrow.node.accessRole = platform.roleButton
        arrow.node.accessRoleSet = true
        arrow.node.label = (if item.open: "Collapse " else: "Expand ") & label
      discard arrow.onClick(proc() =
        state.activeKey = item.key
        item.open = not item.open
        if not item.open:
          discard state.closeTreeActive(index)
      )
      state.rows[index].arrowSlot = int(arrow.slot)
      let glyph = if item.open: "⌄"
        elif state.rightToLeft: "‹" else: "›"
      let color = if state.activeKey == item.key:
          theme.accentText
        else:
          theme.textMuted
      discard arrow.children(proc() =
        discard c.text(glyph).textColor(color)
      )
    discard c.text(label)
  )
  if branch and item.open:
    state.parents.add(index)
    inc state.depth
    try:
      buildChildren()
    finally:
      dec state.depth
      state.parents.setLen(state.parents.len - 1)
