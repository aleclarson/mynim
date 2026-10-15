## Persistent state and sparse height estimates for virtualized lists.

const
  listHeightBlockSize = 64
  listOverscan = 2
  listMaxRowsPerFrame = 4096
  listKeySearch = 1000
  defaultListViewport = 480'f32

type
  ListPlan = object
    first, pastLast: int
    top, bottom: float32

proc estimatedHeight(heights: var ListHeights): float64
proc listHeightTop(heights: var ListHeights; row: int;
                   gap: float32): float64

proc listHeightFloat32(value: float64): float32 =
  if value <= 0:
    return 0
  if value >= float64(high(float32)):
    return high(float32)
  float32(value)

proc findListKey(state: ListState; key: string; nearRow: int): int =
  if state.rowKey == nil or state.rowCount <= 0:
    return -1
  let near = max(0, min(nearRow, state.rowCount - 1))
  for distance in 0..listKeySearch:
    let before = near - distance
    if before >= 0 and state.rowKey(before) == key:
      return before
    let after64 = int64(near) + int64(distance)
    if distance > 0 and after64 < int64(state.rowCount) and
        state.rowKey(int(after64)) == key:
      return int(after64)
  -1

proc resetListMeasurements(heights: var ListHeights) =
  let estimate = heights.estimatedHeight()
  heights.blockIds.setLen(0)
  heights.blocks.setLen(0)
  heights.prefixHeights.setLen(0)
  heights.prefixCounts.setLen(0)
  heights.defaultHeight = estimate
  heights.dirty = true

proc syncListAnchor(state: ListState) =
  if state.rowKey == nil or not state.anchorValid or state.rowCount <= 0:
    return
  var oldAnchorChanged = state.anchor < 0 or
    state.anchor >= state.rowCount
  if not oldAnchorChanged:
    oldAnchorChanged = state.rowKey(state.anchor) != state.anchorKey
  if not oldAnchorChanged:
    return

  let newAnchor = state.findListKey(state.anchorKey, state.anchor)
  state.heights.resetListMeasurements()
  if newAnchor >= 0 and not state.keepOffset and
      state.request == listNoRequest:
    let inputMovement = float64(state.scrollState.offsetY - state.anchorScrollY)
    let top = state.heights.listHeightTop(newAnchor, state.gap)
    state.scrollState.scrollTo(0,
      listHeightFloat32(max(top + state.anchorInset + inputMovement, 0.0)))

proc clearListSelection(state: ListState) =
  let previous = state.selectedRow
  state.selectedRow = -1
  state.selectedKey = ""
  state.selectedKeyValid = false
  state.selectionPivot = -1
  state.selectionPivotKey = ""
  state.selectionPivotKeyValid = false
  state.selectionSpan = 0
  if state.request == listRequestIntoView and state.requestRow == previous:
    state.request = listNoRequest

proc selectionEntry(state: ListState; row: int): ListSelectedRow =
  result.row = row
  result.nearRow = row
  if state.rowKey != nil and row < state.rowCount:
    result.key = state.rowKey(row)
    result.keyValid = true

proc listRowIsSelected(state: ListState; row: int): bool =
  if row < 0 or row >= state.rowCount:
    return false
  if state.rowKey != nil:
    state.selectedKeys.contains(state.rowKey(row))
  else:
    state.selectedIndices.contains(row)

proc setListRowSelected(state: ListState; row: int; selected: bool): bool =
  if row < 0:
    return false
  let entry = state.selectionEntry(row)
  let exists = if entry.keyValid:
      state.selectedKeys.contains(entry.key)
    else:
      state.selectedIndices.contains(row)
  if exists == selected:
    return false
  if selected:
    if entry.keyValid:
      state.selectedKeys.incl(entry.key)
    else:
      state.selectedIndices.incl(row)
    state.chosenRows.add(entry)
    return true
  if entry.keyValid:
    state.selectedKeys.excl(entry.key)
  else:
    state.selectedIndices.excl(row)
  for i, chosen in state.chosenRows:
    let same = if entry.keyValid:
        chosen.keyValid and chosen.key == entry.key
      else:
        not chosen.keyValid and chosen.row == row
    if same:
      state.chosenRows.delete(i)
      break
  true

proc setListCursor(state: ListState; row: int; pivot: bool) =
  state.selectedRow = row
  state.selectedKey = ""
  state.selectedKeyValid = state.rowKey != nil and row < state.rowCount
  if state.selectedKeyValid:
    state.selectedKey = state.rowKey(row)
  if pivot:
    state.selectionPivot = row
    state.selectionPivotKey = state.selectedKey
    state.selectionPivotKeyValid = state.selectedKeyValid
    state.selectionSpan = 0

proc syncListSelection(state: ListState) =
  for i in 0..<state.chosenRows.len:
    var chosen = state.chosenRows[i]
    if not chosen.keyValid and state.rowKey != nil and
        chosen.row >= 0 and chosen.row < state.rowCount:
      chosen.key = state.rowKey(chosen.row)
      chosen.keyValid = true
      chosen.nearRow = chosen.row
      state.selectedIndices.excl(chosen.row)
      state.selectedKeys.incl(chosen.key)
    elif chosen.keyValid and state.rowKey != nil:
      if chosen.row >= 0 and chosen.row < state.rowCount and
          state.rowKey(chosen.row) == chosen.key:
        chosen.nearRow = chosen.row
      else:
        let moved = state.findListKey(chosen.key, chosen.nearRow)
        chosen.row = moved
        if moved >= 0:
          chosen.nearRow = moved
    state.chosenRows[i] = chosen

  if state.selectionPivotKeyValid and state.rowKey != nil:
    if state.selectionPivot >= 0 and
        state.selectionPivot < state.rowCount and
        state.rowKey(state.selectionPivot) == state.selectionPivotKey:
      discard
    else:
      state.selectionPivot = state.findListKey(state.selectionPivotKey,
        state.selectionPivot)

  if state.selectedRow < 0:
    return
  if state.selectedRow >= state.rowCount:
    if not state.selectedKeyValid:
      state.clearListSelection()
      return
  if state.rowKey == nil:
    state.selectedKeyValid = false
    if state.selectedRow >= state.rowCount:
      state.clearListSelection()
    return
  if state.selectedKeyValid:
    if state.selectedRow < state.rowCount and
        state.rowKey(state.selectedRow) == state.selectedKey:
      return
    let moved = state.findListKey(state.selectedKey, state.selectedRow)
    if moved >= 0:
      if state.request == listRequestIntoView and
          state.requestRow == state.selectedRow:
        state.requestRow = moved
      state.selectedRow = moved
      return
    state.clearListSelection()
    return
  if state.selectedRow < state.rowCount:
    state.selectedKey = state.rowKey(state.selectedRow)
    state.selectedKeyValid = true
  else:
    state.clearListSelection()

proc prepareListFollow(state: ListState) =
  state.followRequest = false
  if not state.followEnd:
    return
  if not state.followStarted:
    state.following = true
  elif abs(state.scrollState.offsetY - state.followOffsetY) >= 0.5'f32:
    state.following = state.scrollState.offsetY >= state.followMaxY - 0.5'f32
  if state.following and state.request == listNoRequest:
    state.request = listRequestToEnd
    state.followRequest = true

proc blockPosition(heights: ListHeights; id: int): tuple[index: int, found: bool] =
  var low = 0
  var high = heights.blockIds.len
  while low < high:
    let mid = (low + high) div 2
    if heights.blockIds[mid] < id:
      low = mid + 1
    else:
      high = mid
  (low, low < heights.blockIds.len and heights.blockIds[low] == id)

proc rebuildHeightIndex(heights: var ListHeights) =
  if not heights.dirty and heights.prefixHeights.len == heights.blocks.len + 1:
    return
  let blockCount = heights.blocks.len
  heights.prefixHeights.setLen(blockCount + 1)
  heights.prefixCounts.setLen(blockCount + 1)
  heights.prefixHeights[0] = 0
  heights.prefixCounts[0] = 0
  for i in 0..<blockCount:
    heights.prefixHeights[i + 1] = heights.prefixHeights[i] +
      heights.blocks[i].sum
    heights.prefixCounts[i + 1] = heights.prefixCounts[i] +
      heights.blocks[i].knownCount
  heights.dirty = false

proc estimatedHeight(heights: var ListHeights): float64 =
  heights.rebuildHeightIndex()
  if heights.prefixCounts[^1] > 0:
    let average = heights.prefixHeights[^1] /
      float64(heights.prefixCounts[^1])
    if average > 0 and finiteMotion(average):
      return average
  heights.defaultHeight

proc measuredHeight(heights: ListHeights; row: int): tuple[value: float32, ok: bool] =
  if row < 0 or row >= heights.count:
    return
  let (blockIndex, found) = heights.blockPosition(row div listHeightBlockSize)
  if not found:
    return
  let index = row mod listHeightBlockSize
  let item = heights.blocks[blockIndex]
  if (item.known and (1'u64 shl index)) != 0:
    result = (item.heights[index], true)

proc listRowHeight(heights: var ListHeights; row: int): float64 =
  let (value, known) = heights.measuredHeight(row)
  if known:
    result = float64(value)
  else:
    result = heights.estimatedHeight()

proc listHeightTop(heights: var ListHeights; row: int;
                   gap: float32): float64 =
  let index = max(0, min(row, heights.count))
  if index == 0:
    return 0
  heights.rebuildHeightIndex()
  let blockID = index div listHeightBlockSize
  let withinBlock = index mod listHeightBlockSize
  let (blockIndex, found) = heights.blockPosition(blockID)
  let estimate = heights.estimatedHeight()
  let blockStart = blockID * listHeightBlockSize
  result = heights.prefixHeights[blockIndex] +
    float64(blockStart - heights.prefixCounts[blockIndex]) * estimate
  if found:
    let item = heights.blocks[blockIndex]
    for i in 0..<withinBlock:
      if (item.known and (1'u64 shl i)) != 0:
        result += float64(item.heights[i])
      else:
        result += estimate
  else:
    result += float64(withinBlock) * estimate
  result += float64(index) * float64(gap)

proc listRowAt(heights: var ListHeights; y: float64;
               gap: float32): int =
  if heights.count <= 0:
    return 0
  let target = max(y, 0)
  var low = 0
  var high = heights.count - 1
  while low < high:
    let mid = (low + high + 1) div 2
    if heights.listHeightTop(mid, gap) <= target:
      low = mid
    else:
      high = mid - 1
  low

proc setListHeight(heights: var ListHeights; row: int;
                   value: float32): bool =
  if row < 0 or row >= heights.count or not value.finiteMotion:
    return false
  let newHeight = max(value, 0'f32)
  let blockID = row div listHeightBlockSize
  var (blockIndex, found) = heights.blockPosition(blockID)
  if not found:
    heights.blockIds.insert(blockID, blockIndex)
    heights.blocks.insert(ListHeightBlock(), blockIndex)
  let item = heights.blocks[blockIndex]
  let index = row mod listHeightBlockSize
  let bit = 1'u64 shl index
  if (item.known and bit) != 0 and item.heights[index] == newHeight:
    return false
  if (item.known and bit) == 0:
    inc item.knownCount
  else:
    item.sum -= float64(item.heights[index])
  item.known = item.known or bit
  item.heights[index] = newHeight
  item.sum += float64(newHeight)
  heights.dirty = true
  true

proc resizeListHeights(heights: var ListHeights; count: int) =
  let newCount = max(count, 0)
  if newCount < heights.count:
    let firstRemovedBlock = (newCount + listHeightBlockSize - 1) div
      listHeightBlockSize
    let (removeAt, _) = heights.blockPosition(firstRemovedBlock)
    heights.blockIds.setLen(removeAt)
    heights.blocks.setLen(removeAt)
    let remainder = newCount mod listHeightBlockSize
    if remainder > 0:
      let (lastBlock, found) = heights.blockPosition(newCount div listHeightBlockSize)
      if found:
        let item = heights.blocks[lastBlock]
        let keepMask = (1'u64 shl remainder) - 1'u64
        item.known = item.known and keepMask
        item.knownCount = 0
        item.sum = 0
        for i in 0..<remainder:
          if (item.known and (1'u64 shl i)) != 0:
            inc item.knownCount
            item.sum += float64(item.heights[i])
        if item.known == 0:
          heights.blockIds.delete(lastBlock)
          heights.blocks.delete(lastBlock)
  heights.count = newCount
  heights.dirty = true

proc newListState*(estimatedRowHeight = 28'f32; rowGap = 0'f32;
                   rowKey: ListRowKey = nil; keepOffset = false;
                   selectable = false; followEnd = false;
                   multiSelectable = false;
                   rowLabel: ListRowLabel = nil): ListState =
  ## Creates persistent state for a virtualized list.
  ##
  ## rowKey should return a stable, unique key for each logical row. When a
  ## keyed row moves, the list follows it unless keepOffset is true. The moved
  ## key is searched within 1000 rows of its previous index. Set selectable
  ## to enable row clicks and keyboard selection; rowLabel enables row focus
  ## and type-to-select. select also enables keyboard selection.
  ## followEnd starts at and follows the end until the user scrolls away.
  ## multiSelectable enables multi-row selection and modifier handling; rowKey
  ## keeps those choices with their rows as they move.
  ## rowLabel names rows for accessibility and enables type-to-select.
  if not estimatedRowHeight.finiteMotion or estimatedRowHeight <= 0 or
      not rowGap.finiteMotion or rowGap < 0:
    raise newException(ValueError,
      "ui: list row height must be positive and row gap cannot be negative")
  new(result)
  result.scrollState = newScrollState()
  result.selectedKeys = initHashSet[string]()
  result.selectedIndices = initHashSet[int]()
  result.heights.defaultHeight = float64(estimatedRowHeight)
  result.heights.dirty = true
  result.gap = rowGap
  result.rowKey = rowKey
  result.rowLabel = rowLabel
  result.keepOffset = keepOffset
  result.selectionEnabled = selectable or multiSelectable or rowLabel != nil
  result.multiSelectionEnabled = multiSelectable
  result.followEnd = followEnd
  result.selectedRow = -1
  result.selectionPivot = -1
  result.last = -1

proc setFollowEndAnimation*(state: ListState; animation: Animation) =
  ## Enables follow-end and animates rows added while the list stays at its end.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  validateAnimation(animation)
  state.followEnd = true
  state.followEndAnimation = animation
  state.followEndAnimated = true

func selected*(state: ListState): int =
  ## Returns the chosen row index, or -1 when no row is chosen.
  if state == nil: -1 else: state.selectedRow

proc select*(state: ListState; row: int) =
  ## Chooses row, or clears the choice with -1, and scrolls it into view.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  if row < -1:
    raise newException(ValueError, "ui: selected row must be -1 or greater")
  state.selectionEnabled = true
  if row < 0:
    state.clearListSelection()
    state.chosenRows.setLen(0)
    state.selectedKeys.clear()
    state.selectedIndices.clear()
    return
  if state.multiSelectionEnabled:
    state.chosenRows.setLen(0)
    state.selectedKeys.clear()
    state.selectedIndices.clear()
    discard state.setListRowSelected(row, true)
  state.setListCursor(row, pivot = true)
  state.request = listRequestIntoView
  state.requestRow = row

proc enableSelection*(state: ListState): ListState =
  ## Enables click and keyboard selection for this list.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  state.selectionEnabled = true
  state

proc enableMultiSelection*(state: ListState): ListState =
  ## Enables multi-row selection by click and keyboard.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  if not state.multiSelectionEnabled and state.selectedRow >= 0:
    discard state.setListRowSelected(state.selectedRow, true)
  state.selectionEnabled = true
  state.multiSelectionEnabled = true
  state

proc isSelected*(state: ListState; row: int): bool =
  ## Reports whether row belongs to this list's multi-selection.
  state != nil and state.multiSelectionEnabled and
    state.listRowIsSelected(row)

proc selectedRows*(state: ListState): seq[int] =
  ## Returns the selected row indices still present in the current list.
  if state == nil or not state.multiSelectionEnabled:
    return
  for chosen in state.chosenRows:
    if chosen.keyValid:
      if chosen.row >= 0 and chosen.row < state.rowCount and
          state.rowKey != nil and state.rowKey(chosen.row) == chosen.key:
        result.add(chosen.row)
    elif chosen.row >= 0 and chosen.row < state.rowCount:
      result.add(chosen.row)

proc clearSelection*(state: ListState) =
  ## Clears the row choice and any multi-selection.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  state.clearListSelection()
  state.chosenRows.setLen(0)
  state.selectedKeys.clear()
  state.selectedIndices.clear()

proc toggleSelection*(state: ListState; row: int) =
  ## Adds row to the multi-selection, or removes it if already selected.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  if row < 0 or row >= state.rowCount:
    raise newException(ValueError, "ui: row is outside the list")
  discard state.setListRowSelected(row, not state.listRowIsSelected(row))
  state.multiSelectionEnabled = true
  state.selectionEnabled = true
  state.setListCursor(row, pivot = true)
  state.request = listRequestIntoView
  state.requestRow = row

proc extendListSelection(state: ListState; row: int; keep: bool) =
  let pivot = state.selectionPivot
  if pivot < 0 or pivot >= state.rowCount:
    state.select(row)
    return
  let first = min(pivot, row)
  let last = max(pivot, row)
  when defined(macosx):
    let oldLast = max(0, min(pivot + state.selectionSpan, state.rowCount - 1))
    for oldRow in min(pivot, oldLast)..max(pivot, oldLast):
      if (oldRow < first or oldRow > last) and
          state.listRowIsSelected(oldRow):
        discard state.setListRowSelected(oldRow, false)
  else:
    if not keep:
      state.chosenRows.setLen(0)
      state.selectedKeys.clear()
      state.selectedIndices.clear()
  for selectedRow in first..last:
    discard state.setListRowSelected(selectedRow, true)
  state.selectionSpan = row - pivot
  state.setListCursor(row, pivot = false)
  state.request = listRequestIntoView
  state.requestRow = row

proc clickListRow(state: ListState; row: int; mods: platform.Modifiers) =
  if not state.multiSelectionEnabled:
    state.select(row)
    return
  when defined(macosx):
    const commandMask = platform.modSuper
  else:
    const commandMask = platform.modCtrl
  if (mods and platform.modShift) != 0:
    state.extendListSelection(row, keep = (mods and commandMask) != 0)
  elif (mods and commandMask) != 0:
    state.toggleSelection(row)
  else:
    state.select(row)

proc selectAllListRows(state: ListState) =
  for row in 0..<state.rowCount:
    discard state.setListRowSelected(row, true)

proc typeSelectListLabel(state: ListState; text: string): bool =
  if state.rowLabel == nil:
    return false
  if text.len == 0:
    return false

  let now = getMonoTime()
  if state.typedLabel.len > 0 and
      (now - state.typedAt).inMilliseconds > 1_000:
    state.typedLabel.setLen(0)
  let lowerText = unicode.toLower(text)
  let repeated = text.runeLen == 1 and state.typedLabel.runeLen == 1 and
    unicode.toLower(state.typedLabel) == lowerText
  var query = state.typedLabel & text
  var start = max(state.selectedRow, 0)
  if repeated:
    query = text
    if state.selectedRow >= 0:
      start = state.selectedRow + 1
  state.typedLabel = query
  state.typedAt = now

  let prefix = unicode.toLower(query)
  for distance in 0..<state.rowCount:
    let row = (start + distance) mod state.rowCount
    if unicode.toLower(state.rowLabel(row)).startsWith(prefix):
      state.select(row)
      break
  true

proc selectListKey(state: ListState; key: platform.Key;
                   mods: platform.Modifiers): bool =
  if state == nil or not state.selectionEnabled or state.rowCount <= 0:
    return false

  when defined(macosx):
    const commandMask = platform.modSuper
  else:
    const commandMask = platform.modCtrl

  if state.multiSelectionEnabled and key == platform.keyA and
      mods == commandMask:
    state.selectAllListRows()
    return true

  when not defined(macosx):
    if state.multiSelectionEnabled and key == platform.keySpace and
        mods == platform.modCtrl:
      if state.selectedRow >= 0 and state.selectedRow < state.rowCount:
        state.toggleSelection(state.selectedRow)
      return true

  var extend = false
  var moveCursor = false
  if mods != 0:
    if not state.multiSelectionEnabled:
      return false
    if mods == platform.modShift or
        mods == (platform.modShift or commandMask):
      extend = true
    elif not defined(macosx) and mods == platform.modCtrl:
      moveCursor = true
    else:
      return false

  let current = state.selectedRow
  var target = -1
  case key
  of platform.keyDown:
    target = if current < 0: 0 else: min(current + 1, state.rowCount - 1)
  of platform.keyUp:
    target = if current < 0: 0 else: max(current - 1, 0)
  of platform.keyHome:
    target = 0
  of platform.keyEnd:
    target = state.rowCount - 1
  of platform.keyPageDown, platform.keyPageUp:
    when defined(macosx):
      return false
    else:
      let direction = if key == platform.keyPageDown: 1.0 else: -1.0
      let start = if current >= 0:
          current
        else:
          state.heights.listRowAt(float64(state.scrollState.offsetY), state.gap)
      let top = state.heights.listHeightTop(start, state.gap)
      let pageY = max(0.0, top + direction * float64(state.viewportHeight))
      target = state.heights.listRowAt(pageY, state.gap)
      if target == start:
        let step = if direction > 0: 1 else: -1
        target = max(0, min(state.rowCount - 1, start + step))
  else:
    return false
  if extend:
    state.extendListSelection(target, keep = (mods and commandMask) != 0)
  elif moveCursor:
    state.setListCursor(target, pivot = false)
    state.request = listRequestIntoView
    state.requestRow = target
  else:
    state.select(target)
  true

proc handleListKey(layout: LayoutResult; focusSlot: int;
                    key: platform.Key; mods: platform.Modifiers): bool =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or
      layout.generation != owner.generation or focusSlot <= 0 or
      focusSlot >= owner.nodes.len:
    return false
  var slot = focusSlot
  while slot > 0:
    let node = owner.nodes[slot]
    if node.listState != nil and node.listRowIndex == -1:
      return node.listState.selectListKey(key, mods)
    slot = int(node.parent)

proc handleListText(layout: LayoutResult; focusSlot: int;
                    text: string): bool =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or
      layout.generation != owner.generation or focusSlot <= 0 or
      focusSlot >= owner.nodes.len:
    return false
  var slot = focusSlot
  while slot > 0:
    let node = owner.nodes[slot]
    if node.listState != nil and node.listRowIndex == -1:
      return node.listState.typeSelectListLabel(text)
    slot = int(node.parent)

proc offset*(state: ListState): tuple[x, y: float32] =
  ## Returns the current scroll offsets of the list.
  if state != nil:
    result = state.scrollState.offset()

proc maxOffset*(state: ListState): tuple[x, y: float32] =
  ## Returns the greatest scroll offsets of the list.
  if state != nil:
    result = state.scrollState.maxOffset()

proc scrollTo*(state: ListState; row: int; align = Align.Start) =
  ## Scrolls to place row at the start, center, or end of the viewport.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  state.request = listRequestToRow
  state.requestRow = row
  state.requestAlign = align

proc scrollIntoView*(state: ListState; row: int) =
  ## Scrolls only as far as needed to show row.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  state.request = listRequestIntoView
  state.requestRow = row

proc scrollToEnd*(state: ListState) =
  ## Scrolls the list to its current end.
  if state == nil:
    raise newException(ValueError, "ui: list state cannot be nil")
  state.request = listRequestToEnd

proc visible*(state: ListState): tuple[first, last: int] =
  ## Returns the first and last visible row from the latest layout.
  if state == nil:
    return (first: 0, last: -1)
  state.visibleRead = true
  if not state.laidOut:
    return (first: 0, last: -1)
  (first: state.first, last: state.last)

proc atEnd*(state: ListState): bool =
  ## Reports whether the last layout showed the list's end.
  if state == nil:
    return false
  state.visibleRead = true
  state.laidOut and state.atEnd

proc beginList(state: ListState; count: int): ListPlan =
  state.rowCount = max(count, 0)
  state.heights.resizeListHeights(state.rowCount)
  state.syncListSelection()
  state.prepareListFollow()
  state.syncListAnchor()
  let viewport = if state.viewportHeight > 0:
      state.viewportHeight
    else:
      defaultListViewport
  let viewport64 = float64(viewport)
  let contentHeight = max(
    state.heights.listHeightTop(state.rowCount, state.gap) -
      float64(state.gap),
    0.0)
  let maximum = min(max(contentHeight - viewport64, 0.0),
    float64(high(float32)))
  if state.request != listNoRequest:
    let request = state.request
    var target = 0.0
    if state.rowCount > 0:
      case state.request
      of listRequestToRow, listRequestIntoView:
        let row = max(0, min(state.requestRow, state.rowCount - 1))
        let top = state.heights.listHeightTop(row, state.gap)
        let height = state.heights.listRowHeight(row)
        case state.request
        of listRequestIntoView:
          let current = float64(state.scrollState.offset().y)
          if top < current:
            target = top
          elif top + height > current + viewport64:
            target = top + height - viewport64
          else:
            target = current
        of listRequestToRow:
          case state.requestAlign
          of Align.Center:
            target = top + (height - viewport64) / 2
          of Align.End:
            target = top + height - viewport64
          else:
            target = top
        else:
          discard
      of listRequestToEnd:
        target = max(contentHeight - viewport64, 0.0)
      of listNoRequest:
        discard
    state.scrollState.scrollTo(0,
      listHeightFloat32(min(max(target, 0.0), maximum)))
    state.request = listNoRequest
    if state.followEnd:
      if request == listRequestToEnd:
        state.following = true
      else:
        state.following = state.scrollState.offsetY >=
          float32(maximum) - 0.5'f32

  state.scrollState.maxX = 0
  state.scrollState.maxY = float32(maximum)
  state.scrollState.offsetX = 0
  state.scrollState.offsetY = min(max(state.scrollState.offsetY, 0'f32),
    state.scrollState.maxY)

  if state.rowCount <= 0:
    result = ListPlan(first: 0, pastLast: 0)
    return

  let offset = float64(state.scrollState.offset().y)
  let firstVisible = state.heights.listRowAt(offset, state.gap)
  let viewEnd = offset + viewport64
  var visiblePast = firstVisible
  var rowTop = state.heights.listHeightTop(firstVisible, state.gap)
  while visiblePast < state.rowCount and rowTop < viewEnd and
      visiblePast-firstVisible < listMaxRowsPerFrame:
    rowTop += state.heights.listRowHeight(visiblePast) + float64(state.gap)
    inc visiblePast
  let first = max(0, firstVisible - listOverscan)
  let pastLast = min(state.rowCount, visiblePast + listOverscan)
  let top = state.heights.listHeightTop(first, state.gap)
  let totalHeight = state.heights.listHeightTop(state.rowCount, state.gap) -
    float64(state.gap)
  let after = state.heights.listHeightTop(pastLast, state.gap)
  result = ListPlan(first: first, pastLast: pastLast,
    top: listHeightFloat32(top),
    bottom: listHeightFloat32(totalHeight - after))

proc observeListHeight(state: ListState; row: int; height: float32): bool =
  if state != nil:
    result = state.heights.setListHeight(row, height)

proc observeListViewport(state: ListState; height: float32): bool =
  if state == nil or height <= 0 or not height.finiteMotion:
    return false
  result = abs(state.viewportHeight - height) >= 0.5'f32
  state.viewportHeight = height

proc resetListFollowAnimation(state: ListState; now: MonoTime) =
  state.followLag = ScrollMotionChannel(at: now)
  state.followSeen = false
  state.followRow = -1
  state.followKey = ""
  state.followKeyValid = false

proc applyListFollowAnimation(state: ListState; nodes: seq[ElementNode];
    rects: var seq[Rect]; listSlot: int; rowWidth, viewportHeight: float32;
    now: MonoTime;
    reduceMotion: bool): bool =
  if state == nil or listSlot <= 0 or listSlot >= nodes.len or
      rects.len != nodes.len:
    return false
  if not state.followEndAnimated or not state.followEnd or
      not state.following or not state.followRequest or
      state.rowCount == 0 or reduceMotion:
    state.resetListFollowAnimation(now)
    return false

  if not state.followSeen or abs(rowWidth - state.followWidth) >= 0.5'f32:
    state.resetListFollowAnimation(now)
  else:
    state.followLag.advance(now)
    var previousRow = state.followRow
    var previousFound = previousRow >= 0 and previousRow < state.rowCount
    if previousFound and state.followKeyValid and state.rowKey != nil:
      previousRow = state.findListKey(state.followKey, previousRow)
      previousFound = previousRow >= 0
    if previousFound:
      let total = state.heights.listHeightTop(state.rowCount, state.gap)
      let below = total - state.heights.listHeightTop(previousRow, state.gap)
      let change = below - state.followBelow
      if change > 0.5:
        state.followLag.value = min(state.followLag.value + change,
          float64(viewportHeight))
        state.followLag.headFor(0, state.followEndAnimation, now)
      elif change < -0.5:
        state.followLag.value = max(state.followLag.value + change,
          -float64(viewportHeight))
        state.followLag.headFor(0, state.followEndAnimation, now)
    else:
      state.resetListFollowAnimation(now)

  let total = state.heights.listHeightTop(state.rowCount, state.gap)
  let last = state.rowCount - 1
  state.followRow = last
  state.followBelow = total - state.heights.listHeightTop(last, state.gap)
  state.followWidth = rowWidth
  state.followKeyValid = state.rowKey != nil
  state.followKey = if state.rowKey != nil: state.rowKey(last) else: ""
  state.followSeen = true

  let lag = float32(state.followLag.value)
  if abs(lag) > 0.01'f32:
    for slot in 1..<nodes.len:
      var followsRow = nodes[slot].listState == state and
        nodes[slot].listRowIndex >= 0
      var parent = int(nodes[slot].parent)
      while not followsRow and parent > 0:
        let ancestor = nodes[parent]
        if ancestor.listState == state:
          followsRow = ancestor.listRowIndex >= 0
          break
        parent = int(ancestor.parent)
      if followsRow:
        rects[slot].y += lag

  state.followLag.moving or state.followLag.pending

proc finishList(state: ListState; first, last: int): bool =
  if state == nil:
    return false
  result = state.visibleRead and
    (not state.laidOut or state.first != first or state.last != last)
  state.first = first
  state.last = last
  state.atEnd = state.rowCount == 0 or
    (state.scrollState.offset().y >= state.scrollState.maxOffset().y - 0.5'f32 and
      abs(float32(state.followLag.value)) <= 0.5'f32 and
      not state.followLag.pending)
  if state.followEnd:
    if state.atEnd:
      state.following = true
    state.followOffsetY = state.scrollState.offsetY
    state.followMaxY = state.scrollState.maxY
    state.followStarted = true
  state.anchorValid = state.rowKey != nil and state.rowCount > 0
  if state.anchorValid:
    state.anchor = max(0, min(first, state.rowCount - 1))
    state.anchorKey = state.rowKey(state.anchor)
    state.anchorScrollY = state.scrollState.offset().y
    state.anchorInset = float64(state.anchorScrollY) -
      state.heights.listHeightTop(state.anchor, state.gap)
  else:
    state.anchorKey = ""
  state.laidOut = true
  state.visibleRead = false
