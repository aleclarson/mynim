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
  ## Adds a paragraph made of styled text spans.
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
