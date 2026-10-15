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

  result = scene.Scene(width: 0, height: 0, scale: scale)
  result.reset(width, height, sceneColor(clear.srgb))
  result.scale = scale

  for slot, node in layout.owner.nodes:
    let fillVisible = node.background.a > 0
    let borderVisible = node.borderColor.a > 0 and scene.hasBorder(node.border)
    if not fillVisible and not borderVisible:
      continue

    let rect = layout.rects[slot].sceneRect(layout.root, scale)
    if rect.empty:
      continue
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
