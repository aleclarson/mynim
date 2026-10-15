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

proc measureTree(nodes: seq[ElementNode]; natural: var seq[NaturalSize]) =
  natural.setLen(nodes.len)
  if nodes.len == 0:
    return

  for slot in countdown(nodes.high, 0):
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

    if childCount > 1:
      if node.row:
        contentW += node.gapX * float32(childCount - 1)
      else:
        contentH += node.gapY * float32(childCount - 1)

    let width = node.width.resolve(-1)
    let height = node.height.resolve(-1)
    let rawW = if width.ok: width.value else: contentW + node.contentInsetX
    let rawH = if height.ok: height.value else: contentH + node.contentInsetY
    natural[slot] = NaturalSize(
      w: node.clampWidth(rawW, -1),
      h: node.clampHeight(rawH, -1))

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

proc distribute(nodes: seq[ElementNode]; parent: int;
                sizes, minimum, maximum, factors: var seq[float32];
                amount: float32; growing: bool) =
  var remaining = amount
  for _ in 0..nodes.len:
    var totalFactor: float32
    var child = int(nodes[parent].firstChild)
    while child >= 0:
      let room = if growing:
          maximum[child] - sizes[child]
        else:
          sizes[child] - minimum[child]
      if room > 0 and factors[child] > 0:
        totalFactor += factors[child]
      child = int(nodes[child].nextSibling)
    if totalFactor <= 0 or remaining <= 0:
      break

    var changed: float32
    child = int(nodes[parent].firstChild)
    while child >= 0:
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
      child = int(nodes[child].nextSibling)
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
               base: float32; available, margins: float32;
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
  if not resolved.ok and align == Align.Stretch and not autoMargin:
    value = max(available - margins, 0'f32)
  clampSize(value, minimum, maximum, base)

proc placeNode(nodes: seq[ElementNode]; natural: seq[NaturalSize];
               rects: var seq[Rect]; sizes, bases, minimum, maximum,
               factors: var seq[float32]; slot: int; bounds: Rect) =
  rects[slot] = bounds
  let node = nodes[slot]
  var child = int(node.firstChild)
  var childCount = 0
  while child >= 0:
    inc childCount
    child = int(nodes[child].nextSibling)
  if childCount == 0:
    return

  let row = node.row
  let innerX = bounds.x + node.pad[3] + node.border[3]
  let innerY = bounds.y + node.pad[0] + node.border[0]
  let innerW = max(bounds.w - node.contentInsetX, 0'f32)
  let innerH = max(bounds.h - node.contentInsetY, 0'f32)
  let mainSize = if row: innerW else: innerH
  let crossSize = if row: innerH else: innerW
  let gap = if row: node.gapX else: node.gapY
  let mainStart = if row: 3 else: 0
  let mainEnd = if row: 1 else: 2
  let crossStart = if row: 0 else: 3
  let crossEnd = if row: 2 else: 1

  var outerMain, gaps: float32
  if childCount > 1:
    gaps = gap * float32(childCount - 1)

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
    let childNode = nodes[childSlot]
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
    outerMain += sizes[childSlot] + marginMain
    child = int(childNode.nextSibling)

  var free = mainSize - gaps - outerMain
  if free > 0:
    child = int(node.firstChild)
    while child >= 0:
      factors[child] = nodes[child].grow
      child = int(nodes[child].nextSibling)
    distribute(nodes, slot, sizes, minimum, maximum, factors, free, true)
  elif free < 0:
    child = int(node.firstChild)
    while child >= 0:
      factors[child] = nodes[child].shrink * max(bases[child], 0'f32)
      child = int(nodes[child].nextSibling)
    distribute(nodes, slot, sizes, minimum, maximum, factors, -free, false)

  outerMain = gaps
  var autoMainMargins = 0
  child = int(node.firstChild)
  while child >= 0:
    let childNode = nodes[child]
    outerMain += sizes[child] +
      (if row: childNode.marginX else: childNode.marginY)
    if childNode.margin[mainStart] == Auto:
      inc autoMainMargins
    if childNode.margin[mainEnd] == Auto:
      inc autoMainMargins
    child = int(childNode.nextSibling)
  free = max(mainSize - outerMain, 0'f32)
  let autoMain = if autoMainMargins > 0:
      free / float32(autoMainMargins)
    else:
      0'f32
  let justifyFree = if autoMainMargins > 0: 0'f32 else: free
  let offsets = justifyOffsets(node.justify, justifyFree, childCount)
  var position = offsets.start
  let between = offsets.between
  let defaultAlign = if node.align == Align.Auto: Align.Stretch else: node.align

  child = int(node.firstChild)
  while child >= 0:
    let childSlot = child
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
    let crossBase = if row: innerH else: innerW
    let crossExtent = childNode.crossSize(childNatural, row,
      crossBase, crossSize, crossMargins, childAlign)
    let crossFree = crossSize - crossExtent - crossMargins
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
    crossOffset += crossBefore

    let mainOffset = position + mainBefore
    var childRect: Rect
    if row:
      childRect = Rect(x: innerX + mainOffset, y: innerY + crossOffset,
        w: sizes[childSlot], h: crossExtent)
    else:
      childRect = Rect(x: innerX + crossOffset, y: innerY + mainOffset,
        w: crossExtent, h: sizes[childSlot])
    placeNode(nodes, natural, rects, sizes, bases, minimum, maximum,
      factors, childSlot, childRect)
    position += mainBefore + sizes[childSlot] + mainAfter + gap + between
    child = int(childNode.nextSibling)

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
  shapeText(c.owner.nodes)
  measureTree(c.owner.nodes, c.owner.natural)
  if c.owner.nodes.len > 0:
    var stable = false
    for attempt in 0..1:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, 0, result.root)
      if not shapeTextToBounds(c.owner.nodes, c.owner.rectScratch):
        stable = true
        break
      measureTree(c.owner.nodes, c.owner.natural)
    if not stable:
      placeNode(c.owner.nodes, c.owner.natural, c.owner.rectScratch,
        c.owner.flexSizes, c.owner.flexBases, c.owner.flexMin,
        c.owner.flexMax, c.owner.flexFactors, 0, result.root)
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
  for slot in countdown(layout.rects.high, 1):
    if layout.owner.nodes[slot].clickHandler != nil and
        layout.rects[slot].contains(x, y):
      return Element(owner: layout.owner, slot: uint32(slot),
                     generation: layout.generation)

proc dispatchClick(layout: LayoutResult; pressed: Element;
                   x, y: float32): bool =
  if pressed.owner == nil or pressed.owner != layout.owner or
      pressed.generation != layout.generation:
    return false
  let target = layout.targetAt(x, y)
  if target.owner != pressed.owner or target.slot != pressed.slot or
      target.generation != pressed.generation:
    return false
  let handler = layout.owner.nodes[int(target.slot)].clickHandler
  if handler == nil:
    return false
  handler()
  true

proc len*(layout: LayoutResult): int = max(layout.rects.len - 1, 0)

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
