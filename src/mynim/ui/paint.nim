## Element decorations and conversion of a completed layout to Mygo's
## GPU-ready scene display list.

const continuousCorners = defined(macosx)

proc finite(value: float32): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

proc nonnegative(value: float32): float32 =
  if not value.finite or value <= 0: 0'f32 else: value

proc background*(e: Element; color: Color): Element =
  ## Sets the element's solid background color.
  result = e
  let n = e.node
  if n != nil:
    n.background = color

proc radius*(e: Element; all: float32): Element =
  ## Rounds all four corners by the same radius in DIPs.
  result = e
  let n = e.node
  if n != nil:
    let value = nonnegative(all)
    n.radius = [value, value, value, value]

proc radius*(e: Element; topLeft, topRight, bottomRight,
             bottomLeft: float32): Element =
  ## Sets corner radii in top-left, top-right, bottom-right, bottom-left order.
  result = e
  let n = e.node
  if n != nil:
    n.radius = [nonnegative(topLeft), nonnegative(topRight),
                nonnegative(bottomRight), nonnegative(bottomLeft)]

proc setBorderWidth(e: Element; values: array[4, float32]): Element =
  result = e
  let n = e.node
  if n != nil:
    for i, value in values:
      n.border[i] = nonnegative(value)

proc borderWidth*(e: Element): Element =
  ## Removes the element's border widths.
  e.setBorderWidth([0'f32, 0, 0, 0])

proc borderWidth*(e: Element; all: float32): Element =
  ## Sets one border width for every side.
  e.setBorderWidth([all, all, all, all])

proc borderWidth*(e: Element; vertical, horizontal: float32): Element =
  ## Sets border widths for top/bottom and left/right.
  e.setBorderWidth([vertical, horizontal, vertical, horizontal])

proc borderWidth*(e: Element; top, horizontal, bottom: float32): Element =
  ## Sets top, horizontal, and bottom border widths.
  e.setBorderWidth([top, horizontal, bottom, horizontal])

proc borderWidth*(e: Element; top, right, bottom, left: float32): Element =
  ## Sets border widths in top, right, bottom, left order.
  e.setBorderWidth([top, right, bottom, left])

proc borderColor*(e: Element; color: Color): Element =
  ## Sets the border color.
  result = e
  let n = e.node
  if n != nil:
    n.borderColor = color

proc border*(e: Element; width: float32; color: Color): Element =
  ## Sets a uniform solid border and its color.
  discard e.borderWidth(width)
  e.borderColor(color)

proc borderStyle*(e: Element; style: BorderStyle): Element =
  ## Sets whether the border is solid or dashed.
  result = e
  let n = e.node
  if n != nil:
    n.borderStyle = style

proc sceneColor(color: Color): scene.Color =
  scene.Color(r: color.r, g: color.g, b: color.b, a: color.a)

proc wideRgba(color: Color; value: var array[4, float32]): bool =
  if not color.wide.wideOk or color.a == 0:
    return false
  let (r, g, b) = color.extended
  value = [r, g, b, color.a.float32 / 255]
  true

proc wideColors(fill, border: Color): scene.WideColors =
  if fill.wideRgba(result.color):
    result.`set` = result.`set` or scene.wideColor
  if border.wideRgba(result.border):
    result.`set` = result.`set` or scene.wideBorder

proc addWide(s: scene.Scene; colors: scene.WideColors): uint16 =
  if colors.`set` == 0:
    return 0
  if s.wide.len > 0 and s.wide[^1] == colors:
    return uint16(s.wide.len)
  if s.wide.len >= high(uint16).int:
    return 0
  s.wide.add(colors)
  uint16(s.wide.len)

proc pixelDimension(value, scale: float32): int =
  let pixels = ceil(value.float64 * scale.float64)
  if pixels >= high(int).float64:
    raise newException(ValueError, "ui: scene dimensions exceed the platform limit")
  int(max(pixels, 0))

proc scaled(value, scale: float32): float32 =
  result = value * scale
  if not result.finite:
    raise newException(ValueError, "ui: painted geometry exceeds the float range")

proc scaledEdges(values: array[4, float32]; scale: float32): array[4, float32] =
  for i, value in values:
    result[i] = value.scaled(scale)

proc snapPixel(value: float64): float32 =
  if classify(value) in {fcNan, fcInf, fcNegInf} or
      abs(value) > float64(high(float32)):
    raise newException(ValueError, "ui: painted position exceeds the float range")
  float32(round(value))

proc sceneRect(rect, root: Rect; scale: float32): scene.Rect =
  for value in [rect.x, rect.y, rect.w, rect.h]:
    if not value.finite:
      raise newException(ValueError, "ui: layout contains non-finite geometry")
  let scale64 = scale.float64
  let x0 = snapPixel((rect.x.float64 - root.x.float64) * scale64)
  let y0 = snapPixel((rect.y.float64 - root.y.float64) * scale64)
  let x1 = snapPixel((rect.x.float64 - root.x.float64 + rect.w.float64) * scale64)
  let y1 = snapPixel((rect.y.float64 - root.y.float64 + rect.h.float64) * scale64)
  let width = max(x1.float64 - x0.float64, 0)
  let height = max(y1.float64 - y0.float64, 0)
  if width > float64(high(float32)) or height > float64(high(float32)):
    raise newException(ValueError, "ui: painted size exceeds the float range")
  scene.Rect(x: x0, y: y0, w: float32(width), h: float32(height))

proc paintText(s: scene.Scene; node: ElementNode; rect, root: Rect;
               scale: float32; system: textStack.System) =
  if not node.hasText or node.shapedText == nil or node.textColor.a == 0:
    return
  let originX = rect.x - root.x + node.pad[3] + node.border[3]
  let originY = rect.y - root.y + node.pad[0] + node.border[0]
  let color = sceneColor(node.textColor)
  let wide = wideColors(node.textColor, transparent)
  let wideIndex = s.addWide(wide)
  let start = s.glyphs.len
  let shade = textStack.shadeOf(node.textColor.r, node.textColor.g,
                                node.textColor.b)
  for line in node.shapedText.lines:
    let baseline = system.baseline((originY + line.baseline) * scale)
    for glyph in line.glyphs:
      if glyph.`object` or glyph.font.isNil:
        continue
      let pen = (originX + glyph.x) * scale
      let image = system.glyph(glyph.font, glyph.id, scale, pen, shade, false)
      if not image.ok:
        continue
      s.glyphs.add(scene.Glyph(x: floor(pen) + image.left,
        y: baseline + image.top, w: float32(image.w), h: float32(image.h),
        u: image.x, v: image.y, uw: image.w, vh: image.h,
        color: color, wide: wideIndex, colored: image.colored,
        subpixel: image.subpixel, thin: image.thin))
  if s.glyphs.len > start:
    s.ops.add(scene.Op(kind: scene.opGlyphs, first: int32(start),
                       last: int32(s.glyphs.len)))

proc fitImage(box: Rect; bitmap: Bitmap; fit: Fit):
    tuple[rect: Rect, src: scene.Rect] =
  if bitmap == nil or bitmap.image == nil or bitmap.image.w <= 0 or
      bitmap.image.h <= 0 or box.w <= 0 or box.h <= 0:
    return
  let imageW = float32(bitmap.image.w)
  let imageH = float32(bitmap.image.h)
  result.src = scene.Rect(w: imageW, h: imageH)
  case fit
  of Fit.FillBox:
    result.rect = box
  of Fit.Contain, Fit.ScaleDown:
    var scale = min(box.w / imageW, box.h / imageH)
    if fit == Fit.ScaleDown:
      scale = min(scale, 1'f32)
    let width = imageW * scale
    let height = imageH * scale
    result.rect = Rect(x: box.x + (box.w - width) / 2,
                       y: box.y + (box.h - height) / 2,
                       w: width, h: height)
  of Fit.Cover:
    let scale = max(box.w / imageW, box.h / imageH)
    let width = box.w / scale
    let height = box.h / scale
    result.src = scene.Rect(x: (imageW - width) / 2,
      y: (imageH - height) / 2, w: width, h: height)
    result.rect = box
  of Fit.NaturalSize:
    let width = min(imageW, box.w)
    let height = min(imageH, box.h)
    let x = box.x + (box.w - imageW) / 2
    let y = box.y + (box.h - imageH) / 2
    result.rect = Rect(x: max(x, box.x), y: max(y, box.y),
      w: width, h: height)
    result.src = scene.Rect(x: result.rect.x - x, y: result.rect.y - y,
                            w: width, h: height)

proc fitVector(box: Rect; imageW, imageH: float32; fit: Fit):
    tuple[raw, shown: Rect, src: scene.Rect, stretch: bool] =
  if imageW <= 0 or imageH <= 0 or box.w <= 0 or box.h <= 0:
    return
  result.stretch = fit == Fit.FillBox
  case fit
  of Fit.FillBox:
    result.raw = box
    result.shown = box
  of Fit.Contain, Fit.ScaleDown:
    var factor = min(box.w / imageW, box.h / imageH)
    if fit == Fit.ScaleDown:
      factor = min(factor, 1'f32)
    let width = imageW * factor
    let height = imageH * factor
    result.raw = Rect(x: box.x + (box.w - width) / 2,
                      y: box.y + (box.h - height) / 2,
                      w: width, h: height)
    result.shown = result.raw
  of Fit.Cover:
    let factor = max(box.w / imageW, box.h / imageH)
    let width = imageW * factor
    let height = imageH * factor
    result.raw = Rect(x: box.x + (box.w - width) / 2,
                      y: box.y + (box.h - height) / 2,
                      w: width, h: height)
    result.shown = box
  of Fit.NaturalSize:
    result.raw = Rect(x: box.x + (box.w - imageW) / 2,
                      y: box.y + (box.h - imageH) / 2,
                      w: imageW, h: imageH)
    let x0 = max(result.raw.x, box.x)
    let y0 = max(result.raw.y, box.y)
    let x1 = min(result.raw.x + result.raw.w, box.x + box.w)
    let y1 = min(result.raw.y + result.raw.h, box.y + box.h)
    if x1 <= x0 or y1 <= y0:
      return
    result.shown = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

  result.src = scene.Rect(x: result.shown.x - result.raw.x,
    y: result.shown.y - result.raw.y, w: result.shown.w, h: result.shown.h)

proc picture(vector: Svg; width, height: int; color: Color;
             stretch: bool): scene.Image =
  if vector == nil or width <= 0 or height <= 0 or width > 4096 or
      height > 4096 or width > (16 * 1024 * 1024) div height:
    return
  let usesColor = svgRenderer.usesCurrentColor(vector.doc)
  let cacheColor = if usesColor: color.srgb else: transparent
  for cached in vector.pictures:
    if cached.width == width and cached.height == height and
        cached.color == cacheColor and cached.stretch == stretch:
      return cached.image

  result = scene.newImageRgba(width, height, newSeq[byte](4 * width * height))
  let current = if usesColor:
    sourceImage.Nrgba(r: cacheColor.r, g: cacheColor.g,
                      b: cacheColor.b, a: cacheColor.a)
  else:
    sourceImage.Nrgba()
  let dst = sourceImage.RgbaImage(pix: result.pix, stride: 4 * width,
    rect: sourceImage.rect(0, 0, width, height))
  svgRenderer.draw(vector.doc, dst, current, stretch)
  result.pix = dst.pix

  if vector.pictures.len >= 8:
    vector.pictures.delete(0)
  vector.pictures.add(SvgPicture(width: width, height: height,
    color: cacheColor, stretch: stretch, image: result))

proc paintSvg(s: scene.Scene; node: ElementNode; rect, root: Rect;
              scale: float32) =
  if node.vector == nil:
    return
  let box = Rect(x: rect.x + node.pad[3] + node.border[3],
    y: rect.y + node.pad[0] + node.border[0],
    w: max(rect.w - node.contentInsetX, 0'f32),
    h: max(rect.h - node.contentInsetY, 0'f32))
  let fitted = fitVector(box, node.vector.width, node.vector.height, node.fit)
  if fitted.raw.w <= 0 or fitted.raw.h <= 0 or
      fitted.shown.w <= 0 or fitted.shown.h <= 0:
    return

  let rasterRect = fitted.raw.sceneRect(root, scale)
  let pixelRect = fitted.shown.sceneRect(root, scale)
  let rasterW = int(rasterRect.w)
  let rasterH = int(rasterRect.h)
  if rasterRect.empty or pixelRect.empty or rasterW <= 0 or rasterH <= 0:
    return
  let image = node.vector.picture(rasterW, rasterH, node.vectorColor,
                                  fitted.stretch)
  if image == nil:
    return
  let factorX = rasterW.float32 / fitted.raw.w
  let factorY = rasterH.float32 / fitted.raw.h
  let src = scene.Rect(x: fitted.src.x * factorX,
    y: fitted.src.y * factorY, w: fitted.src.w * factorX,
    h: fitted.src.h * factorY)
  s.ops.add(scene.Op(kind: scene.opImage, rect: pixelRect,
    radii: node.radius.scaledEdges(scale), continuous: continuousCorners,
    image: image, src: src, grayscale: node.grayscale))

proc paintBitmap(s: scene.Scene; node: ElementNode; rect, root: Rect;
                 scale: float32) =
  if node.bitmap == nil or node.bitmap.image == nil:
    return
  let box = Rect(x: rect.x + node.pad[3] + node.border[3],
    y: rect.y + node.pad[0] + node.border[0],
    w: max(rect.w - node.contentInsetX, 0'f32),
    h: max(rect.h - node.contentInsetY, 0'f32))
  let fitted = fitImage(box, node.bitmap, node.fit)
  if fitted.rect.w <= 0 or fitted.rect.h <= 0:
    return
  let pixelRect = fitted.rect.sceneRect(root, scale)
  if pixelRect.empty:
    return
  let enlarged = fitted.rect.w * scale >= fitted.src.w or
    fitted.rect.h * scale >= fitted.src.h
  s.ops.add(scene.Op(kind: scene.opImage, rect: pixelRect,
    radii: node.radius.scaledEdges(scale), continuous: continuousCorners,
    image: node.bitmap.image, src: fitted.src,
    pixelated: node.bitmap.pixelated and enlarged,
    grayscale: node.grayscale))

proc paintScene*(layout: LayoutResult; scale = 1'f32;
                 clear = transparent): scene.Scene =
  ## Converts a current layout into a device-pixel scene for Mygo's renderers.
  ## Element bounds are translated to the layout root's origin before snapping.
  if layout.owner == nil or layout.owner.closed or
      layout.owner.inBuild or not layout.owner.hasFrame or
      layout.generation != layout.owner.generation or
      layout.rects.len != layout.owner.nodes.len:
    raise newException(ValueError, "ui: cannot paint a stale layout")
  if not scale.finite or scale <= 0:
    raise newException(ValueError, "ui: scene scale must be finite and positive")

  let width = layout.root.w.pixelDimension(scale)
  let height = layout.root.h.pixelDimension(scale)
  let maxPixels = high(int) div 4
  if height > 0 and width > maxPixels div height:
    raise newException(ValueError, "ui: scene pixel storage exceeds the platform limit")

  let system = textStack.shared()
  system.beginFrame()
  try:
    for attempt in 0..2:
      result = scene.Scene(width: 0, height: 0, scale: scale)
      result.reset(width, height, sceneColor(clear.srgb))
      result.scale = scale
      result.text = system.textParams()
      result.maskAtlas = system.maskAtlas
      result.colorAtlas = system.colorAtlas

      for slot, node in layout.owner.nodes:
        let fillVisible = node.background.a > 0
        let borderVisible = node.borderColor.a > 0 and scene.hasBorder(node.border)
        if not fillVisible and not borderVisible and not node.hasText and
            node.bitmap == nil and node.vector == nil:
          continue

        let rect = layout.rects[slot].sceneRect(layout.root, scale)
        if rect.empty:
          continue
        if fillVisible or borderVisible:
          var op = scene.Op(kind: scene.opFill, rect: rect,
            color: sceneColor(node.background), paint: scene.paintSolid,
            radii: node.radius.scaledEdges(scale),
            border: node.border.scaledEdges(scale),
            continuous: continuousCorners,
            borderColor: sceneColor(node.borderColor),
            dashed: node.borderStyle == BorderStyle.Dashed)
          var wide = node.background.wideColors(node.borderColor)
          if not borderVisible:
            wide.border = [0'f32, 0, 0, 0]
            wide.`set` = wide.`set` and not scene.wideBorder
          if not fillVisible:
            wide.color = [0'f32, 0, 0, 0]
            wide.`set` = wide.`set` and not scene.wideColor
          op.wide = result.addWide(wide)
          result.ops.add(op)
        result.paintText(node, layout.rects[slot], layout.root, scale, system)
        result.paintBitmap(node, layout.rects[slot], layout.root, scale)
        result.paintSvg(node, layout.rects[slot], layout.root, scale)

      if not system.full() or attempt == 2:
        break
      system.makeRoom()
  finally:
    system.endFrame()
