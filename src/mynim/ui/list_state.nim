## Persistent state and sparse height estimates for virtualized lists.

const
  listHeightBlockSize = 64
  listOverscan = 2
  listMaxRowsPerFrame = 4096
  defaultListViewport = 480'f32

type
  ListPlan = object
    first, pastLast: int
    top, bottom: float32

proc listHeightFloat32(value: float64): float32 =
  if value <= 0:
    return 0
  if value >= float64(high(float32)):
    return high(float32)
  float32(value)

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

proc newListState*(estimatedRowHeight = 28'f32;
                   rowGap = 0'f32): ListState =
  ## Creates persistent state for a virtualized list.
  if not estimatedRowHeight.finiteMotion or estimatedRowHeight <= 0 or
      not rowGap.finiteMotion or rowGap < 0:
    raise newException(ValueError,
      "ui: list row height must be positive and row gap cannot be negative")
  new(result)
  result.scrollState = newScrollState()
  result.heights.defaultHeight = float64(estimatedRowHeight)
  result.heights.dirty = true
  result.gap = rowGap
  result.last = -1

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

proc finishList(state: ListState; first, last: int): bool =
  if state == nil:
    return false
  result = state.visibleRead and
    (not state.laidOut or state.first != first or state.last != last)
  state.first = first
  state.last = last
  state.atEnd = state.rowCount == 0 or
    state.scrollState.offset().y >= state.scrollState.maxOffset().y - 0.5'f32
  state.laidOut = true
  state.visibleRead = false
