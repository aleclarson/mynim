## Responsive, virtualized grids with retained selection and reordering.

proc gridItemKey(state: GridState; item: int): string =
  if state.itemKey == nil: $item else: state.itemKey(item)

proc gridSelectionCount(state: GridState): int =
  if state.externalKeySelection != nil:
    state.externalKeySelection.len
  elif state.externalIndexSelection != nil:
    state.externalIndexSelection.len
  else:
    state.selectedKeys.len

proc gridItemIsSelected(state: GridState; item: int): bool =
  if state.externalKeySelection != nil:
    state.externalKeySelection.has(state.gridItemKey(item))
  elif state.externalIndexSelection != nil:
    state.externalIndexSelection.has(item)
  else:
    state.selectedKeys.contains(state.gridItemKey(item))

proc setGridItemSelected(state: GridState; item: int;
                         selected: bool): bool =
  let exists = state.gridItemIsSelected(item)
  if exists == selected:
    return false
  if state.externalKeySelection != nil:
    if selected:
      state.externalKeySelection.add(state.gridItemKey(item))
    else:
      state.externalKeySelection.remove(state.gridItemKey(item))
  elif state.externalIndexSelection != nil:
    if selected:
      state.externalIndexSelection.add(item)
    else:
      state.externalIndexSelection.remove(item)
  if selected:
    state.selectedKeys.incl(state.gridItemKey(item))
  else:
    state.selectedKeys.excl(state.gridItemKey(item))
  true

proc clearGridSelection(state: GridState): bool =
  result = state.gridSelectionCount() > 0
  state.selectedKeys.clear()
  if state.externalKeySelection != nil:
    state.externalKeySelection.clear()
  if state.externalIndexSelection != nil:
    state.externalIndexSelection.clear()

proc findGridItemKey(state: GridState; key: string; nearItem: int): int =
  if state == nil or state.itemCount <= 0:
    return -1
  let near = max(0, min(nearItem, state.itemCount - 1))
  for distance in 0..1000:
    let before = near - distance
    if before >= 0 and state.gridItemKey(before) == key:
      return before
    let after = int64(near) + int64(distance)
    if distance > 0 and after < int64(state.itemCount) and
        state.gridItemKey(int(after)) == key:
      return int(after)
  -1

proc setGridPivot(state: GridState; item: int) =
  state.selectionPivot = item
  state.selectionPivotKeyValid = item >= 0 and item < state.itemCount
  state.selectionPivotKey = if state.selectionPivotKeyValid:
      state.gridItemKey(item)
    else:
      ""

proc syncGridItems(state: GridState; count: int) =
  state.itemCount = max(count, 0)
  if state.selectedItem >= 0:
    if state.selectedKeyValid:
      let same = state.selectedItem < state.itemCount and
        state.gridItemKey(state.selectedItem) == state.selectedKey
      if not same:
        let moved = state.findGridItemKey(state.selectedKey,
          state.selectedItem)
        if moved >= 0:
          state.selectedItem = moved
          state.pendingChanged = true
        else:
          state.selectedItem = -1
          state.selectedKey = ""
          state.selectedKeyValid = false
          state.pendingChanged = true
    elif state.selectedItem < state.itemCount:
      state.selectedKey = state.gridItemKey(state.selectedItem)
      state.selectedKeyValid = true
    else:
      state.selectedItem = -1
      state.pendingChanged = true
  else:
    state.selectedKey = ""
    state.selectedKeyValid = false

  if state.selectionPivotKeyValid:
    let same = state.selectionPivot >= 0 and
      state.selectionPivot < state.itemCount and
      state.gridItemKey(state.selectionPivot) == state.selectionPivotKey
    if not same:
      state.selectionPivot = state.findGridItemKey(
        state.selectionPivotKey, state.selectionPivot)
      if state.selectionPivot < 0:
        state.selectionPivotKey = ""
        state.selectionPivotKeyValid = false
      else:
        state.selectionPivotKey = state.gridItemKey(state.selectionPivot)
  elif state.selectionPivot >= state.itemCount:
    state.selectionPivot = -1

proc newGridState*(selectable = false; itemKey: GridItemKey = nil;
                   itemLabel: GridItemLabel = nil;
                   multiSelectable = false;
                   reorder: GridItemReorder = nil): GridState =
  ## Creates retained selection and scroll state for a virtualized grid.
  new(result)
  result.selectedItem = -1
  result.selectionPivot = -1
  result.reorderOrigin = -1
  result.reorderTarget = -1
  result.reorderTargetCell = -1
  result.selectable = selectable or multiSelectable
  result.multiSelectable = multiSelectable
  result.itemKey = itemKey
  result.itemLabel = itemLabel
  result.reorder = reorder
  result.selectedKeys = initHashSet[string]()
  result.rows = newListState()
  result.rows.rowAccess = proc(row: int): ListRowAccess =
    ListRowAccess(role: platform.roleGroup)

proc bindSelection*(state: GridState;
                    selection: var Selection[string]): GridState =
  ## Binds app-owned selection to a grid with stable string item keys.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if state.itemKey == nil:
    raise newException(ValueError,
      "ui: string selection requires a grid itemKey")
  selection.ensure()
  state.externalKeySelection = selection
  state.externalIndexSelection = nil
  state.selectedKeys.clear()
  state.selectable = true
  state.multiSelectable = true
  state

proc bindSelection*(state: GridState;
                    selection: var Selection[int]): GridState =
  ## Binds app-owned selection to an unkeyed grid, using item indices as keys.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if state.itemKey != nil:
    raise newException(ValueError,
      "ui: integer selection requires a grid without itemKey")
  selection.ensure()
  state.externalKeySelection = nil
  state.externalIndexSelection = selection
  state.selectedKeys.clear()
  state.selectable = true
  state.multiSelectable = true
  state

func selected*(state: GridState): int =
  ## Returns the active item index, or -1 when no item is active.
  if state == nil: -1 else: state.selectedItem

proc isSelected*(state: GridState; item: int): bool =
  ## Reports whether item belongs to the current selection.
  if state == nil or item < 0 or item >= state.itemCount:
    return false
  if state.multiSelectable:
    state.gridItemIsSelected(item)
  else:
    state.selectedItem == item

proc selectedItems*(state: GridState): seq[int] =
  ## Returns selected item indices in grid order.
  if state == nil:
    return
  for item in 0..<state.itemCount:
    if state.isSelected(item):
      result.add(item)

proc chooseGridItem(state: GridState; item: int) =
  if state == nil or item < -1:
    return
  var changed = state.selectedItem != item
  if item < 0:
    let hadSelection = state.clearGridSelection()
    if state.multiSelectable and hadSelection:
      changed = true
    state.selectedItem = -1
    state.selectedKey = ""
    state.selectedKeyValid = false
    state.setGridPivot(-1)
  else:
    let key = state.gridItemKey(item)
    if state.multiSelectable:
      if state.gridSelectionCount() != 1 or
          not state.gridItemIsSelected(item):
        changed = true
      discard state.clearGridSelection()
      discard state.setGridItemSelected(item, true)
    elif state.gridSelectionCount() > 0:
      discard state.clearGridSelection()
      changed = true
    state.selectedItem = item
    state.selectedKey = key
    state.selectedKeyValid = true
    state.setGridPivot(item)
    if state.rows != nil:
      state.rows.scrollIntoView(item div max(state.columns, 1))
  if changed:
    state.pendingChanged = true

proc toggleGridItem(state: GridState; item: int) =
  if state == nil or item < 0 or item >= state.itemCount:
    return
  if not state.multiSelectable:
    state.chooseGridItem(item)
    return
  discard state.setGridItemSelected(item, not state.gridItemIsSelected(item))
  state.selectedItem = item
  state.selectedKey = state.gridItemKey(item)
  state.selectedKeyValid = true
  state.setGridPivot(item)
  if state.rows != nil:
    state.rows.scrollIntoView(item div max(state.columns, 1))
  state.pendingChanged = true

proc extendGridSelection(state: GridState; item: int) =
  if state == nil or item < 0 or item >= state.itemCount:
    return
  if not state.multiSelectable or state.selectionPivot < 0:
    state.chooseGridItem(item)
    return
  let first = min(state.selectionPivot, item)
  let last = max(state.selectionPivot, item)
  discard state.clearGridSelection()
  for selectedItem in first..last:
    discard state.setGridItemSelected(selectedItem, true)
  state.selectedItem = item
  state.selectedKey = state.gridItemKey(item)
  state.selectedKeyValid = true
  if state.rows != nil:
    state.rows.scrollIntoView(item div max(state.columns, 1))
  state.pendingChanged = true

proc select*(state: GridState; item: int) =
  ## Selects one item, or clears selection with -1.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if item < -1:
    raise newException(ValueError, "ui: selected item must be -1 or greater")
  state.chooseGridItem(item)

proc clearSelection*(state: GridState) =
  ## Clears the active item and any multi-selection.
  state.select(-1)

proc toggleSelection*(state: GridState; item: int) =
  ## Adds an item to the multi-selection, or removes it if already selected.
  if state == nil:
    raise newException(ValueError, "ui: grid state cannot be nil")
  if item < 0 or item >= state.itemCount:
    raise newException(ValueError, "ui: grid item is outside the grid")
  state.toggleGridItem(item)

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

proc clickGridItem(state: GridState; item: int; mods: platform.Modifiers) =
  when defined(macosx):
    const commandMask = platform.modSuper
  else:
    const commandMask = platform.modCtrl
  if state.multiSelectable and (mods and platform.modShift) != 0:
    state.extendGridSelection(item)
  elif state.multiSelectable and (mods and commandMask) != 0:
    state.toggleGridItem(item)
  else:
    state.chooseGridItem(item)

proc gridItemClickHandler(state: GridState; item: int):
    proc(mods: platform.Modifiers) {.closure.} =
  result = proc(mods: platform.Modifiers) =
    if item < state.itemCount:
      state.clickGridItem(item, mods)

proc gridTypeSelect(state: GridState; text: string) =
  if state == nil or not state.selectable or state.itemLabel == nil or
      text.len == 0 or state.itemCount == 0:
    return
  let now = getMonoTime()
  if state.typedLabel.len > 0 and
      (now - state.typedAt).inMilliseconds > 1000:
    state.typedLabel.setLen(0)
  let continued = state.typedLabel.len > 0
  let lowerText = unicode.toLower(text)
  let repeated = text.runeLen == 1 and state.typedLabel.runeLen == 1 and
    unicode.toLower(state.typedLabel) == lowerText
  var query = state.typedLabel & text
  var start = state.selectedItem
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
  for distance in 0..<state.itemCount:
    let item = (start + distance) mod state.itemCount
    if unicode.toLower(state.itemLabel(item)).startsWith(prefix):
      state.chooseGridItem(item)
      return

proc gridKey(state: GridState; key: platform.Key;
             mods: platform.Modifiers): bool =
  if state == nil or not state.selectable or state.itemCount <= 0:
    return false
  when defined(macosx):
    const commandMask = platform.modSuper
  else:
    const commandMask = platform.modCtrl

  if state.multiSelectable and key == platform.keyA and mods == commandMask:
    var changed = false
    for item in 0..<state.itemCount:
      changed = state.setGridItemSelected(item, true) or changed
    if changed:
      state.pendingChanged = true
    return true

  let extend = state.multiSelectable and
    (mods == platform.modShift or
      mods == (platform.modShift or commandMask))
  if mods != 0 and not extend:
    return false

  let count = state.itemCount
  let columns = min(max(state.columns, 1), max(count, 1))
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
  if extend:
    if state.selectionPivot < 0 or not selected:
      state.setGridPivot(max(current, 0))
    state.extendGridSelection(target)
  else:
    state.chooseGridItem(target)
  true

proc cancelGridReorder(state: GridState) =
  if state == nil:
    return
  state.reorderItems.setLen(0)
  state.reorderOrigin = -1
  state.reorderTarget = -1
  state.reorderTargetCell = -1
  state.reorderPressed = false
  state.reorderDragging = false
  state.reorderTargetValid = false
  state.reorderTargetAfter = false

proc beginGridReorder(state: GridState; item: int; x, y: float32): bool =
  if state == nil or state.reorder == nil or item < 0 or
      item >= state.itemCount:
    return false
  state.cancelGridReorder()
  state.reorderOrigin = item
  if state.multiSelectable and state.isSelected(item):
    state.reorderItems = state.selectedItems()
  else:
    state.reorderItems.add(item)
  state.reorderTarget = item
  state.reorderPointerX = x
  state.reorderPointerY = y
  state.reorderStartX = x
  state.reorderStartY = y
  state.reorderPressed = true
  true

proc updateGridReorder(state: GridState; x, y: float32): bool =
  if state == nil or not state.reorderPressed:
    return false
  state.reorderPointerX = x
  state.reorderPointerY = y
  if not state.reorderDragging and
      abs(x - state.reorderStartX) + abs(y - state.reorderStartY) >= 4'f32:
    state.reorderDragging = true
  state.reorderDragging

proc finishGridReorder(state: GridState; commit: bool): bool =
  if state == nil or not state.reorderPressed:
    return false
  let handler = state.reorder
  let items = state.reorderItems
  let target = state.reorderTarget
  let valid = state.reorderDragging and state.reorderTargetValid and
    target >= 0 and target <= state.itemCount
  let samePosition = items.len == 1 and
    (target == items[0] or target == items[0] + 1)
  state.reorderItems = @[]
  state.reorderPressed = false
  state.reorderDragging = false
  state.reorderTargetValid = false
  state.reorderTargetAfter = false
  state.reorderOrigin = -1
  state.reorderTarget = -1
  state.reorderTargetCell = -1
  if commit and valid and not samePosition and handler != nil:
    handler(items, target)
    return true

proc gridView*(c: Context; state: GridState; count: Natural;
               minItemWidth, itemHeight: float32;
               buildItem: proc(item: int) {.closure.}): Element =
  ## Builds a responsive, virtualized grid with optional selection and reorder.
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

  state.itemHeight = itemHeight
  state.gap = gap
  state.syncGridItems(int(count))
  if state.reorder == nil:
    state.cancelGridReorder()

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
          let itemIndex = first + offset
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
            node[].gridCellState = state
            node[].gridItemIndex = itemIndex
            if state.selectable:
              node[].accessExtraStates = platform.accessSelectable
              if state.isSelected(itemIndex):
                node[].accessExtraStates = node[].accessExtraStates or
                  platform.accessChecked
                node[].background = c.theme.accent
              if state.selectedItem == itemIndex:
                node[].accessExtraStates = node[].accessExtraStates or
                  platform.accessSelected
                activeIdentity = node[].identity
            if state.reorderDragging and itemIndex in state.reorderItems:
              node[].opacity = 0.4'f32
              node[].opacitySet = true
            if state.reorderDragging and
                itemIndex == state.reorderTargetCell:
              node[].borderColor = c.theme.accent
              if state.reorderTargetAfter != state.rightToLeft:
                node[].border[1] = 2'f32
              else:
                node[].border[3] = 2'f32
            if state.itemLabel != nil:
              node[].label = state.itemLabel(itemIndex)
          if state.selectable:
            discard cell.tabStop(false).onClick(
              state.gridItemClickHandler(itemIndex))
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
  root[].accessSetSize = state.itemCount
  state.rightToLeft = root[].rightToLeft
  for slot in cellSlots:
    c.owner.nodes[slot].focusTargetSlot = int32(result.slot)
  if state.selectable:
    root[].accessExtraStates = root[].accessExtraStates or
      platform.accessSelectable
    if state.multiSelectable:
      root[].accessExtraStates = root[].accessExtraStates or
        platform.accessMultiselectable
    discard result.focusable().focusRing(false)
    root[].keyHandler = proc(key: platform.Key; mods: platform.Modifiers;
                             focusSlot: var int): bool =
      state.gridKey(key, mods)
    if state.itemLabel != nil:
      root[].textInputHandler = proc(text: string) = state.gridTypeSelect(text)
  if state.selectable:
    root[].activeDescendantIdentity = activeIdentity
  if state.pendingChanged:
    result.markBoundValueChanged()
    state.pendingChanged = false
  if state.pendingSubmitted:
    root[].submitted = true
    state.pendingSubmitted = false
