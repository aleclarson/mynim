## Shapes text for custom painting and draws those shaped glyphs into the
## current GPU scene.

type
  Font* = object
    ## A font for text shaped with `shape` and drawn with `glyphs`.
    family*: string
    size*: float32
    weight*: int
    italic*: bool
    features*: string
    lang*: string
    thicken*: bool
    antialiased*: bool

  FontMetrics* = object
    ## Vertical font metrics in DIPs.
    ascent*, descent*, lineGap*: float32

  Glyph* = object
    ## A shaped glyph and the runes of its text cluster.
    cluster*, runes*: int
    x*, advance*: float32
    font: textStack.Font
    id: uint32
    thicken, antialiased: bool

proc textStyle(font: Font): textStack.Style =
  textStack.Style(family: font.family, size: font.size,
    weight: font.weight, italic: font.italic, features: font.features,
    lang: font.lang)

proc metrics*(font: Font): FontMetrics =
  ## Returns the ascent, descent, and line gap for this font in DIPs.
  let (ascent, descent, lineHeight) = textStack.shared().metrics(font.textStyle)
  FontMetrics(ascent: ascent, descent: descent,
    lineGap: max(lineHeight - ascent - descent, 0'f32))

proc shape*(text: string; font: Font): seq[Glyph] =
  ## Shapes text without wrapping or retaining a layout cache. Keep the
  ## returned glyphs when drawing the same text in later frames.
  let layout = textStack.shared().shape(textStack.Params(text: text,
    style: font.textStyle, noWrap: true, keepSpaces: true))
  for line in layout.lines:
    for glyph in line.glyphs:
      result.add(Glyph(cluster: glyph.cluster, runes: glyph.runes,
        x: line.x + glyph.x, advance: glyph.advance, font: glyph.font,
        id: glyph.id, thicken: font.thicken,
        antialiased: font.antialiased))

proc addPaintedGlyph(painter: var Painter; image: textStack.GlyphImage;
    x, baseline: float32; color: Color; wide: uint16) =
  if not image.ok:
    return
  painter.frame.glyphs.add(scene.Glyph(x: floor(x) + image.left,
    y: baseline + image.top, w: float32(image.w), h: float32(image.h),
    u: image.x, v: image.y, uw: image.w, vh: image.h,
    color: sceneColor(color), wide: wide, colored: image.colored,
    subpixel: image.subpixel, thin: image.thin))

proc glyphs*(painter: var Painter; shaped: openArray[Glyph];
             x, baselineY: float32; color: Color) =
  ## Draws shaped glyphs from x at the baseline baselineY, in DIPs.
  if painter.frame == nil or painter.textSystem == nil or shaped.len == 0 or
      color.a == 0 or painter.opacity <= 0:
    return
  let
    scale = painter.scale
    baseline = painter.textSystem.baseline(
      (baselineY - painter.root.y) * scale)
    paintColor = color.alpha(painter.opacity)
    wide = painter.frame.addWide(wideColors(paintColor, transparent,
      transparent))
    baseShade = textStack.shadeOf(color.r, color.g, color.b)
    joins = painter.textSystem.joinsGlyphs()
    first = int32(painter.frame.glyphs.len)

  var i = 0
  while i < shaped.len:
    let glyph = shaped[i]
    if glyph.font.isNil:
      inc i
      continue
    let shade = if glyph.thicken: textStack.Thick
      elif glyph.antialiased: textStack.Flat
      else: baseShade
    if joins:
      var last = i + 1
      while last < shaped.len and shaped[last].font == glyph.font and
          shaped[last].thicken == glyph.thicken and
          shaped[last].antialiased == glyph.antialiased:
        inc last
      var ids = newSeqOfCap[uint32](last - i)
      var pens = newSeqOfCap[float32](last - i)
      for j in i ..< last:
        ids.add(shaped[j].id)
        pens.add((x + shaped[j].x - painter.root.x) * scale)
      let image = painter.textSystem.glyphRun(glyph.font, ids, pens, scale,
        shade, false)
      if image.ok:
        painter.addPaintedGlyph(image, pens[0], baseline, paintColor, wide)
      i = last
    else:
      let pen = (x + glyph.x - painter.root.x) * scale
      let image = painter.textSystem.glyph(glyph.font, glyph.id, scale, pen,
        shade, false)
      painter.addPaintedGlyph(image, pen, baseline, paintColor, wide)
      inc i

  if painter.frame.glyphs.len > int(first):
    painter.frame.ops.add(scene.Op(kind: scene.opGlyphs, first: first,
      last: int32(painter.frame.glyphs.len)))
