## Flex layout and element sizing for the frame tree.

type LayoutDimension = enum
  ldWidth, ldHeight, ldMinWidth, ldMinHeight, ldMaxWidth, ldMaxHeight

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
  let system = textStack.shared()
  for node in nodes.mitems:
    if not node.hasText:
      continue
    node.shapedText = system.layout(textStack.Params(text: node.textValue,
      style: node.textStyle, keepSpaces: true))

proc shapeTextToBounds(nodes: var seq[ElementNode]; rects: seq[Rect]): bool =
  let system = textStack.shared()
  for slot, node in nodes.mpairs:
    if not node.hasText:
      continue
    let width = max(rects[slot].w - node.contentInsetX, 0'f32)
    if width > 0 and node.shapedText.params.width != width:
      var params = node.shapedText.params
      params.width = width
      node.shapedText = system.layout(params)
      result = true

proc measureTree(nodes: seq[ElementNode]; natural: var seq[NaturalSize];
                 constraints: seq[Rect] = @[]): bool =
  natural.setLen(nodes.len)
  if nodes.len == 0:
    return

  for slot in countdown(nodes.high, 0):
    let previous = natural[slot]
    let node = nodes[slot]
    var contentW, contentH: float32
    if node.hasText and node.shapedText != nil:
      contentW = node.shapedText.width
      contentH = node.shapedText.height
    if node.bitmap != nil and node.bitmap.image != nil:
      contentW = max(contentW, float32(node.bitmap.image.w))
      contentH = max(contentH, float32(node.bitmap.image.h))
    if node.vector != nil:
      contentW = max(contentW, node.vector.width)
      contentH = max(contentH, node.vector.height)
    var childCount = 0
    var child = int(node.firstChild)
    while child >= 0:
      let childNode = nodes[child]
      let childSize = natural[child]
      if not childNode.absolute:
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

    var measuredMain = (if node.row: node.width else: node.height).resolve(-1)
    if slot < constraints.len:
      measuredMain = (value: (if node.row: constraints[slot].w
        else: constraints[slot].h), ok: true)
    if node.wrap and measuredMain.ok and childCount > 0:
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
        if not childNode.absolute:
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

proc distribute(nodes: seq[ElementNode]; children: seq[int];
                first, pastLast: int;
                sizes, minimum, maximum, factors: var seq[float32];
                amount: float32; growing: bool) =
  var remaining = amount
  for _ in 0 .. (pastLast - first):
    var totalFactor: float32
    for itemIndex in first ..< pastLast:
      let child = children[itemIndex]
      let room = if growing:
          maximum[child] - sizes[child]
        else:
          sizes[child] - minimum[child]
      if room > 0 and factors[child] > 0:
        totalFactor += factors[child]
    if totalFactor <= 0 or remaining <= 0:
      break

    var changed: float32
    for itemIndex in first ..< pastLast:
      let child = children[itemIndex]
      let room = if growing:
          maximum[child] - sizes[child]
        else:
          sizes[child] - minimum[child]
      if room > 0 and factors[child] > 0:
        let share = remaining * factors[child] / totalFactor
        let delta = min(share, room)
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
                        flexLines: var seq[FlexLine]; parentSlot,
                        childSlot: int; bounds: Rect)

proc placeNode(nodes: seq[ElementNode]; natural: seq[NaturalSize];
               rects: var seq[Rect]; sizes, bases, minimum, maximum,
               factors: var seq[float32]; flexSlots: var seq[int];
               flexLines: var seq[FlexLine]; slot: int; bounds: Rect) =
  rects[slot] = bounds
  let node = nodes[slot]
  var child = int(node.firstChild)
  var totalChildren = 0
  while child >= 0:
    inc totalChildren
    child = int(nodes[child].nextSibling)
  if totalChildren == 0:
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
  let mainStart = if row:
      (if node.reverse: 1 else: 3)
    else:
      (if node.reverse: 2 else: 0)
  let mainEnd = if row:
      (if node.reverse: 3 else: 1)
    else:
      (if node.reverse: 0 else: 2)
  var crossStart = if row: 0 else: 3
  var crossEnd = if row: 2 else: 1
  if node.wrapReverse:
    swap(crossStart, crossEnd)

  var activeLine = FlexLine(first: slotsBase)

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
    let childNode = nodes[childSlot]
    if not childNode.absolute:
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
      if node.wrapReverse:
        crossOffset = crossSize - crossOffset - childCross

      let mainPosition = position + mainBefore
      let mainOffset = if node.reverse:
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
        factors, flexSlots, flexLines, childSlot, childRect)
      position += mainBefore + sizes[childSlot] + mainAfter + gap +
        offsets.between
      inc itemIndex
    linePosition += line.cross + crossGap + lineBetween
    inc lineIndex

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
    let childNode = nodes[childSlot]
    if childNode.absolute:
      placeAbsoluteChild(nodes, natural, rects, sizes, bases, minimum,
        maximum, factors, flexSlots, flexLines, slot, childSlot, bounds)
    child = int(childNode.nextSibling)
  flexSlots.setLen(slotsBase)
  flexLines.setLen(linesBase)

proc placeAbsoluteChild(nodes: seq[ElementNode]; natural: seq[NaturalSize];
                        rects: var seq[Rect]; sizes, bases, minimum, maximum,
                        factors: var seq[float32]; flexSlots: var seq[int];
                        flexLines: var seq[FlexLine]; parentSlot,
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
  elif right.ok:
    x = paddingW - right.value - childW - marginValue(child.margin[1])
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
    factors, flexSlots, flexLines, childSlot, childRect)

proc layout*(c: Context; bounds: Rect): LayoutResult =
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
  shapeText(c.owner.nodes)
  discard measureTree(c.owner.nodes, c.owner.natural)
  if c.owner.nodes.len > 0:
    var stable = false
    for attempt in 0..2:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
        c.owner.flexLines, 0, result.root)
      let textChanged = shapeTextToBounds(c.owner.nodes, c.owner.rectScratch)
      let sizesChanged = measureTree(c.owner.nodes, c.owner.natural,
        c.owner.rectScratch)
      if not textChanged and not sizesChanged:
        stable = true
        break
    if not stable:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, c.owner.flexSlots,
        c.owner.flexLines, 0, result.root)
    for slot in 0..<result.rects.len:
      result.rects[slot] = c.owner.rectScratch[slot]

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
    if slot > 0 and layout.rects[slot].contains(x, y):
      let target = Element(owner: layout.owner, slot: uint32(slot),
                           generation: layout.generation)
      if topmost.owner == nil:
        topmost = target
      if layout.owner.nodes[slot].clickHandler != nil:
        return target
    dec orderIndex
  topmost

proc slotsAt(layout: LayoutResult; x, y: float32): seq[int] =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation or
      layout.rects.len != layout.owner.nodes.len:
    return
  for slot in 1..<layout.rects.len:
    if layout.rects[slot].contains(x, y):
      result.add(slot)

proc dispatchClick(layout: LayoutResult; pressed: Element;
                   x, y: float32; clickedSlot: var int): bool =
  if pressed.owner == nil or pressed.owner != layout.owner or
      layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or layout.generation != layout.owner.generation:
    return false
  let target = layout.targetAt(x, y)
  if target.owner != pressed.owner or target.slot != pressed.slot:
    return false
  clickedSlot = int(target.slot)
  let handler = layout.owner.nodes[clickedSlot].clickHandler
  if handler != nil:
    handler()
  true

proc dispatchAccessPress(layout: LayoutResult; id: uint64): bool =
  if layout.owner == nil or layout.owner.closed or layout.owner.inBuild or
      not layout.owner.hasFrame or
      layout.generation != layout.owner.generation:
    return false
  for slot in 1..<layout.owner.nodes.len:
    if uint64(slot + 1) != id:
      continue
    let handler = layout.owner.nodes[slot].clickHandler
    if handler == nil:
      return false
    handler()
    return true

proc len*(layout: LayoutResult): int = max(layout.rects.len - 1, 0)

proc hovered*(e: Element): bool =
  ## Reports whether the pointer is over this element during the current build.
  ## During a press, only elements under the pointer when the press began stay hovered.
  let n = e.node
  n != nil and n.hovered

proc pressed*(e: Element): bool =
  ## Reports whether a primary press began over this element and remains over it.
  let n = e.node
  n != nil and n.pressed

proc clicked*(e: Element): bool =
  ## Reports a primary pointer or accessibility activation since the previous build.
  let n = e.node
  n != nil and n.clicked

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

proc margin*(e: Element; all: float32): Element =
  e.setMargin([all, all, all, all])

proc margin*(e: Element; vertical, horizontal: float32): Element =
  e.setMargin([vertical, horizontal, vertical, horizontal])

proc margin*(e: Element; top, right, bottom, left: float32): Element =
  e.setMargin([top, right, bottom, left])

proc textSize*(e: Element; value: float32): Element =
  ## Sets the text font size in DIPs; zero selects the system default.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textStyle.size = if classify(value) notin {fcNan, fcInf, fcNegInf}:
        max(value, 0'f32)
      else:
        0'f32

proc textColor*(e: Element; value: Color): Element =
  ## Sets the text color.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textColor = value

proc textFamily*(e: Element; value: string): Element =
  ## Selects a font family for the text.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textStyle.family = value

proc textWeight*(e: Element; value: int): Element =
  ## Sets the text font weight from 100 to 900; zero selects the default.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textStyle.weight = if value <= 0: 0 else: max(100, min(value, 900))

proc textItalic*(e: Element; value = true): Element =
  ## Toggles italic text.
  result = e
  let n = e.node
  if n != nil and n.hasText:
    n.textStyle.italic = value

proc onClick*(e: Element; handler: proc() {.closure.}): Element =
  ## Runs handler when the primary pointer is pressed and released on e.
  result = e
  let n = e.node
  if n != nil:
    n.clickHandler = handler

proc label*(e: Element; value: string): Element =
  ## Gives an element an accessible name.
  result = e
  let n = e.node
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

proc marginY*(e: Element; value: float32): Element =
  result = e
  let n = e.node
  if n != nil:
    n.margin[0] = value
    n.margin[2] = value
