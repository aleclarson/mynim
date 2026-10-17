## Flex layout and element sizing for the frame tree.

type LayoutDimension = enum
  ldWidth, ldHeight, ldMinWidth, ldMinHeight, ldMaxWidth, ldMaxHeight

const
  MaxGridTrackIndex = high(int16).int
  MaxGridOccupiedCells = 1_048_576
  transitionXKey = "\x00mynim.transition.x"
  transitionYKey = "\x00mynim.transition.y"
  transitionWidthKey = "\x00mynim.transition.width"
  transitionHeightKey = "\x00mynim.transition.height"
  transitionBackgroundKey = "\x00mynim.transition.background"
  transitionBorderKey = "\x00mynim.transition.border"

proc pixels(value: float32): UiLength =
  UiLength(value: value, kind: lengthPixels)

proc percent(value: float32): UiLength =
  UiLength(value: value, kind: lengthPercent)

proc resolve(value: UiLength; base: float32): tuple[value: float32, ok: bool] =
  case value.kind
  of lengthPixels:
    (value.value, true)
  of lengthPercent:
    if base >= 0:
      (value.value * base / 100, true)
    else:
      (0'f32, false)
  of lengthAuto:
    (0'f32, false)

proc marginValue(value: float32): float32 =
  if value == Auto: 0'f32 else: value

proc marginX(node: ElementNode): float32 =
  marginValue(node.margin[1]) + marginValue(node.margin[3])

proc marginY(node: ElementNode): float32 =
  marginValue(node.margin[0]) + marginValue(node.margin[2])

proc contentInsetX(node: ElementNode): float32 =
  node.pad[1] + node.pad[3] + node.border[1] + node.border[3]
proc contentInsetY(node: ElementNode): float32 =
  node.pad[0] + node.pad[2] + node.border[0] + node.border[2]

func reverseHorizontalAlign(value: Align): Align =
  case value
  of Align.Start: Align.End
  of Align.End: Align.Start
  else: value

proc clampSize(value: float32; minimum, maximum: UiLength;
               base: float32): float32 =
  result = max(value, 0'f32)
  let maxValue = maximum.resolve(base)
  if maxValue.ok:
    result = min(result, maxValue.value)
  let minValue = minimum.resolve(base)
  if minValue.ok:
    result = max(result, minValue.value)
  result = max(result, 0'f32)

proc clampWidth(node: ElementNode; width, base: float32): float32 =
  clampSize(width, node.minW, node.maxW, base)

proc clampHeight(node: ElementNode; height, base: float32): float32 =
  clampSize(height, node.minH, node.maxH, base)

proc crossSize(node: ElementNode; natural: NaturalSize; row: bool;
               base, mainExtent, available, margins: float32;
               align: Align): float32

proc shapeText(nodes: var seq[ElementNode]) =
  nodes.prepareInlineText()
  let system = textStack.shared()
  for node in nodes.mitems:
    if not node.hasText or node.textInline:
      continue
    let alignment = if node.textAlign == Align.Center:
        textStack.Center
      elif node.rightToLeft:
        if node.textAlign == Align.End: textStack.Left else: textStack.Right
      elif node.textAlign == Align.End:
        textStack.End
      else:
        textStack.Start
    node.shapedText = system.layout(textStack.Params(text: node.textValue,
      style: node.textStyle, maxLines: node.textMaxLines,
      align: alignment, rtl: node.rightToLeft,
      keepSpaces: true, noWrap: node.textNoWrap,
      spans: node.textSpanStyles))

proc shapeTextToBounds(nodes: var seq[ElementNode]; rects: seq[Rect];
                       firstSlot = 0; lastSlot = -1): bool =
  let system = textStack.shared()
  let last = if lastSlot < 0: nodes.high else: min(lastSlot, nodes.high)
  for slot in firstSlot .. last:
    var node = addr nodes[slot]
    if not node[].hasText or node[].textInline:
      continue
    let width = max(rects[slot].w - node[].contentInsetX, 0'f32)
    if width > 0 and node[].shapedText.params.width != width:
      var params = node[].shapedText.params
      params.width = width
      node[].shapedText = system.layout(params)
      result = true

proc finiteUi(value: float32): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc checkGridCellCount(columns, rows, base: int) =
  if columns < 0 or rows < 0 or base < 0 or
      base > MaxGridOccupiedCells or
      (rows > 0 and columns > (MaxGridOccupiedCells - base) div rows):
    raise newException(ValueError,
      "ui: grid placement exceeds 1,048,576 occupied cells")

proc gridCellOccupied(scratch: GridScratch; base, columns, row,
                      column: int): bool =
  let index = base + row * columns + column
  index < scratch.occupied.len and scratch.occupied[index]

proc gridCellFits(scratch: GridScratch; base, columns, row, column,
                  rowSpan, columnSpan: int): bool =
  if row < 0 or column < 0 or column + columnSpan > columns:
    return false
  for r in row ..< row + rowSpan:
    for c in column ..< column + columnSpan:
      if scratch.gridCellOccupied(base, columns, r, c):
        return false
  true

proc markGridCell(scratch: var GridScratch; base, columns, itemIndex,
                  row, column: int; rowCount: var int) =
  let item = scratch.items[itemIndex]
  checkGridCellCount(columns, row + item.rowSpan, base)
  let needed = base + (row + item.rowSpan) * columns
  if needed > scratch.occupied.len:
    let oldLength = scratch.occupied.len
    scratch.occupied.setLen(needed)
    for index in oldLength ..< needed:
      scratch.occupied[index] = false
  scratch.items[itemIndex].row = row
  scratch.items[itemIndex].col = column
  for r in row ..< row + item.rowSpan:
    for c in column ..< column + item.colSpan:
      scratch.occupied[base + r * columns + c] = true
  rowCount = max(rowCount, row + item.rowSpan)

proc gridPlaceItems(nodes: seq[ElementNode]; parent: int;
                    scratch: var GridScratch): tuple[first, pastLast,
                    columns, rows: int] =
  let grid = nodes[parent]
  result.first = scratch.items.len
  result.columns = max(grid.cols.len, 1)
  result.rows = grid.rows.len
  var child = int(grid.firstChild)
  while child >= 0:
    let node = nodes[child]
    if not node.absolute:
      var item = GridItem(slot: child,
        col: (if node.gridCol > 0: node.gridCol - 1 else: -1),
        row: (if node.gridRow > 0: node.gridRow - 1 else: -1),
        colSpan: node.gridColSpan, rowSpan: node.gridRowSpan)
      if item.colSpan < 0:
        item.colSpan = max(grid.cols.len - max(item.col, 0), 1)
      elif item.colSpan == 0:
        item.colSpan = 1
      if item.rowSpan < 0:
        item.rowSpan = max(grid.rows.len - max(item.row, 0), 1)
      elif item.rowSpan == 0:
        item.rowSpan = 1
      result.columns = max(result.columns,
        max(item.col, 0) + item.colSpan)
      scratch.items.add(item)
    child = int(node.nextSibling)
  result.pastLast = scratch.items.len

  for index in result.first ..< result.pastLast:
    let item = scratch.items[index]
    checkGridCellCount(item.colSpan, item.rowSpan, 0)
    if item.row >= 0:
      checkGridCellCount(result.columns, item.row + item.rowSpan, 0)

  let cellsBase = scratch.occupied.len
  for index in result.first ..< result.pastLast:
    let item = scratch.items[index]
    if item.row >= 0 and item.col >= 0:
      scratch.markGridCell(cellsBase, result.columns, index,
        item.row, item.col, result.rows)

  for index in result.first ..< result.pastLast:
    let item = scratch.items[index]
    if item.row >= 0 and item.col < 0:
      var column = 0
      while column + item.colSpan <= result.columns and
          not scratch.gridCellFits(cellsBase, result.columns, item.row,
            column, item.rowSpan, item.colSpan):
        inc column
      if column + item.colSpan > result.columns:
        column = max(result.columns - item.colSpan, 0)
      scratch.markGridCell(cellsBase, result.columns, index,
        item.row, column, result.rows)

  var cursorRow, cursorColumn: int
  for index in result.first ..< result.pastLast:
    let item = scratch.items[index]
    if item.row < 0:
      if item.col >= 0:
        if item.col < cursorColumn:
          inc cursorRow
        cursorColumn = item.col
        var row = cursorRow
        while not scratch.gridCellFits(cellsBase, result.columns, row,
            item.col, item.rowSpan, item.colSpan):
          inc row
        cursorRow = row
        scratch.markGridCell(cellsBase, result.columns, index,
          row, item.col, result.rows)
      else:
        var row = cursorRow
        var column = cursorColumn
        while not scratch.gridCellFits(cellsBase, result.columns, row,
            column, item.rowSpan, item.colSpan):
          if column + item.colSpan <= result.columns:
            inc column
          else:
            inc row
            column = 0
        scratch.markGridCell(cellsBase, result.columns, index,
          row, column, result.rows)
        cursorRow = row
        cursorColumn = column + item.colSpan
  scratch.occupied.setLen(cellsBase)

proc gridTrack(tracks: seq[Track]; index: int): Track =
  if index < tracks.len: tracks[index] else: Track(kind: trackFit)

proc gridTrackCount(tracks: seq[Track]; first, span: int;
                    kind: TrackKind): int =
  for index in first ..< first + span:
    if tracks.gridTrack(index).kind == kind:
      inc result

proc sizeGridTracks(tracks: seq[Track]; count: int; available, gap: float32;
                    scratch: GridScratch; contributionFirst,
                    contributionPast: int; minContent, stretch: bool;
                    values: var seq[float32]; valuesFirst: int) =
  let limitFirst = valuesFirst + count
  values.setLen(max(values.len, valuesFirst + 2 * count))
  for index in 0 ..< count:
    let track = tracks.gridTrack(index)
    values[valuesFirst + index] = if track.kind == trackFixed:
        track.value
      else:
        0'f32
    values[limitFirst + index] = values[valuesFirst + index]

  for itemIndex in contributionFirst ..< contributionPast:
    let contribution = scratch.contributions[itemIndex]
    if contribution.span == 1 and
        tracks.gridTrack(contribution.start).kind == trackFit:
      let sizeIndex = valuesFirst + contribution.start
      let limitIndex = limitFirst + contribution.start
      values[sizeIndex] = max(values[sizeIndex], contribution.minimum)
      values[limitIndex] = max(values[limitIndex], contribution.maximum)

  for itemIndex in contributionFirst ..< contributionPast:
    let contribution = scratch.contributions[itemIndex]
    let fractionalCount = tracks.gridTrackCount(contribution.start,
      contribution.span, trackFr)
    if contribution.span > 1 and fractionalCount == 0:
      let fitCount = tracks.gridTrackCount(contribution.start,
        contribution.span, trackFit)
      if fitCount > 0:
        var sum, limit: float32
        for index in contribution.start ..<
            contribution.start + contribution.span:
          sum += values[valuesFirst + index]
          limit += max(values[limitFirst + index], values[valuesFirst + index])
        sum += gap * float32(contribution.span - 1)
        limit += gap * float32(contribution.span - 1)
        for index in contribution.start ..<
            contribution.start + contribution.span:
          if tracks.gridTrack(index).kind == trackFit:
            if contribution.minimum > sum:
              values[valuesFirst + index] +=
                (contribution.minimum - sum) / float32(fitCount)
            if contribution.maximum > limit:
              values[limitFirst + index] =
                max(values[limitFirst + index], values[valuesFirst + index]) +
                (contribution.maximum - limit) / float32(fitCount)

  var fractionalSum: float32
  for index in 0 ..< count:
    values[limitFirst + index] = max(values[limitFirst + index],
      values[valuesFirst + index])
    let track = tracks.gridTrack(index)
    if track.kind == trackFr:
      fractionalSum += track.value
  if minContent:
    return

  let gaps = gap * float32(max(count - 1, 0))
  if not finiteUi(available):
    var unit: float32
    for itemIndex in contributionFirst ..< contributionPast:
      let contribution = scratch.contributions[itemIndex]
      var fractional, other: float32
      for index in contribution.start ..< contribution.start +
          contribution.span:
        let track = tracks.gridTrack(index)
        if track.kind == trackFr:
          fractional += track.value
        else:
          other += values[limitFirst + index]
      if fractional > 0:
        unit = max(unit, (contribution.maximum - other -
          gap * float32(contribution.span - 1)) / fractional)
    for index in 0 ..< count:
      let track = tracks.gridTrack(index)
      values[valuesFirst + index] = if track.kind == trackFr:
          unit * track.value
        else:
          values[limitFirst + index]
    return

  var free = available - gaps
  for index in 0 ..< count:
    free -= values[valuesFirst + index]
  while free > 0.01'f32:
    var growing: int
    for index in 0 ..< count:
      if tracks.gridTrack(index).kind == trackFit and
          values[valuesFirst + index] < values[limitFirst + index]:
        inc growing
    if growing == 0:
      break
    let share = free / float32(growing)
    for index in 0 ..< count:
      if tracks.gridTrack(index).kind == trackFit and
          values[valuesFirst + index] < values[limitFirst + index]:
        let delta = min(share,
          values[limitFirst + index] - values[valuesFirst + index])
        values[valuesFirst + index] += delta
        free -= delta
  free = max(free, 0'f32)
  if fractionalSum > 0:
    let unit = free / max(fractionalSum, 1'f32)
    for index in 0 ..< count:
      let track = tracks.gridTrack(index)
      if track.kind == trackFr:
        values[valuesFirst + index] = unit * track.value
    return
  if stretch and free > 0:
    let fitCount = tracks.gridTrackCount(0, count, trackFit)
    if fitCount > 0:
      for index in 0 ..< count:
        if tracks.gridTrack(index).kind == trackFit:
          values[valuesFirst + index] += free / float32(fitCount)

proc gridItemAlign(grid, item: ElementNode; horizontal: bool): Align =
  if horizontal:
    if item.justifySelf != Align.Auto:
      result = item.justifySelf
    elif grid.justifyItems != Align.Auto:
      result = grid.justifyItems
    else:
      result = Align.Stretch
  else:
    if item.selfAlign != Align.Auto:
      result = item.selfAlign
    elif grid.align != Align.Auto:
      result = grid.align
    else:
      result = Align.Stretch
  if horizontal and grid.rightToLeft:
    result = reverseHorizontalAlign(result)

proc gridCellDimension(node: ElementNode; natural: NaturalSize;
                       horizontal: bool; area, base, mainExtent: float32;
                       align: Align): tuple[size, offset: float32] =
  let dimension = if horizontal: node.width else: node.height
  let minimum = if horizontal: node.minW else: node.minH
  let maximum = if horizontal: node.maxW else: node.maxH
  let marginStartIndex = if horizontal: 3 else: 0
  let marginEndIndex = if horizontal: 1 else: 2
  let marginStart = marginValue(node.margin[marginStartIndex])
  let marginEnd = marginValue(node.margin[marginEndIndex])
  let margins = marginStart + marginEnd
  let autoStart = node.margin[marginStartIndex] == Auto
  let autoEnd = node.margin[marginEndIndex] == Auto
  let resolved = dimension.resolve(base)
  if resolved.ok:
    result.size = clampSize(resolved.value, minimum, maximum, base)
  elif not horizontal and node.aspectRatio > 0:
    result.size = clampSize(
      max(mainExtent - node.contentInsetX, 0'f32) / node.aspectRatio +
        node.contentInsetY, minimum, maximum, base)
  elif align == Align.Stretch and not autoStart and not autoEnd and
      (horizontal or node.aspectRatio <= 0):
    result.size = clampSize(max(area - margins, 0'f32),
      minimum, maximum, base)
  else:
    let naturalSize = if horizontal: natural.w else: natural.h
    result.size = clampSize(min(naturalSize, max(area - margins, 0'f32)),
      minimum, maximum, base)

  let free = area - result.size - margins
  result.offset = marginStart
  if autoStart and autoEnd:
    result.offset += max(free, 0'f32) / 2
  elif autoStart:
    result.offset += max(free, 0'f32)
  elif not autoEnd:
    case align
    of Align.Center:
      result.offset += free / 2
    of Align.End:
      result.offset += free
    else:
      discard

proc gridArea(values: seq[float32]; first, start, span: int;
              gap: float32): float32 =
  result = gap * float32(span - 1)
  for index in start ..< start + span:
    result += values[first + index]

proc gridColumns(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                 parent: int; scratch: var GridScratch; first, pastLast,
                 columns, valuesFirst: int; available, base: float32) =
  let grid = nodes[parent]
  let contributionFirst = scratch.contributions.len
  for itemIndex in first ..< pastLast:
    let item = scratch.items[itemIndex]
    let node = nodes[item.slot]
    let width = node.width.resolve(base)
    let contentWidth = if width.ok:
        node.clampWidth(width.value, base)
      else:
        natural[item.slot].w
    scratch.contributions.add(GridContribution(start: item.col,
      span: item.colSpan, minimum: contentWidth + node.marginX,
      maximum: contentWidth + node.marginX))
  sizeGridTracks(grid.cols, columns, available, grid.gapX,
    scratch, contributionFirst, scratch.contributions.len, false,
    grid.justify == Align.Auto, scratch.values, valuesFirst)
  scratch.contributions.setLen(contributionFirst)

proc justifyOffsets(justify: Align; free: float32; count: int):
    tuple[start, between: float32] =
  if count <= 0:
    return (0'f32, 0'f32)
  case justify
  of Align.Center:
    (free / 2, 0'f32)
  of Align.End:
    (free, 0'f32)
  of Align.SpaceBetween:
    if count > 1:
      (0'f32, free / float32(count - 1))
    else:
      (0'f32, 0'f32)
  of Align.SpaceAround:
    (free / float32(count) / 2, free / float32(count))
  of Align.SpaceEvenly:
    (free / float32(count + 1), free / float32(count + 1))
  else:
    (0'f32, 0'f32)

proc gridRows(nodes: seq[ElementNode]; natural: seq[NaturalSize]; parent: int;
              scratch: var GridScratch; first, pastLast, columns, rows,
              columnValues, rowValues: int; available, widthBase,
              heightBase, columnGap: float32) =
  let grid = nodes[parent]
  let contributionFirst = scratch.contributions.len
  for itemIndex in first ..< pastLast:
    let item = scratch.items[itemIndex]
    let node = nodes[item.slot]
    let areaWidth = scratch.values.gridArea(columnValues, item.col,
      item.colSpan, columnGap)
    let itemWidth = node.gridCellDimension(natural[item.slot], true,
      areaWidth, widthBase, 0'f32, grid.gridItemAlign(node, true)).size
    let height = node.height.resolve(heightBase)
    let itemHeight = if height.ok:
        node.clampHeight(height.value, heightBase)
      elif node.aspectRatio > 0:
        node.clampHeight(
          max(itemWidth - node.contentInsetX, 0'f32) / node.aspectRatio +
            node.contentInsetY, heightBase)
      else:
        natural[item.slot].h
    scratch.contributions.add(GridContribution(start: item.row,
      span: item.rowSpan, minimum: itemHeight + node.marginY,
      maximum: itemHeight + node.marginY))
  sizeGridTracks(grid.rows, rows, available, grid.gapY, scratch,
    contributionFirst, scratch.contributions.len, false,
    grid.alignContent == Align.Auto, scratch.values, rowValues)
  scratch.contributions.setLen(contributionFirst)

proc measureGrid(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                 parent: int; constraints: seq[Rect];
                 scratch: var GridScratch): tuple[w, h: float32] =
  let grid = nodes[parent]
  let itemsFirst = scratch.items.len
  let valuesFirst = scratch.values.len
  let placed = gridPlaceItems(nodes, parent, scratch)
  let width = grid.width.resolve(-1)
  let height = grid.height.resolve(-1)
  let outerWidth = if parent < constraints.len: constraints[parent].w
    elif width.ok: width.value
    else: Inf.float32
  let outerHeight = if parent < constraints.len: constraints[parent].h
    elif height.ok: height.value
    else: Inf.float32
  let widthBase = if finiteUi(outerWidth):
      max(outerWidth - grid.contentInsetX, 0'f32)
    else:
      -1'f32
  let heightBase = if finiteUi(outerHeight):
      max(outerHeight - grid.contentInsetY, 0'f32)
    else:
      -1'f32
  let columnAvailable = if widthBase >= 0: widthBase else: Inf.float32
  let rowAvailable = if heightBase >= 0: heightBase else: Inf.float32
  let columnsFirst = scratch.values.len
  gridColumns(nodes, natural, parent, scratch, placed.first,
    placed.pastLast, placed.columns, columnsFirst, columnAvailable, widthBase)
  var usedWidth = grid.gapX * float32(max(placed.columns - 1, 0))
  for index in 0 ..< placed.columns:
    usedWidth += scratch.values[columnsFirst + index]
  let columnOffsets = if finiteUi(columnAvailable) and
      grid.justify != Align.Auto:
    justifyOffsets(grid.justify,
      max(columnAvailable - usedWidth, 0'f32), placed.columns)
  else:
    (start: 0'f32, between: 0'f32)
  let rowsFirst = scratch.values.len
  gridRows(nodes, natural, parent, scratch, placed.first, placed.pastLast,
    placed.columns, placed.rows, columnsFirst, rowsFirst, rowAvailable,
    widthBase, heightBase, grid.gapX + columnOffsets.between)
  result.w = grid.gapX * float32(max(placed.columns - 1, 0))
  for index in 0 ..< placed.columns:
    result.w += scratch.values[columnsFirst + index]
  result.h = grid.gapY * float32(max(placed.rows - 1, 0))
  for index in 0 ..< placed.rows:
    result.h += scratch.values[rowsFirst + index]
  scratch.items.setLen(itemsFirst)
  scratch.values.setLen(valuesFirst)

proc measureTree(nodes: seq[ElementNode]; natural: var seq[NaturalSize];
                 scratch: var GridScratch; constraints: seq[Rect] = @[];
                 firstSlot = 0; lastSlot = -1): bool =
  natural.setLen(nodes.len)
  if nodes.len == 0:
    return
  let last = if lastSlot < 0: nodes.high else: min(lastSlot, nodes.high)
  if firstSlot > last:
    return

  for slot in countdown(last, firstSlot):
    let previous = natural[slot]
    let node = nodes[slot]
    var contentW, contentH: float32
    if node.hasText and not node.textInline and not node.textOverlay and
        node.shapedText != nil:
      contentW = node.shapedText.width
      contentH = node.shapedText.height
    if node.bitmap != nil and node.bitmap.image != nil:
      let source = node.bitmapSource
      contentW = max(contentW, source.w)
      contentH = max(contentH, source.h)
    if node.vector != nil:
      if node.icon:
        let em = if node.textStyle.size > 0: node.textStyle.size else: 16'f32
        let aspect = if node.vector.height > 0:
            node.vector.width / node.vector.height
          else:
            1'f32
        contentW = max(contentW, em * aspect)
        contentH = max(contentH, em)
      else:
        contentW = max(contentW, node.vector.width)
        contentH = max(contentH, node.vector.height)
    elif node.icon:
      let em = if node.textStyle.size > 0: node.textStyle.size else: 16'f32
      contentW = max(contentW, em)
      contentH = max(contentH, em)
    var childCount = 0
    var child = int(node.firstChild)
    while child >= 0:
      let childNode = nodes[child]
      if not childNode.textInline:
        let childSize = natural[child]
        if not childNode.absolute and not node.grid:
          if node.row:
            let basis = childNode.basis.resolve(-1)
            let mainW = if basis.ok:
                childNode.clampWidth(basis.value, -1)
              else:
                childSize.w
            contentW += mainW + childNode.marginX
            contentH = max(contentH, childSize.h + childNode.marginY)
          else:
            contentW = max(contentW, childSize.w + childNode.marginX)
            let basis = childNode.basis.resolve(-1)
            let mainH = if basis.ok:
                childNode.clampHeight(basis.value, -1)
              else:
                childSize.h
            contentH += mainH + childNode.marginY
          inc childCount
      child = int(childNode.nextSibling)

    if node.grid and not node.textInlineParagraph:
      let gridNatural = measureGrid(nodes, natural, slot, constraints, scratch)
      contentW = max(contentW, gridNatural.w)
      contentH = max(contentH, gridNatural.h)

    var measuredMain = (if node.row: node.width else: node.height).resolve(-1)
    if slot < constraints.len:
      measuredMain = (value: (if node.row: constraints[slot].w
        else: constraints[slot].h), ok: true)
    if node.wrap and not node.grid and measuredMain.ok and childCount > 0:
      let mainInset = if node.row: node.contentInsetX else:
        node.contentInsetY
      let mainLimit = max(measuredMain.value - mainInset, 0'f32)
      let mainGap = if node.row: node.gapX else: node.gapY
      let crossGap = if node.row: node.gapY else: node.gapX
      let crossDimension = if node.row: node.height else: node.width
      let measuredCross = crossDimension.resolve(-1)
      let crossInset = if node.row: node.contentInsetY else:
        node.contentInsetX
      var crossBase = if measuredCross.ok:
          max(measuredCross.value - crossInset, 0'f32)
        else:
          -1'f32
      if slot < constraints.len:
        crossBase = max((if node.row: constraints[slot].h
          else: constraints[slot].w) - crossInset, 0'f32)
      var lineMain, lineCross, usedCross: float32
      var lineCount = 0
      var hasCompletedLine = false
      child = int(node.firstChild)
      while child >= 0:
        let childSlot = child
        let childNode = nodes[childSlot]
        if not childNode.absolute and not childNode.textInline:
          let childNatural = natural[childSlot]
          let basis = childNode.basis.resolve(mainLimit)
          let dimension = (if node.row: childNode.width else:
            childNode.height).resolve(mainLimit)
          let mainSize = if basis.ok: basis.value
            elif dimension.ok: dimension.value
            elif node.row: childNatural.w
            else: childNatural.h
          let mainMargin = if node.row: childNode.marginX else:
            childNode.marginY
          let crossMargin = if node.row: childNode.marginY else:
            childNode.marginX
          let outerMain = max(mainSize, 0'f32) + mainMargin
          if lineCount > 0 and lineMain + mainGap + outerMain > mainLimit:
            if hasCompletedLine:
              usedCross += crossGap
            usedCross += lineCross
            hasCompletedLine = true
            lineMain = 0
            lineCross = 0
            lineCount = 0
          if lineCount > 0:
            lineMain += mainGap
          lineMain += outerMain
          let crossExtent = childNode.crossSize(childNatural, node.row,
            crossBase, mainSize, 0'f32, crossMargin, Align.Start)
          lineCross = max(lineCross, crossExtent + crossMargin)
          inc lineCount
        child = int(childNode.nextSibling)
      if lineCount > 0:
        if hasCompletedLine:
          usedCross += crossGap
        usedCross += lineCross
      if node.row:
        contentH = max(contentH, usedCross)
      else:
        contentW = max(contentW, usedCross)

    if childCount > 1:
      if node.row:
        contentW += node.gapX * float32(childCount - 1)
      else:
        contentH += node.gapY * float32(childCount - 1)

    if node.textAreaInput:
      let line = textStack.shared().layout(textStack.Params(text: " ",
        style: node.textStyle, keepSpaces: true, rtl: node.rightToLeft))
      let lineHeight = max(line.height, max(node.textStyle.size, 1'f32))
      if node.textAreaMaxLines > 0:
        contentH = min(max(contentH,
          float32(node.textAreaMinLines) * lineHeight),
          float32(node.textAreaMaxLines) * lineHeight)
      else:
        contentH = float32(max(node.textAreaParagraphs, 3)) * lineHeight

    let width = node.width.resolve(-1)
    let height = node.height.resolve(-1)
    var rawW = if width.ok: width.value else: contentW + node.contentInsetX
    var rawH = if height.ok: height.value else: contentH + node.contentInsetY
    if node.aspectRatio > 0:
      if width.ok and not height.ok:
        rawH = max(rawW - node.contentInsetX, 0'f32) /
          node.aspectRatio + node.contentInsetY
      elif height.ok and not width.ok:
        rawW = max(rawH - node.contentInsetY, 0'f32) *
          node.aspectRatio + node.contentInsetX
      elif not width.ok and not height.ok:
        let contentWidth = max(rawW - node.contentInsetX, 0'f32)
        let contentHeight = max(rawH - node.contentInsetY, 0'f32)
        if contentWidth > 0 or contentHeight <= 0:
          rawH = contentWidth / node.aspectRatio + node.contentInsetY
        else:
          rawW = contentHeight * node.aspectRatio + node.contentInsetX
    let measured = NaturalSize(
      w: node.clampWidth(rawW, -1),
      h: node.clampHeight(rawH, -1))
    if measured.w != previous.w or measured.h != previous.h:
      result = true
    natural[slot] = measured

proc distribute(nodes: seq[ElementNode]; children: seq[int];
                first, pastLast: int;
                sizes, minimum, maximum, factors: var seq[float32];
                amount: float32; growing: bool) =
  template room(child: int): float32 =
    if growing:
      if classify(maximum[child]) == fcInf: Inf.float32
      else: maximum[child] - sizes[child]
    else:
      sizes[child] - minimum[child]
  var remaining = amount
  for _ in 0 .. (pastLast - first):
    var totalFactor: float32
    for itemIndex in first ..< pastLast:
      let child = children[itemIndex]
      if room(child) > 0 and factors[child] > 0:
        totalFactor += factors[child]
    if totalFactor <= 0 or remaining <= 0:
      break

    var changed: float32
    for itemIndex in first ..< pastLast:
      let child = children[itemIndex]
      let available = room(child)
      if available > 0 and factors[child] > 0:
        let share = remaining * factors[child] / totalFactor
        let delta = min(share, available)
        if growing:
          sizes[child] += delta
        else:
          sizes[child] -= delta
        changed += delta
    remaining -= changed
    if changed <= 0:
      break

proc preferredMain(node: ElementNode; natural: NaturalSize; row: bool;
                   base: float32): float32 =
  let dimension = if row: node.width else: node.height
  let intrinsic = if row: natural.w else: natural.h
  let resolved = dimension.resolve(base)
  if resolved.ok: resolved.value else: intrinsic

proc crossSize(node: ElementNode; natural: NaturalSize; row: bool;
               base, mainExtent, available, margins: float32;
               align: Align): float32 =
  let dimension = if row: node.height else: node.width
  let minimum = if row: node.minH else: node.minW
  let maximum = if row: node.maxH else: node.maxW
  let intrinsic = if row: natural.h else: natural.w
  let resolved = dimension.resolve(base)
  var value = if resolved.ok: resolved.value else: intrinsic
  let startMargin = if row: 0 else: 3
  let endMargin = if row: 2 else: 1
  let autoMargin = node.margin[startMargin] == Auto or
    node.margin[endMargin] == Auto
  if not resolved.ok and node.aspectRatio > 0:
    let mainInset = if row: node.contentInsetX else: node.contentInsetY
    let crossInset = if row: node.contentInsetY else: node.contentInsetX
    let mainContent = max(mainExtent - mainInset, 0'f32)
    value = (if row: mainContent / node.aspectRatio
             else: mainContent * node.aspectRatio) + crossInset
  elif not resolved.ok and align == Align.Stretch and not autoMargin:
    value = max(available - margins, 0'f32)
  clampSize(value, minimum, maximum, base)

proc placeAbsoluteChild(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                        rects: var seq[Rect]; sizes, bases, minimum, maximum,
                        factors: var seq[float32]; flexSlots: var seq[int];
                        flexLines: var seq[FlexLine]; gridScratch: var GridScratch;
                        parentSlot,
                        childSlot: int; bounds: Rect)

proc placeNode(nodes: seq[ElementNode]; natural: seq[NaturalSize];
               rects: var seq[Rect]; sizes, bases, minimum, maximum,
               factors: var seq[float32]; flexSlots: var seq[int];
               flexLines: var seq[FlexLine]; gridScratch: var GridScratch;
               slot: int; bounds: Rect)

proc placeGridChildren(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                       rects: var seq[Rect]; sizes, bases, minimum, maximum,
                       factors: var seq[float32]; flexSlots: var seq[int];
                       flexLines: var seq[FlexLine];
                       gridScratch: var GridScratch; parent: int;
                       bounds: Rect)

proc placeNode(nodes: seq[ElementNode]; natural: seq[NaturalSize];
               rects: var seq[Rect]; sizes, bases, minimum, maximum,
               factors: var seq[float32]; flexSlots: var seq[int];
               flexLines: var seq[FlexLine]; gridScratch: var GridScratch;
               slot: int; bounds: Rect) =
  rects[slot] = bounds
  let node = nodes[slot]
  var child = int(node.firstChild)
  var totalChildren = 0
  while child >= 0:
    if not nodes[child].textInline:
      inc totalChildren
    child = int(nodes[child].nextSibling)
  if totalChildren == 0:
    return

  if node.grid and not node.textInlineParagraph:
    placeGridChildren(nodes, natural, rects, sizes, bases, minimum, maximum,
      factors, flexSlots, flexLines, gridScratch, slot, bounds)
    return

  let slotsBase = flexSlots.len
  let linesBase = flexLines.len

  let row = node.row
  let innerX = bounds.x + node.pad[3] + node.border[3]
  let innerY = bounds.y + node.pad[0] + node.border[0]
  let innerW = max(bounds.w - node.contentInsetX, 0'f32)
  let innerH = max(bounds.h - node.contentInsetY, 0'f32)
  let mainSize = if row: innerW else: innerH
  let crossSize = if row: innerH else: innerW
  let gap = if row: node.gapX else: node.gapY
  let reverseMain = node.reverse xor (row and node.rightToLeft)
  let mainStart = if row:
      (if reverseMain: 1 else: 3)
    else:
      (if reverseMain: 2 else: 0)
  let mainEnd = if row:
      (if reverseMain: 3 else: 1)
    else:
      (if reverseMain: 0 else: 2)
  var crossStart = if row: 0 else: (if node.rightToLeft: 1 else: 3)
  var crossEnd = if row: 2 else: (if node.rightToLeft: 3 else: 1)
  let reverseCross = node.wrapReverse xor (not row and node.rightToLeft)
  if node.wrapReverse:
    swap(crossStart, crossEnd)

  var activeLine = FlexLine(first: slotsBase)

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
    let childNode = nodes[childSlot]
    if not childNode.absolute and not childNode.textInline:
      let childNatural = natural[childSlot]
      let mainBase = childNode.basis.resolve(mainSize)
      let fallback = childNode.preferredMain(childNatural, row,
        if row: innerW else: innerH)
      bases[childSlot] = if mainBase.ok: mainBase.value else: fallback
      let minLength = if row: childNode.minW else: childNode.minH
      let maxLength = if row: childNode.maxW else: childNode.maxH
      let dimensionBase = if row: innerW else: innerH
      let minValue = minLength.resolve(dimensionBase)
      let maxValue = maxLength.resolve(dimensionBase)
      var autoMin: float32
      if row:
        autoMin = childNatural.w
      elif childNode.grow == 0:
        autoMin = childNatural.h
      let preferred = if row:
          childNode.width.resolve(dimensionBase)
        else:
          childNode.height.resolve(dimensionBase)
      if preferred.ok:
        autoMin = min(autoMin, preferred.value)
      minimum[childSlot] = if minValue.ok:
          max(minValue.value, 0'f32)
        else:
          max(autoMin, 0'f32)
      maximum[childSlot] = if maxValue.ok:
          max(maxValue.value, minimum[childSlot])
        else:
          Inf.float32
      sizes[childSlot] = min(max(bases[childSlot], minimum[childSlot]),
        maximum[childSlot])
      let marginMain = if row: childNode.marginX else: childNode.marginY
      let outer = sizes[childSlot] + marginMain
      if node.wrap and classify(mainSize) notin {fcNan, fcInf, fcNegInf} and
          flexSlots.len > activeLine.first and
          activeLine.main + gap + outer > mainSize:
        activeLine.pastLast = flexSlots.len
        flexLines.add(activeLine)
        activeLine = FlexLine(first: flexSlots.len)
      if flexSlots.len > activeLine.first:
        activeLine.main += gap
      activeLine.main += outer
      flexSlots.add(childSlot)
    child = int(childNode.nextSibling)

  if flexSlots.len > activeLine.first:
    activeLine.pastLast = flexSlots.len
    flexLines.add(activeLine)

  var lineIndex = linesBase
  while lineIndex < flexLines.len:
    var line = flexLines[lineIndex]
    let itemCount = line.pastLast - line.first
    let lineGaps = if itemCount > 1:
        gap * float32(itemCount - 1)
      else:
        0'f32
    var outerMain = lineGaps
    for itemIndex in line.first ..< line.pastLast:
      let childSlot = flexSlots[itemIndex]
      let childNode = nodes[childSlot]
      outerMain += sizes[childSlot] +
        (if row: childNode.marginX else: childNode.marginY)
    let free = mainSize - outerMain
    if free > 0:
      for itemIndex in line.first ..< line.pastLast:
        let childSlot = flexSlots[itemIndex]
        factors[childSlot] = nodes[childSlot].grow
      distribute(nodes, flexSlots, line.first, line.pastLast, sizes,
        minimum, maximum, factors, free, true)
    elif free < 0:
      for itemIndex in line.first ..< line.pastLast:
        let childSlot = flexSlots[itemIndex]
        factors[childSlot] = nodes[childSlot].shrink *
          max(bases[childSlot], 0'f32)
      distribute(nodes, flexSlots, line.first, line.pastLast, sizes,
        minimum, maximum, factors, -free, false)
    line.main = lineGaps
    for itemIndex in line.first ..< line.pastLast:
      let childSlot = flexSlots[itemIndex]
      let childNode = nodes[childSlot]
      line.main += sizes[childSlot] +
        (if row: childNode.marginX else: childNode.marginY)
    flexLines[lineIndex] = line
    inc lineIndex

  let defaultAlign = if node.align == Align.Auto: Align.Stretch else: node.align
  let crossBase = if row: innerH else: innerW

  lineIndex = linesBase
  while lineIndex < flexLines.len:
    var line = flexLines[lineIndex]
    for itemIndex in line.first ..< line.pastLast:
      let childSlot = flexSlots[itemIndex]
      let childNode = nodes[childSlot]
      let childNatural = natural[childSlot]
      let crossBefore = if childNode.margin[crossStart] == Auto:
          0'f32
        else:
          childNode.margin[crossStart]
      let crossAfter = if childNode.margin[crossEnd] == Auto:
          0'f32
        else:
          childNode.margin[crossEnd]
      let extent = childNode.crossSize(childNatural, row,
        crossBase, sizes[childSlot], 0'f32, crossBefore + crossAfter,
        Align.Start)
      line.cross = max(line.cross, extent + crossBefore + crossAfter)
    flexLines[lineIndex] = line
    inc lineIndex

  let lineCount = flexLines.len - linesBase
  if lineCount == 1 and not node.wrap and
      classify(crossSize) notin {fcNan, fcInf, fcNegInf}:
    flexLines[linesBase].cross = crossSize

  var linesCross: float32
  for index in linesBase ..< flexLines.len:
    if index > linesBase:
      linesCross += (if row: node.gapY else: node.gapX)
    linesCross += flexLines[index].cross
  var lineStart, lineBetween: float32
  if node.alignContent != Align.Auto and
      classify(crossSize) notin {fcNan, fcInf, fcNegInf} and
      lineCount > 0 and (node.wrap or lineCount > 1):
    let crossFree = crossSize - linesCross
    if node.alignContent == Align.Stretch and crossFree > 0:
      for index in linesBase ..< flexLines.len:
        flexLines[index].cross += crossFree / float32(lineCount)
      linesCross = crossSize
    else:
      let distribution = justifyOffsets(node.alignContent,
        max(crossFree, 0'f32), lineCount)
      lineStart = distribution.start
      lineBetween = distribution.between
      if crossFree < 0 and node.alignContent in {Align.Center, Align.End}:
        lineStart = justifyOffsets(node.alignContent, crossFree, lineCount).start

  let crossGap = if row: node.gapY else: node.gapX
  var linePosition = lineStart
  lineIndex = linesBase
  while lineIndex < flexLines.len:
    let line = flexLines[lineIndex]
    let free = max(mainSize - line.main, 0'f32)
    var autoMainMargins = 0
    for itemIndex in line.first ..< line.pastLast:
      let childSlot = flexSlots[itemIndex]
      let childNode = nodes[childSlot]
      if childNode.margin[mainStart] == Auto:
        inc autoMainMargins
      if childNode.margin[mainEnd] == Auto:
        inc autoMainMargins
    let autoMain = if autoMainMargins > 0:
        free / float32(autoMainMargins)
      else:
        0'f32
    let justifyFree = if autoMainMargins > 0: 0'f32 else: free
    let offsets = justifyOffsets(node.justify, justifyFree,
      line.pastLast - line.first)
    var position = offsets.start
    var itemIndex = line.first
    while itemIndex < line.pastLast:
      let childSlot = flexSlots[itemIndex]
      let childNode = nodes[childSlot]
      let childNatural = natural[childSlot]
      let mainBefore = if childNode.margin[mainStart] == Auto:
          autoMain
        else:
          childNode.margin[mainStart]
      let mainAfter = if childNode.margin[mainEnd] == Auto:
          autoMain
        else:
          childNode.margin[mainEnd]
      let crossBefore = if childNode.margin[crossStart] == Auto:
          0'f32
        else:
          childNode.margin[crossStart]
      let crossAfter = if childNode.margin[crossEnd] == Auto:
          0'f32
        else:
          childNode.margin[crossEnd]
      let crossMargins = crossBefore + crossAfter
      let childAlign = if childNode.selfAlign == Align.Auto:
          defaultAlign
        else:
          childNode.selfAlign
      let childCross = childNode.crossSize(childNatural, row,
        crossBase, sizes[childSlot], line.cross, crossMargins, childAlign)
      let crossFree = line.cross - childCross - crossMargins
      var crossOffset: float32
      if childNode.margin[crossStart] == Auto and
          childNode.margin[crossEnd] == Auto:
        crossOffset = max(crossFree, 0'f32) / 2
      elif childNode.margin[crossStart] == Auto:
        crossOffset = max(crossFree, 0'f32)
      elif childNode.margin[crossEnd] != Auto:
        case childAlign
        of Align.Center:
          crossOffset = crossFree / 2
        of Align.End:
          crossOffset = crossFree
        else:
          discard
      crossOffset += crossBefore + linePosition
      if reverseCross:
        crossOffset = crossSize - crossOffset - childCross

      let mainPosition = position + mainBefore
      let mainOffset = if reverseMain:
          mainSize - mainPosition - sizes[childSlot]
        else:
          mainPosition
      var childRect: Rect
      if row:
        childRect = Rect(x: innerX + mainOffset, y: innerY + crossOffset,
          w: sizes[childSlot], h: childCross)
      else:
        childRect = Rect(x: innerX + crossOffset, y: innerY + mainOffset,
          w: childCross, h: sizes[childSlot])
      let left = childNode.inset[3].resolve(innerW)
      let right = childNode.inset[1].resolve(innerW)
      let top = childNode.inset[0].resolve(innerH)
      let bottom = childNode.inset[2].resolve(innerH)
      if left.ok:
        childRect.x += left.value
      elif right.ok:
        childRect.x -= right.value
      if top.ok:
        childRect.y += top.value
      elif bottom.ok:
        childRect.y -= bottom.value
      placeNode(nodes, natural, rects, sizes, bases, minimum, maximum,
        factors, flexSlots, flexLines, gridScratch, childSlot, childRect)
      position += mainBefore + sizes[childSlot] + mainAfter + gap +
        offsets.between
      inc itemIndex
    linePosition += line.cross + crossGap + lineBetween
    inc lineIndex

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
    let childNode = nodes[childSlot]
    if childNode.absolute and not childNode.textInline:
      placeAbsoluteChild(nodes, natural, rects, sizes, bases, minimum,
        maximum, factors, flexSlots, flexLines, gridScratch, slot, childSlot,
        bounds)
    child = int(childNode.nextSibling)
  flexSlots.setLen(slotsBase)
  flexLines.setLen(linesBase)

proc placeGridChildren(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                       rects: var seq[Rect]; sizes, bases, minimum, maximum,
                       factors: var seq[float32]; flexSlots: var seq[int];
                       flexLines: var seq[FlexLine];
                       gridScratch: var GridScratch; parent: int;
                       bounds: Rect) =
  let grid = nodes[parent]
  let itemsBase = gridScratch.items.len
  let valuesBase = gridScratch.values.len
  let contributionsBase = gridScratch.contributions.len
  let cellsBase = gridScratch.occupied.len
  let innerX = bounds.x + grid.pad[3] + grid.border[3]
  let innerY = bounds.y + grid.pad[0] + grid.border[0]
  let innerW = max(bounds.w - grid.contentInsetX, 0'f32)
  let innerH = max(bounds.h - grid.contentInsetY, 0'f32)
  let placed = gridPlaceItems(nodes, parent, gridScratch)
  let itemCount = placed.pastLast - placed.first

  let columnsFirst = gridScratch.values.len
  gridColumns(nodes, natural, parent, gridScratch, placed.first,
    placed.pastLast, placed.columns, columnsFirst, innerW, innerW)
  var usedW = grid.gapX * float32(max(placed.columns - 1, 0))
  for index in 0 ..< placed.columns:
    usedW += gridScratch.values[columnsFirst + index]
  var xStart, xBetween, yStart, yBetween: float32
  let freeW = innerW - usedW
  if grid.justify != Align.Auto:
    let alignment = if grid.rightToLeft:
        reverseHorizontalAlign(grid.justify)
      else:
        grid.justify
    let offsets = justifyOffsets(alignment, max(freeW, 0'f32), placed.columns)
    xStart = offsets.start
    xBetween = offsets.between
    if freeW < 0 and alignment in {Align.Center, Align.End}:
      xStart = justifyOffsets(alignment, freeW, placed.columns).start
  let itemValues = gridScratch.values.len
  gridScratch.values.setLen(itemValues + 2 * itemCount)
  for itemIndex in placed.first ..< placed.pastLast:
    let item = gridScratch.items[itemIndex]
    let child = nodes[item.slot]
    let area = gridScratch.values.gridArea(columnsFirst, item.col,
      item.colSpan, grid.gapX + xBetween)
    let itemSize = child.gridCellDimension(natural[item.slot], true,
      area, innerW, 0'f32, grid.gridItemAlign(child, true))
    let relativeIndex = itemIndex - placed.first
    gridScratch.values[itemValues + relativeIndex] = itemSize.size
    gridScratch.values[itemValues + itemCount + relativeIndex] =
      itemSize.offset

  let rowsFirst = gridScratch.values.len
  gridRows(nodes, natural, parent, gridScratch, placed.first,
    placed.pastLast, placed.columns, placed.rows, columnsFirst, rowsFirst,
    innerH, innerW, innerH, grid.gapX + xBetween)

  var usedH = grid.gapY * float32(max(placed.rows - 1, 0))
  for index in 0 ..< placed.rows:
    usedH += gridScratch.values[rowsFirst + index]
  if grid.alignContent != Align.Auto:
    let offsets = justifyOffsets(grid.alignContent,
      max(innerH - usedH, 0'f32), placed.rows)
    yStart = offsets.start
    yBetween = offsets.between

  let columnPositions = gridScratch.values.len
  gridScratch.values.setLen(columnPositions + placed.columns + placed.rows)
  let rowPositions = columnPositions + placed.columns
  var position = xStart
  if grid.rightToLeft:
    position += usedW + xBetween * float32(max(placed.columns - 1, 0))
    for index in 0 ..< placed.columns:
      position -= gridScratch.values[columnsFirst + index]
      gridScratch.values[columnPositions + index] = position
      position -= grid.gapX + xBetween
  else:
    for index in 0 ..< placed.columns:
      gridScratch.values[columnPositions + index] = position
      position += gridScratch.values[columnsFirst + index] + grid.gapX +
        xBetween
  position = yStart
  for index in 0 ..< placed.rows:
    gridScratch.values[rowPositions + index] = position
    position += gridScratch.values[rowsFirst + index] + grid.gapY + yBetween

  for itemIndex in placed.first ..< placed.pastLast:
    let item = gridScratch.items[itemIndex]
    let childSlot = item.slot
    let child = nodes[childSlot]
    let relativeIndex = itemIndex - placed.first
    let width = gridScratch.values[itemValues + relativeIndex]
    let offsetX = gridScratch.values[itemValues + itemCount + relativeIndex]
    let firstPhysicalColumn = if grid.rightToLeft:
        item.col + item.colSpan - 1
      else:
        item.col
    let area = gridScratch.values.gridArea(rowsFirst, item.row,
      item.rowSpan, grid.gapY + yBetween)
    let itemSize = child.gridCellDimension(natural[childSlot], false,
      area, innerH, width, grid.gridItemAlign(child, false))
    var childRect = Rect(
      x: innerX + gridScratch.values[columnPositions + firstPhysicalColumn] +
        offsetX,
      y: innerY + gridScratch.values[rowPositions + item.row] + itemSize.offset,
      w: width,
      h: itemSize.size)
    let left = child.inset[3].resolve(innerW)
    let right = child.inset[1].resolve(innerW)
    let top = child.inset[0].resolve(innerH)
    let bottom = child.inset[2].resolve(innerH)
    if left.ok:
      childRect.x += left.value
    elif right.ok:
      childRect.x -= right.value
    if top.ok:
      childRect.y += top.value
    elif bottom.ok:
      childRect.y -= bottom.value
    placeNode(nodes, natural, rects, sizes, bases, minimum, maximum,
      factors, flexSlots, flexLines, gridScratch, childSlot, childRect)

  var childSlot = int(grid.firstChild)
  while childSlot >= 0:
    let child = nodes[childSlot]
    if child.absolute:
      placeAbsoluteChild(nodes, natural, rects, sizes, bases, minimum,
        maximum, factors, flexSlots, flexLines, gridScratch, parent,
        childSlot, bounds)
    childSlot = int(child.nextSibling)

  gridScratch.items.setLen(itemsBase)
  gridScratch.values.setLen(valuesBase)
  gridScratch.contributions.setLen(contributionsBase)
  gridScratch.occupied.setLen(cellsBase)

proc placeAbsoluteChild(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                        rects: var seq[Rect]; sizes, bases, minimum, maximum,
                        factors: var seq[float32]; flexSlots: var seq[int];
                        flexLines: var seq[FlexLine]; gridScratch: var GridScratch;
                        parentSlot,
                        childSlot: int; bounds: Rect) =
  let parent = nodes[parentSlot]
  let child = nodes[childSlot]
  let paddingW = max(bounds.w - parent.border[1] - parent.border[3], 0'f32)
  let paddingH = max(bounds.h - parent.border[0] - parent.border[2], 0'f32)
  let top = child.inset[0].resolve(paddingH)
  let right = child.inset[1].resolve(paddingW)
  let bottom = child.inset[2].resolve(paddingH)
  let left = child.inset[3].resolve(paddingW)
  let width = child.width.resolve(paddingW)
  let height = child.height.resolve(paddingH)

  var childW: float32
  if width.ok:
    childW = child.clampWidth(width.value, paddingW)
  elif left.ok and right.ok:
    childW = child.clampWidth(
      paddingW - left.value - right.value - child.marginX, paddingW)
  elif child.aspectRatio > 0 and height.ok:
    childW = child.clampWidth(
      max(height.value - child.contentInsetY, 0'f32) *
        child.aspectRatio + child.contentInsetX, paddingW)
  else:
    childW = child.clampWidth(
      min(natural[childSlot].w,
        max(paddingW - child.marginX, 0'f32)), paddingW)

  var childH: float32
  if height.ok:
    childH = child.clampHeight(height.value, paddingH)
  elif top.ok and bottom.ok:
    childH = child.clampHeight(
      paddingH - top.value - bottom.value - child.marginY, paddingH)
  elif child.aspectRatio > 0:
    childH = child.clampHeight(
      max(childW - child.contentInsetX, 0'f32) /
        child.aspectRatio + child.contentInsetY, paddingH)
  else:
    childH = child.clampHeight(natural[childSlot].h, paddingH)

  var x = marginValue(child.margin[3])
  if left.ok:
    x += left.value
  elif right.ok or child.rightToLeft:
    let inset = if right.ok: right.value else: 0'f32
    x = paddingW - inset - childW - marginValue(child.margin[1])
  if left.ok and right.ok:
    let free = paddingW - left.value - right.value - childW - child.marginX
    let autoLeft = child.margin[3] == Auto
    let autoRight = child.margin[1] == Auto
    if autoLeft and autoRight:
      x += max(free, 0'f32) / 2
    elif autoLeft:
      x += max(free, 0'f32)

  var y = marginValue(child.margin[0])
  if top.ok:
    y += top.value
  elif bottom.ok:
    y = paddingH - bottom.value - childH - marginValue(child.margin[2])
  if top.ok and bottom.ok:
    let free = paddingH - top.value - bottom.value - childH - child.marginY
    let autoTop = child.margin[0] == Auto
    let autoBottom = child.margin[2] == Auto
    if autoTop and autoBottom:
      y += max(free, 0'f32) / 2
    elif autoTop:
      y += max(free, 0'f32)

  let childRect = Rect(x: bounds.x + parent.border[3] + x,
    y: bounds.y + parent.border[0] + y, w: childW, h: childH)
  placeNode(nodes, natural, rects, sizes, bases, minimum, maximum,
    factors, flexSlots, flexLines, gridScratch, childSlot, childRect)

proc scrollExtent(nodes: seq[ElementNode]; rects: seq[Rect]; root: int;
                  horizontal: bool): float32 =
  let node = nodes[root]
  let box = rects[root]
  var leftStart: float32
  var leftmost: float32
  result = if horizontal:
      box.x + node.border[3] + node.pad[3]
    else:
      box.y + node.border[0] + node.pad[0]
  if horizontal:
    leftStart = result
    leftmost = result
  var pending: seq[int]
  var child = int(node.firstChild)
  while child >= 0:
    pending.add(child)
    child = int(nodes[child].nextSibling)
  while pending.len > 0:
    let slot = pending.pop()
    let item = nodes[slot]
    let itemBox = rects[slot]
    if horizontal:
      leftmost = min(leftmost,
        itemBox.x - marginValue(item.margin[3]))
      result = max(result, itemBox.x + itemBox.w +
        marginValue(item.margin[1]))
    else:
      result = max(result, itemBox.y + itemBox.h +
        marginValue(item.margin[2]))
    if not (if horizontal: item.scrollX else: item.scrollY):
      child = int(item.firstChild)
      while child >= 0:
        pending.add(child)
        child = int(nodes[child].nextSibling)
  if horizontal:
    let rightOverflow = max(result + node.pad[1] -
      (box.x + box.w - node.border[1]), 0'f32)
    let leftOverflow = max(leftStart - leftmost, 0'f32)
    result = leftOverflow + rightOverflow
  else:
    result = max(result + node.pad[2] -
      (box.y + box.h - node.border[2]), 0'f32)
  if not result.finiteUi:
    result = 0

proc physicalScrollX(node: ElementNode; state: ScrollState): float32 =
  if node.rightToLeft:
    -state.offsetX
  else:
    state.offsetX

proc updateScrollRanges(nodes: seq[ElementNode]; rects: seq[Rect];
                        now: MonoTime; reduceMotion: bool): bool =
  for slot in 1..<nodes.len:
    let node = nodes[slot]
    let state = node.scrollState
    if state == nil:
      continue
    state.maxX = if node.scrollX:
        scrollExtent(nodes, rects, slot, true)
      else:
        0'f32
    state.maxY = if node.scrollY:
        scrollExtent(nodes, rects, slot, false)
      else:
        0'f32
    state.offsetX = min(max(state.offsetX, 0'f32), state.maxX)
    state.offsetY = min(max(state.offsetY, 0'f32), state.maxY)
    if state.animate(now, reduceMotion):
      result = true

proc nearestScrollOffset(offset, pos, size, visibleStart,
                         visibleEnd, maximum: float32): float32 =
  let start = pos - offset
  let finish = pos + size - offset
  if start < visibleStart:
    return min(max(pos - visibleStart, 0'f32), maximum)
  if finish > visibleEnd:
    return min(max(offset + min(finish - visibleEnd,
      start - visibleStart), 0'f32), maximum)
  offset

proc revealInScrollContainers(nodes: seq[ElementNode]; rects: seq[Rect]) =
  for slot in 1..<nodes.len:
    if not nodes[slot].revealInScroll:
      continue
    var box = rects[slot]
    var parent = int(nodes[slot].parent)
    while parent > 0:
      let node = nodes[parent]
      let state = node.scrollState
      if state != nil:
        let view = rects[parent]
        let oldY = state.offsetY
        if node.scrollX:
          let visibleLeft = view.x + node.border[3]
          let visibleRight = max(view.x + view.w - node.border[1],
            visibleLeft)
          if node.rightToLeft:
            state.offsetX = nearestScrollOffset(state.offsetX, -box.x,
              box.w, -visibleRight, -visibleLeft, state.maxX)
          else:
            state.offsetX = nearestScrollOffset(state.offsetX, box.x, box.w,
              visibleLeft, visibleRight, state.maxX)
        if node.scrollY:
          state.offsetY = nearestScrollOffset(oldY, box.y, box.h,
            view.y + node.border[0],
            max(view.y + view.h - node.border[2],
              view.y + node.border[0]), state.maxY)
        if node.scrollX:
          box.x -= node.physicalScrollX(state)
        if node.scrollY:
          box.y -= state.offsetY
      parent = int(node.parent)

proc shiftScrolledRects(nodes: seq[ElementNode]; rects: var seq[Rect]) =
  for slot in 1..<nodes.len:
    var parent = int(nodes[slot].parent)
    while parent >= 0:
      let ancestor = nodes[parent]
      let state = ancestor.scrollState
      if state != nil:
        if ancestor.scrollX:
          rects[slot].x -= ancestor.physicalScrollX(state)
        if ancestor.scrollY:
          rects[slot].y -= state.offsetY
      if ancestor.hasFollowScroll:
        let followSlot = int(ancestor.followScrollSlot)
        if followSlot >= 0 and followSlot < nodes.len:
          let follow = nodes[followSlot]
          if follow.scrollX and follow.scrollState != nil:
            rects[slot].x -= follow.physicalScrollX(follow.scrollState)
      parent = int(ancestor.parent)

proc shiftDescendantRectsY(nodes: seq[ElementNode]; rects: var seq[Rect];
                           slot: int; shiftY: float32) =
  var child = int(nodes[slot].firstChild)
  while child >= 0:
    rects[child].y += shiftY
    shiftDescendantRectsY(nodes, rects, child, shiftY)
    child = int(nodes[child].nextSibling)

proc pinActiveListHeaders(nodes: seq[ElementNode]; rects: var seq[Rect];
                          state: ListState; listSlot: int) =
  if listSlot <= 0 or listSlot >= nodes.len or rects.len != nodes.len:
    return
  for slot in 1..<nodes.len:
    let header = nodes[slot]
    if header.listState != state or not header.listRowPinnedHeader:
      continue
    var nextHeader = -1
    for candidate in 1..<nodes.len:
      let row = nodes[candidate]
      if row.listState == state and row.listRowHeader and
          row.listRowIndex > header.listRowIndex and
          (nextHeader < 0 or row.listRowIndex <
            nodes[nextHeader].listRowIndex):
        nextHeader = candidate
    let listNode = nodes[listSlot]
    let viewportTop = rects[listSlot].y + listNode.border[0] +
      listNode.pad[0]
    let oldY = rects[slot].y
    var pinnedY = max(oldY, viewportTop)
    if nextHeader >= 0:
      pinnedY = min(pinnedY, rects[nextHeader].y - rects[slot].h)
    let shiftY = pinnedY - oldY
    if shiftY == 0:
      continue
    rects[slot].y = pinnedY
    shiftDescendantRectsY(nodes, rects, slot, shiftY)

proc updateListReorderTarget(nodes: seq[ElementNode]; rects: seq[Rect];
                             state: ListState; listSlot: int) =
  if state == nil or not state.reorderDragging or listSlot <= 0 or
      listSlot >= nodes.len or rects.len != nodes.len:
    return
  let list = nodes[listSlot]
  let viewport = rects[listSlot]
  let left = viewport.x + list.border[3] + list.pad[3]
  let right = viewport.x + viewport.w - list.border[1] - list.pad[1]
  let top = viewport.y + list.border[0] + list.pad[0]
  let bottom = viewport.y + viewport.h - list.border[2] - list.pad[2]
  let x = state.reorderPointerX
  let y = state.reorderPointerY
  state.reorderTargetValid = false
  if x < left or x >= right or y < top or y >= bottom:
    return

  var before = high(int)
  var after = -1
  var beforeY, afterY: float32
  for slot in 1..<nodes.len:
    let row = nodes[slot]
    if row.listState != state or row.listRowIndex < 0 or row.listRowHeader:
      continue
    let box = rects[slot]
    if box.y + box.h <= top or box.y >= bottom:
      continue
    if y < box.y + box.h / 2:
      if row.listRowIndex < before:
        before = row.listRowIndex
        beforeY = box.y - state.gap / 2
    elif row.listRowIndex > after:
      after = row.listRowIndex
      afterY = box.y + box.h + state.gap / 2

  if before != high(int):
    state.reorderTarget = before
    state.reorderIndicatorY = max(top, beforeY)
    state.reorderTargetValid = true
  elif after >= 0:
    state.reorderTarget = min(after + 1, state.rowCount)
    state.reorderIndicatorY = min(bottom, afterY)
    state.reorderTargetValid = true

proc applyTableFits(nodes: var seq[ElementNode]; natural: seq[NaturalSize]): bool =
  for slot in 1..<nodes.len:
    if not nodes[slot].tableFitMeasure or nodes[slot].tableState == nil:
      continue
    let state = nodes[slot].tableState
    let column = nodes[slot].tableColumnId
    var width: float32
    for other in 1..<nodes.len:
      if nodes[other].tableFitMeasure and nodes[other].tableState == state and
          nodes[other].tableColumnId == column:
        width = max(width, natural[other].w)
    if nodes[slot].tableColumnMaxWidth > 0:
      width = min(width, nodes[slot].tableColumnMaxWidth)
    width = max(width, max(nodes[slot].tableColumnMinWidth, 16'f32))
    if state.columns.widths.len == 0:
      state.columns.widths = initTable[string, float32]()
    state.columns.widths[column] = width
    state.tableFitColumn.setLen(0)
    for other in 1..<nodes.len:
      if nodes[other].tableFitMeasure and nodes[other].tableState == state and
          nodes[other].tableColumnId == column:
        nodes[other].width = pixels(width)
        nodes[other].grow = 0
        nodes[other].shrink = 0
        nodes[other].tableFitMeasure = false
    result = true

proc step(channel: var ScalarAnimation; now: MonoTime) =
  let dt = float64((now - channel.at).inNanoseconds) / 1_000_000_000
  if dt <= 0:
    channel.at = now
    return
  channel.at = now
  let wasJumped = channel.jumped
  channel.jumped = false
  if not channel.moving:
    if not wasJumped or dt > 0.1:
      channel.velocity = 0
    return
  if channel.curve:
    let duration = float64(channel.duration.inNanoseconds) / 1_000_000_000
    let progress = float64((now - channel.startAt).inNanoseconds) /
      1_000_000_000 / duration
    if progress >= 1:
      channel.value = channel.target
      channel.velocity = 0
      channel.moving = false
      return
    let t = max(progress, 0.0)
    let easing = if channel.ease == nil: easeOut else: channel.ease
    let eased = easing(float32(t))
    if not finiteMotion(float64(eased)):
      raise newException(ValueError, "ui: easing result must be finite")
    let span = channel.target - channel.fromValue
    channel.value = channel.fromValue + span * float64(eased)
    let lo = max(t - 1e-3, 0.0)
    let hi = min(t + 1e-3, 1.0)
    if hi > lo:
      let slope = float64(easing(float32(hi)) - easing(float32(lo))) /
        (hi - lo) / duration
      if not finiteMotion(slope) or not finiteMotion(span * slope):
        raise newException(ValueError, "ui: easing slope must be finite")
      channel.velocity = span * slope
    else:
      channel.velocity = 0
    return
  let moved = solveSpring(channel.value - channel.target, channel.velocity,
    channel.mass, channel.stiffness, channel.damping, dt)
  channel.value = channel.target + moved.x
  channel.velocity = moved.velocity
  if abs(moved.x) <= channel.precision and
      abs(moved.velocity) <= channel.precision *
        sqrt(channel.stiffness / channel.mass):
    channel.value = channel.target
    channel.velocity = 0
    channel.moving = false

proc retarget(channel: var ScalarAnimation; target: float64;
              animation: Animation; now: MonoTime) =
  channel.target = target
  channel.moving = true
  channel.jumped = false
  channel.restedGeneration = 0
  if animation.duration > DurationZero:
    channel.curve = true
    channel.fromValue = channel.value
    channel.startAt = now
    channel.duration = animation.duration
    channel.ease = if animation.ease == nil: easeOut else: animation.ease
    return
  let physics = springPhysics(animation.spring)
  channel.curve = false
  channel.mass = physics.mass
  channel.stiffness = physics.stiffness
  channel.damping = physics.damping
  channel.precision = physics.precision
  if animation.spring.velocity != 0:
    channel.velocity = float64(animation.spring.velocity)

proc advance(channel: var ScalarAnimation; now: MonoTime) =
  if channel.pending and now >= channel.pendingAt:
    channel.step(channel.pendingAt)
    let target = channel.pendingTarget
    let animation = channel.pendingAnimation
    channel.pending = false
    channel.retarget(target, animation, channel.pendingAt)
    channel.at = channel.pendingAt
  channel.step(now)

proc goal(channel: ScalarAnimation): float64 =
  if channel.pending: channel.pendingTarget else: channel.target

proc playhead(raw, duration: int64; repeatCount: int; alternate: bool;
              repeatDelay: int64): tuple[at, iteration: int64, done: bool] =
  if raw <= 0:
    return (0'i64, 0'i64, false)
  if duration <= 0:
    return (raw, 0'i64, false)
  let period = if repeatDelay > high(int64) - duration:
      high(int64)
    else:
      duration + repeatDelay
  let iteration = raw div period
  let rest = raw mod period
  if repeatCount != RepeatForever:
    let plays = if repeatCount == high(int): high(int64)
      else: int64(repeatCount) + 1
    if iteration >= plays or (iteration == plays - 1 and rest >= duration):
      let finalAt = if alternate and plays mod 2 == 0: 0'i64 else: duration
      return (finalAt, iteration, true)
  var at = min(rest, duration)
  if alternate and iteration mod 2 == 1:
    at = duration - at
  (at, iteration, false)

proc finalValue(sequence: ScalarSequence): float32 =
  let plays = if sequence.options.repeat == high(int): high(int64)
    else: int64(sequence.options.repeat) + 1
  if sequence.options.alternate and plays mod 2 == 0:
    sequence.frames[0].value
  else:
    sequence.frames[^1].value

proc sample(sequence: ScalarSequence; now: MonoTime):
    tuple[value: float32, done: bool] =
  if sequence.done:
    return (sequence.value, true)
  let elapsed = (now - sequence.startAt).inNanoseconds
  if elapsed < 0:
    return (sequence.fromValue, false)
  let duration = sequence.frames[^1].at.inNanoseconds
  let position = playhead(elapsed, duration, sequence.options.repeat,
    sequence.options.alternate, sequence.options.repeatDelay.inNanoseconds)
  if position.done:
    return (sequence.finalValue(), true)
  for i in 1..<sequence.frames.len:
    let next = sequence.frames[i]
    if position.at > next.at.inNanoseconds:
      continue
    let previous = sequence.frames[i - 1]
    let start = previous.at.inNanoseconds
    let stop = next.at.inNanoseconds
    let fromValue = if i == 1 and position.iteration == 0:
        sequence.fromValue
      else:
        previous.value
    let progress = float32(position.at - start) / float32(stop - start)
    let easing = if next.ease == nil: linear else: next.ease
    let eased = easing(progress)
    if not finiteMotion(float64(eased)):
      raise newException(ValueError, "ui: keyframe easing result must be finite")
    let value = fromValue + (next.value - fromValue) * eased
    if not finiteMotion(float64(value)):
      raise newException(ValueError, "ui: keyframe values must be finite")
    return (value, false)
  (sequence.finalValue(), false)

proc keyframes*(e: Element; key: string; frames: openArray[Keyframe];
                options = KeyframeOptions()): float32 =
  ## Plays keyed scalar values in order, with optional repeats and alternation.
  ## Increment `options.run` to replace a running sequence from its current value.
  if frames.len < 2 or frames[0].at != DurationZero:
    raise newException(ValueError,
      "ui: keyframes needs at least two frames starting at zero")
  for i, frame in frames:
    if not finiteMotion(float64(frame.value)):
      raise newException(ValueError, "ui: keyframe values must be finite")
    if i > 0 and frame.at <= frames[i - 1].at:
      raise newException(ValueError, "ui: keyframe times must strictly increase")
  if options.repeat < RepeatForever or options.delay < DurationZero or
      options.repeatDelay < DurationZero:
    raise newException(ValueError,
      "ui: keyframe repeat and delays must be nonnegative")
  let node = e.node
  if node == nil:
    return frames[0].value
  let owner = e.owner
  var sequences = owner.keyframes.mgetOrPut(node.identity,
    initTable[string, ScalarSequence]())
  var sequence = sequences.getOrDefault(key)
  if not sequence.initialized or
      (sequence.generation != owner.generation and
       sequence.generation + 1 != owner.generation):
    sequence = ScalarSequence(frames: @frames, options: options,
      startAt: owner.frameNow + options.delay,
      fromValue: frames[0].value, value: frames[0].value,
      generation: owner.generation, initialized: true)
  elif sequence.options.run != options.run:
    let fromValue = sequence.sample(owner.frameNow).value
    sequence = ScalarSequence(frames: @frames, options: options,
      startAt: owner.frameNow + options.delay,
      fromValue: fromValue, value: fromValue,
      generation: owner.generation, initialized: true)

  if sequence.done:
    discard
  elif owner.reduceMotion:
    sequence.value = sequence.finalValue()
    sequence.done = true
    sequence.restedGeneration = owner.generation
  else:
    let sampled = sequence.sample(owner.frameNow)
    sequence.value = sampled.value
    sequence.done = sampled.done
    if sequence.done:
      sequence.restedGeneration = owner.generation
    if not sequence.done:
      owner.animating = true
      owner.otherAnimating = true
  sequence.generation = owner.generation
  sequences[key] = sequence
  owner.keyframes[node.identity] = sequences
  sequence.value

proc saturatingAdd(a, b: int64): int64 =
  if b > 0 and a > high(int64) - b:
    high(int64)
  elif b < 0 and a < low(int64) - b:
    low(int64)
  else:
    a + b

proc saturatingMultiply(a, b: int64): int64 =
  if a <= 0 or b <= 0:
    return 0
  if a > high(int64) div b:
    high(int64)
  else:
    a * b

proc timelineEnd(state: TimelineState; options: TimelineOptions):
    tuple[at: int64, known: bool] =
  if options.repeat == RepeatForever or state.duration <= 0:
    return (0'i64, false)
  if options.repeat == high(int):
    return (high(int64), true)
  let plays = int64(options.repeat) + 1
  let duration = saturatingMultiply(plays, state.duration)
  let pauses = saturatingMultiply(plays - 1,
    options.repeatDelay.inNanoseconds)
  (saturatingAdd(duration, pauses), true)

proc tweenValue(timeline: Timeline; segment: TimelineSegment): float32 =
  let state = timeline.state
  if state.over:
    return if state.atStart: segment.fromValue else: segment.toValue
  if segment.duration <= 0:
    return if state.time >= segment.start: segment.toValue else: segment.fromValue
  if state.time <= segment.start:
    return segment.fromValue
  if state.time >= saturatingAdd(segment.start, segment.duration):
    return segment.toValue
  let ease = if segment.ease == nil: easeOut else: segment.ease
  let progress = float32(state.time - segment.start) /
    float32(segment.duration)
  let eased = ease(progress)
  if not finiteMotion(float64(eased)):
    raise newException(ValueError,
      "ui: timeline easing result must be finite")
  let value = float64(segment.fromValue) +
    (float64(segment.toValue) - float64(segment.fromValue)) * float64(eased)
  result = float32(value)
  if not finiteMotion(float64(result)):
    raise newException(ValueError, "ui: timeline values must be finite")

proc timelineCue(state: TimelineState; owner: ElementOwner;
                 options: TimelineOptions) =
  let delay = options.delay.inNanoseconds
  if state.run != options.run:
    state.run = options.run
    state.raw = 0
    state.done = false
    state.over = false
    state.restedGeneration = 0
    if options.reverse:
      let ending = state.timelineEnd(options)
      state.raw = saturatingAdd(delay,
        if ending.known: ending.at else: state.duration)
  state.reverse = options.reverse
  var held = false
  if options.seek.isSome:
    state.raw = saturatingAdd(delay, options.seek.get.inNanoseconds)
    held = true
  if options.progress.isSome:
    let progress = options.progress.get
    let rawOffset = float64(progress) * float64(state.duration)
    let offset = if rawOffset >= float64(high(int64)): high(int64)
      elif rawOffset <= float64(low(int64)): low(int64)
      else: int64(rawOffset)
    state.raw = saturatingAdd(delay, offset)
    held = true
  if held:
    state.over = false
  elif not options.paused and owner.reduceMotion:
    state.over = true
  if state.over:
    state.atStart = options.reverse or
      (options.alternate and options.repeat mod 2 != 0)
    state.time = if state.atStart: 0 else: state.duration
    state.done = true
    state.moving = false
    state.holding = true
    if state.restedGeneration == 0:
      state.restedGeneration = owner.generation
    return
  let ending = state.timelineEnd(options)
  if ending.known:
    state.raw = min(state.raw, saturatingAdd(delay, ending.at))
  state.raw = max(state.raw, 0'i64)
  let raw = saturatingAdd(state.raw, -delay)
  let position = playhead(raw, state.duration, options.repeat,
    options.alternate, options.repeatDelay.inNanoseconds)
  state.time = position.at
  state.done = position.done
  if raw > 0 and state.duration <= 0:
    state.done = state.built
  if options.reverse:
    state.done = raw <= 0
  state.holding = options.paused or held
  state.moving = not state.done and not state.holding
  if state.done:
    if state.restedGeneration == 0:
      state.restedGeneration = owner.generation
    return
  state.restedGeneration = 0
  if held and not state.built:
    owner.animating = true
    owner.otherAnimating = true
    return
  if state.moving:
    owner.animating = true
    owner.otherAnimating = true

proc timelineTick(state: TimelineState; owner: ElementOwner;
                  options: TimelineOptions) =
  if not state.started:
    state.started = true
    state.at = owner.frameNow
    state.run = options.run
    state.timelineCue(owner, options)
    return
  state.built = true
  let elapsed = (owner.frameNow - state.at).inNanoseconds
  state.at = owner.frameNow
  if elapsed > 0 and state.moving:
    if state.reverse:
      let delay = options.delay.inNanoseconds
      state.raw = max(saturatingAdd(state.raw, -elapsed),
        min(state.raw, delay))
    else:
      state.raw = saturatingAdd(state.raw, elapsed)
  state.timelineCue(owner, options)

proc beginTimeline(timeline: Timeline; options: TimelineOptions) =
  let state = timeline.state
  state.generation = timeline.generation
  state.duration = state.build
  state.build = 0
  state.segments.setLen(0)
  state.labels.setLen(0)
  state.timelineTick(timeline.owner, options)

proc timeline*(e: Element; key: string;
               options = TimelineOptions()): Timeline =
  ## Returns the keyed timeline for this element in the current build.
  ## Ask for it once per element and build; change `options.run` to replay it.
  if options.repeat < RepeatForever or options.delay < DurationZero or
      options.repeatDelay < DurationZero:
    raise newException(ValueError,
      "ui: timeline repeat and delays must be nonnegative")
  if options.seek.isSome and options.progress.isSome:
    raise newException(ValueError,
      "ui: a timeline takes seek or progress, not both")
  if options.progress.isSome and
      not finiteMotion(float64(options.progress.get)):
    raise newException(ValueError, "ui: timeline progress must be finite")
  let node = e.node
  if node == nil:
    return nil
  let owner = e.owner
  var timelines = owner.timelines.mgetOrPut(node.identity,
    initTable[string, TimelineState]())
  var state = timelines.getOrDefault(key)
  if state == nil:
    new(state)
  elif state.seenGeneration == owner.generation:
    raise newException(ValueError,
      "ui: an element asked for its timeline twice in one build: " & key)
  elif not state.initialized or state.generation + 1 != owner.generation:
    new(state)
  state.initialized = true
  state.seenGeneration = owner.generation
  timelines[key] = state
  owner.timelines[node.identity] = timelines
  new(result)
  result.owner = owner
  result.generation = owner.generation
  result.state = state
  result.beginTimeline(options)

proc place(timeline: Timeline; placement: Placement): int64 =
  var position: int64
  let offset = placement.offset.inNanoseconds
  case placement.kind
  of placementWith:
    position = saturatingAdd(timeline.previousStart, offset)
  of placementAt:
    position = offset
  of placementLabel:
    var found = false
    if timeline.state.labels.len > 0:
      for i in countdown(timeline.state.labels.high, 0):
        if timeline.state.labels[i].name == placement.labelName:
          position = saturatingAdd(timeline.state.labels[i].at, offset)
          found = true
          break
    if not found:
      raise newException(ValueError,
        "ui: timeline has no label " & placement.labelName)
  of placementAfter:
    position = saturatingAdd(timeline.previousEnd, offset)
  max(position, 0'i64)

proc afterPrevious*(offset: Duration = DurationZero): Placement =
  ## Starts after the previous tween, or overlaps it by a negative offset.
  Placement(kind: placementAfter, offset: offset)

proc withPrevious*(offset: Duration = DurationZero): Placement =
  ## Starts relative to the previous tween's start.
  Placement(kind: placementWith, offset: offset)

proc atTime*(time: Duration): Placement =
  ## Starts at an absolute time on the timeline.
  Placement(kind: placementAt, offset: time)

proc atLabel*(name: string; offset: Duration = DurationZero): Placement =
  ## Starts relative to a label previously added to the timeline.
  Placement(kind: placementLabel, offset: offset, labelName: name)

proc tween*(timeline: Timeline; value: Tween;
            placement = Placement()): float32 =
  ## Adds a tween and returns the scalar value at this frame's playhead.
  if not finiteMotion(float64(value.fromValue)) or
      not finiteMotion(float64(value.to)):
    raise newException(ValueError, "ui: timeline tween values must be finite")
  if value.duration < DurationZero:
    raise newException(ValueError,
      "ui: timeline tween duration must not be negative")
  if timeline == nil or timeline.owner == nil or
      not timeline.owner.inBuild or
      timeline.generation != timeline.owner.generation:
    return value.fromValue
  let start = timeline.place(placement)
  let duration = value.duration.inNanoseconds
  let segment = TimelineSegment(start: start, duration: duration,
    fromValue: value.fromValue, toValue: value.to, ease: value.ease)
  timeline.state.segments.add(segment)
  let ending = saturatingAdd(start, duration)
  if ending > timeline.state.build:
    timeline.state.build = ending
    if timeline.state.done and not timeline.state.over and
        not timeline.state.reverse and not timeline.state.holding and
        ending > timeline.state.duration:
      timeline.state.moving = true
      timeline.owner.animating = true
      timeline.owner.otherAnimating = true
  timeline.previousStart = start
  timeline.previousEnd = ending
  timeline.tweenValue(segment)

proc label*(timeline: Timeline; name: string;
            placement = Placement()) =
  ## Marks a time for later tweens to reference with `atLabel`.
  if timeline == nil or timeline.owner == nil or
      not timeline.owner.inBuild or
      timeline.generation != timeline.owner.generation:
    return
  timeline.state.labels.add(TimelineLabel(name: name,
    at: timeline.place(placement)))

proc duration*(timeline: Timeline): Duration =
  ## Returns the timeline duration without its repeats.
  if timeline == nil:
    return DurationZero
  initDuration(nanoseconds = max(timeline.state.build, timeline.state.duration))

proc time*(timeline: Timeline): Duration =
  ## Returns the playhead time within one play of the timeline.
  if timeline == nil:
    return DurationZero
  let state = timeline.state
  if state.over:
    return initDuration(nanoseconds =
      if state.atStart: 0 else: max(state.build, state.duration))
  initDuration(nanoseconds = min(state.time,
    max(state.build, state.duration)))

proc progress*(timeline: Timeline): float32 =
  ## Returns the playhead position from zero to one.
  if timeline == nil:
    return 0
  let state = timeline.state
  let duration = max(state.build, state.duration)
  if state.over or (state.done and duration <= 0):
    return if state.atStart: 0 else: 1
  if duration <= 0:
    return 0
  float32(min(max(float64(state.time) / float64(duration), 0), 1))

proc settled*(timeline: Timeline): bool =
  ## Reports whether playback has come to rest at either end.
  if timeline == nil or not timeline.state.done:
    return false
  if timeline.state.over or timeline.state.reverse:
    return true
  timeline.state.build <= timeline.state.duration

proc arrived*(timeline: Timeline): bool =
  ## Reports whether the timeline came to rest in this build.
  timeline != nil and timeline.state.restedGeneration == timeline.generation

proc cubicEaseOut(progress: float32): float32 =
  let inverse = 1'f32 - progress
  1'f32 - inverse * inverse * inverse

proc update(channel: var ScalarAnimation; owner: ElementOwner; target: float64;
            animation: Animation; respectReduceMotion = true;
            poseChannel = false): float64 =
  if not channel.initialized or
      (channel.generation != owner.generation and
       channel.generation + 1 != owner.generation):
    channel = ScalarAnimation(value: target, fromValue: target,
      target: target, at: owner.frameNow, generation: owner.generation,
      initialized: true)
    return target

  let moving = channel.moving or channel.pending
  if owner.reduceMotion and respectReduceMotion:
    let arrived = channel.moving or channel.pending or channel.value != target
    channel.value = target
    channel.velocity = 0
    channel.fromValue = target
    channel.target = target
    channel.at = owner.frameNow
    channel.moving = false
    channel.pending = false
    channel.jumped = false
    if arrived:
      channel.restedGeneration = owner.generation
  else:
    channel.advance(owner.frameNow)
    if target != channel.goal() and animation.delay > DurationZero:
      channel.pending = true
      channel.pendingTarget = target
      channel.pendingAt = owner.frameNow + animation.delay
      channel.pendingAnimation = animation
      channel.pendingAnimation.delay = DurationZero
      channel.restedGeneration = 0
    elif target != channel.goal():
      channel.pending = false
      channel.retarget(target, animation, owner.frameNow)
    elif channel.moving and not channel.curve and
        animation.duration == DurationZero and not channel.pending:
      let physics = springPhysics(animation.spring)
      channel.mass = physics.mass
      channel.stiffness = physics.stiffness
      channel.damping = physics.damping
      channel.precision = physics.precision
    if channel.moving or channel.pending:
      owner.animating = true
      if poseChannel:
        owner.poseAnimating = true
      else:
        owner.otherAnimating = true
    elif moving:
      channel.restedGeneration = owner.generation

  channel.generation = owner.generation
  channel.value

proc animateValue(e: Element; key: string; target: float32;
                  animation: Animation;
                  respectReduceMotion: bool; poseChannel = false): float32 =
  if not finiteMotion(float64(target)):
    raise newException(ValueError, "ui: animation values must be finite")
  animation.validateAnimation()
  let node = e.node
  if node == nil:
    return target
  let owner = e.owner
  var channels = owner.animations.mgetOrPut(node.identity,
    initTable[string, ScalarAnimation]())
  var channel = channels.getOrDefault(key)
  let value = channel.update(owner, float64(target), animation,
    respectReduceMotion, poseChannel)
  channels[key] = channel
  owner.animations[node.identity] = channels
  float32(value)

proc animate*(e: Element; key: string; target: float32;
              animation: Animation): float32 =
  ## Moves a keyed scalar value with a timed easing curve or spring and
  ## requests frames while it moves. The first target appears immediately.
  ## Reduced motion preferences also apply immediately.
  e.animateValue(key, target, animation, true)

proc animate*(e: Element; key: string; target: float32;
              duration: Duration): float32 =
  ## Moves a keyed scalar value with cubic ease-out over duration.
  ## Durations below 1 ms are treated as 1 ms for compatibility.
  let minimum = initDuration(milliseconds = 1)
  e.animate(key, target, Animation(duration: max(duration, minimum),
    ease: cubicEaseOut))

proc spring*(e: Element; key: string; target: float32;
             options = SpringOptions()): float32 =
  ## Moves a keyed scalar value to target with a spring.
  e.animate(key, target, Animation(spring: options))

proc animateColor(owner: ElementOwner; identity: uint64; key: string;
                  target: Color; animation: Animation): Color =
  animation.validateAnimation()
  var motions = owner.colorMotions.mgetOrPut(identity,
    initTable[string, ColorMotion]())
  var motion = motions.getOrDefault(key)
  if not motion.initialized or
      (motion.generation != owner.generation and
       motion.generation + 1 != owner.generation):
    motion = ColorMotion(fromColor: target, targetColor: target,
      shown: target,
      progress: ScalarAnimation(value: 1, fromValue: 1, target: 1,
        at: owner.frameNow, generation: owner.generation, initialized: true),
      generation: owner.generation, initialized: true)
    motions[key] = motion
    owner.colorMotions[identity] = motions
    return target

  if target != motion.targetColor:
    motion.fromColor = motion.shown
    motion.progress = ScalarAnimation(value: 0, fromValue: 0, target: 0,
      at: owner.frameNow, generation: owner.generation, initialized: true)
    motion.targetColor = target
  let progress = motion.progress.update(owner, 1, animation,
    respectReduceMotion = false)
  if motion.progress.moving or motion.progress.pending:
    motion.shown = motion.fromColor.mixPremultiplied(motion.targetColor,
      max(0'f32, min(float32(progress), 1'f32)))
  else:
    motion.shown = motion.targetColor
  motion.generation = owner.generation
  motions[key] = motion
  owner.colorMotions[identity] = motions
  motion.shown

proc animateColor*(e: Element; key: string; target: Color;
                   animation: Animation): Color =
  ## Moves a keyed color using premultiplied-alpha interpolation. Colors
  ## continue to animate when reduced motion is enabled.
  let node = e.node
  if node == nil:
    return target
  e.owner.animateColor(node.identity, key, target, animation)

proc transitionAnimation(value: ElementTransition): Animation =
  if value.animation.isSome:
    result = value.animation.get
  else:
    if value.duration < DurationZero:
      raise newException(ValueError,
        "ui: transition duration must not be negative")
    result = Animation(
      duration: if value.duration == DurationZero:
          initDuration(milliseconds = 200)
        else:
          value.duration,
      ease: if value.ease == nil: easeOut else: value.ease)
  result.validateAnimation()

proc transitionMovesPosition(value: ElementTransition): bool =
  (not value.position and not value.size and not value.colors) or
    value.position

proc transitionMovesSize(value: ElementTransition): bool =
  (not value.position and not value.size and not value.colors) or value.size

proc transitionMovesColors(value: ElementTransition): bool =
  (not value.position and not value.size and not value.colors) or value.colors

proc transition*(element: Element;
                 value: ElementTransition): Element =
  ## Animates this element's position, size, and background/border colors as
  ## layouts change. Size changes reflow descendants at the sampled bounds.
  ## Elements need a stable key or sibling position between builds.
  result = element
  let node = element.node
  if node == nil:
    return
  discard value.transitionAnimation()
  node[].elementTransition = value
  node[].transitionSet = true

proc transitioning*(element: Element): bool =
  ## Reports whether this element, its pose, or its drag motion was moving.
  let node = element.node
  if node == nil:
    return false
  if node[].draggableDragging or node[].draggableMoving:
    return true
  let channels = element.owner.animations.getOrDefault(node[].identity)
  for key, channel in channels:
    if key.startsWith("\x00mynim.pose.") and
        (channel.moving or channel.pending):
      return true
  if node[].transitionSet:
    let value = node[].elementTransition
    if value.transitionMovesPosition:
      for key in [transitionXKey, transitionYKey]:
        let channel = channels.getOrDefault(key)
        if channel.moving or channel.pending:
          return true
    if value.transitionMovesSize:
      for key in [transitionWidthKey, transitionHeightKey]:
        let channel = channels.getOrDefault(key)
        if channel.moving or channel.pending:
          return true
    if value.transitionMovesColors:
      let motions = element.owner.colorMotions.getOrDefault(node[].identity)
      for key in [transitionBackgroundKey, transitionBorderKey]:
        let motion = motions.getOrDefault(key)
        if motion.progress.moving or motion.progress.pending:
          return true

proc jump*(e: Element; key: string; value: float32): float32 =
  ## Sets a keyed scalar value immediately and tracks drag velocity for a
  ## spring that takes over shortly after the jump.
  if not finiteMotion(float64(value)):
    raise newException(ValueError, "ui: animation values must be finite")
  let node = e.node
  if node == nil:
    return value
  let owner = e.owner
  var channels = owner.animations.mgetOrPut(node.identity,
    initTable[string, ScalarAnimation]())
  var channel = channels.getOrDefault(key)
  if not channel.initialized or
      (channel.generation != owner.generation and
       channel.generation + 1 != owner.generation):
    channel = ScalarAnimation(value: float64(value),
      fromValue: float64(value), target: float64(value), at: owner.frameNow,
      generation: owner.generation, initialized: true)
  else:
    let dt = float64((owner.frameNow - channel.at).inNanoseconds) /
      1_000_000_000
    if dt > 0 and dt <= 0.1 and channel.jumped:
      channel.velocity = (float64(value) - channel.value) / dt
    elif dt > 0:
      channel.advance(owner.frameNow)
      if dt > 0.1:
        channel.velocity = 0
    channel.value = float64(value)
    channel.target = float64(value)
    channel.moving = false
    channel.pending = false
    channel.jumped = true
    channel.at = owner.frameNow
  channel.generation = owner.generation
  channel.restedGeneration = 0
  channels[key] = channel
  owner.animations[node.identity] = channels
  value

proc velocity*(e: Element; key: string): float32 =
  ## Returns the current velocity of a keyed scalar animation, or zero.
  let node = e.node
  if node == nil:
    return 0
  let channels = e.owner.animations.getOrDefault(node.identity)
  float32(channels.getOrDefault(key).velocity)

proc settled*(e: Element; key: string): bool =
  ## Reports whether keyed animation, color, keyframe, or timeline state is at rest.
  let node = e.node
  if node == nil:
    return true
  let motions = e.owner.colorMotions.getOrDefault(node.identity)
  let motion = motions.getOrDefault(key)
  if motion.initialized and
      (motion.progress.moving or motion.progress.pending):
    return false
  let sequences = e.owner.keyframes.getOrDefault(node.identity)
  let sequence = sequences.getOrDefault(key)
  if sequence.initialized and not sequence.done:
    return false
  let timelines = e.owner.timelines.getOrDefault(node.identity)
  let timelineState = timelines.getOrDefault(key)
  if timelineState != nil:
    if not timelineState.done:
      return false
    if not timelineState.over and not timelineState.reverse and
        timelineState.build > timelineState.duration:
      return false
  let channels = e.owner.animations.getOrDefault(node.identity)
  let channel = channels.getOrDefault(key)
  not channel.initialized or (not channel.moving and not channel.pending)

proc arrived*(e: Element; key: string): bool =
  ## Reports whether a keyed animation reached rest in this build.
  let node = e.node
  if node == nil:
    return false
  let generation = e.owner.generation
  let channels = e.owner.animations.getOrDefault(node.identity)
  if channels.getOrDefault(key).restedGeneration == generation:
    return true
  let motions = e.owner.colorMotions.getOrDefault(node.identity)
  if motions.getOrDefault(key).progress.restedGeneration == generation:
    return true
  let sequences = e.owner.keyframes.getOrDefault(node.identity)
  if sequences.getOrDefault(key).restedGeneration == generation:
    return true
  let timelines = e.owner.timelines.getOrDefault(node.identity)
  let timelineState = timelines.getOrDefault(key)
  timelineState != nil and timelineState.restedGeneration == generation

proc alignFormLabels(nodes: var seq[ElementNode]) =
  var widths = initTable[int, float32]()
  for slot in 1..<nodes.len:
    if not nodes[slot].formLabel:
      continue
    var form = int(nodes[slot].parent)
    while form > 0 and form < nodes.len and
        not nodes[form].formContainer:
      form = int(nodes[form].parent)
    if form <= 0 or form >= nodes.len:
      continue
    var child = int(nodes[slot].firstChild)
    var width = 0'f32
    while child > 0 and child < nodes.len:
      if nodes[child].hasText and nodes[child].shapedText != nil:
        width = max(width, nodes[child].shapedText.width)
      child = int(nodes[child].nextSibling)
    widths[form] = max(widths.getOrDefault(form), width)

  for slot in 1..<nodes.len:
    if not nodes[slot].formLabel:
      continue
    var form = int(nodes[slot].parent)
    while form > 0 and form < nodes.len and
        not nodes[form].formContainer:
      form = int(nodes[form].parent)
    if widths.hasKey(form):
      nodes[slot].width = UiLength(value: widths[form], kind: lengthPixels)

proc firstFormText(nodes: seq[ElementNode]; slot: int): int =
  if slot <= 0 or slot >= nodes.len:
    return -1
  if nodes[slot].hasText and not nodes[slot].textOverlay and
      nodes[slot].shapedText != nil and nodes[slot].shapedText.lines.len > 0:
    return slot
  var child = int(nodes[slot].firstChild)
  while child > 0 and child < nodes.len:
    if not nodes[child].absolute:
      result = nodes.firstFormText(child)
      if result > 0:
        return
    child = int(nodes[child].nextSibling)
  result = -1

proc alignFormLabelBaselines(nodes: seq[ElementNode]; rects: var seq[Rect]) =
  for fieldSlot in 1..<nodes.len:
    let field = nodes[fieldSlot]
    let labelSlot = int(field.fieldLabelSlot)
    let controlSlot = int(field.fieldControlSlot)
    if not field.formField or labelSlot <= 0 or labelSlot >= rects.len or
        controlSlot <= 0 or controlSlot >= rects.len:
      continue
    let control = nodes[controlSlot]
    var labelY: float32
    if control.textClient != nil:
      labelY = rects[controlSlot].y + control.pad[0] + control.border[0]
    else:
      let textSlot = nodes.firstFormText(controlSlot)
      if textSlot > 0:
        labelY = rects[textSlot].y
      else:
        labelY = rects[controlSlot].y +
          (rects[controlSlot].h - rects[labelSlot].h) / 2
    let delta = labelY - rects[labelSlot].y
    if delta == 0:
      continue
    var pending = @[labelSlot]
    while pending.len > 0:
      let slot = pending.pop()
      rects[slot].y += delta
      var child = int(nodes[slot].firstChild)
      while child > 0 and child < nodes.len:
        pending.add(child)
        child = int(nodes[child].nextSibling)

proc toolbarInnerText(nodes: seq[ElementNode]; root: int): string =
  var pending = @[root]
  while pending.len > 0:
    let slot = pending.pop()
    let node = nodes[slot]
    if node.accessHidden:
      continue
    if node.hasText:
      if node.textValue.len > 0:
        if result.len > 0:
          result.add(' ')
        result.add(node.textValue)
      continue
    var children: seq[int]
    var child = int(node.firstChild)
    while child >= 0:
      children.add(child)
      child = int(nodes[child].nextSibling)
    for index in countdown(children.high, 0):
      pending.add(children[index])

proc appendToolbarItems(owner: ElementOwner; nodes: seq[ElementNode];
                        slot: int; items: var seq[ToolbarMenuItem]) =
  let node = nodes[slot]
  if node.clickHandler != nil:
    let label = if node.label.len > 0: node.label
      else: toolbarInnerText(nodes, slot)
    items.add(ToolbarMenuItem(
      identity: node.identity,
      label: label,
      toggle: node.accessRole in {platform.roleToggleButton,
        platform.roleSwitch, platform.roleRadio},
      checked: (node.accessExtraStates and platform.accessChecked) !=
        platform.AccessStates(0),
      disabled: owner.effectivelyDisabled(slot),
      menuBuilder: node.menuBuilder))
    return
  var child = int(node.firstChild)
  while child >= 0:
    appendToolbarItems(owner, nodes, child, items)
    child = int(nodes[child].nextSibling)

proc updateToolbarOverflow(owner: ElementOwner; natural: seq[NaturalSize];
                           rects: seq[Rect]): bool =
  if owner == nil:
    return
  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    let state = node.toolbarState
    if state == nil:
      continue
    var children: seq[int]
    var more = -1
    var child = int(node.firstChild)
    while child >= 0:
      let childNode = owner.nodes[child]
      if childNode.toolbarMore:
        more = child
      elif not childNode.absolute:
        children.add(child)
      child = int(childNode.nextSibling)
    if more < 0:
      state.items.setLen(0)
      continue

    let contentWidth = max(rects[slot].w - node.contentInsetX, 0'f32)
    let moreNode = owner.nodes[more]
    let moreWidth = natural[more].w + moreNode.marginX
    var total = 0'f32
    for index, childSlot in children:
      if index > 0:
        total += node.gapX
      total += natural[childSlot].w + owner.nodes[childSlot].marginX

    var fits = children.len
    if total > contentWidth + 0.5'f32:
      let room = contentWidth - moreWidth - node.gapX
      var used = 0'f32
      fits = 0
      while fits < children.len:
        let childSlot = children[fits]
        var width = natural[childSlot].w + owner.nodes[childSlot].marginX
        if fits > 0:
          width += node.gapX
        if used + width > room + 0.5'f32:
          break
        used += width
        inc fits

    var items: seq[ToolbarMenuItem]
    var previousGroup = false
    for childIndex in fits..<children.len:
      let childSlot = children[childIndex]
      let first = items.len
      owner.appendToolbarItems(owner.nodes, childSlot, items)
      let group = items.len - first > 1
      if items.len > first and (group or previousGroup):
        items[first].startsGroup = true
      if items.len > first:
        previousGroup = group
      owner.nodes[childSlot].toolbarCollapsed = true
      owner.nodes[childSlot].absolute = true
      result = true
    state.items = items
    if fits == children.len:
      owner.nodes[more].toolbarCollapsed = true
      owner.nodes[more].absolute = true
      result = true

proc gridColumns(width, minWidth, gap: float32; itemCount: int): int =
  if minWidth <= 0:
    return 1
  let available = max(float64(width), 0.0)
  let unit = float64(minWidth) + float64(gap)
  let fit = floor((available + float64(gap)) / unit)
  let limit = max(itemCount, 1)
  if fit >= float64(limit):
    return limit
  max(int(fit), 1)

proc alignSplitHandles(nodes: var seq[ElementNode]; rects: var seq[Rect]) =
  for slot in 1..<min(nodes.len, rects.len):
    if not nodes[slot].splitHandle:
      continue
    let parent = int(nodes[slot].parent)
    if parent <= 0 or parent >= nodes.len:
      continue
    var divider = -1
    var child = int(nodes[parent].firstChild)
    while child >= 0 and child < nodes.len:
      if nodes[child].splitDivider:
        divider = child
        break
      child = int(nodes[child].nextSibling)
    if divider < 0 or divider >= rects.len:
      continue

    let bar = rects[divider]
    var handle = rects[slot]
    if nodes[slot].splitVertical:
      handle.x = bar.x
      handle.y = bar.y - (handle.h - bar.h) / 2
      handle.w = bar.w
    else:
      handle.x = bar.x - (handle.w - bar.w) / 2
      handle.y = bar.y
      handle.h = bar.h
    rects[slot] = handle

    var root = slot
    while root > 0 and root < nodes.len and not nodes[root].splitPane:
      root = int(nodes[root].parent)
    if root <= 0 or root >= rects.len:
      continue
    let bounds = rects[root]
    let position = if nodes[slot].splitVertical:
        bar.y - bounds.y
      elif nodes[slot].rightToLeft:
        bounds.x + bounds.w - bar.x - bar.w
      else:
        bar.x - bounds.x
    nodes[slot].sliderValue = float64(position)

proc hasVisibleArea(box, clip: Rect): bool =
  min(box.x + box.w, clip.x + clip.w) > max(box.x, clip.x) and
    min(box.y + box.h, clip.y + clip.h) > max(box.y, clip.y)

proc childClip(clip: Rect; node: ElementNode; box: Rect): Rect =
  result = clip
  if not node.clipsChildren:
    return
  let clipsX = node.scrollState != nil or node.clipX
  let clipsY = node.scrollState != nil or node.clipY
  if clipsX:
    let left = max(clip.x, box.x + node.border[3])
    let right = min(clip.x + clip.w, box.x + box.w - node.border[1])
    result.x = left
    result.w = max(right - left, 0'f32)
  if clipsY:
    let top = max(clip.y, box.y + node.border[0])
    let bottom = min(clip.y + clip.h, box.y + box.h - node.border[2])
    result.y = top
    result.h = max(bottom - top, 0'f32)

proc localTransform(node: ElementNode; box: Rect): scene.Affine =
  var transform = node.transform
  if node.poseTransform.set:
    transform = transform.then(node.poseTransform)
  if node.transitionTransform.set:
    transform = transform.then(node.transitionTransform)
  if not transform.set:
    return
  let originX = box.x + box.w *
    (if node.transformOriginSet: node.transformOriginX else: 0.5'f32)
  let originY = box.y + box.h *
    (if node.transformOriginSet: node.transformOriginY else: 0.5'f32)
  validateTransformValues(originX, originY)
  result = scene.translation(originX, originY).mul(transform.flat())
    .mul(scene.translation(-originX, -originY))
  validateTransform(result)

proc transformedRect(transform: scene.Affine; box: Rect): Rect =
  let mapped = transform.bounds(scene.Rect(x: box.x, y: box.y,
    w: box.w, h: box.h))
  Rect(x: mapped.x, y: mapped.y, w: mapped.w, h: mapped.h)

proc transformedLocalRect(layout: LayoutResult; slot: int;
                          rect: Rect): Rect =
  if slot < 0 or slot >= layout.rects.len or
      slot >= layout.worldTransforms.len:
    return
  let bounds = layout.rects[slot]
  layout.worldTransforms[slot].transformedRect(Rect(
    x: bounds.x + rect.x, y: bounds.y + rect.y, w: rect.w, h: rect.h))

proc transitionLocalPosition(nodes: seq[ElementNode]; rects: seq[Rect];
                             slot: int): Point =
  if slot <= 0 or slot >= nodes.len or rects.len != nodes.len:
    return
  let parent = int(nodes[slot].parent)
  if parent < 0 or parent >= nodes.len:
    return
  result.x = rects[slot].x - rects[parent].x
  result.y = rects[slot].y - rects[parent].y
  let node = nodes[parent]
  if node.scrollState != nil:
    if node.scrollX:
      result.x += node.physicalScrollX(node.scrollState)
    if node.scrollY:
      result.y += node.scrollState.offsetY
  if node.hasFollowScroll:
    let followSlot = int(node.followScrollSlot)
    if followSlot >= 0 and followSlot < nodes.len:
      let follow = nodes[followSlot]
      if follow.scrollX and follow.scrollState != nil:
        result.x += follow.physicalScrollX(follow.scrollState)

proc transitionSubtreeEnd(nodes: seq[ElementNode]; root: int): int =
  result = root
  var slot = root
  while true:
    let child = int(nodes[slot].firstChild)
    if child >= 0:
      slot = child
      result = slot
      continue
    while slot != root and nodes[slot].nextSibling < 0:
      slot = int(nodes[slot].parent)
    if slot == root:
      break
    slot = int(nodes[slot].nextSibling)
    result = slot

proc shiftTransitionSubtree(nodes: seq[ElementNode]; rects: var seq[Rect];
                             root: int) =
  var pending: seq[int]
  var child = int(nodes[root].firstChild)
  while child >= 0:
    pending.add(child)
    child = int(nodes[child].nextSibling)
  while pending.len > 0:
    let slot = pending.pop()
    var parent = int(nodes[slot].parent)
    while parent >= root:
      let node = nodes[parent]
      if node.scrollState != nil:
        if node.scrollX:
          rects[slot].x -= node.physicalScrollX(node.scrollState)
        if node.scrollY:
          rects[slot].y -= node.scrollState.offsetY
      if node.hasFollowScroll:
        let followSlot = int(node.followScrollSlot)
        if followSlot >= 0 and followSlot < nodes.len:
          let follow = nodes[followSlot]
          if follow.scrollX and follow.scrollState != nil:
            rects[slot].x -= follow.physicalScrollX(follow.scrollState)
      parent = int(node.parent)
    child = int(nodes[slot].firstChild)
    while child >= 0:
      pending.add(child)
      child = int(nodes[child].nextSibling)

proc relayoutTransitionSubtree(c: Context; layout: var LayoutResult;
                                slot: int) =
  let bounds = layout.rects[slot]
  let last = transitionSubtreeEnd(c.owner.nodes, slot)
  discard shapeTextToBounds(c.owner.nodes, layout.rects, slot, last)
  discard measureTree(c.owner.nodes, c.owner.natural, c.owner.gridScratch,
    layout.rects, slot, last)
  c.owner.flexSlots.setLen(0)
  c.owner.flexLines.setLen(0)
  c.owner.gridScratch.items.setLen(0)
  c.owner.gridScratch.occupied.setLen(0)
  c.owner.gridScratch.contributions.setLen(0)
  c.owner.gridScratch.values.setLen(0)
  var stable = false
  for attempt in 0..2:
    placeNode(c.owner.nodes, c.owner.natural, layout.rects,
      c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
      c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
      c.owner.flexLines, c.owner.gridScratch, slot, bounds)
    let textChanged = shapeTextToBounds(c.owner.nodes, layout.rects, slot, last)
    let sizesChanged = measureTree(c.owner.nodes, c.owner.natural,
      c.owner.gridScratch, layout.rects, slot, last)
    if not textChanged and not sizesChanged:
      stable = true
      break
  if not stable:
    placeNode(c.owner.nodes, c.owner.natural, layout.rects,
      c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
      c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
      c.owner.flexLines, c.owner.gridScratch, slot, bounds)
  shiftTransitionSubtree(c.owner.nodes, layout.rects, slot)
  alignFormLabelBaselines(c.owner.nodes, layout.rects)
  alignSplitHandles(c.owner.nodes, layout.rects)
  placeInlineText(c.owner.nodes, layout.rects)

proc layoutAt(c: Context; bounds: Rect; now: MonoTime;
              reduceMotion: bool): LayoutResult =
  ## Lays out the latest completed build inside bounds.
  if c == nil or c.owner.closed or not c.owner.hasFrame:
    raise newException(ValueError, "ui: layout requires a completed build")
  if c.owner.inBuild:
    raise newException(ValueError, "ui: cannot lay out during a frame build")
  for value in [bounds.x, bounds.y, bounds.w, bounds.h]:
    if classify(value) in {fcNan, fcInf, fcNegInf}:
      raise newException(ValueError, "ui: layout bounds must be finite")

  result.owner = c.owner
  result.generation = c.owner.generation
  result.animating = c.owner.animating
  result.root = Rect(x: bounds.x, y: bounds.y,
    w: max(bounds.w, 0'f32), h: max(bounds.h, 0'f32))
  result.rects = newSeq[Rect](c.owner.nodes.len)
  c.owner.natural.setLen(c.owner.nodes.len)
  c.owner.rectScratch.setLen(c.owner.nodes.len)
  c.owner.flexSizes.setLen(c.owner.nodes.len)
  c.owner.flexBases.setLen(c.owner.nodes.len)
  c.owner.flexMin.setLen(c.owner.nodes.len)
  c.owner.flexMax.setLen(c.owner.nodes.len)
  c.owner.flexFactors.setLen(c.owner.nodes.len)
  c.owner.flexSlots.setLen(0)
  c.owner.flexLines.setLen(0)
  c.owner.gridScratch.items.setLen(0)
  c.owner.gridScratch.occupied.setLen(0)
  c.owner.gridScratch.contributions.setLen(0)
  c.owner.gridScratch.values.setLen(0)
  for slot in 1..<c.owner.nodes.len:
    if c.owner.nodes[slot].toolbarCollapsed:
      c.owner.nodes[slot].toolbarCollapsed = false
      c.owner.nodes[slot].absolute = false
    if c.owner.nodes[slot].toolbarState != nil:
      c.owner.nodes[slot].toolbarState.items.setLen(0)
  shapeText(c.owner.nodes)
  alignFormLabels(c.owner.nodes)
  discard measureTree(c.owner.nodes, c.owner.natural, c.owner.gridScratch)
  if c.owner.nodes.applyTableFits(c.owner.natural):
    discard measureTree(c.owner.nodes, c.owner.natural, c.owner.gridScratch)
  if c.owner.nodes.len > 0:
    var stable = false
    for attempt in 0..2:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
        c.owner.flexLines, c.owner.gridScratch, 0, result.root)
      let textChanged = shapeTextToBounds(c.owner.nodes, c.owner.rectScratch)
      let sizesChanged = measureTree(c.owner.nodes, c.owner.natural,
        c.owner.gridScratch, c.owner.rectScratch)
      if not textChanged and not sizesChanged:
        stable = true
        break
    if not stable:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
        c.owner.flexLines, c.owner.gridScratch, 0, result.root)
    if c.owner.updateToolbarOverflow(c.owner.natural, c.owner.rectScratch):
      discard measureTree(c.owner.nodes, c.owner.natural,
        c.owner.gridScratch)
      if c.owner.nodes.applyTableFits(c.owner.natural):
        discard measureTree(c.owner.nodes, c.owner.natural,
          c.owner.gridScratch)
      var stable = false
      for attempt in 0..2:
        placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
          c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
          c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
          c.owner.flexLines, c.owner.gridScratch, 0, result.root)
        let textChanged = shapeTextToBounds(c.owner.nodes,
          c.owner.rectScratch)
        let sizesChanged = measureTree(c.owner.nodes, c.owner.natural,
          c.owner.gridScratch, c.owner.rectScratch)
        if not textChanged and not sizesChanged:
          stable = true
          break
      if not stable:
        placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
          c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
          c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
          c.owner.flexLines, c.owner.gridScratch, 0, result.root)
    placeInlineText(c.owner.nodes, c.owner.rectScratch)
    for slot in 0..<result.rects.len:
      result.rects[slot] = c.owner.rectScratch[slot]
      let node = c.owner.nodes[slot]
      if node.gridViewState != nil:
        let state = node.gridViewState
        let contentWidth = max(result.rects[slot].w - node.contentInsetX,
          0'f32)
        let columns = gridColumns(contentWidth, node.gridMinWidth,
          node.gridGap, state.itemCount)
        if columns != state.columns:
          let previousColumns = state.columns
          if previousColumns > 0 and state.rows != nil:
            let visible = state.rows.visible()
            if visible.first >= 0:
              let firstItem = int64(visible.first) * int64(previousColumns)
              state.rows.scrollTo(int(firstItem div int64(columns)),
                Align.Start)
          state.columns = columns
          result.animating = true
          c.owner.otherAnimating = true
      if node.listState != nil and
          node.listState.frameOwner == cast[pointer](c.owner) and
          node.listState.frameSlot == int32(slot) and
          node.listState.generation == c.owner.generation:
        if node.listRowIndex >= 0:
          let observing = node.listState.observeListHeight(
            node.listRowIndex, c.owner.rectScratch[slot].h)
          result.animating = observing or result.animating
          c.owner.otherAnimating = c.owner.otherAnimating or observing
        else:
          let observing = node.listState.observeListViewport(
            max(c.owner.rectScratch[slot].h - node.contentInsetY, 0'f32))
          result.animating = observing or result.animating
          c.owner.otherAnimating = c.owner.otherAnimating or observing
    let scrollAnimating = updateScrollRanges(c.owner.nodes,
      c.owner.rectScratch, now, reduceMotion)
    result.animating = scrollAnimating or result.animating
    c.owner.otherAnimating = c.owner.otherAnimating or scrollAnimating
    revealInScrollContainers(c.owner.nodes, c.owner.rectScratch)
    shiftScrolledRects(c.owner.nodes, result.rects)
    alignFormLabelBaselines(c.owner.nodes, result.rects)
    for slot in 0..<c.owner.nodes.len:
      let node = c.owner.nodes[slot]
      if node.listState == nil or node.listRowIndex != -1 or
          node.listState.frameOwner != cast[pointer](c.owner) or
          node.listState.frameSlot != int32(slot) or
          node.listState.generation != c.owner.generation:
        continue
      let state = node.listState
      var first = high(int)
      var last = -1
      let viewport = result.rects[slot]
      let followAnimating = state.applyListFollowAnimation(
        c.owner.nodes, result.rects, slot,
        max(viewport.w - node.contentInsetX, 0'f32),
        max(viewport.h - node.contentInsetY, 0'f32), now, reduceMotion)
      result.animating = followAnimating or result.animating
      c.owner.otherAnimating = c.owner.otherAnimating or followAnimating
      pinActiveListHeaders(c.owner.nodes, result.rects, state, slot)
      let top = viewport.y + node.border[0] + node.pad[0]
      let bottom = viewport.y + viewport.h - node.border[2] - node.pad[2]
      for rowSlot in 1..<c.owner.nodes.len:
        let row = c.owner.nodes[rowSlot]
        if row.listState != state or row.listRowIndex < 0:
          continue
        let box = result.rects[rowSlot]
        if box.y + box.h > top and box.y < bottom:
          first = min(first, row.listRowIndex)
          last = max(last, row.listRowIndex)
      if first == high(int):
        first = 0
      let finishing = state.finishList(first, last)
      result.animating = finishing or result.animating
      c.owner.otherAnimating = c.owner.otherAnimating or finishing
      updateListReorderTarget(c.owner.nodes, result.rects, state, slot)
  for slot in 1..<c.owner.nodes.len:
    let anchorIdentity = c.owner.nodes[slot].overlayAnchorIdentity
    if anchorIdentity == 0:
      continue
    let anchorSlot = c.owner.idSlots.getOrDefault(anchorIdentity, -1)
    if anchorSlot <= 0 or anchorSlot >= result.rects.len:
      continue
    let anchor = result.rects[anchorSlot]
    let overlay = result.rects[slot]
    let width = min(max(overlay.w, anchor.w), bounds.w)
    let gap = c.owner.nodes[slot].overlayGap
    let below = anchor.y + anchor.h + gap
    let above = anchor.y - overlay.h - gap
    let fitsBelow = below + overlay.h <= bounds.y + bounds.h
    let fitsAbove = above >= bounds.y
    let wantedY = if fitsBelow or not fitsAbove: below else: above
    let maxX = max(bounds.x, bounds.x + bounds.w - width)
    let wantedX = if c.owner.nodes[anchorSlot].rightToLeft:
        anchor.x + anchor.w - width
      else:
        anchor.x
    let targetX = min(max(wantedX, bounds.x), maxX)
    let maxY = max(bounds.y, bounds.y + bounds.h - overlay.h)
    let targetY = min(max(wantedY, bounds.y), maxY)
    let deltaX = targetX - overlay.x
    let deltaY = targetY - overlay.y
    result.rects[slot].x = targetX
    result.rects[slot].y = targetY
    result.rects[slot].w = width
    if deltaX != 0 or deltaY != 0:
      for descendant in slot + 1..<c.owner.nodes.len:
        var current = descendant
        while current > slot and current > 0:
          current = int(c.owner.nodes[current].parent)
        if current == slot:
          result.rects[descendant].x += deltaX
          result.rects[descendant].y += deltaY

  for slot in 1..<c.owner.nodes.len:
    if not c.owner.nodes[slot].tooltipOverlay:
      continue
    let anchorSlot = int(c.owner.nodes[slot].parent)
    if anchorSlot <= 0 or anchorSlot >= result.rects.len:
      continue
    let anchor = result.rects[anchorSlot]
    let overlay = result.rects[slot]
    let gap = c.owner.nodes[slot].tooltipGap
    let above = anchor.y - overlay.h - gap
    let targetY = if above >= bounds.y:
        above
      else:
        anchor.y + anchor.h + gap
    let delta = targetY - overlay.y
    if delta == 0:
      continue
    for descendant in slot..<c.owner.nodes.len:
      var current = descendant
      while current > slot and current > 0:
        current = int(c.owner.nodes[current].parent)
      if current == slot:
        result.rects[descendant].y += delta
  alignSplitHandles(c.owner.nodes, result.rects)
  placeInlineText(c.owner.nodes, result.rects)
  let transitionResized = c.owner.hasTransitionBounds and
    (result.root.w != c.owner.transitionBounds.w or
     result.root.h != c.owner.transitionBounds.h)
  for slot in 1..<c.owner.nodes.len:
    var node = addr c.owner.nodes[slot]
    node[].transitionTransform = Transform()
    if not node[].transitionSet:
      continue
    let value = node[].elementTransition
    let animation = value.transitionAnimation()
    if value.transitionMovesPosition:
      let target = c.owner.nodes.transitionLocalPosition(result.rects, slot)
      var channels = c.owner.animations.mgetOrPut(node[].identity,
        initTable[string, ScalarAnimation]())
      var xChannel = channels.getOrDefault(transitionXKey)
      var yChannel = channels.getOrDefault(transitionYKey)
      var shownX, shownY: float32
      if transitionResized:
        xChannel = ScalarAnimation(value: float64(target.x),
          fromValue: float64(target.x), target: float64(target.x),
          at: now, generation: c.owner.generation, initialized: true)
        yChannel = ScalarAnimation(value: float64(target.y),
          fromValue: float64(target.y), target: float64(target.y),
          at: now, generation: c.owner.generation, initialized: true)
        shownX = target.x
        shownY = target.y
      else:
        shownX = float32(xChannel.update(c.owner, float64(target.x),
          animation, respectReduceMotion = true))
        shownY = float32(yChannel.update(c.owner, float64(target.y),
          animation, respectReduceMotion = true))
      channels[transitionXKey] = xChannel
      channels[transitionYKey] = yChannel
      c.owner.animations[node[].identity] = channels
      let offsetX = shownX - target.x
      let offsetY = shownY - target.y
      if offsetX != 0 or offsetY != 0:
        node[].transitionTransform = translation(offsetX, offsetY)
    if value.transitionMovesSize:
      let targetWidth = result.rects[slot].w
      let targetHeight = result.rects[slot].h
      var channels = c.owner.animations.mgetOrPut(node[].identity,
        initTable[string, ScalarAnimation]())
      var widthChannel = channels.getOrDefault(transitionWidthKey)
      var heightChannel = channels.getOrDefault(transitionHeightKey)
      let shownWidth = if transitionResized:
          widthChannel = ScalarAnimation(value: float64(targetWidth),
            fromValue: float64(targetWidth), target: float64(targetWidth),
            at: now, generation: c.owner.generation, initialized: true)
          targetWidth
        else:
          float32(widthChannel.update(c.owner, float64(targetWidth),
            animation, respectReduceMotion = true))
      let shownHeight = if transitionResized:
          heightChannel = ScalarAnimation(value: float64(targetHeight),
            fromValue: float64(targetHeight), target: float64(targetHeight),
            at: now, generation: c.owner.generation, initialized: true)
          targetHeight
        else:
          float32(heightChannel.update(c.owner, float64(targetHeight),
            animation, respectReduceMotion = true))
      channels[transitionWidthKey] = widthChannel
      channels[transitionHeightKey] = heightChannel
      c.owner.animations[node[].identity] = channels
      if shownWidth != targetWidth or shownHeight != targetHeight:
        result.rects[slot].w = max(shownWidth, 0'f32)
        result.rects[slot].h = max(shownHeight, 0'f32)
        c.relayoutTransitionSubtree(result, slot)
    if value.transitionMovesColors:
      node[].background = c.owner.animateColor(node[].identity,
        transitionBackgroundKey, node[].background, animation)
      node[].borderColor = c.owner.animateColor(node[].identity,
        transitionBorderKey, node[].borderColor, animation)
  result.animating = result.animating or c.owner.animating
  c.owner.draggableOffsetScratch.setLen(c.owner.nodes.len)
  if c.owner.nodes.len > 0:
    c.owner.draggableOffsetScratch[0] = Point()
  for slot in 1..<c.owner.nodes.len:
    let node = c.owner.nodes[slot]
    let parent = int(node.parent)
    var inherited = c.owner.draggableOffsetScratch[parent]
    if node.overlayAnchorIdentity != 0 and
        c.owner.idSlots.hasKey(node.overlayAnchorIdentity):
      let anchor = c.owner.idSlots[node.overlayAnchorIdentity]
      var ancestor = parent
      var containsAnchor = false
      while ancestor > 0 and ancestor < c.owner.nodes.len:
        if ancestor == anchor:
          containsAnchor = true
          break
        ancestor = int(c.owner.nodes[ancestor].parent)
      if not containsAnchor and anchor >= 0 and
          anchor < c.owner.draggableOffsetScratch.len:
        inherited.x += c.owner.draggableOffsetScratch[anchor].x
        inherited.y += c.owner.draggableOffsetScratch[anchor].y
    if node.draggable:
      inherited.x += node.dragOffset.x
      inherited.y += node.dragOffset.y
    result.rects[slot].x += inherited.x
    result.rects[slot].y += inherited.y
    for rect in mitems(c.owner.nodes[slot].textInlineRects):
      rect.x += inherited.x
      rect.y += inherited.y
    c.owner.draggableOffsetScratch[slot] = inherited
  result.worldTransforms = newSeq[scene.Affine](c.owner.nodes.len)
  result.visualRects = newSeq[Rect](c.owner.nodes.len)
  result.backfaceBlocked = newSeq[bool](c.owner.nodes.len)
  for slot in 0..<c.owner.nodes.len:
    let node = c.owner.nodes[slot]
    let local = node.localTransform(result.rects[slot])
    let parent = int(node.parent)
    result.worldTransforms[slot] = if parent >= 0:
        scene.mul(result.worldTransforms[parent], local)
      else:
        local
    validateTransform(result.worldTransforms[slot])
    result.visualRects[slot] = transformedRect(result.worldTransforms[slot],
      result.rects[slot])
    result.backfaceBlocked[slot] =
      (parent >= 0 and result.backfaceBlocked[parent]) or
      (node.backfaceHidden and node.transform.facesAway())
  c.owner.visibleIdentities.clear()
  c.owner.visibleClipScratch.setLen(c.owner.nodes.len)
  c.owner.visibilityBlockedScratch.setLen(c.owner.nodes.len)
  if c.owner.nodes.len > 0:
    c.owner.visibleClipScratch[0] = result.root
    c.owner.visibilityBlockedScratch[0] = false
  for slot in 1..<c.owner.nodes.len:
    let node = c.owner.nodes[slot]
    let parent = int(node.parent)
    let inheritedClip = c.owner.visibleClipScratch[parent]
    let blocked = c.owner.visibilityBlockedScratch[parent] or node.inert or
      result.backfaceBlocked[slot]
    c.owner.visibilityBlockedScratch[slot] = blocked
    if not blocked and hasVisibleArea(result.visualRects[slot], inheritedClip):
      c.owner.visibleIdentities.incl(c.owner.nodes[slot].identity)
    c.owner.visibleClipScratch[slot] = childClip(inheritedClip, node,
      result.visualRects[slot])
  c.owner.visibleGeneration = c.owner.generation
  c.owner.committedRects = result.rects
  c.owner.committedTransforms = result.worldTransforms
  c.owner.transitionBounds = result.root
  c.owner.hasTransitionBounds = true
  for slot, node in c.owner.nodes:
    if node.identity in c.owner.trackedBounds:
      c.owner.lastBounds[node.identity] = result.rects[slot]
      c.owner.lastTransforms[node.identity] = result.worldTransforms[slot]
  result.poseOnlyAnimating = result.animating and c.owner.poseAnimating and
    not c.owner.otherAnimating

proc layout*(c: Context; bounds: Rect): LayoutResult =
  ## Lays out the latest completed build inside bounds.
  c.layoutAt(bounds, getMonoTime(), false)

proc layout*(c: Context; width, height: float32): LayoutResult =
  ## Lays out the latest completed build at the window origin.
  c.layout(Rect(w: width, h: height))

proc bounds*(layout: LayoutResult; element: Element): Rect =
  ## Returns an element's rectangle from this layout result.
  if layout.owner == nil or layout.owner.closed or
      layout.owner != element.owner or
      layout.generation != element.generation or
      layout.generation != layout.owner.generation or
      int(element.slot) >= layout.rects.len:
    raise newException(ValueError, "ui: element is not part of this layout")
  layout.rects[int(element.slot)]

proc bounds*(e: Element): Rect =
  ## Returns the element's most recently laid out bounds.
  let n = e.node
  if n == nil:
    return
  e.owner.trackedBounds.incl(n[].identity)
  e.owner.lastBounds.getOrDefault(n[].identity)

proc inView*(e: Element): bool =
  ## Reports whether this element had visible area in the previous layout.
  let n = e.node
  if n == nil or e.generation == 0 or
      e.owner.visibleGeneration != e.generation - 1:
    return false
  n[].identity in e.owner.visibleIdentities

proc pointerPosition*(e: Element): tuple[x, y: float32, over: bool] =
  ## Returns pointer coordinates relative to the element and whether it is
  ## hovered.
  let n = e.node
  if n == nil:
    return
  n[].trackPointer = true
  let rect = e.bounds()
  if not e.owner.hasPointer:
    return
  let transform = e.owner.lastTransforms.getOrDefault(n[].identity)
  let (inverse, ok) = transform.inverse()
  if not ok:
    return
  let (x, y) = inverse.point(e.owner.pointerX, e.owner.pointerY)
  result.x = x - rect.x
  result.y = y - rect.y
  result.over = n[].hovered

proc local*[T](e: Element; key: string;
               init: proc(): T {.closure.}): LocalCell[T] =
  ## Returns state retained for this element and key across frame builds.
  let n = e.node
  if n == nil or init == nil:
    return
  let identity = n[].identity
  if not e.owner.localStates.hasKey(identity):
    e.owner.localStates[identity] = initTable[string, RootRef]()
  var values = e.owner.localStates[identity]
  let existing = values.getOrDefault(key)
  if existing != nil and existing of LocalCell[T]:
    return LocalCell[T](existing)
  new(result)
  result.value = init()
  values[key] = RootRef(result)
  e.owner.localStates[identity] = values

proc bounds*(handle: Handle; c: Context): Rect =
  ## Returns the last committed window-space bounds for handle in c.
  if c == nil or c.owner == nil or c.owner.closed:
    return
  let binding = handle.existingBinding(c.owner)
  if binding == nil or binding.identity == 0 or
      not c.owner.idSlots.hasKey(binding.identity):
    return
  let slot = c.owner.idSlots[binding.identity]
  if slot >= 0 and slot < c.owner.committedRects.len:
    result = c.owner.committedRects[slot]

proc localPoint(layout: LayoutResult; slot: int; x, y: float32):
    tuple[x, y: float32, ok: bool] =
  if slot < 0 or slot >= layout.worldTransforms.len:
    return
  let (inverse, ok) = layout.worldTransforms[slot].inverse()
  if not ok:
    return
  let (x, y) = inverse.point(x, y)
  (x, y, true)

proc localVector(layout: LayoutResult; slot: int; x, y, dx, dy: float32):
    tuple[x, y: float32, ok: bool] =
  let (x0, y0, ok0) = layout.localPoint(slot, x, y)
  let (x1, y1, ok1) = layout.localPoint(slot, x + dx, y + dy)
  if ok0 and ok1:
    result = (x1 - x0, y1 - y0, true)

proc insideClips(layout: LayoutResult; slot: int; x, y: float32): bool =
  var parent = int(layout.owner.nodes[slot].parent)
  while parent >= 0:
    let node = layout.owner.nodes[parent]
    if node.clipsChildren:
      let (localX, localY, ok) = layout.localPoint(parent, x, y)
      if not ok:
        return false
      let box = layout.rects[parent]
      let left = box.x + node.border[3]
      let top = box.y + node.border[0]
      let right = box.x + box.w - node.border[1]
      let bottom = box.y + box.h - node.border[2]
      let clipsX = node.scrollState != nil or node.clipX
      let clipsY = node.scrollState != nil or node.clipY
      if (clipsX and (localX < left or localX >= right)) or
          (clipsY and (localY < top or localY >= bottom)):
        return false
    parent = int(node.parent)
  true

proc pointerTransparent(layout: LayoutResult; slot: int): bool =
  if slot >= 0 and slot < layout.backfaceBlocked.len and
      layout.backfaceBlocked[slot]:
    return true
  var current = slot
  while current > 0:
    if layout.owner.nodes[current].passThrough:
      return true
    current = int(layout.owner.nodes[current].parent)

proc containsPointer(layout: LayoutResult; slot: int;
                     x, y: float32): bool =
  let node = layout.owner.nodes[slot]
  let (localX, localY, ok) = layout.localPoint(slot, x, y)
  if not ok:
    return false
  if node.textInline:
    for rect in node.textInlineRects:
      if rect.contains(localX, localY):
        return true
    return false
  layout.rects[slot].contains(localX, localY)

proc targetAt(layout: LayoutResult; x, y: float32): Element =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation or
      layout.rects.len != layout.owner.nodes.len:
    return
  let usePaintOrder = layout.owner.paintSlots.len == layout.rects.len
  var topmost: Element
  var orderIndex = if usePaintOrder:
      layout.owner.paintSlots.high
    else:
      layout.rects.high
  while orderIndex >= 1:
    let slot = if usePaintOrder:
        layout.owner.paintSlots[orderIndex]
      else:
        orderIndex
    if slot > 0 and layout.owner.inActiveModalScope(slot) and
        not layout.owner.effectivelyInert(slot) and
        not layout.owner.effectivelyToolbarCollapsed(slot) and
        not layout.pointerTransparent(slot) and
        layout.containsPointer(slot, x, y) and
        layout.insideClips(slot, x, y):
      let target = Element(owner: layout.owner, slot: uint32(slot),
                           generation: layout.generation)
      if layout.owner.nodes[slot].listRowHeader or
          layout.owner.nodes[slot].tableResizeHandle:
        return target
      if topmost.owner == nil:
        topmost = target
      if layout.owner.nodes[slot].clickHandler != nil:
        return target
    dec orderIndex
  topmost

proc hasScrollAncestor(layout: LayoutResult; slot: int): bool =
  if layout.owner == nil or slot <= 0 or slot >= layout.owner.nodes.len:
    return false
  var parent = int(layout.owner.nodes[slot].parent)
  while parent > 0:
    if layout.owner.nodes[parent].scrollState != nil:
      return true
    parent = int(layout.owner.nodes[parent].parent)
  false

proc revealSlot(layout: LayoutResult; slot: int): bool =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      layout.generation != layout.owner.generation or
      layout.rects.len != layout.owner.nodes.len or
      slot <= 0 or slot >= layout.owner.nodes.len:
    return false
  var moved = false
  var box = layout.rects[slot]
  var parent = int(layout.owner.nodes[slot].parent)
  while parent > 0:
    let node = layout.owner.nodes[parent]
    let state = node.scrollState
    if state != nil:
      let view = layout.rects[parent]
      let oldX = state.offsetX
      let oldY = state.offsetY
      if node.scrollX:
        state.offsetX = nearestScrollOffset(oldX, box.x + oldX, box.w,
          view.x + node.border[3],
          max(view.x + view.w - node.border[1],
            view.x + node.border[3]), state.maxX)
      if node.scrollY:
        state.offsetY = nearestScrollOffset(oldY, box.y + oldY, box.h,
          view.y + node.border[0],
          max(view.y + view.h - node.border[2],
            view.y + node.border[0]), state.maxY)
      if state.offsetX != oldX or state.offsetY != oldY:
        moved = true
      box.x -= state.offsetX - oldX
      box.y -= state.offsetY - oldY
    parent = int(node.parent)
  moved

type ScrollbarGeometry = object
  vertical, horizontal: bool
  verticalTrack, verticalThumb, horizontalTrack, horizontalThumb: Rect

proc scrollbarThumb(start, track, view, content,
                    offset: float32): tuple[position, length: float32] =
  let inner = max(track - 4'f32, 0'f32)
  if inner == 0 or content <= 0:
    return
  result.length = min(max(inner * view / content, 24'f32), inner)
  let travel = max(inner - result.length, 0'f32)
  let range = max(content - view, 0'f32)
  let along = if range > 0:
      min(max(travel * offset / range, 0'f32), travel)
    else:
      0'f32
  result.position = start + 2 + along

proc scrollbars(layout: LayoutResult; slot: int): ScrollbarGeometry =
  if layout.owner == nil or slot <= 0 or slot >= layout.owner.nodes.len:
    return
  let node = layout.owner.nodes[slot]
  let state = node.scrollState
  if state == nil:
    return
  let box = layout.rects[slot]
  let width = if node.scrollbarWidth.finiteUi and node.scrollbarWidth > 0:
      node.scrollbarWidth
    else:
      6'f32
  let top = node.border[0]
  let right = node.border[1]
  let bottom = node.border[2]
  let left = node.border[3]
  let barTop = top + node.scrollbarInsets[0]
  let barRight = right + node.scrollbarInsets[1]
  let barBottom = bottom + node.scrollbarInsets[2]
  let barLeft = left + node.scrollbarInsets[3]
  let viewWidth = max(box.w - left - right, 0'f32)
  let viewHeight = max(box.h - top - bottom, 0'f32)
  let contentWidth = viewWidth + state.maxX
  let contentHeight = viewHeight + state.maxY
  result.vertical = node.scrollY and state.maxY > 0.5
  result.horizontal = node.scrollX and state.maxX > 0.5
  let corner = if result.vertical and result.horizontal:
      width + 3
    else:
      0'f32
  if result.vertical:
    let trackHeight = max(box.h - barTop - barBottom - corner, 0'f32)
    let trackX = if node.rightToLeft:
        box.x + barLeft
      else:
        box.x + box.w - barRight - width - 6
    let trackY = box.y + barTop
    result.verticalTrack = Rect(x: trackX, y: trackY,
      w: width + 6, h: trackHeight)
    let thumb = scrollbarThumb(trackY, trackHeight, viewHeight,
      contentHeight, state.offsetY)
    let thumbX = if node.rightToLeft:
        box.x + barLeft + 3
      else:
        box.x + box.w - barRight - width - 3
    result.verticalThumb = Rect(x: thumbX,
      y: thumb.position, w: width, h: thumb.length)
  if result.horizontal:
    let trackWidth = max(box.w - barLeft - barRight - corner, 0'f32)
    let cornerInset = if node.rightToLeft and result.vertical: corner else: 0'f32
    let trackX = box.x + barLeft + cornerInset
    let trackY = box.y + box.h - barBottom - width - 6
    result.horizontalTrack = Rect(x: trackX, y: trackY,
      w: trackWidth, h: width + 6)
    let thumb = scrollbarThumb(trackX, trackWidth, viewWidth,
      contentWidth, state.offsetX)
    let thumbX = if node.rightToLeft:
        trackX + trackWidth - (thumb.position - trackX) - thumb.length
      else:
        thumb.position
    result.horizontalThumb = Rect(x: thumbX,
      y: box.y + box.h - barBottom - width - 3,
      w: thumb.length, h: width)

proc scrollbarPress(layout: LayoutResult; x, y: float32;
                    drag: var ScrollbarDrag): bool =
  let target = layout.targetAt(x, y)
  if target.owner == nil:
    return false
  var slot = int(target.slot)
  while slot > 0:
    let node = layout.owner.nodes[slot]
    let state = node.scrollState
    if state != nil:
      let (localX, localY, ok) = layout.localPoint(slot, x, y)
      if not ok:
        slot = int(node.parent)
        continue
      let geometry = layout.scrollbars(slot)
      if geometry.vertical and geometry.verticalTrack.contains(localX, localY):
        state.stopScrollMotion()
        if geometry.verticalThumb.contains(localX, localY):
          drag = ScrollbarDrag(state: state, slot: slot,
            pointerStart: localY,
            offsetStart: state.offsetY, rangeStart: state.maxY,
            travel: max(geometry.verticalTrack.h - 4 -
              geometry.verticalThumb.h, 0'f32))
          state.scrollbarDragging = true
        elif localY < geometry.verticalThumb.y:
          state.offsetY = max(0'f32, state.offsetY -
            layout.rects[slot].h * 0.9'f32)
        else:
          state.offsetY = min(state.maxY, state.offsetY +
            layout.rects[slot].h * 0.9'f32)
        return true
      if geometry.horizontal and geometry.horizontalTrack.contains(localX,
          localY):
        state.stopScrollMotion()
        if geometry.horizontalThumb.contains(localX, localY):
          drag = ScrollbarDrag(state: state, slot: slot, horizontal: true,
            rightToLeft: node.rightToLeft,
            pointerStart: localX, offsetStart: state.offsetX,
            rangeStart: state.maxX,
            travel: max(geometry.horizontalTrack.w - 4 -
              geometry.horizontalThumb.w, 0'f32))
          state.scrollbarDragging = true
        elif (localX < geometry.horizontalThumb.x) != node.rightToLeft:
          state.offsetX = max(0'f32, state.offsetX -
            layout.rects[slot].w * 0.9'f32)
        else:
          state.offsetX = min(state.maxX, state.offsetX +
            layout.rects[slot].w * 0.9'f32)
        return true
    slot = int(node.parent)
  false

proc dragScrollbar(layout: LayoutResult; drag: ScrollbarDrag;
                   x, y: float32): bool =
  let state = drag.state
  if state == nil or drag.travel <= 0 or drag.rangeStart <= 0:
    return false
  let (localX, localY, ok) = layout.localPoint(drag.slot, x, y)
  if not ok:
    return false
  state.stopScrollMotion()
  let maxOffset = if drag.horizontal: state.maxX else: state.maxY
  let coordinate = if drag.horizontal: localX else: localY
  let movement = if drag.horizontal and drag.rightToLeft:
      drag.pointerStart - coordinate
    else:
      coordinate - drag.pointerStart
  let offset = min(max(drag.offsetStart / drag.rangeStart +
    movement / drag.travel, 0'f32), 1'f32) * maxOffset
  if drag.horizontal:
    result = state.offsetX != offset
    state.offsetX = offset
  else:
    result = state.offsetY != offset
    state.offsetY = offset

proc slotsAt(layout: LayoutResult; x, y: float32): seq[int] =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation or
      layout.rects.len != layout.owner.nodes.len:
    return
  for slot in 1..<layout.rects.len:
    if layout.owner.inActiveModalScope(slot) and
        not layout.owner.effectivelyToolbarCollapsed(slot) and
        not layout.pointerTransparent(slot) and
        layout.containsPointer(slot, x, y) and
        layout.insideClips(slot, x, y):
      result.add(slot)

proc scrollAt(layout: LayoutResult; x, y, dx, dy: float32): bool =
  let target = layout.targetAt(x, y)
  if target.owner == nil:
    return false
  var slot = int(target.slot)
  while slot > 0:
    let node = layout.owner.nodes[slot]
    let state = node.scrollState
    if state != nil:
      let (localDx, localDy, ok) = layout.localVector(slot, x, y, dx, dy)
      if not ok:
        slot = int(node.parent)
        continue
      let oldX = state.offsetX
      let oldY = state.offsetY
      if dx != 0 or dy != 0:
        state.stopScrollMotion()
      if node.scrollX:
        let deltaX = if node.rightToLeft: -localDx else: localDx
        state.offsetX = min(max(oldX + deltaX, 0'f32), state.maxX)
      if node.scrollY:
        state.offsetY = min(max(oldY + localDy, 0'f32), state.maxY)
      if state.offsetX != oldX or state.offsetY != oldY:
        return true
    slot = int(node.parent)
  false

proc scrollKey(layout: LayoutResult; focusSlot: int;
               pointerX, pointerY, dx, dy, page: float32;
               hasPointer: bool): bool =
  if layout.owner == nil or layout.owner.closed or
      layout.owner.inBuild or layout.generation != layout.owner.generation:
    return false
  var slot = focusSlot
  if slot <= 0 or slot >= layout.owner.nodes.len:
    if not hasPointer:
      return false
    let target = layout.targetAt(pointerX, pointerY)
    if target.owner == nil:
      return false
    slot = int(target.slot)
  var hasScroller = false
  var check = slot
  while check > 0:
    if layout.owner.nodes[check].scrollState != nil:
      hasScroller = true
      break
    check = int(layout.owner.nodes[check].parent)
  if not hasScroller:
    if not hasPointer:
      return false
    let target = layout.targetAt(pointerX, pointerY)
    if target.owner == nil:
      return false
    slot = int(target.slot)
  while slot > 0:
    let node = layout.owner.nodes[slot]
    let state = node.scrollState
    if state != nil:
      let oldX = state.offsetX
      let oldY = state.offsetY
      if dx != 0 or dy != 0 or page != 0:
        state.stopScrollMotion()
      let stepY = if page == 0:
          dy
        else:
          page * max(layout.rects[slot].h - 40'f32,
                     layout.rects[slot].h / 2)
      if node.scrollX:
        let deltaX = if node.rightToLeft: -dx else: dx
        state.offsetX = min(max(oldX + deltaX, 0'f32), state.maxX)
      if node.scrollY:
        state.offsetY = min(max(oldY + stepY, 0'f32), state.maxY)
      if state.offsetX != oldX or state.offsetY != oldY:
        return true
    slot = int(node.parent)
  false

proc scrollIntoView*(e: Element): Element =
  ## Scrolls the element's ancestors just enough to show it in each viewport.
  result = e
  let node = e.node
  if node != nil:
    node.revealInScroll = true

proc dispatchClick(layout: LayoutResult; pressed: Element;
                   x, y: float32; mods: platform.Modifiers;
                   clickedSlot: var int): bool =
  if pressed.owner == nil or pressed.owner != layout.owner or
      layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or layout.generation != layout.owner.generation:
    return false
  let target = layout.targetAt(x, y)
  if target.owner != pressed.owner or target.slot != pressed.slot:
    return false
  clickedSlot = int(target.slot)
  let labelTarget = int(layout.owner.nodes[clickedSlot].labelTargetSlot)
  if labelTarget > 0 and labelTarget < layout.owner.nodes.len:
    clickedSlot = labelTarget
  if layout.owner.effectivelyDisabled(clickedSlot):
    return false
  let node = layout.owner.nodes[clickedSlot]
  if node.listState != nil and node.listRowIndex >= 0 and
      not node.listRowHeader and not node.listRowAction:
    node.listState.clickListRow(node.listRowIndex, mods)
  else:
    let handler = node.clickHandler
    if handler != nil:
      handler(mods)
  true

proc dispatchAccessTreeAction(layout: LayoutResult; id: uint64;
                              action: platform.AccessActionKind): bool =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation:
    return false
  for slot in 1..<layout.owner.nodes.len:
    if uint64(slot + 1) != id:
      continue
    if layout.backfaceBlocked[slot] or
        layout.owner.effectivelyDisabled(slot) or
        layout.owner.effectivelyToolbarCollapsed(slot):
      return false
    let node = layout.owner.nodes[slot]
    if node.treeAccessAction != nil:
      return node.treeAccessAction(action)
    if node.listState == nil or node.listRowIndex < 0 or
        node.listState.rowAccessAction == nil:
      return false
    return node.listState.rowAccessAction(node.listRowIndex, action)
  false

proc dispatchAccessPress(layout: LayoutResult; id: uint64): bool =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation:
    return false
  for slot in 1..<layout.owner.nodes.len:
    if uint64(slot + 1) != id:
      continue
    if layout.backfaceBlocked[slot] or
        layout.owner.effectivelyDisabled(slot) or
        layout.owner.effectivelyToolbarCollapsed(slot):
      return false
    let handler = layout.owner.nodes[slot].clickHandler
    if handler == nil:
      return false
    handler(0)
    return true

proc len*(layout: LayoutResult): int = max(layout.rects.len - 1, 0)

proc hovered*(e: Element): bool =
  ## Reports whether the pointer is over this element during the current build.
  ## During a press, only elements under the pointer when the press began stay hovered.
  let n = e.node
  n != nil and n.hovered

proc value*(e: Element; value: string): Element =
  ## Sets the element's accessible value.
  result = e
  let n = e.node
  if n != nil:
    n[].accessValue = value

proc pressed*(e: Element): bool =
  ## Reports whether a primary press began over this element and remains over it.
  let n = e.node
  n != nil and n.pressed

proc clicked*(e: Element): bool =
  ## Reports a primary pointer or accessibility activation since the previous build.
  let n = e.node
  n != nil and n.clicked

proc doubleClicked*(e: Element): bool =
  ## Reports a double click on this element during the current build.
  let n = e.node
  n != nil and n.doubleClicked

proc focusable*(e: Element): Element =
  ## Includes this element in sequential keyboard and accessibility focus.
  result = e
  let n = e.node
  if n != nil:
    n.focusable = true

proc autoFocus*(e: Element): Element =
  ## Gives a newly opened modal focus here before its first Tab press.
  result = e
  let n = e.node
  if n != nil:
    n.focusable = true
    n.autoFocus = true

proc tabStop*(e: Element; enabled = true): Element =
  ## Includes or excludes a focusable element from sequential Tab navigation.
  result = e
  let n = e.node
  if n != nil:
    n.tabStopSet = true
    n.tabStop = enabled

proc focusRing*(e: Element; show = true): Element =
  ## Shows the theme focus ring for keyboard focus, unless disabled here.
  result = e
  let n = e.node
  if n != nil:
    n.focusRingDisabled = not show

proc focused*(e: Element): bool =
  ## Reports whether this element has keyboard focus during the current build.
  let n = e.node
  n != nil and n.focused

proc focusVisible*(e: Element): bool =
  ## Reports whether focus came from keyboard navigation during the current build.
  let n = e.node
  n != nil and n.focusVisible

proc textInput*(e: Element; client: platform.TextInputClient): Element =
  ## Connects this element to an application-owned native text input client.
  ## Client text ranges use UTF-16 document offsets; caret bounds are relative
  ## to this element. Keep the client alive and stable across frame builds.
  result = e
  let n = e.node
  if n != nil:
    n.textClient = client
    if client != nil:
      n.focusable = true

proc scrollX*(e: Element; state: ScrollState): Element =
  ## Clips this element and scrolls its content horizontally with state.
  if state == nil:
    raise newException(ValueError, "ui: scroll state cannot be nil")
  result = e
  let n = e.node
  if n != nil:
    n.scrollX = true
    n.scrollState = state

proc scrollY*(e: Element; state: ScrollState): Element =
  ## Clips this element and scrolls its content vertically with state.
  if state == nil:
    raise newException(ValueError, "ui: scroll state cannot be nil")
  result = e
  let n = e.node
  if n != nil:
    n.scrollY = true
    n.scrollState = state

proc scroll*(e: Element; state: ScrollState): Element =
  ## Clips this element and scrolls its content on both axes with state.
  result = e.scrollX(state).scrollY(state)

proc scroll*(c: Context; state: ScrollState): Element =
  ## Creates a vertically scrolling column with persistent state.
  c.column().scrollY(state)

proc scrollHorizontal*(c: Context; state: ScrollState): Element =
  ## Creates a horizontally scrolling row with persistent state.
  c.row().scrollX(state)

proc scrollBoth*(c: Context; state: ScrollState): Element =
  ## Creates a two-axis scrolling box with persistent state.
  c.box().scroll(state)

proc setScrollbarInsets(e: Element; values: array[4, float32]): Element =
  result = e
  let n = e.node
  if n != nil:
    n.scrollbarInsets = values

proc scrollbarInsets*(e: Element; all: float32): Element =
  ## Moves scroll bars in from all four edges by the same number of DIPs.
  e.setScrollbarInsets([all, all, all, all])

proc scrollbarInsets*(e: Element; vertical, horizontal: float32): Element =
  ## Moves scroll bars in by vertical and horizontal edge insets.
  e.setScrollbarInsets([vertical, horizontal, vertical, horizontal])

proc scrollbarInsets*(e: Element; top, horizontal, bottom: float32): Element =
  ## Sets top, horizontal, and bottom scroll bar insets.
  e.setScrollbarInsets([top, horizontal, bottom, horizontal])

proc scrollbarInsets*(e: Element; top, right, bottom, left: float32): Element =
  ## Sets scroll bar insets in top, right, bottom, left order.
  e.setScrollbarInsets([top, right, bottom, left])

proc clip*(e: Element): Element =
  ## Clips the element's children to its inner rounded rectangle.
  result = e
  let n = e.node
  if n != nil:
    n.clipX = true
    n.clipY = true

proc clipX*(e: Element): Element =
  ## Clips the element's children horizontally to its inner bounds.
  result = e
  let n = e.node
  if n != nil:
    n.clipX = true

proc clipY*(e: Element): Element =
  ## Clips the element's children vertically to its inner bounds.
  result = e
  let n = e.node
  if n != nil:
    n.clipY = true

proc scrollWith*(e, scroller: Element): Element =
  ## Moves this element's content with a horizontal scroll container.
  ## Clip this element when its moving content must stay within its bounds.
  result = e
  let n = e.node
  if n == nil:
    return
  if scroller.owner != e.owner:
    raise newException(ValueError,
      "ui: scrollWith elements must belong to the same frame")
  let source = scroller.node
  if source == nil or source.scrollState == nil or not source.scrollX:
    raise newException(ValueError,
      "ui: scrollWith requires a horizontal scroll container")
  n.followScrollSlot = int32(scroller.slot)
  n.hasFollowScroll = true

proc updateDimension(e: Element; dimension: LayoutDimension;
                     value: UiLength): Element =
  result = e
  let n = e.node
  if n != nil:
    case dimension
    of ldWidth: n.width = value
    of ldHeight: n.height = value
    of ldMinWidth: n.minW = value
    of ldMinHeight: n.minH = value
    of ldMaxWidth: n.maxW = value
    of ldMaxHeight: n.maxH = value

proc width*(e: Element; value: float32): Element =
  e.updateDimension(ldWidth, pixels(value))

proc height*(e: Element; value: float32): Element =
  e.updateDimension(ldHeight, pixels(value))

proc size*(e: Element; width, height: float32): Element =
  discard e.width(width)
  e.height(height)

proc aspectRatio*(e: Element; value: float32): Element =
  ## Keeps an element's content proportions as flex layout changes its size.
  result = e
  let n = e.node
  if n != nil:
    n.aspectRatio = if classify(value) notin {fcNan, fcInf, fcNegInf} and
        value > 0: value else: 0'f32

proc widthPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldWidth, percent(value))

proc heightPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldHeight, percent(value))

proc fillWidth*(e: Element): Element = e.widthPercent(100)
proc fillHeight*(e: Element): Element = e.heightPercent(100)

proc fill*(e: Element): Element =
  discard e.fillWidth()
  e.fillHeight()

proc minWidth*(e: Element; value: float32): Element =
  e.updateDimension(ldMinWidth, pixels(value))

proc minHeight*(e: Element; value: float32): Element =
  e.updateDimension(ldMinHeight, pixels(value))

proc maxWidth*(e: Element; value: float32): Element =
  e.updateDimension(ldMaxWidth, pixels(value))

proc maxHeight*(e: Element; value: float32): Element =
  e.updateDimension(ldMaxHeight, pixels(value))

proc minWidthPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldMinWidth, percent(value))

proc minHeightPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldMinHeight, percent(value))

proc maxWidthPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldMaxWidth, percent(value))

proc maxHeightPercent*(e: Element; value: float32): Element =
  e.updateDimension(ldMaxHeight, percent(value))

proc grow*(e: Element; factor = 1'f32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.grow = max(factor, 0'f32)
    if n.basis.kind == lengthAuto:
      n.basis = percent(0)

proc shrink*(e: Element; factor: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.shrink = max(factor, 0'f32)

proc basis*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.basis = pixels(value)

proc basisPercent*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.basis = percent(value)

proc gap*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.gapX = value
    n.gapY = value

proc gapX*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.gapX = value

proc gapY*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.gapY = value

proc justify*(e: Element; value: Align): Element =
  result = e
  let n = e.node
  if n != nil:
    n.justify = value
    n.justifySet = true

proc fixed*(value: float32): Track =
  ## Creates a grid track with a fixed size in device-independent pixels.
  Track(kind: trackFixed, value: max(value, 0'f32))

proc fr*(factor = 1'f32): Track =
  ## Creates a grid track sized by its share of remaining space.
  Track(kind: trackFr, value: max(factor, 0'f32))

proc fitContent*(): Track =
  ## Creates a grid track sized to fit its content, within available space.
  Track(kind: trackFit)

proc grid*(e: Element): Element =
  ## Turns this element into a row-major grid container.
  result = e
  let n = e.node
  if n != nil:
    if n.row and n.align == Align.Center and not n.alignSet:
      n.align = Align.Auto
    n.grid = true
    n.row = false
    if not n.justifySet:
      n.justify = Align.Auto

proc grid*(c: Context): Element =
  ## Adds a grid container to the current parent.
  result = c.newElement(false, identityKindGrid).grid()

proc columns*(e: Element; count: int): Element =
  ## Sets equal fractional columns for a grid.
  result = e
  let n = e.node
  if n != nil:
    n.cols.setLen(0)
    for _ in 0 ..< max(count, 0):
      n.cols.add(fr())

proc rows*(e: Element; count: int): Element =
  ## Sets equal fractional rows for a grid.
  result = e
  let n = e.node
  if n != nil:
    n.rows.setLen(0)
    for _ in 0 ..< max(count, 0):
      n.rows.add(fr())

proc columnTracks*(e: Element; tracks: varargs[Track]): Element =
  ## Sets explicit column tracks; additional columns fit their content.
  result = e
  let n = e.node
  if n != nil:
    n.cols.setLen(0)
    for track in tracks:
      n.cols.add(track)

proc rowTracks*(e: Element; tracks: varargs[Track]): Element =
  ## Sets explicit row tracks; additional rows fit their content.
  result = e
  let n = e.node
  if n != nil:
    n.rows.setLen(0)
    for track in tracks:
      n.rows.add(track)

proc justifyItems*(e: Element; value: Align): Element =
  ## Aligns grid children horizontally in their cells.
  result = e
  let n = e.node
  if n != nil:
    n.justifyItems = value

proc justifySelf*(e: Element; value: Align): Element =
  ## Overrides the grid's horizontal item alignment for this element.
  result = e
  let n = e.node
  if n != nil:
    n.justifySelf = value

proc columnStart*(e: Element; value: int): Element =
  ## Places the element at a one-based grid column.
  result = e
  let n = e.node
  if n != nil:
    n.gridCol = min(max(value, 1), MaxGridTrackIndex)

proc rowStart*(e: Element; value: int): Element =
  ## Places the element at a one-based grid row.
  result = e
  let n = e.node
  if n != nil:
    n.gridRow = min(max(value, 1), MaxGridTrackIndex)

proc columnSpan*(e: Element; value: int): Element =
  ## Spans grid columns; a negative value reaches the grid's last column.
  result = e
  let n = e.node
  if n != nil:
    n.gridColSpan = if value > 0: min(value, MaxGridTrackIndex)
      elif value < 0: -1 else: 0

proc rowSpan*(e: Element; value: int): Element =
  ## Spans grid rows; a negative value reaches the grid's last explicit row.
  result = e
  let n = e.node
  if n != nil:
    n.gridRowSpan = if value > 0: min(value, MaxGridTrackIndex)
      elif value < 0: -1 else: 0

proc wrap*(e: Element): Element =
  ## Places in-flow children on additional lines when they exceed the main axis.
  result = e
  let n = e.node
  if n != nil:
    n.wrap = true

proc wrapReverse*(e: Element): Element =
  ## Wraps children and stacks the lines from the opposite cross-axis edge.
  result = e
  let n = e.node
  if n != nil:
    n.wrap = true
    n.wrapReverse = true

proc alignContent*(e: Element; value: Align): Element =
  ## Positions wrapped lines across the container's cross axis.
  result = e
  let n = e.node
  if n != nil:
    n.alignContent = value

proc reverse*(e: Element): Element =
  ## Lays out row children from right to left, or column children bottom to top.
  ## Justify.Start then uses the right or bottom edge as the main-axis start.
  result = e
  let n = e.node
  if n != nil:
    n.reverse = true

proc alignItems*(e: Element; value: Align): Element =
  result = e
  let n = e.node
  if n != nil:
    n.align = value
    n.alignSet = true

proc alignSelf*(e: Element; value: Align): Element =
  result = e
  let n = e.node
  if n != nil:
    n.selfAlign = value

proc absolute*(e: Element): Element =
  ## Removes this element from its parent's flow and positions it by its insets.
  result = e
  let n = e.node
  if n != nil:
    n.absolute = true

proc updateInset(e: Element; side: int; value: UiLength): Element =
  result = e
  let n = e.node
  if n != nil:
    n.inset[side] = value
    n.unlog(side, logInset)

proc top*(e: Element; value: float32): Element =
  ## Sets the top inset, or moves an in-flow element down.
  e.updateInset(0, pixels(value))

proc right*(e: Element; value: float32): Element =
  ## Sets the right inset, or moves an in-flow element left.
  e.updateInset(1, pixels(value))

proc bottom*(e: Element; value: float32): Element =
  ## Sets the bottom inset, or moves an in-flow element up.
  e.updateInset(2, pixels(value))

proc left*(e: Element; value: float32): Element =
  ## Sets the left inset, or moves an in-flow element right.
  e.updateInset(3, pixels(value))

proc topPercent*(e: Element; value: float32): Element =
  ## Sets the top inset as a percentage of its parent's height.
  e.updateInset(0, percent(value))

proc rightPercent*(e: Element; value: float32): Element =
  ## Sets the right inset as a percentage of its parent's width.
  e.updateInset(1, percent(value))

proc bottomPercent*(e: Element; value: float32): Element =
  ## Sets the bottom inset as a percentage of its parent's height.
  e.updateInset(2, percent(value))

proc leftPercent*(e: Element; value: float32): Element =
  ## Sets the left inset as a percentage of its parent's width.
  e.updateInset(3, percent(value))

proc center*(e: Element): Element =
  discard e.justify(Align.Center)
  e.alignItems(Align.Center)

proc setPadding(e: Element; values: array[4, float32]): Element =
  result = e
  let n = e.node
  if n != nil:
    n.pad = values
    n.logical = n.logical and not logPad

proc padding*(e: Element; all: float32): Element =
  e.setPadding([all, all, all, all])

proc padding*(e: Element; vertical, horizontal: float32): Element =
  e.setPadding([vertical, horizontal, vertical, horizontal])

proc padding*(e: Element; top, right, bottom, left: float32): Element =
  e.setPadding([top, right, bottom, left])

proc paddingX*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.pad[1] = value
    n.pad[3] = value
    n.logical = n.logical and not logPad

proc paddingY*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.pad[0] = value
    n.pad[2] = value

proc setMargin(e: Element; values: array[4, float32]): Element =
  result = e
  let n = e.node
  if n != nil:
    n.margin = values
    n.logical = n.logical and not logMargin

proc margin*(e: Element; all: float32): Element =
  e.setMargin([all, all, all, all])

proc margin*(e: Element; vertical, horizontal: float32): Element =
  e.setMargin([vertical, horizontal, vertical, horizontal])

proc margin*(e: Element; top, right, bottom, left: float32): Element =
  e.setMargin([top, right, bottom, left])

proc propagateTextAreaStyle(e: Element) =
  let node = e.node
  if node == nil or node.textClient == nil or e.owner == nil:
    return
  var slot = int(node.firstChild)
  while slot > 0 and slot < e.owner.nodes.len:
    let next = int(e.owner.nodes[slot].nextSibling)
    var child = addr e.owner.nodes[slot]
    if child.textAreaOwner != node.textClient:
      slot = next
      continue
    child[].textStyle = node.textStyle
    child[].textColor = node.textColor
    child[].textColorSet = node.textColorSet
    child[].textAlign = node.textAlign
    child[].rightToLeft = node.rightToLeft
    slot = next

proc textSize*(e: Element; value: float32): Element =
  ## Sets the text font size in DIPs; zero selects the system default.
  result = e
  let n = e.node
  if n != nil:
    n.textStyle.size = if classify(value) notin {fcNan, fcInf, fcNegInf}:
        max(value, 0'f32)
      else:
        0'f32
    n.textSizeSet = n.textStyle.size > 0
    if n.hasText or n.textClient != nil:
      e.propagateTextAreaStyle()

proc noWrap*(e: Element): Element =
  ## Keeps text on one line, allowing it to extend beyond its element.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textNoWrap = true

proc textColor*(e: Element; value: Color): Element =
  ## Sets the text color.
  result = e
  let n = e.node
  if n != nil:
    n.textColor = value
    n.textColorSet = true
    if n.icon:
      n.vectorColor = value
    if n.hasText or n.textClient != nil:
      e.propagateTextAreaStyle()

proc textFamily*(e: Element; value: string): Element =
  ## Selects a font family for the text.
  result = e
  let n = e.node
  if n != nil and (n.hasText or n.textClient != nil):
    n.textStyle.family = value
    n.textFamilySet = value.len > 0
    e.propagateTextAreaStyle()

proc textWeight*(e: Element; value: int): Element =
  ## Sets the text font weight from 100 to 900; zero selects the default.
  result = e
  let n = e.node
  if n != nil and (n.hasText or n.textClient != nil):
    n.textStyle.weight = if value <= 0: 0 else: max(100, min(value, 900))
    n.textWeightSet = n.textStyle.weight > 0
    e.propagateTextAreaStyle()

proc textItalic*(e: Element; value = true): Element =
  ## Toggles italic text.
  result = e
  let n = e.node
  if n != nil and (n.hasText or n.textClient != nil):
    n.textStyle.italic = value
    n.textItalicSet = value
    e.propagateTextAreaStyle()

proc textAlign*(e: Element; value: Align): Element =
  ## Aligns text to Start, Center, or End within its element.
  result = e
  let n = e.node
  if n != nil and (n.hasText or n.textClient != nil):
    n.textAlign = value
    e.propagateTextAreaStyle()

proc onClick*(e: Element; handler: proc() {.closure.}): Element =
  ## Runs handler for pointer clicks and Enter/Space activation on e.
  result = e
  let n = e.node
  if n != nil:
    n.clickHandler = if handler == nil: nil else:
      proc(mods: platform.Modifiers) = handler()
    if handler != nil:
      n.focusable = true

proc onClick*(e: Element;
              handler: proc(mods: platform.Modifiers) {.closure.}): Element =
  ## Runs handler for clicks and passes the modifiers held on pointer down.
  result = e
  let n = e.node
  if n != nil:
    n.clickHandler = handler
    if handler != nil:
      n.focusable = true

proc inputMethod*(e: Element; on: bool): Element =
  ## Controls whether focused text accepts input-method composition.
  result = e
  let n = e.node
  if n != nil:
    n.noInputMethod = not on

proc cursor*(e: Element; value: platform.Cursor): Element =
  ## Sets the pointer cursor while the pointer is over e.
  result = e
  let n = e.node
  if n != nil:
    n.pointerCursor = value
    n.pointerCursorSet = true

proc buttonBase*(c: Context): Element =
  ## Creates a button without a look. Use clicked() or onClick() to respond;
  ## the button activates with pointer, Enter, Space, and accessibility input.
  result = c.row().center().focusable().shrink(0)
    .onClick(proc() = discard)

proc focusGroup*(e: Element; orientation: FocusOrientation;
                 selects = false): Element =
  ## Makes focusable descendants one Tab stop. Arrow keys move within the
  ## group, and Home and End move to its first and last members. When selects
  ## is true, moving focus activates the member it moves to.
  result = e
  let n = e.node
  if n != nil:
    n.focusGroupSet = true
    n.focusOrientation = orientation
    n.groupSelects = selects

proc radioGroup*(c: Context; build: proc() {.closure.}; row = false): Element =
  ## Creates one Tab stop for radioBase options. Arrows, Home, and End move
  ## focus and choose the corresponding option. Set a label on the result;
  ## pass row = true to lay out options horizontally.
  let container = if row: c.row() else: c.column()
  result = container.focusGroup(FocusOrientation.Both, selects = true)
  let n = result.node
  if n != nil:
    n.accessRole = platform.roleRadioGroup
    n.accessRoleSet = true
  result = result.children(build)

proc markBoundValueChanged(e: Element) =
  let n = e.node
  if n != nil:
    n[].changed = true
    n[].valueChangedInBuild = true
    if e.owner.invalidate != nil:
      e.owner.invalidate()

proc sliderDecimals(value: float64): int =
  let parts = formatFloat(abs(value), ffScientific, -1).split('e')
  if parts.len != 2:
    return 15
  let exponent = parseInt(parts[1])
  let point = parts[0].find('.')
  let digits = if point < 0: 0 else: parts[0].len - point - 1
  max(digits - exponent, 0)

proc snapSliderValue(value, low, high, step: float64): float64 =
  if high <= low:
    return low
  result = min(max(value, low), high)
  if step <= 0:
    return
  result = low + round((result - low) / step) * step
  if result > high:
    result -= step
  let precision = max(sliderDecimals(step), sliderDecimals(low))
  if precision < 15:
    try:
      result = parseFloat(formatFloat(result, ffDecimal, precision))
    except ValueError:
      discard

proc step*(e: Element; value: float64): Element =
  ## Sets the slider's keyboard and accessibility increment, and pointer snap.
  result = e
  let n = e.node
  if n != nil and n[].slider and classify(value) notin
      {fcNan, fcInf, fcNegInf} and value > 0:
    n[].sliderStep = value

proc vertical*(e: Element): Element =
  ## Makes a SliderBase run from low at the bottom to high at the top.
  result = e
  let n = e.node
  if n != nil and n[].slider:
    n[].sliderVertical = true

proc sliderBase*(c: Context; value: var float64; low, high: float64): Element =
  ## Creates a slider without a look. Drag it or use arrows, Page Up/Down,
  ## Home, and End to change the value; step sets the increment and snap.
  ## Call changed() or register onChange() to observe edits in this build.
  if classify(low) in {fcNan, fcInf, fcNegInf} or
      classify(high) in {fcNan, fcInf, fcNegInf} or low > high or
      classify(high - low) in {fcNan, fcInf, fcNegInf} or
      classify(value) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: slider values and range must be finite")
  result = c.box().focusable()
  let n = result.node
  if n == nil:
    return
  n[].slider = true
  n[].sliderLow = low
  n[].sliderHigh = high
  n[].sliderStep = (high - low) / 100
  n[].sliderClampLow = low
  n[].sliderClampHigh = high
  n[].accessRole = platform.roleSlider
  n[].accessRoleSet = true
  if result.owner.pendingSliderValues.hasKey(n[].identity):
    let pending = result.owner.pendingSliderValues[n[].identity]
    let next = min(max(pending, low), high)
    if next != value:
      value = next
      result.markBoundValueChanged()
  n[].sliderValue = value

proc checkboxBase*(c: Context; checked: var bool): Element =
  ## Creates a check box without a look. Style its contents and set a label;
  ## pointer, Space, or accessibility activation toggles checked and reports
  ## changed() during this frame's build.
  result = c.row().focusable()
  let node = result.node
  if node == nil:
    return
  result = result.onClick(proc() = discard)
  let n = result.node
  if n != nil:
    if n[].clicked:
      checked = not checked
      result.markBoundValueChanged()
    n.activateEnter = false
    n.accessRole = platform.roleCheckBox
    n.accessRoleSet = true
    if checked:
      n.accessExtraStates = n.accessExtraStates or platform.accessChecked

proc switchBase*(c: Context; on: var bool): Element =
  ## Creates a switch without a look. Style its contents and set a label;
  ## pointer, Space, or accessibility activation toggles on and reports
  ## changed() during this frame's build.
  result = c.row().focusable()
  let node = result.node
  if node == nil:
    return
  result = result.onClick(proc() = discard)
  let n = result.node
  if n != nil:
    if n[].clicked:
      on = not on
      result.markBoundValueChanged()
    n.activateEnter = false
    n.accessRole = platform.roleSwitch
    n.accessRoleSet = true
    if on:
      n.accessExtraStates = n.accessExtraStates or platform.accessChecked

proc toggleBase*(c: Context; on: var bool): Element =
  ## Creates a toggle button without a look. Pointer or Space activation
  ## changes on and reports changed() in this build; set a label for access.
  result = c.row().focusable()
  let node = result.node
  if node == nil:
    return
  result = result.onClick(proc() = discard)
  let n = result.node
  if n != nil:
    if n[].clicked:
      on = not on
      result.markBoundValueChanged()
    n.activateEnter = false
    n.accessRole = platform.roleToggleButton
    n.accessRoleSet = true
    if on:
      n.accessExtraStates = n.accessExtraStates or platform.accessChecked

proc radioBase*[T](c: Context; selected: var T; value: T): Element =
  ## Creates a radio option without a look. Style its contents and set a
  ## label; pointer, Space, or accessibility activation selects value and
  ## reports changed() during this frame's build.
  result = c.row().focusable()
  let node = result.node
  if node == nil:
    return
  result = result.onClick(proc() = discard)
  let n = result.node
  if n != nil:
    if n[].clicked and selected != value:
      selected = value
      result.markBoundValueChanged()
    n.activateEnter = false
    n.accessRole = platform.roleRadio
    n.accessRoleSet = true
    if selected == value:
      n.accessExtraStates = n.accessExtraStates or platform.accessChecked

proc delegatedControl(e: Element): Element

proc changed*(e: Element): bool =
  ## Reports a value change delivered to this element in the current build.
  let n = e.delegatedControl().node
  n != nil and n[].changed

proc submitted*(e: Element): bool =
  ## Reports a submission delivered to this element in the current build.
  let n = e.delegatedControl().node
  n != nil and n[].submitted

proc delegatedControl(e: Element): Element =
  result = e
  let n = e.node
  if n == nil:
    return
  let slot = int(n[].fieldControlSlot)
  if slot > 0 and slot < e.owner.nodes.len:
    result = Element(owner: e.owner, slot: uint32(slot),
                     generation: e.generation)

proc onChange*(e: Element; action: proc() {.closure.}): Element =
  ## Runs when input changes this element. Bound controls report synchronous
  ## edits during the build; text-field edits report after syncing on next build.
  result = e
  let target = e.delegatedControl()
  let n = target.node
  if n != nil and action != nil:
    target.owner.actions.add(UiAction(identity: n[].identity,
      generation: target.generation, kind: actionChange, action: action))
    if n[].valueChangedInBuild:
      action()

proc onSubmit*(e: Element; action: proc() {.closure.}): Element =
  ## Runs when Enter submits the focused text input on this element.
  result = e
  let target = e.delegatedControl()
  let n = target.node
  if n != nil and action != nil:
    target.owner.actions.add(UiAction(identity: n[].identity,
      generation: target.generation, kind: actionSubmit, action: action))

proc onShortcut*(e: Element; mods: platform.Modifiers; key: platform.Key;
                 action: proc() {.closure.}): Element =
  ## Runs action when this element or one of its descendants has focus.
  result = e
  let n = e.node
  if n != nil and action != nil:
    e.owner.actions.add(UiAction(
      identity: n[].identity, generation: e.generation, kind: actionShortcut,
      modifiers: mods, key: key, action: action))

proc label*(e: Element; value: string): Element =
  ## Gives an element an accessible name.
  result = e
  var n = e.node
  if n != nil:
    let slot = int(n[].labelTargetSlot)
    if slot > 0 and slot < e.owner.nodes.len:
      n = addr e.owner.nodes[slot]
    else:
      n = e.delegatedControl().node
  else:
    n = e.delegatedControl().node
  if n != nil:
    n.label = value

proc fit*(e: Element; value: Fit): Element =
  ## Sets how an image fills its element.
  result = e
  let n = e.node
  if n != nil and (n.bitmap != nil or n.vector != nil):
    n.fit = value

proc pixelated*(e: Element): Element =
  ## Uses nearest-neighbor sampling for enlarged bitmap pixels.
  result = e
  let n = e.node
  if n != nil and n.bitmap != nil:
    n.bitmap.pixelated = true

proc grayscale*(e: Element): Element =
  ## Draws bitmap or SVG pixels in shades of gray.
  result = e
  let n = e.node
  if n != nil and (n.bitmap != nil or n.vector != nil):
    n.grayscale = true

proc tint*(e: Element; value: Color): Element =
  ## Multiplies bitmap or SVG pixels by a straight color and alpha.
  ## Color() removes the tint.
  result = e
  let n = e.node
  if n != nil and (n.bitmap != nil or n.vector != nil):
    n.imageTint = value

proc svgColor*(e: Element; value: Color): Element =
  ## Sets the color SVG shapes use for `currentColor`.
  result = e
  let n = e.node
  if n != nil and n.vector != nil:
    n.vectorColor = value

proc marginX*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.margin[1] = value
    n.margin[3] = value
    n.logical = n.logical and not logMargin

proc marginY*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.margin[0] = value
    n.margin[2] = value
