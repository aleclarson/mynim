## Virtualized list elements and their frame-local row nodes.

proc rowSelectionHandler(state: ListState; row: int): proc() {.closure.} =
  result = proc() = state.select(row)

proc list*(c: Context; state: ListState; count: Natural;
           buildRow: proc(row: int) {.closure.}): Element =
  ## Builds only the rows visible in the viewport and a small overscan.
  ## Heights are measured as rows appear; unseen rows use the mean measured
  ## height, or the estimate passed to newListState before any are measured.
  ## When multiSelectable is enabled, selectedRows() and isSelected(row)
  ## report its chosen rows; callers can use them to style each row.
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
    discard result.focusable()
  let container = result.node
  if container == nil:
    return
  container.listState = state
  container.listRowIndex = -1
  state.frameOwner = cast[pointer](c.owner)
  state.frameSlot = int32(result.slot)
  state.generation = c.owner.generation

  discard result.children(proc() =
    if plan.first > 0 and plan.top > 0:
      discard c.box().height(plan.top).shrink(0)
    for rowIndex in plan.first..<plan.pastLast:
      let row = c.box().shrink(0)
      let rowNode = row.node
      if rowNode != nil:
        rowNode.listState = state
        rowNode.listRowIndex = rowIndex
      if state.selectionEnabled:
        discard row.focusable().onClick(rowSelectionHandler(state, rowIndex))
      discard row.children(proc() =
        if buildRow != nil:
          buildRow(rowIndex)
      )
      if state.gap > 0 and rowIndex + 1 < plan.pastLast:
        discard c.box().height(state.gap).shrink(0)
    if plan.pastLast < state.rowCount:
      if state.gap > 0:
        discard c.box().height(state.gap).shrink(0)
      if plan.bottom > 0:
        discard c.box().height(plan.bottom).shrink(0)
  )
