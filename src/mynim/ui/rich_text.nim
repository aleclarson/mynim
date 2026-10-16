## Styled text runs for a single native text element.

proc finiteRichText(value: float32): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc normalizeRichTextSpan(span: Span): Span =
  result = span
  if not result.size.finiteRichText or result.size <= 0:
    result.size = 0
  if result.weight <= 0:
    result.weight = 0
  else:
    result.weight = max(100, min(result.weight, 900))
  if not result.letterSpacing.finiteRichText:
    result.letterSpacing = 0
  if not result.objectWidth.finiteRichText or result.objectWidth <= 0:
    result.objectWidth = 0
    result.objectHeight = 0
  elif not result.objectHeight.finiteRichText or result.objectHeight < 0:
    result.objectHeight = 0
  if not result.decorationThickness.finiteRichText or
      result.decorationThickness <= 0:
    result.decorationThickness = 0
  if not result.radius.finiteRichText or result.radius <= 0:
    result.radius = 0

proc encodeRichTextSpans(spans: openArray[Span]): string =
  var styles: seq[textStack.Span]
  var ending = 0
  for span in spans:
    ending += span.text.runeLen
    styles.add(textStack.Span(`end`: ending, family: span.font,
      size: span.size, weight: span.weight, italic: span.italic,
      letterSpacing: span.letterSpacing, features: span.features,
      lang: span.lang, objectWidth: span.objectWidth,
      objectHeight: span.objectHeight))
  textStack.encodeSpans(styles)

proc overRichTextSpan(span, base: Span): Span =
  result = span
  if result.font.len == 0: result.font = base.font
  if result.size == 0: result.size = base.size
  if result.weight == 0: result.weight = base.weight
  if result.color.a == 0: result.color = base.color
  if result.decorationColor.a == 0:
    result.decorationColor = base.decorationColor
  if result.decorationThickness == 0:
    result.decorationThickness = base.decorationThickness
  if result.background.a == 0: result.background = base.background
  if result.letterSpacing == 0:
    result.letterSpacing = base.letterSpacing
  if result.features.len == 0: result.features = base.features
  if result.lang.len == 0: result.lang = base.lang
  if result.radius == 0: result.radius = base.radius
  result.italic = result.italic or base.italic
  result.underline = result.underline or base.underline
  result.wavyUnderline = result.wavyUnderline or base.wavyUnderline
  result.strikethrough = result.strikethrough or base.strikethrough

proc richTextBase(node: ElementNode; inherited: Span): Span =
  result = inherited
  if node.textFamilySet:
    result.font = node.textStyle.family
  if node.textSizeSet:
    result.size = node.textStyle.size
  if node.textWeightSet:
    result.weight = node.textStyle.weight
  if node.textItalicSet:
    result.italic = true
  if node.textColorSet:
    result.color = node.textColor
  if node.backgroundSet and not node.hasGradient:
    result.background = node.background
    result.radius = max(node.radius)

proc richTextSpanAlpha(span: var Span; alpha: float32) =
  if alpha >= 1:
    return
  span.color = span.color.alpha(alpha)
  span.background = span.background.alpha(alpha)
  span.decorationColor = span.decorationColor.alpha(alpha)

proc isInlineTextNode(node: ElementNode): bool =
  node.hasText and node.textClient == nil and node.textAreaOwner == nil

proc collectInlineText(nodes: var seq[ElementNode]; slot, root: int;
                       text: var string; spans: var seq[Span];
                       ending: var int; inherited: Span;
                       inheritedAlpha: float32; disabledSeen: bool) =
  let node = nodes[slot]
  let start = ending
  let byteStart = text.len
  let base = if slot == root: inherited else: node.richTextBase(inherited)
  var alpha = inheritedAlpha
  var hasDisabled = disabledSeen
  if slot != root:
    if node.opacitySet:
      alpha *= node.opacity
    if node.disabled and not hasDisabled:
      alpha *= 0.5'f32
      hasDisabled = true

  var ownSpans = node.textOwnSpans
  if ownSpans.len == 0 and node.textOwnValue.len > 0:
    ownSpans.add(Span(text: node.textOwnValue))
  for source in ownSpans:
    var span = source.overRichTextSpan(base)
    span.richTextSpanAlpha(alpha)
    spans.add(span)
    text.add(source.text)
    ending += source.text.runeLen

  var child = int(node.firstChild)
  var hasInlineChildren = false
  while child >= 0:
    if nodes[child].isInlineTextNode:
      hasInlineChildren = true
      nodes.collectInlineText(child, root, text, spans, ending, base,
        alpha, hasDisabled)
    child = int(nodes[child].nextSibling)

  if slot != root:
    nodes[slot].textInline = true
    nodes[slot].textInlineRoot = int32(root)
    nodes[slot].textInlineStart = start
    nodes[slot].textInlineEnd = ending
    nodes[slot].textValue = if text.len > byteStart:
        text[byteStart .. ^1]
      else:
        ""
  nodes[slot].textInlineParagraph = hasInlineChildren

proc prepareInlineText(nodes: var seq[ElementNode]) =
  for node in nodes.mitems:
    node.textInline = false
    node.textInlineParagraph = false
    node.textInlineRoot = -1
    node.textInlineStart = 0
    node.textInlineEnd = 0
    node.textInlineRects.setLen(0)

  for slot in 0..<nodes.len:
    if not nodes[slot].isInlineTextNode or nodes[slot].textInline:
      continue
    var hasInlineChildren = false
    var child = int(nodes[slot].firstChild)
    while child >= 0:
      if nodes[child].isInlineTextNode:
        hasInlineChildren = true
        break
      child = int(nodes[child].nextSibling)
    if not hasInlineChildren:
      continue

    var base = Span()
    base = nodes[slot].richTextBase(base)
    base.background = transparent
    base.radius = 0
    if not nodes[slot].textColorSet:
      var ancestor = int(nodes[slot].parent)
      while ancestor > 0 and ancestor < nodes.len:
        if nodes[ancestor].listRowSelected:
          base.color = nodes[ancestor].listSelectedTextColor
          break
        ancestor = int(nodes[ancestor].parent)
      if base.color.a == 0:
        base.color = nodes[slot].textColor
    var text = ""
    var spans: seq[Span]
    var ending = 0
    let rootDisabled = nodes[slot].disabled
    nodes.collectInlineText(slot, slot, text, spans, ending, base, 1'f32,
      rootDisabled)
    nodes[slot].textValue = text
    nodes[slot].textSpans = spans
    nodes[slot].textSpanEnds.setLen(0)
    ending = 0
    for span in spans:
      ending += span.text.runeLen
      nodes[slot].textSpanEnds.add(ending)
    nodes[slot].textSpanStyles = encodeRichTextSpans(spans)

proc unionRichTextRects(a, b: Rect): Rect =
  let x0 = min(a.x, b.x)
  let y0 = min(a.y, b.y)
  let x1 = max(a.x + a.w, b.x + b.w)
  let y1 = max(a.y + a.h, b.y + b.h)
  Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc placeInlineText(nodes: var seq[ElementNode]; rects: var seq[Rect]) =
  for slot in 1..<nodes.len:
    if not nodes[slot].textInline:
      continue
    nodes[slot].textInlineRects.setLen(0)
    let root = int(nodes[slot].textInlineRoot)
    if root < 0 or root >= nodes.len or nodes[root].shapedText == nil:
      continue
    let paragraph = nodes[root]
    let originX = rects[root].x + paragraph.pad[3] + paragraph.border[3]
    let originY = rects[root].y + paragraph.pad[0] + paragraph.border[0]
    var box: Rect
    var hasBox = false
    for selection in paragraph.shapedText.appendSelection(@[],
        nodes[slot].textInlineStart, nodes[slot].textInlineEnd, false):
      let fragment = Rect(x: originX + selection.x,
        y: originY + selection.y, w: selection.w, h: selection.h)
      nodes[slot].textInlineRects.add(fragment)
      if hasBox:
        box = unionRichTextRects(box, fragment)
      else:
        box = fragment
        hasBox = true
    rects[slot] = if hasBox: box else: Rect(x: originX, y: originY)

proc richSpanAt(node: ElementNode; rune: int): int =
  var lo = 0
  var hi = node.textSpanEnds.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if node.textSpanEnds[mid] <= rune:
      lo = mid + 1
    else:
      hi = mid
  if lo < node.textSpanEnds.len: lo else: -1

proc richText*(c: Context; spans: varargs[Span]): Element =
  ## Adds a paragraph of styled spans; text children continue this paragraph.
  result = c.newElement(false, identityKindText)
  let node = result.node
  if node == nil:
    return
  node.hasText = true
  node.textColor = if c.themeEnabled: c.theme.text else: rgb(0, 0, 0)
  if c.themeEnabled:
    if c.theme.font.len > 0:
      node.textStyle.family = c.theme.font
    node.textStyle.size = c.theme.fontSize
  node.textSpans = newSeqOfCap[Span](spans.len)
  node.textSpanEnds = newSeqOfCap[int](spans.len)
  var ending = 0
  for source in spans:
    let span = normalizeRichTextSpan(source)
    node.textSpans.add(span)
    node.textValue.add(span.text)
    ending += span.text.runeLen
    node.textSpanEnds.add(ending)
  node.textOwnValue = node.textValue
  node.textOwnSpans = node.textSpans
  node.textSpanStyles = encodeRichTextSpans(node.textSpans)

proc measureText*(c: Context; width: float32; spans: varargs[Span]):
    tuple[width, height: float32] =
  ## Measures styled spans in DIPs; zero width wraps only at newlines.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  var text = ""
  var normalized = newSeqOfCap[Span](spans.len)
  for source in spans:
    let span = normalizeRichTextSpan(source)
    normalized.add(span)
    text.add(span.text)
  var style: textStack.Style
  if c.themeEnabled:
    if c.theme.font.len > 0:
      style.family = c.theme.font
    style.size = c.theme.fontSize
  let shaped = textStack.shared().layout(textStack.Params(
    text: text, style: style,
    width: if width.finiteRichText: max(width, 0'f32) else: 0'f32,
    spans: encodeRichTextSpans(normalized)))
  (shaped.width, shaped.height)
