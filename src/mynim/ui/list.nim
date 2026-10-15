## Virtualized list elements and their frame-local row nodes.

proc rowSelectionHandler(state: ListState; row: int): proc() {.closure.} =
  result = proc() = state.select(row)

proc buildListRow(c: Context; state: ListState; rowIndex: int;
                  buildRow: proc(row: int) {.closure.};
                  pinnedHeader = false; listFocusVisible = false): Element =
  result = c.box().shrink(0)
  let rowNode = result.node
  let isHeader = state.isListHeader(rowIndex)
  if state.rowLabel != nil:
    discard result.label(state.rowLabel(rowIndex))
  if rowNode != nil:
    rowNode.listState = state
    rowNode.listRowIndex = rowIndex
    rowNode.listRowHeader = isHeader
    rowNode.listRowPinnedHeader = pinnedHeader
    if state.rowAccess != nil:
      let access = state.rowAccess(rowIndex)
      rowNode.accessRole = access.role
      rowNode.accessRoleSet = true
      rowNode.accessLevel = access.level
      rowNode.accessExtraStates = access.states
      rowNode.accessExtraActions = access.actions
    elif state.tableRowsRole:
      rowNode.accessRole = platform.roleRow
      rowNode.accessRoleSet = true
    let selected = if state.multiSelectionEnabled:
        state.isSelected(rowIndex)
      else:
        state.selected() == rowIndex
    rowNode.listRowSelected = selected
    rowNode.listRowFocusVisible = state.multiSelectionEnabled and
      listFocusVisible and state.selected() == rowIndex and not selected
    if state.reorderDragging and rowIndex in state.reorderRows:
      rowNode.opacity = 0.4'f32
      rowNode.opacitySet = true
    if selected:
      rowNode.background = c.theme.accent
      rowNode.listSelectedTextColor = c.theme.accentText
  if state.selectionEnabled and not isHeader:
    discard result.focusable().onClick(rowSelectionHandler(state, rowIndex))
  discard result.children(proc() =
    if buildRow != nil:
      buildRow(rowIndex)
  )

proc list*(c: Context; state: ListState; count: Natural;
           buildRow: proc(row: int) {.closure.}): Element =
  ## Builds only the rows visible in the viewport and a small overscan.
  ## Heights are measured as rows appear; unseen rows use the mean measured
  ## height, or the estimate passed to newListState before any are measured.
  ## rowLabel names each row for accessibility and type-to-select. When
  ## multiSelectable is enabled, selectedRows() and isSelected(row) let
  ## callers style the chosen rows.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: list must be built in a frame")
  if state.frameOwner == cast[pointer](c.owner) and
      state.generation == c.owner.generation:
    raise newException(ValueError, "ui: one ListState cannot build two lists in a frame")

  let plan = state.beginList(int(count))
  result = c.column().scrollY(state.scrollState)
  if state.selectionEnabled:
    discard result.focusable().focusRing(false)
  let container = result.node
  if container == nil:
    return
  container.listState = state
  container.listRowIndex = -1
  state.reorderColor = c.theme.accent
  state.frameOwner = cast[pointer](c.owner)
  state.frameSlot = int32(result.slot)
  state.generation = c.owner.generation

  discard result.children(proc() =
    if plan.first > 0 and plan.top > 0:
      discard c.box().height(plan.top).shrink(0)
    for rowIndex in plan.first..<plan.pastLast:
      discard c.buildListRow(state, rowIndex, buildRow,
        pinnedHeader = rowIndex == plan.pinnedHeader,
        listFocusVisible = container.focusVisible)
      if state.gap > 0 and rowIndex + 1 < plan.pastLast:
        discard c.box().height(state.gap).shrink(0)
    if plan.pastLast < state.rowCount:
      if state.gap > 0:
        discard c.box().height(state.gap).shrink(0)
      if plan.bottom > 0:
        discard c.box().height(plan.bottom).shrink(0)
    if plan.pinnedHeader >= 0 and
        (plan.pinnedHeader < plan.first or
          plan.pinnedHeader >= plan.pastLast):
      let y = listHeightFloat32(state.heights.listHeightTop(
        plan.pinnedHeader, state.gap))
      let header = c.buildListRow(state, plan.pinnedHeader, buildRow,
        pinnedHeader = true)
      discard header.absolute().top(y).left(0).right(0)
  )
