## Column layout, sorting, and the virtualized row body of a table.

proc columnId*(column: TableColumn): string =
  ## Returns the stable layout and sorting key of a column.
  if column.id.len > 0: column.id else: column.title

proc arrange*(layout: TableLayout; columns: openArray[TableColumn]): seq[int] =
  ## Orders movable columns by the saved order and leaves fixed columns in place.
  var named: seq[int]
  for id in layout.order:
    for index, column in columns:
      if column.columnId == id and not column.fixed and index notin named:
        named.add(index)
        break
  var movable = named
  for index, column in columns:
    if not column.fixed and index notin named:
      movable.add(index)
  var nextMovable = 0
  for index, column in columns:
    if column.fixed:
      result.add(index)
    else:
      result.add(movable[nextMovable])
      inc nextMovable

proc clampWidth*(column: TableColumn; width: float32): float32 =
  ## Clamps a user-chosen width to the column's limits and a 16-DIP minimum.
  result = width
  if column.maxWidth > 0:
    result = min(result, column.maxWidth)
  result = max(result, max(column.minWidth, 16'f32))

proc columnWidth*(layout: TableLayout; column: TableColumn):
    tuple[width: float32, fixed: bool] =
  ## Returns the saved or declared width, or fixed=false for a flexible column.
  result.width = column.width
  if not column.fixed and layout.widths.hasKey(column.columnId):
    result.width = layout.widths[column.columnId]
  if result.width > 0:
    result.width = column.clampWidth(result.width)
    result.fixed = true

proc setWidth*(layout: var TableLayout; column: TableColumn; width: float32) =
  ## Persists a user-chosen width for a movable column.
  if column.fixed:
    return
  if layout.widths.len == 0:
    layout.widths = initTable[string, float32]()
  layout.widths[column.columnId] = column.clampWidth(width)

proc beginTableColumnDrag(state: ListState; column: string;
                          x: float32): bool =
  if state == nil or column.len == 0:
    return false
  state.tableDrag = TableDrag(column: column, startX: x, lastX: x)
  true

proc beginTableColumnResize(state: ListState; column: string; x: float32;
                            nodes: openArray[ElementNode];
                            rects: openArray[Rect]): bool =
  if state == nil or column.len == 0:
    return false
  var headers: seq[int]
  for slot in 1..<nodes.len:
    if nodes[slot].tableState == state and
        nodes[slot].tableColumnHeader and
        nodes[slot].tableColumnId.len > 0:
      headers.add(slot)
  var at = -1
  for index, slot in headers:
    if nodes[slot].tableColumnId == column:
      at = index
      break
  if at < 0:
    return false

  let header = headers[at]
  if nodes[header].tableColumnFixed:
    return false
  for index in 0..<at:
    let previous = headers[index]
    if nodes[previous].tableColumnFlexible:
      state.columns.setWidth(TableColumn(id: nodes[previous].tableColumnId,
        minWidth: nodes[previous].tableColumnMinWidth,
        maxWidth: nodes[previous].tableColumnMaxWidth), rects[previous].w)

  state.tableDrag = TableDrag(column: column, startX: x, lastX: x,
    startWidth: rects[header].w,
    minWidth: nodes[header].tableColumnMinWidth,
    maxWidth: nodes[header].tableColumnMaxWidth,
    rightToLeft: nodes[header].rightToLeft, resizing: true)
  true

proc updateTableColumnDrag(state: ListState; nodes: openArray[ElementNode];
                           rects: openArray[Rect]; x: float32): bool =
  if state == nil or state.tableDrag == nil:
    return false
  let drag = state.tableDrag
  if drag.resizing:
    let delta = (x - drag.startX) *
      (if drag.rightToLeft: -1'f32 else: 1'f32)
    state.columns.setWidth(TableColumn(id: drag.column,
      minWidth: drag.minWidth, maxWidth: drag.maxWidth),
      drag.startWidth + delta)
    drag.moving = drag.moving or abs(delta) > 0.01'f32
    return true
  drag.offsetX += x - drag.lastX
  drag.lastX = x
  if not drag.moving and abs(x - drag.startX) >= 4'f32:
    drag.moving = true
  if not drag.moving:
    return false

  var headers: seq[int]
  for slot in 1..<nodes.len:
    if nodes[slot].tableState == state and
        nodes[slot].tableColumnHeader and
        nodes[slot].tableColumnId.len > 0:
      headers.add(slot)
  var at = -1
  for index, slot in headers:
    if nodes[slot].tableColumnId == drag.column:
      at = index
      break
  if at < 0:
    return true

  let sign = if nodes[headers[at]].rightToLeft: -1'f32 else: 1'f32
  let distance = drag.offsetX * sign
  var to = at
  if distance > 0 and at + 1 < headers.len:
    let next = headers[at + 1]
    if not nodes[next].tableColumnFixed and rects[next].w > 0 and
        distance > rects[next].w / 2:
      to = at + 1
  elif distance < 0 and at > 0:
    let previous = headers[at - 1]
    if not nodes[previous].tableColumnFixed and rects[previous].w > 0 and
        -distance > rects[previous].w / 2:
      to = at - 1
  if to != at:
    var order = newSeq[string](headers.len)
    for index, slot in headers:
      order[index] = nodes[slot].tableColumnId
    swap(order[at], order[to])
    state.columns.order.setLen(0)
    for index, slot in headers:
      if not nodes[slot].tableColumnFixed:
        state.columns.order.add(order[index])
    let neighborWidth = rects[headers[to]].w
    if to > at:
      drag.offsetX -= sign * neighborWidth
    else:
      drag.offsetX += sign * neighborWidth
  true

proc finishTableColumnDrag(state: ListState): bool =
  if state == nil or state.tableDrag == nil:
    return false
  result = state.tableDrag.moving
  state.tableDrag = nil

proc cancelTableColumnDrag(state: ListState) =
  if state != nil:
    state.tableDrag = nil

proc usesMultiSort(state: ListState): bool =
  state.multiSort or state.sortBy.len > 0

proc syncSort(state: ListState) =
  if state == nil or not state.usesMultiSort:
    return
  state.sort = if state.sortBy.len > 0: state.sortBy[0] else: SortOrder()

proc enableMultiSort*(state: ListState; orders: seq[SortOrder] = @[]) =
  ## Enables additive sorting with Command-click or Shift-click on headers.
  ## The supplied sequence is copied into persistent table state.
  if state == nil:
    raise newException(ValueError, "ui: table state cannot be nil")
  state.multiSort = true
  var copied = newSeqOfCap[SortOrder](orders.len)
  for order in orders:
    copied.add(order)
  state.sortBy = copied
  state.syncSort()

proc sortPlace(state: ListState; column: TableColumn):
    tuple[position: int, descending: bool] =
  result.position = -1
  if not column.sortable:
    return
  let id = column.columnId
  if state.usesMultiSort:
    for index, order in state.sortBy:
      if order.column == id:
        return (index, order.descending)
  elif state.sort.column == id and id.len > 0:
    return (0, state.sort.descending)

proc sortClicked(state: ListState; id: string; add: bool) =
  if not state.usesMultiSort:
    if state.sort.column == id:
      state.sort.descending = not state.sort.descending
    else:
      state.sort = SortOrder(column: id)
    return

  var at = -1
  for index, order in state.sortBy:
    if order.column == id:
      at = index
      break
  if not add:
    if at == 0:
      state.sortBy = @[SortOrder(column: id,
        descending: not state.sortBy[0].descending)]
    else:
      state.sortBy = @[SortOrder(column: id)]
  else:
    var next: seq[SortOrder]
    for index, order in state.sortBy:
      if index == at:
        if not order.descending:
          next.add(SortOrder(column: id, descending: true))
      else:
        next.add(order)
    if at < 0:
      next.add(SortOrder(column: id))
    state.sortBy = next
  state.syncSort()

proc sortHeader(state: ListState; id: string;
                mods: platform.Modifiers) =
  state.sortClicked(id, (mods and
    (platform.modSuper or platform.modShift)) != 0)

proc tableCells(c: Context; state: ListState;
                columns: openArray[TableColumn]; order: seq[int];
                layout: TableLayout; flexMin: float32; role: platform.AccessRole;
                fill: proc(column: int; box: Element) {.closure.}) =
  let theme = c.theme
  for index in order:
    let columnIndex = index
    let column = columns[index]
    let box = c.row().padding(theme.space(1.5), theme.space(2.5))
      .alignItems(Align.Center).shrink(0).clip()
    let size = layout.columnWidth(column)
    let fitting = state.tableFitColumn == column.columnId
    if not fitting:
      if size.fixed:
        discard box.width(size.width)
      else:
        discard box.grow().shrink(1).minWidth(max(column.minWidth, flexMin))
    if column.align == Align.Center or column.align == Align.End:
      discard box.justify(column.align)
    if box.node != nil:
      box.node.accessRole = role
      box.node.accessRoleSet = true
      if role == platform.roleColumnHeader:
        box.node.label = column.title
      box.node.tableState = state
      box.node.tableColumnId = column.columnId
      box.node.tableColumnFixed = column.fixed
      box.node.tableColumnHeader = role == platform.roleColumnHeader
      box.node.tableColumnFlexible = not size.fixed
      box.node.tableColumnMinWidth = column.minWidth
      box.node.tableColumnMaxWidth = column.maxWidth
      box.node.tableFitMeasure = fitting
    discard box.children(proc() =
      if fill != nil:
        fill(columnIndex, box)
    )

proc table*(c: Context; state: ListState; columns: openArray[TableColumn];
            count: Natural;
            cell: proc(row, column: int) {.closure.}): Element =
  ## Builds a table with virtualized rows and persistent column layout.
  ## Sort state is updated by clicking sortable headers; the cell callback
  ## receives each row and its original column index. List selection, row
  ## labels, and pinned section headers come from state as they do for list.
  if state == nil:
    raise newException(ValueError, "ui: table state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: table must be built in a frame")

  let columnList = @columns
  let theme = c.theme
  state.syncSort()
  let headerHeight = theme.space(8)
  let flexMin = theme.space(15)
  let order = state.columns.arrange(columnList)
  var leastWidth = 0'f32
  for index in order:
    let column = columnList[index]
    let width = state.columns.columnWidth(column)
    let minColumnWidth = if width.fixed: width.width
      else: max(column.minWidth, flexMin)
    leastWidth += minColumnWidth

  result = c.column().clip().focusable().focusRing(false)
  if result.node != nil:
    result.node.accessRole = if state.outlineMode:
        platform.roleTree
      else:
        platform.roleTable
    result.node.accessRoleSet = true
    result.node.listState = state
    result.node.listRowIndex = -1

  discard result.children(proc() =
    let header = c.row().height(headerHeight).minWidth(leastWidth)
      .shrink(0).alignItems(Align.Stretch).clipX()
    if header.node != nil:
      header.node.accessRole = platform.roleRow
      header.node.accessRoleSet = true
    discard header.children(proc() =
      c.tableCells(state, columnList, order, state.columns, flexMin,
        platform.roleColumnHeader, proc(index: int; box: Element) =
          let column = columnList[index]
          let title = c.text(column.title).textWeight(600)
            .textColor(theme.textMuted).shrink(1)
          discard title
          let sort = state.sortPlace(column)
          if sort.position >= 0:
            if state.usesMultiSort and state.sortBy.len > 1:
              discard c.text($(sort.position + 1))
                .textSize(theme.fontSize * 0.75).textColor(theme.textMuted)
                .shrink(0)
            discard c.text(if sort.descending: "↓" else: "↑")
              .textColor(theme.textMuted).shrink(0)
          if column.sortable:
            let id = column.columnId
            discard box.onClick(proc(mods: platform.Modifiers) =
              state.sortHeader(id, mods)
            )
            if sort.position >= 0:
              if box.node != nil:
                box.node.accessSort = if sort.descending:
                  platform.accessSortDescending
                else:
                  platform.accessSortAscending
          if not column.fixed:
            let edge = c.box().absolute().top(0).bottom(0).width(2)
              .endInset(0)
            if edge.node != nil:
              edge.node.tableState = state
              edge.node.tableColumnId = column.columnId
              edge.node.tableResizeHandle = true
            discard edge.background(if edge.hovered() or edge.pressed():
              theme.accent else: theme.border)
      )
    )

    discard c.box().height(1).shrink(0).background(theme.border)
    state.tableRowsRole = true
    var list: Element
    try:
      list = c.list(state, count, proc(rowIndex: int) =
        let row = c.row().minHeight(headerHeight).minWidth(leastWidth)
          .alignItems(Align.Stretch)
        if state.isListHeader(rowIndex):
          discard row.alignItems(Align.Center).padding(theme.space(1.5),
            theme.space(2.5)).background(theme.surface)
          discard row.children(proc() =
            if cell != nil:
              cell(rowIndex, 0)
          )
        else:
          discard row.children(proc() =
            c.tableCells(state, columnList, order, state.columns, flexMin,
              platform.roleCell, proc(index: int; box: Element) =
                if cell != nil:
                  cell(rowIndex, index)
            )
          )
      ).grow(1).scrollX(state.scrollState)
    finally:
      state.tableRowsRole = false
    if list.node != nil:
      list.node.accessRole = platform.roleGroup
      list.node.accessRoleSet = true
    discard header.scrollWith(list)
  )
