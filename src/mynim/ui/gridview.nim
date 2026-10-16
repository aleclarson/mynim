## Responsive, virtualized grids with single-item selection.

proc newGridState*(selectable = false; itemKey: GridItemKey = nil;
                   itemLabel: GridItemLabel = nil): GridState =
  ## Creates retained selection and scroll state for a virtualized grid.
  new(result)
  result.selectedItem = -1
  result.selectable = selectable
  result.itemKey = itemKey
  result.itemLabel = itemLabel
  result.rows = newListState()
  result.rows.rowAccess = proc(row: int): ListRowAccess =
    ListRowAccess(role: platform.roleGroup)

func selected*(state: GridState): int =
  ## Returns the selected item index, or -1 when none is selected.
  if state == nil: -1 else: state.selectedItem

proc selectGridItem(state: GridState; item: int) =
  if state == nil or item < -1:
    return
  if state.selectedItem != item:
    state.selectedItem = item
    state.pendingChanged = true
  if item >= 0 and state.rows != nil:
    state.rows.scrollIntoView(item div max(state.columns, 1))

proc select*(state: GridState; item: int) =
  ## Selects an item, or clears selection with -1.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if item < -1:
    raise newException(ValueError, "ui: selected item must be -1 or greater")
  state.selectGridItem(item)

proc scrollTo*(state: GridState; item: int; align = Align.Start) =
  ## Scrolls to show an item at the requested vertical alignment.
  if state == nil or state.rows == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if item < 0:
    raise newException(ValueError, "ui: grid item must be zero or greater")
  state.rows.scrollTo(item div max(state.columns, 1), align)

proc scrollIntoView*(state: GridState; item: int) =
  ## Scrolls only when the requested item is outside the viewport.
  if state == nil or state.rows == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if item < 0:
    raise newException(ValueError, "ui: grid item must be zero or greater")
  state.rows.scrollIntoView(item div max(state.columns, 1))

func offset*(state: GridState): tuple[x, y: float32] =
  ## Returns the current horizontal and vertical scroll offsets.
  if state != nil and state.rows != nil:
    result = state.rows.offset()

func visible*(state: GridState): tuple[first, last: int] =
  ## Returns the first and last visible item indices, or an empty range.
  if state == nil or state.rows == nil:
    return (first: 0, last: -1)
  let rows = state.rows.visible()
  if rows.last < rows.first:
    return (first: 0, last: -1)
  let columns = min(max(state.columns, 1), max(state.itemCount, 1))
  let firstItem = int64(rows.first) * int64(columns)
  let lastItem = min(int64(state.itemCount) - 1,
    (int64(rows.last) + 1) * int64(columns) - 1)
  (first: int(firstItem), last: int(lastItem))

proc gridKey(state: GridState; key: platform.Key;
             mods: platform.Modifiers): bool =
  if state == nil or not state.selectable or state.itemCount <= 0 or mods != 0:
    return false

  let count = state.itemCount
  let columns = min(max(state.columns, 1), max(state.itemCount, 1))
  let current = state.selectedItem
  let selected = current >= 0 and current < count
  var target = -1

  case key
  of platform.keyEnter:
    if selected:
      state.pendingSubmitted = true
      return true
  of platform.keyHome:
    target = 0
  of platform.keyEnd:
    target = count - 1
  of platform.keyLeft:
    if not selected:
      target = 0
    elif state.rightToLeft and current + 1 < count:
      target = current + 1
    elif not state.rightToLeft and current > 0:
      target = current - 1
  of platform.keyRight:
    if not selected:
      target = 0
    elif state.rightToLeft and current > 0:
      target = current - 1
    elif not state.rightToLeft and current + 1 < count:
      target = current + 1
  of platform.keyUp:
    if not selected:
      target = 0
    elif current >= columns:
      target = current - columns
  of platform.keyDown:
    if not selected:
      target = 0
    elif current + columns < count:
      target = current + columns
    elif current div columns < (count - 1) div columns:
      target = count - 1
  else:
    return false

  if target < 0:
    return false
  state.selectGridItem(target)
  true

proc gridView*(c: Context; state: GridState; count: Natural;
               minItemWidth, itemHeight: float32;
               buildItem: proc(item: int) {.closure.}): Element =
  ## Builds a responsive, virtualized grid. Cells are at least minItemWidth
  ## wide and itemHeight tall; selection and keyboard navigation are optional.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if c == nil or c.owner == nil or not c.owner.inBuild:
    raise newException(ValueError, "ui: grid must be built in a frame")
  if not minItemWidth.finiteMotion or minItemWidth <= 0 or
      not itemHeight.finiteMotion or itemHeight <= 0:
    raise newException(ValueError,
      "ui: grid item width and height must be positive and finite")

  let gap = c.theme.space(2)
  let rowHeight = float64(itemHeight) + float64(gap)
  if not gap.finiteMotion or gap < 0 or rowHeight > float64(high(float32)):
    raise newException(ValueError, "ui: grid spacing and item height are too large")
  if state.rows == nil:
    state.rows = newListState(float32(rowHeight))
    state.rows.rowAccess = proc(row: int): ListRowAccess =
      ListRowAccess(role: platform.roleGroup)
  elif state.itemHeight != itemHeight or state.gap != gap:
    state.rows.heights.defaultHeight = rowHeight
    state.rows.heights.dirty = true

  state.itemCount = int(count)
  state.itemHeight = itemHeight
  state.gap = gap
  if state.selectedItem >= state.itemCount:
    state.selectedItem = -1
    state.pendingChanged = true

  let columns = min(max(state.columns, 1), max(state.itemCount, 1))
  let rowCount = if state.itemCount == 0: 0 else:
    (state.itemCount - 1) div columns + 1
  var activeIdentity = 0'u64
  var cellSlots: seq[int]

  result = c.list(state.rows, Natural(rowCount), proc(row: int) =
    let first = row * columns
    let itemCount = min(columns, state.itemCount - first)
    discard c.row().gap(gap).paddingY(gap / 2).alignItems(Align.Stretch)
      .shrink(0).children(proc() =
        for offset in 0..<itemCount:
          let item = first + offset
          let itemIndex = item
          if state.itemKey != nil:
            discard c.key(state.itemKey(itemIndex))
          else:
            discard c.key(itemIndex)
          let cell = c.column().grow().basis(0).minWidth(0)
            .height(itemHeight).shrink(0)
          let node = cell.node
          if node != nil:
            cellSlots.add(int(cell.slot))
            node[].accessRole = platform.roleListItem
            node[].accessRoleSet = true
            node[].accessPosInSet = itemIndex + 1
            node[].accessSetSize = state.itemCount
            if state.selectable:
              node[].accessExtraStates = platform.accessSelectable
              if state.selectedItem == itemIndex:
                node[].accessExtraStates = node[].accessExtraStates or
                  platform.accessSelected
                node[].background = c.theme.accent
                activeIdentity = node[].identity
            if state.itemLabel != nil:
              node[].label = state.itemLabel(itemIndex)
          if state.selectable:
            discard cell.tabStop(false).onClick(
              proc(mods: platform.Modifiers) =
                if itemIndex < state.itemCount:
                  state.selectGridItem(itemIndex)
            )
          discard cell.children(proc() =
            if buildItem != nil:
              buildItem(itemIndex)
          )
        for _ in itemCount..<columns:
          discard c.box().grow().basis(0).minWidth(0)
      )
  )

  let root = result.node
  if root == nil:
    return
  root[].gridViewState = state
  root[].gridMinWidth = minItemWidth
  root[].gridGap = gap
  state.rightToLeft = root[].rightToLeft
  for slot in cellSlots:
    c.owner.nodes[slot].focusTargetSlot = int32(result.slot)
  root[].accessExtraStates = root[].accessExtraStates or
    (if state.selectable: platform.accessSelectable
     else: platform.AccessStates(0))
  if state.selectable:
    discard result.focusable().focusRing(false)
    root[].keyHandler = proc(key: platform.Key; mods: platform.Modifiers;
                             focusSlot: var int): bool =
      state.gridKey(key, mods)
  if state.selectable:
    root[].activeDescendantIdentity = activeIdentity
  if state.pendingChanged:
    result.markBoundValueChanged()
    state.pendingChanged = false
  if state.pendingSubmitted:
    root[].submitted = true
    state.pendingSubmitted = false
