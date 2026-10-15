## Virtualized trees built from list and table rows.

type
  OutlineItemKey*[K] = proc(item: K): string {.closure.}
    ## Returns a stable, unique key for an outline item.
  OutlineChildren*[K] = proc(item: K): seq[K] {.closure.}
    ## Returns an item's children; an empty sequence marks a leaf.
  OutlineRowBuilder*[K] = proc(item: K) {.closure.}

  OutlineRow[K] = object
    item: K
    depth, parent: int
    branch: bool

  OutlineState*[K] = ref object
    ## Persistent expanded items, flattened rows, and list behavior.
    list*: ListState
    indent*: float32 ## Indent per tree level; zero uses theme spacing.
    rows: seq[OutlineRow[K]]
    openItems: HashSet[string]
    itemKey: OutlineItemKey[K]
    itemLabel: OutlineItemKey[K]
    children: OutlineChildren[K]
    rightToLeft: bool

proc outlineHas[K](state: OutlineState[K]; item: K): bool =
  state.itemKey(item) in state.openItems

proc outlineSetOpen[K](state: OutlineState[K]; item: K; open, all: bool;
                       children: OutlineChildren[K]) =
  var visited = initHashSet[string]()
  proc apply(current: K) =
    let key = state.itemKey(current)
    if key in visited:
      return
    visited.incl(key)
    if open:
      state.openItems.incl(key)
    else:
      state.openItems.excl(key)
    if all and children != nil:
      for child in children(current):
        if children(child).len > 0:
          apply(child)
  apply(item)

proc closeOutlineSelection[K](state: OutlineState[K]; row: int;
                              wasOpen: bool) =
  let selected = state.list.selected()
  if not wasOpen or selected <= row or selected >= state.rows.len:
    return
  var ancestor = selected
  while ancestor >= 0:
    if ancestor == row:
      state.list.select(row)
      return
    ancestor = state.rows[ancestor].parent

proc outlineRowAccess[K](state: OutlineState[K]; row: int): ListRowAccess =
  let item = state.rows[row]
  result.role = platform.roleTreeItem
  result.level = item.depth + 1
  if item.branch:
    result.states = platform.accessExpandable
    if state.outlineHas(item.item):
      result.states = result.states or platform.accessExpanded
    result.actions = platform.actionExpand

proc outlineAccessAction[K](state: OutlineState[K]; row: int;
                            action: platform.AccessActionKind): bool =
  if row < 0 or row >= state.rows.len or not state.rows[row].branch:
    return false
  let item = state.rows[row].item
  case action
  of platform.accessExpand:
    if state.outlineHas(item):
      return false
    state.outlineSetOpen(item, true, false, nil)
  of platform.accessCollapse:
    if not state.outlineHas(item):
      return false
    state.outlineSetOpen(item, false, false, nil)
    state.closeOutlineSelection(row, true)
  else:
    return false
  true

proc outlineKey[K](state: OutlineState[K]; key: platform.Key;
                   mods: platform.Modifiers;
                   children: OutlineChildren[K]): bool =
  let selected = state.list.selected()
  if selected < 0 or selected >= state.rows.len:
    return false
  let row = state.rows[selected]
  let forward = if state.rightToLeft: platform.keyLeft else: platform.keyRight
  let backward = if state.rightToLeft: platform.keyRight else: platform.keyLeft
  let allMods = when defined(macosx): platform.modAlt else: platform.modShift
  let all = (mods and allMods) != 0
  let isOpen = row.branch and state.outlineHas(row.item)
  if key == forward and row.branch and (not isOpen or all):
    state.outlineSetOpen(row.item, true, all, children)
    return true
  if key == forward and isOpen and selected + 1 < state.rows.len and
      state.rows[selected + 1].parent == selected:
    state.list.select(selected + 1)
    return true
  if (key == backward or (all and key == backward)) and isOpen:
    state.outlineSetOpen(row.item, false, all, children)
    state.closeOutlineSelection(selected, true)
    return true
  if (key == backward or (all and key == backward)) and row.parent >= 0:
    state.list.select(row.parent)
    return true

proc newOutlineState*[K](itemKey: OutlineItemKey[K];
                         estimatedRowHeight = 28'f32; indent = 0'f32;
                         selectable = true; multiSelectable = false;
                         itemLabel: OutlineItemKey[K] = nil): OutlineState[K] =
  ## Creates persistent outline state. itemKey must be stable and unique.
  if itemKey == nil:
    raise newException(ValueError, "ui: outline item key cannot be nil")
  if classify(indent) in {fcNan, fcInf, fcNegInf} or indent < 0:
    raise newException(ValueError, "ui: outline indent cannot be negative")
  new(result)
  result.itemKey = itemKey
  result.itemLabel = if itemLabel == nil: itemKey else: itemLabel
  result.indent = indent
  result.openItems = initHashSet[string]()
  let currentState = result
  result.list = newListState(estimatedRowHeight,
    rowKey = proc(row: int): string =
      currentState.itemKey(currentState.rows[row].item),
    selectable = selectable, multiSelectable = multiSelectable)
  result.list.rowLabel = proc(row: int): string =
    currentState.itemLabel(currentState.rows[row].item)
  result.list.rowAccess = proc(row: int): ListRowAccess =
    currentState.outlineRowAccess(row)
  result.list.rowAccessAction = proc(row: int;
      action: platform.AccessActionKind): bool =
    currentState.outlineAccessAction(row, action)
  result.list.keyHandler = proc(key: platform.Key;
      mods: platform.Modifiers): bool =
    currentState.outlineKey(key, mods, currentState.children)

proc newOutlineState*[K](itemKey: OutlineItemKey[K];
                         children: OutlineChildren[K];
                         estimatedRowHeight = 28'f32; indent = 0'f32;
                         selectable = true; multiSelectable = false;
                         itemLabel: OutlineItemKey[K] = nil): OutlineState[K] =
  ## Creates persistent outline state with Right/Left tree navigation.
  result = newOutlineState(itemKey, estimatedRowHeight, indent, selectable,
    multiSelectable, itemLabel)
  let currentState = result
  currentState.children = children
  result.list.keyHandler = proc(key: platform.Key;
      mods: platform.Modifiers): bool =
    currentState.outlineKey(key, mods, currentState.children)

proc rowCount*[K](state: OutlineState[K]): int =
  ## Returns the number of flattened rows from the most recent build.
  if state != nil: result = state.rows.len

proc item*[K](state: OutlineState[K]; row: int): K = state.rows[row].item

proc depth*[K](state: OutlineState[K]; row: int): int = state.rows[row].depth

proc isOpen*[K](state: OutlineState[K]; item: K): bool =
  state != nil and state.outlineHas(item)

proc setOpen*[K](state: OutlineState[K]; item: K; open: bool;
                 children: OutlineChildren[K]; all = false) =
  ## Opens or closes an item and optionally all descendant branches.
  if state == nil:
    raise newException(ValueError, "ui: outline state cannot be nil")
  state.children = children
  state.outlineSetOpen(item, open, all, children)

proc flatten[K](state: OutlineState[K]; roots: openArray[K];
                children: OutlineChildren[K]) =
  if state.indent < 0 or classify(state.indent) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: outline indent cannot be negative")
  state.rows.setLen(0)
  var path = initHashSet[string]()
  proc walk(items: openArray[K]; depth, parent: int) =
    for item in items:
      let kids = if children == nil: newSeq[K]() else: children(item)
      let key = state.itemKey(item)
      let row = state.rows.len
      state.rows.add(OutlineRow[K](item: item, depth: depth,
        parent: parent, branch: kids.len > 0))
      if kids.len > 0 and state.outlineHas(item) and key notin path:
        path.incl(key)
        walk(kids, depth + 1, row)
        path.excl(key)
  walk(roots, 0, -1)

proc outlinePrefix[K](c: Context; state: OutlineState[K]; index: int;
                      children: OutlineChildren[K];
                      content: proc() {.closure.}) =
  let treeRow = state.rows[index]
  let theme = c.theme
  let indent = if state.indent > 0: state.indent else: theme.space(4)
  if treeRow.depth > 0:
    discard c.box().width(float32(treeRow.depth) * indent).shrink(0)
  let arrow = c.row().size(theme.space(4), theme.space(4)).shrink(0)
    .alignItems(Align.Center).justify(Align.Center).focusRing(false)
  if treeRow.branch:
    let isOpen = state.outlineHas(treeRow.item)
    if arrow.node != nil:
      arrow.node.listState = state.list
      arrow.node.listRowIndex = index
      arrow.node.listRowAction = true
      arrow.node.accessRole = platform.roleButton
      arrow.node.accessRoleSet = true
      let label = state.itemLabel(treeRow.item)
      arrow.node.label = (if isOpen: "Collapse " else: "Expand ") & label
    discard arrow.onClick(proc(mods: platform.Modifiers) =
      let all = (mods and platform.modAlt) != 0
      state.outlineSetOpen(treeRow.item, not isOpen, all, children)
      if isOpen:
        state.closeOutlineSelection(index, true)
    )
    discard arrow.children(proc() =
      let glyph = if isOpen: "⌄"
        elif state.rightToLeft: "‹" else: "›"
      let color = if state.list.selected() == index:
          theme.accentText
        else:
          theme.textMuted
      discard c.text(glyph).textColor(color)
    )
  else:
    discard arrow
  if content != nil:
    content()

proc outline*[K](c: Context; state: OutlineState[K]; roots: openArray[K];
                 children: OutlineChildren[K]; row: OutlineRowBuilder[K]):
                 Element =
  ## Builds a virtualized tree. The cell callback receives each visible item.
  if state == nil:
    raise newException(ValueError, "ui: outline state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: outline must be built in a frame")
  let rootItems = @roots
  state.rightToLeft = c.rightToLeft
  state.children = children
  state.flatten(rootItems, children)
  let currentState = state
  result = c.list(state.list, state.rows.len, proc(index: int) =
    let line = c.row().gap(c.theme.space(1))
      .alignItems(Align.Center).padding(c.theme.space(1), c.theme.space(2))
    discard line.children(proc() =
      c.outlinePrefix(currentState, index, children, proc() =
        if row != nil:
          row(currentState.rows[index].item)
      )
    )
  )
  if result.node != nil:
    result.node.accessRole = platform.roleTree
    result.node.accessRoleSet = true

proc outlineTable*[K](c: Context; state: OutlineState[K];
                      columns: openArray[TableColumn]; roots: openArray[K];
                      children: OutlineChildren[K];
                      cell: proc(item: K; column: int) {.closure.}): Element =
  ## Builds a virtualized outline table, indenting and toggling in column zero.
  if state == nil:
    raise newException(ValueError, "ui: outline state cannot be nil")
  let rootItems = @roots
  state.rightToLeft = c.rightToLeft
  state.children = children
  state.flatten(rootItems, children)
  state.list.outlineMode = true
  try:
    result = c.table(state.list, columns, state.rows.len,
      proc(index, column: int) =
        let item = state.rows[index].item
        if column == 0:
          c.outlinePrefix(state, index, children, proc() =
            if cell != nil:
              cell(item, column)
          )
        elif cell != nil:
          cell(item, column)
    )
  finally:
    state.list.outlineMode = false
