## Element decorations and conversion of a completed layout to Mygo's
## GPU-ready scene display list.

const continuousCorners = defined(macosx)
const
  poseXKey = "\x00mynim.pose.x"
  poseYKey = "\x00mynim.pose.y"
  poseScaleKey = "\x00mynim.pose.scale"
  poseRotateKey = "\x00mynim.pose.rotate"
  poseFadeKey = "\x00mynim.pose.fade"

proc updatePoseChannel(owner: ElementOwner;
                      channels: var Table[string, ScalarAnimation];
                      key: string; target: float32; animation: Animation;
                      respectReduceMotion: bool): float32 =
  var channel = channels.getOrDefault(key)
  result = float32(channel.update(owner, float64(target), animation,
    respectReduceMotion, poseChannel = true))
  channels[key] = channel

proc samplePose(owner: ElementOwner; node: var ElementNode) =
  if not node.poseSet:
    return
  let target = node.poseTarget.channels()
  var channels = if owner.animations.hasKey(node.identity):
      owner.animations[node.identity]
    else:
      initTable[string, ScalarAnimation]()
  let x = owner.updatePoseChannel(channels, poseXKey, target[0],
    node.poseAnimation, true)
  let y = owner.updatePoseChannel(channels, poseYKey, target[1],
    node.poseAnimation, true)
  let scale = owner.updatePoseChannel(channels, poseScaleKey, target[2],
    node.poseAnimation, true)
  let rotate = owner.updatePoseChannel(channels, poseRotateKey, target[3],
    node.poseAnimation, true)
  let fade = owner.updatePoseChannel(channels, poseFadeKey, target[4],
    node.poseAnimation, false)
  owner.animations[node.identity] = channels
  node.poseTransform = scaling(scale, scale).then(rotation(rotate))
    .then(translation(x, y))
  node.poseFade = fade

proc samplePoses(owner: ElementOwner) =
  if owner == nil or owner.closed:
    return
  for node in owner.nodes.mitems:
    owner.samplePose(node)

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
    n.backgroundSet = true
    n.hasGradient = false

proc opacity*(e: Element; value: float32): Element =
  ## Multiplies the opacity of this element and all its descendants.
  result = e
  let n = e.node
  if n != nil:
    n.opacity = if value.finite: min(max(value, 0'f32), 1'f32) else: 0
    n.opacitySet = true

proc gradient*(e: Element; value: LinearGradient): Element =
  ## Fills the element with a two-color linear gradient.
  result = e
  let n = e.node
  if n != nil:
    n.gradient = value
    n.hasGradient = true

proc gradient*(e: Element; fromColor, toColor: Color;
               angle: float32): Element =
  ## Fills the element with a gradient at an angle clockwise from upward.
  e.gradient(LinearGradient(fromColor: fromColor, toColor: toColor,
                            angle: angle))

proc shadow*(e: Element; x, y, blur, spread: float32;
             color: Color): Element =
  ## Adds a blurred shadow outside the element's rounded box.
  result = e
  let n = e.node
  if n != nil:
    n.shadows.add(UiShadow(x: x, y: y, blur: blur, spread: spread,
                           color: color))

proc insetShadow*(e: Element; x, y, blur, spread: float32;
                  color: Color): Element =
  ## Adds a blurred shadow inside the element's padding edge.
  result = e
  let n = e.node
  if n != nil:
    n.shadows.add(UiShadow(x: x, y: y, blur: blur, spread: spread,
                           color: color, inset: true))

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
    n.logical = n.logical and not logBorder

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

proc wideColors(fill, fill2, border: Color): scene.WideColors =
  if fill.wideRgba(result.color):
    result.`set` = result.`set` or scene.wideColor
  if fill2.wideRgba(result.color2):
    result.`set` = result.`set` or scene.wideColor2
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

proc sceneGradient(rect: scene.Rect; value: LinearGradient):
    tuple[paint: scene.Paint, points: array[4, float32]] =
  if not value.angle.finite or not value.start.finite or not value.stop.finite:
    raise newException(ValueError, "ui: gradient values must be finite")
  let
    angle = float64(value.angle) * PI / 180
    dx = float32(sin(angle))
    dy = float32(-cos(angle))
    half = (abs(rect.w * dx) + abs(rect.h * dy)) / 2
    cx = rect.x + rect.w / 2
    cy = rect.y + rect.h / 2
    x0 = cx - dx * half
    y0 = cy - dy * half
    x1 = cx + dx * half
    y1 = cy + dy * half
  var stop = value.stop
  if value.start == 0 and stop == 0:
    stop = 1
  let
    sx = x0 + (x1 - x0) * value.start
    sy = y0 + (y1 - y0) * value.start
  var
    ex = x0 + (x1 - x0) * stop
    ey = y0 + (y1 - y0) * stop
  if stop - value.start < 0.5 / max(2 * half, 1'f32):
    ex = sx + dx * 0.5
    ey = sy + dy * 0.5
  for point in [sx, sy, ex, ey]:
    if not point.finite:
      raise newException(ValueError, "ui: gradient exceeds the float range")
  result.paint = if value.oklab: scene.paintOklab else: scene.paintLinear
  result.points = [sx, sy, ex, ey]

proc mixPathHash(key: var uint64; value: uint32) =
  let mixed = cast[int64](key xor uint64(value)) *%
    cast[int64](1099511628211'u64)
  key = cast[uint64](mixed)

proc pathHash(path: FlatPath; width: float32): uint64 =
  result = 14695981039346656037'u64
  result.mixPathHash(cast[uint32](width))
  for i in 0 ..< path.flatPolys:
    for point in path.poly(i):
      result.mixPathHash(cast[uint32](point[0]))
      result.mixPathHash(cast[uint32](point[1]))
    result.mixPathHash(if path.closed[i]: 1'u32 else: 0'u32)

proc paintPath(painter: var Painter; path: Path; strokeWidth: float32;
               color: Color; gradient: LinearGradient; hasGradient: bool) =
  if path == nil or painter.frame == nil or
      (if hasGradient: gradient.fromColor.a == 0 and gradient.toColor.a == 0
       else: color.a == 0):
    return
  let width = if classify(strokeWidth) in {fcNan, fcInf, fcNegInf}:
      0'f32
    else:
      max(strokeWidth, 0'f32) * painter.scale
  var flat = path.flatten(painter.scale)
  if flat.flatPolys == 0:
    return
  let rootX = painter.root.x * painter.scale
  let rootY = painter.root.y * painter.scale
  for point in flat.points.mitems:
    point[0] -= rootX
    point[1] -= rootY

  var minX = high(float32)
  var minY = high(float32)
  var maxX = low(float32)
  var maxY = low(float32)
  for point in flat.points:
    if classify(point[0]) in {fcNan, fcInf, fcNegInf} or
        classify(point[1]) in {fcNan, fcInf, fcNegInf}:
      return
    minX = min(minX, point[0])
    minY = min(minY, point[1])
    maxX = max(maxX, point[0])
    maxY = max(maxY, point[1])

  let halfWidth = width / 2
  let x0 = floor(minX - halfWidth).float32
  let y0 = floor(minY - halfWidth).float32
  let widthValue = ceil(maxX + halfWidth - x0) + 1
  let heightValue = ceil(maxY + halfWidth - y0) + 1
  if classify(widthValue) in {fcNan, fcInf, fcNegInf} or
      classify(heightValue) in {fcNan, fcInf, fcNegInf} or
      widthValue <= 0 or heightValue <= 0 or widthValue > 4096 or
      heightValue > 4096:
    return
  let maskWidth = int(widthValue)
  let maskHeight = int(heightValue)
  let maskKey = flat.pathHash(width)
  let image = painter.textSystem.mask(maskKey,
    proc(): tuple[w, h: int, pix: seq[byte]] =
      result.w = maskWidth
      result.h = maskHeight
      result.pix = if halfWidth > 0:
          flat.strokeMask(x0, y0, halfWidth, maskWidth, maskHeight)
        else:
          flat.fillMask(x0, y0, maskWidth, maskHeight))
  if not image.ok:
    return

  var drawColor = color
  if width > 0:
    let fade = flat.capFade(width)
    drawColor = drawColor.alpha(fade)
  let gradientFrom = if hasGradient:
      gradient.fromColor.alpha(flat.capFade(width))
    else:
      transparent
  let gradientTo = if hasGradient:
      gradient.toColor.alpha(flat.capFade(width))
    else:
      transparent
  let wideColors = if hasGradient:
      wideColors(gradientFrom, gradientTo, transparent)
    else:
      wideColors(drawColor, transparent, transparent)
  let wideIndex = painter.frame.addWide(wideColors)
  let start = int32(painter.frame.glyphs.len)
  painter.frame.glyphs.add(scene.Glyph(x: x0, y: y0,
    w: float32(image.w), h: float32(image.h), u: image.x, v: image.y,
    uw: image.w, vh: image.h, color: sceneColor(drawColor), wide: wideIndex))
  var op = scene.Op(kind: scene.opGlyphs, first: start, last: start + 1,
    opacity: painter.opacity)
  if hasGradient:
    let rect = scene.Rect(x: x0, y: y0,
      w: maxX - minX + width, h: maxY - minY + width)
    let info = sceneGradient(rect, gradient)
    op.rect = rect
    op.paint = info.paint
    op.color = sceneColor(gradientFrom)
    op.color2 = sceneColor(gradientTo)
    op.gradient = info.points
    op.wide = wideIndex
  painter.frame.ops.add(op)

proc draw*(element: Element;
           callback: proc(painter: var Painter; rect: Rect) {.closure.}): Element =
  ## Adds custom vector drawing in the element's bounds.
  result = element
  let node = element.node
  if node != nil:
    node.drawFn = callback

proc transform*(element: Element; value: Transform): Element =
  ## Transforms this element visually without changing its layout space.
  result = element
  let node = element.node
  if node != nil:
    node[].transform = value

proc translate*(element: Element; x, y: float32): Element =
  ## Moves the element after its current transform.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(translation(x, y))
  element

proc scale*(element: Element; x, y: float32): Element =
  ## Scales the element after its current transform, around its origin.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(scaling(x, y))
  element

proc rotate*(element: Element; degrees: float32): Element =
  ## Rotates the element clockwise around its transform origin.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(rotation(degrees))
  element

proc rotateX*(element: Element; degrees: float32): Element =
  ## Turns the element around its horizontal axis in 3D.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(rotationX(degrees))
  element

proc rotateY*(element: Element; degrees: float32): Element =
  ## Turns the element around its vertical axis in 3D.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(rotationY(degrees))
  element

proc perspective*(element: Element; distance: float32): Element =
  ## Applies a 3D perspective view at the given distance in DIPs.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(perspective(distance))
  element

proc backfaceHidden*(element: Element): Element =
  ## Hides and disables the element when its 3D transform faces away.
  let node = element.node
  if node != nil:
    node[].backfaceHidden = true
  element

proc animatePose*(element: Element; pose: Pose;
                  animation: Animation): Element =
  ## Animates visual translation, uniform scale, rotation, and opacity.
  ## Pose transforms follow the element transform and share its origin.
  result = element
  for value in [pose.x, pose.y, pose.scale, pose.rotate, pose.fade]:
    if not finiteMotion(float64(value)):
      raise newException(ValueError, "ui: pose values must be finite")
  animation.validateAnimation()
  let node = element.node
  if node == nil:
    return
  node[].poseTarget = pose
  node[].poseAnimation = animation
  node[].poseSet = true
  element.owner.samplePose(node[])

proc transformOrigin*(element: Element; x, y: float32): Element =
  ## Sets the transform origin as fractions of the border box.
  validateTransformValues(x, y)
  let node = element.node
  if node != nil:
    node[].transformOriginX = x
    node[].transformOriginY = y
    node[].transformOriginSet = true
  element

proc skew*(element: Element; x, y: float32): Element =
  ## Skews the element after its current transform around its origin.
  let node = element.node
  if node != nil:
    node[].transform = node[].transform.then(skewing(x, y))
  element

proc painterTransform(painter: Painter; value: Transform;
                      originX, originY: float32): scene.Affine =
  validateTransformValues(originX, originY, painter.root.x, painter.root.y,
    painter.scale)
  if painter.scale <= 0:
    raise newException(ValueError, "ui: painter scale must be positive")
  var pixelTransform = value.flat()
  pixelTransform.x *= painter.scale
  pixelTransform.y *= painter.scale
  pixelTransform.g /= painter.scale
  pixelTransform.h /= painter.scale
  validateTransform(pixelTransform)
  let pixelOriginX = (originX - painter.root.x) * painter.scale
  let pixelOriginY = (originY - painter.root.y) * painter.scale
  validateTransformValues(pixelOriginX, pixelOriginY)
  result = scene.translation(pixelOriginX, pixelOriginY)
    .mul(pixelTransform)
    .mul(scene.translation(-pixelOriginX, -pixelOriginY))
  validateTransform(result)

proc applyPainterTransform(frame: scene.Scene; first: int;
                           transform: scene.Affine) =
  for i in first ..< frame.ops.len:
    let composed = scene.mul(transform, frame.ops[i].transform)
    validateTransform(composed)
    frame.ops[i].transform = composed

proc transform*(painter: var Painter; value: Transform;
                originX, originY: float32;
                callback: proc(painter: var Painter) {.closure.}) =
  ## Applies a visual transform around an origin; callback receives the painter.
  if callback == nil:
    raise newException(ValueError, "ui: painter transform callback is nil")
  if painter.frame == nil or not value.set:
    callback(painter)
    return
  let frame = painter.frame
  let first = frame.ops.len
  let transformMatrix = painter.painterTransform(value, originX, originY)
  try:
    callback(painter)
  finally:
    frame.applyPainterTransform(first, transformMatrix)

proc painterBorderPixels(width, scale: float32): float32 =
  if width <= 0:
    return
  result = max(round(width.scaled(scale)), 1'f32)

proc painterFill(painter: var Painter; rect: Rect; radius: float32;
                 fillColor, borderColor: Color; borderWidth: float32;
                 dashed: bool) =
  if painter.frame == nil:
    return
  let fillRect = sceneRect(rect, painter.root, painter.scale)
  let radii = [radius, radius, radius, radius].scaledEdges(painter.scale)
  let border = painterBorderPixels(borderWidth, painter.scale)
  let visibleBorder = if border > 0: borderColor else: transparent
  var op = scene.Op(kind: scene.opFill, rect: fillRect,
    color: sceneColor(fillColor), radii: radii,
    continuous: continuousCorners, border: [border, border, border, border],
    borderColor: sceneColor(borderColor), dashed: dashed,
    opacity: painter.opacity)
  op.wide = painter.frame.addWide(
    wideColors(fillColor, transparent, visibleBorder))
  painter.frame.ops.add(op)

proc fill*(painter: var Painter; rect: Rect; color: Color; radius: float32) =
  ## Paints a rounded rectangle in DIPs.
  painter.painterFill(rect, radius, color, transparent, 0, false)

proc fillGradient*(painter: var Painter; rect: Rect;
                   gradient: LinearGradient; radius: float32) =
  ## Paints a rounded rectangle with a linear gradient.
  if painter.frame == nil:
    return
  let fillRect = sceneRect(rect, painter.root, painter.scale)
  let radii = [radius, radius, radius, radius].scaledEdges(painter.scale)
  let info = sceneGradient(fillRect, gradient)
  var op = scene.Op(kind: scene.opFill, rect: fillRect,
    color: sceneColor(gradient.fromColor),
    color2: sceneColor(gradient.toColor), paint: info.paint,
    gradient: info.points, radii: radii, continuous: continuousCorners,
    opacity: painter.opacity)
  op.wide = painter.frame.addWide(
    wideColors(gradient.fromColor, gradient.toColor, transparent))
  painter.frame.ops.add(op)

proc stroke*(painter: var Painter; rect: Rect; color: Color;
             radius, width: float32) =
  ## Paints the inside outline of a rounded rectangle.
  painter.painterFill(rect, radius, transparent, color, width, false)

proc strokeDashed*(painter: var Painter; rect: Rect; color: Color;
                   radius, width: float32) =
  ## Paints a dashed inside outline of a rounded rectangle.
  painter.painterFill(rect, radius, transparent, color, width, true)

proc shadow*(painter: var Painter; rect: Rect; radius, x, y, blur, spread: float32;
             color: Color) =
  ## Paints a blurred shadow outside a rounded rectangle.
  if painter.frame == nil:
    return
  let
    castRect = sceneRect(rect, painter.root, painter.scale)
    castRadii = [radius, radius, radius, radius].scaledEdges(painter.scale)
    shadowRect = Rect(x: rect.x + x - spread, y: rect.y + y - spread,
      w: rect.w + 2 * spread, h: rect.h + 2 * spread)
    shadowRadii = block:
      var values = castRadii
      for value in values.mitems:
        if value > 0:
          value = max(value + spread * painter.scale, 0'f32)
      values
  var op = scene.Op(kind: scene.opShadow,
    rect: sceneRect(shadowRect, painter.root, painter.scale),
    radii: shadowRadii, continuous: continuousCorners,
    color: sceneColor(color), blur: blur.scaled(painter.scale),
    `cast`: castRect, castRadii: castRadii, opacity: painter.opacity)
  op.wide = painter.frame.addWide(wideColors(color, transparent, transparent))
  painter.frame.ops.add(op)

proc line*(painter: var Painter; x0, y0, x1, y1, width: float32;
           color: Color) =
  ## Paints a straight horizontal or vertical line between two points.
  var rect = Rect(x: min(x0, x1), y: min(y0, y1),
    w: abs(x1 - x0), h: abs(y1 - y0))
  if rect.w < rect.h:
    rect.x -= width / 2
    rect.w = width
  else:
    rect.y -= width / 2
    rect.h = width
  painter.fill(rect, color, 0)

type
  ImageOptions* = object
    ## Options for drawing one region of a bitmap with Painter.imageRegion.
    flipX*, flipY*: bool ## Mirrors the source region on either axis.
    tint*: Color ## Multiplies image color and alpha; zero means no tint.

proc paintSvg(s: scene.Scene; node: ElementNode; rect, root: Rect;
              scale, opacity: float32)
proc paintBitmap(s: scene.Scene; node: ElementNode; rect, root: Rect;
                 scale, opacity: float32)

proc image*(painter: var Painter; bitmap: Bitmap; rect: Rect; fit: Fit) =
  ## Draws a bitmap fitted into a rectangle.
  if painter.frame == nil:
    return
  let node = ElementNode(bitmap: bitmap, fit: fit)
  painter.frame.paintBitmap(node, rect, painter.root, painter.scale,
    painter.opacity)

proc image*(painter: var Painter; vector: Svg; rect: Rect; fit: Fit) =
  ## Draws an SVG fitted into a rectangle, using the theme text color for currentColor.
  if painter.frame == nil:
    return
  let node = ElementNode(vector: vector, vectorColor: painter.theme.text,
    fit: fit)
  painter.frame.paintSvg(node, rect, painter.root, painter.scale,
    painter.opacity)

proc icon*(painter: var Painter; vector: Svg; rect: Rect; color: Color) =
  ## Draws an SVG icon fitted into a rectangle, using color for currentColor.
  if painter.frame == nil:
    return
  let node = ElementNode(vector: vector, vectorColor: color, fit: Fit.Contain)
  painter.frame.paintSvg(node, rect, painter.root, painter.scale,
    painter.opacity)

proc imageRegion*(painter: var Painter; bitmap: Bitmap; source, destination: Rect;
                  options = ImageOptions()) =
  ## Draws a clipped source region stretched into a destination rectangle.
  if painter.frame == nil:
    return
  let node = ElementNode(bitmap: bitmap, imageRegion: source,
    flipX: options.flipX, flipY: options.flipY, imageTint: options.tint,
    fit: Fit.FillBox)
  painter.frame.paintBitmap(node, destination, painter.root, painter.scale,
    painter.opacity)

proc scale*(painter: Painter): float32 =
  ## Returns physical pixels per device-independent pixel for this surface.
  painter.scale

proc clip*(painter: var Painter; rect: Rect; radius: float32;
           callback: proc(painter: var Painter) {.closure.}) =
  ## Clips drawing in `callback` to `rect`, with rounded corners of `radius`.
  if callback == nil:
    raise newException(ValueError, "ui: painter clip callback is nil")
  if painter.frame == nil:
    callback(painter)
    return
  let corner = max(radius, 0'f32)
  painter.frame.ops.add(scene.Op(kind: scene.opPushClip,
    rect: rect.sceneRect(painter.root, painter.scale),
    radii: [corner, corner, corner, corner].scaledEdges(painter.scale),
    continuous: continuousCorners))
  try:
    callback(painter)
  finally:
    painter.frame.ops.add(scene.Op(kind: scene.opPopClip))

proc focusRing*(painter: var Painter; rect: Rect; radius: array[4, float32]) =
  ## Draws a theme-colored keyboard focus ring around a rectangle.
  if painter.frame == nil:
    return
  const width = 2'f32
  const outset = width + 1
  let
    outer = Rect(x: rect.x - outset, y: rect.y - outset,
      w: rect.w + outset * 2, h: rect.h + outset * 2)
    radii = [radius[0] + outset, radius[1] + outset,
      radius[2] + outset, radius[3] + outset]
    color = painter.theme.focus
  let border = painterBorderPixels(width, painter.scale)
  var op = scene.Op(kind: scene.opFill,
    rect: sceneRect(outer, painter.root, painter.scale),
    color: sceneColor(transparent), radii: radii.scaledEdges(painter.scale),
    continuous: continuousCorners,
    border: [border, border, border, border], borderColor: sceneColor(color),
    opacity: painter.opacity)
  op.wide = painter.frame.addWide(wideColors(transparent, transparent, color))
  painter.frame.ops.add(op)

proc fillPath*(painter: var Painter; path: Path; color: Color) =
  ## Fills a vector path with non-zero winding.
  painter.paintPath(path, 0, color, LinearGradient(), false)

proc fillPathGradient*(painter: var Painter; path: Path;
                       gradient: LinearGradient) =
  ## Fills a path with a gradient across its bounds.
  painter.paintPath(path, 0, gradient.fromColor, gradient, true)

proc strokePath*(painter: var Painter; path: Path; width: float32;
                 color: Color) =
  ## Draws a vector path with round joins and caps.
  painter.paintPath(path, width, color, LinearGradient(), false)

proc strokePathGradient*(painter: var Painter; path: Path; width: float32;
                         gradient: LinearGradient) =
  ## Draws a vector path with a gradient across its bounds.
  painter.paintPath(path, width, gradient.fromColor, gradient, true)

proc paintShadow(s: scene.Scene; node: ElementNode; box, root: Rect;
                 scale, opacity: float32; value: UiShadow) =
  if value.color.a == 0:
    return
  let castRect = box.sceneRect(root, scale)
  if castRect.empty:
    return
  let castRadii = node.radius.scaledEdges(scale)
  var op = scene.Op(kind: scene.opShadow, color: sceneColor(value.color),
    continuous: continuousCorners, blur: value.blur.scaled(scale),
    opacity: opacity)
  if value.inset:
    var pad = castRect
    var padRadii = scene.fitRadii(castRect, castRadii)
    if scene.hasBorder(node.border):
      let inner = scene.innerRadii(castRect, padRadii,
        node.border.scaledEdges(scale))
      pad = inner.inner
      padRadii = inner.radii
    if pad.empty:
      return
    let spread = value.spread.scaled(scale)
    let dx = snapPixel(value.x.scaled(scale).float64)
    let dy = snapPixel(value.y.scaled(scale).float64)
    var holeRadii = padRadii
    for i, radius in holeRadii:
      holeRadii[i] = max(radius - spread, 0'f32)
    op.inset = true
    op.rect = scene.Rect(x: pad.x + dx + spread, y: pad.y + dy + spread,
      w: max(pad.w - 2 * spread, 0'f32),
      h: max(pad.h - 2 * spread, 0'f32))
    op.radii = holeRadii
    op.`cast` = pad
    op.castRadii = padRadii
  else:
    let spread = value.spread
    let shadowBox = Rect(x: box.x + value.x - spread,
      y: box.y + value.y - spread,
      w: box.w + 2 * spread, h: box.h + 2 * spread)
    op.rect = shadowBox.sceneRect(root, scale)
    for i, radius in node.radius:
      if radius > 0:
        op.radii[i] = max(radius + spread, 0'f32).scaled(scale)
    op.`cast` = castRect
    op.castRadii = castRadii
  for point in [op.rect.x, op.rect.y, op.rect.w, op.rect.h,
      op.blur, op.`cast`.x, op.`cast`.y, op.`cast`.w, op.`cast`.h]:
    if not point.finite:
      raise newException(ValueError, "ui: shadow exceeds the float range")
  for radii in [op.radii, op.castRadii]:
    for radius in radii:
      if not radius.finite:
        raise newException(ValueError,
          "ui: shadow radius exceeds the float range")
  op.wide = s.addWide(wideColors(value.color, transparent, transparent))
  s.ops.add(op)

proc effectiveTextColor(nodes: seq[ElementNode]; slot: int): Color =
  let node = nodes[slot]
  if node.textColorSet:
    return node.textColor
  var parent = int(node.parent)
  while parent > 0:
    let ancestor = nodes[parent]
    if ancestor.listRowSelected:
      return ancestor.listSelectedTextColor
    parent = int(ancestor.parent)
  node.textColor

proc paintSpanFill(s: scene.Scene; rect: scene.Rect; color: Color;
                  radius, opacity: float32) =
  if rect.w <= 0 or rect.h <= 0 or color.a == 0:
    return
  let corner = max(radius, 0'f32)
  var op = scene.Op(kind: scene.opFill, rect: rect,
    color: sceneColor(color), paint: scene.paintSolid,
    radii: [corner, corner, corner, corner], opacity: opacity)
  op.wide = s.addWide(wideColors(color, transparent, transparent))
  s.ops.add(op)

proc paintRichBackgrounds(s: scene.Scene; node: ElementNode; root: Rect;
                          scale, opacity, originX, originY: float32) =
  for line in node.shapedText.lines:
    var i = 0
    while i < line.glyphs.len:
      let spanIndex = node.richSpanAt(line.glyphs[i].cluster)
      var j = i + 1
      while j < line.glyphs.len and
          node.richSpanAt(line.glyphs[j].cluster) == spanIndex:
        inc j
      if spanIndex >= 0 and node.textSpans[spanIndex].background.a > 0:
        let span = node.textSpans[spanIndex]
        var x0 = float32.high
        var x1 = -float32.high
        for k in i..<j:
          let glyph = line.glyphs[k]
          x0 = min(x0, min(glyph.x, glyph.x + glyph.advance))
          x1 = max(x1, max(glyph.x, glyph.x + glyph.advance))
        if x1 > x0:
          var y = line.y
          var h = line.height
          if span.radius > 0:
            let em = line.glyphs[i].size
            let pad = min(em * 0.22'f32, span.radius)
            x0 -= pad
            x1 += pad
            y = line.baseline - em * 0.98'f32
            h = em * 1.32'f32
          let pixels = Rect(x: root.x + originX + x0,
            y: root.y + originY + y, w: x1 - x0, h: h).sceneRect(root, scale)
          s.paintSpanFill(pixels, span.background,
            span.radius.scaled(scale), opacity)
      i = j

proc paintWavyUnderline(s: scene.Scene; stroke: textStack.Stroke;
                        color: Color; opacity: float32) =
  let width = stroke.x1 - stroke.x0
  let thick = max(stroke.bottom - stroke.top, 1'f32)
  if width <= 0:
    return
  let period = max(thick * 6, 6'f32)
  let step = max(period / 8, 1'f32)
  let count = max(int(ceil(float64(width / step))), 1)
  let center = (stroke.top + stroke.bottom) / 2
  let amplitude = thick * 0.75'f32
  for i in 0..<count:
    let x0 = stroke.x0 + width * float32(i) / float32(count)
    let x1 = stroke.x0 + width * float32(i + 1) / float32(count)
    let mid = (x0 + x1) / 2
    let y = center - amplitude * float32(sin(
      float64((mid - stroke.x0) / period * 2'f32 * PI.float32)))
    s.paintSpanFill(scene.Rect(x: x0, y: y - thick / 2,
      w: x1 - x0 + 1, h: thick), color, thick / 2, opacity)

proc paintRichDecorations(s: scene.Scene; node: ElementNode; textColor: Color;
                          scale, opacity, originX, originY: float32;
                          system: textStack.System) =
  for lineIndex, line in node.shapedText.lines:
    var i = 0
    while i < line.glyphs.len:
      let spanIndex = node.richSpanAt(line.glyphs[i].cluster)
      var j = i + 1
      while j < line.glyphs.len and
          node.richSpanAt(line.glyphs[j].cluster) == spanIndex:
        inc j
      if spanIndex >= 0:
        let span = node.textSpans[spanIndex]
        let decorationColor = if span.decorationColor.a > 0:
            span.decorationColor
          elif span.color.a > 0: span.color
          else: textColor
        for decoration in [textStack.Underline, textStack.Strikethrough]:
          let underline = decoration == textStack.Underline
          if (underline and not (span.underline or span.wavyUnderline)) or
              (not underline and not span.strikethrough):
            continue
          let strokes = system.decorate(node.shapedText, lineIndex, i, j,
            originX, originY, scale, decoration, span.decorationThickness)
          for stroke in strokes:
            if stroke.x1 <= stroke.x0 or stroke.bottom <= stroke.top:
              continue
            if underline and span.wavyUnderline:
              s.paintWavyUnderline(stroke, decorationColor, opacity)
            else:
              s.paintSpanFill(scene.Rect(x: stroke.x0, y: stroke.top,
                w: stroke.x1 - stroke.x0, h: stroke.bottom - stroke.top),
                decorationColor, 0, opacity)
      i = j

proc paintText(s: scene.Scene; node: ElementNode; textColor: Color;
               rect, root: Rect; scale, opacity: float32;
               system: textStack.System) =
  if not node.hasText or node.textInline or node.shapedText == nil:
    return
  if textColor.a == 0:
    var spanPaints = false
    for span in node.textSpans:
      if span.color.a > 0 or span.background.a > 0 or
          span.decorationColor.a > 0 or span.underline or
          span.wavyUnderline or span.strikethrough:
        spanPaints = true
        break
    if not spanPaints:
      return
  let originX = rect.x - root.x + node.pad[3] + node.border[3]
  let originY = rect.y - root.y + node.pad[0] + node.border[0]
  s.paintRichBackgrounds(node, root, scale, opacity, originX, originY)
  let start = s.glyphs.len
  for line in node.shapedText.lines:
    let baseline = system.baseline((originY + line.baseline) * scale)
    for glyph in line.glyphs:
      if glyph.`object` or glyph.font.isNil:
        continue
      let spanIndex = node.richSpanAt(glyph.cluster)
      let color = if spanIndex >= 0 and
          node.textSpans[spanIndex].color.a > 0:
          node.textSpans[spanIndex].color
        else:
          textColor
      let wideIndex = s.addWide(wideColors(color, transparent, transparent))
      let shade = textStack.shadeOf(color.r, color.g, color.b)
      let pen = (originX + glyph.x) * scale
      let image = system.glyph(glyph.font, glyph.id, scale, pen, shade, false)
      if not image.ok:
        continue
      s.glyphs.add(scene.Glyph(x: floor(pen) + image.left,
        y: baseline + image.top, w: float32(image.w), h: float32(image.h),
        u: image.x, v: image.y, uw: image.w, vh: image.h,
        color: sceneColor(color), wide: wideIndex, colored: image.colored,
        subpixel: image.subpixel, thin: image.thin))
  if s.glyphs.len > start:
    s.ops.add(scene.Op(kind: scene.opGlyphs, first: int32(start),
      last: int32(s.glyphs.len), opacity: opacity))
  s.paintRichDecorations(node, textColor, scale, opacity, originX, originY,
    system)

proc painterRichTextParams(painter: Painter; width: float32;
                           spans: openArray[Span]): tuple[
    params: textStack.Params, spans: seq[Span], ends: seq[int]] =
  var value = ""
  var ending = 0
  result.spans = newSeqOfCap[Span](spans.len)
  result.ends = newSeqOfCap[int](spans.len)
  for source in spans:
    let span = normalizeRichTextSpan(source)
    result.spans.add(span)
    value.add(span.text)
    ending += span.text.runeLen
    result.ends.add(ending)
  result.params = textStack.Params(text: value,
    style: textStack.Style(family: painter.theme.font,
      size: painter.theme.fontSize, lang: painter.localeTag),
    width: if width.finiteRichText: max(width, 0'f32) else: 0'f32,
    spans: encodeRichTextSpans(result.spans))

proc measureText*(painter: Painter; width: float32;
                  spans: varargs[Span]): tuple[width, height: float32] =
  ## Measures styled text in DIPs, wrapping at width; zero only breaks at newlines.
  if painter.textSystem == nil:
    return
  let params = painter.painterRichTextParams(width, spans)
  let layout = painter.textSystem.layout(params.params)
  result = (layout.width, layout.height)

proc richText*(painter: var Painter; x, y, width: float32;
               spans: varargs[Span]): tuple[width, height: float32] =
  ## Draws styled text from its top-left in DIPs and returns its size.
  if painter.textSystem == nil:
    return
  let params = painter.painterRichTextParams(width, spans)
  let layout = painter.textSystem.layout(params.params)
  result = (layout.width, layout.height)
  if painter.frame == nil:
    return
  let node = ElementNode(hasText: true, textSpans: params.spans,
    textSpanEnds: params.ends, textColor: painter.theme.text,
    shapedText: layout)
  painter.frame.paintText(node, painter.theme.text,
    Rect(x: x, y: y, w: layout.width, h: layout.height), painter.root,
    painter.scale, painter.opacity, painter.textSystem)

proc text*(painter: var Painter; x, y: float32; value: string;
           size: float32; color: Color) =
  ## Draws a line of text from its top-left corner in DIPs.
  if painter.textSystem == nil or painter.frame == nil:
    return
  let layout = painter.textSystem.layout(textStack.Params(text: value,
    style: textStack.Style(size: size)))
  let node = ElementNode(hasText: true, shapedText: layout)
  painter.frame.paintText(node, color,
    Rect(x: x, y: y, w: layout.width, h: layout.height), painter.root,
    painter.scale, painter.opacity, painter.textSystem)

proc paintTextSelection(s: scene.Scene; owner: ElementOwner;
                        node: ElementNode; rect, root: Rect;
                        scale, opacity: float32) =
  var client: TextFieldClient
  var selectionColor = node.textSelectionColor
  if node.textAreaOwner of TextFieldClient:
    let parent = int(node.parent)
    if owner == nil or parent <= 0 or parent >= owner.nodes.len or
        not owner.nodes[parent].focused or node.shapedText == nil:
      return
    client = TextFieldClient(node.textAreaOwner)
    selectionColor = owner.nodes[parent].textSelectionColor
    discard client.syncTextAreaBuffer()
    let range = client.fieldRange()
    if range.start == range.`end`:
      return
    let firstRune = client.bufferSnapshot.runeOffset(range.start)
    let pastLastRune = client.bufferSnapshot.runeOffset(range.`end`)
    let line = client.bufferSnapshot.lineRange(node.textAreaLine)
    if pastLastRune < line.start or firstRune > line.`end` or
        (firstRune == line.`end` and pastLastRune == firstRune):
      return
    let localStart = max(firstRune - line.start, 0)
    let localEnd = min(pastLastRune - line.start,
      line.`end` - line.start + 1)
    let originX = rect.x + node.pad[3] + node.border[3]
    let originY = rect.y + node.pad[0] + node.border[0]
    for selected in node.shapedText.appendSelection(@[], localStart,
        max(localStart, localEnd), false):
      let selectedRect = Rect(x: originX + selected.x,
        y: originY + selected.y, w: selected.w, h: selected.h)
      s.ops.add(scene.Op(kind: scene.opFill,
        rect: selectedRect.sceneRect(root, scale),
        color: sceneColor(selectionColor), paint: scene.paintSolid,
        opacity: opacity))
      s.ops[^1].wide = s.addWide(wideColors(selectionColor, transparent,
        transparent))
    return
  if not node.focused or not (node.textClient of TextFieldClient) or
      node.shapedText == nil:
    return
  client = TextFieldClient(node.textClient)
  let range = client.fieldRange()
  let originX = rect.x + node.pad[3] + node.border[3]
  let originY = rect.y + node.pad[0] + node.border[0]
  if range.start != range.`end`:
    let first = runeIndexAtUtf16(client.text, range.start)
    let pastLast = runeIndexAtUtf16(client.text, range.`end`)
    for selected in node.shapedText.appendSelection(@[], first, pastLast, false):
      let selectedRect = Rect(x: originX + selected.x,
        y: originY + selected.y, w: selected.w, h: selected.h)
      s.ops.add(scene.Op(kind: scene.opFill,
        rect: selectedRect.sceneRect(root, scale),
        color: sceneColor(selectionColor), paint: scene.paintSolid,
        opacity: opacity))
      s.ops[^1].wide = s.addWide(wideColors(selectionColor, transparent,
        transparent))

proc paintTextCaret(s: scene.Scene; node: ElementNode; rect, root: Rect;
                    scale, opacity: float32) =
  if not node.focused or not (node.textClient of TextFieldClient):
    return
  let client = TextFieldClient(node.textClient)
  if client.multiline:
    return
  let (caret, _, _) = client.boundsForRange(platform.TextRange(
    start: client.caret, `end`: client.caret))
  let caretRect = Rect(x: rect.x + float32(caret.x),
    y: rect.y + float32(caret.y), w: max(float32(caret.w), 1'f32),
    h: max(float32(caret.h), 1'f32))
  let color = node.textColor
  s.ops.add(scene.Op(kind: scene.opFill,
    rect: caretRect.sceneRect(root, scale), color: sceneColor(color),
    paint: scene.paintSolid, opacity: opacity))
  s.ops[^1].wide = s.addWide(wideColors(color, transparent, transparent))

proc fitImage(box, source: Rect; fit: Fit):
    tuple[rect: Rect, src: scene.Rect] =
  if source.w <= 0 or source.h <= 0 or box.w <= 0 or box.h <= 0:
    return
  let imageW = source.w
  let imageH = source.h
  result.src = scene.Rect(x: source.x, y: source.y, w: imageW, h: imageH)
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
    result.src = scene.Rect(x: source.x + (imageW - width) / 2,
      y: source.y + (imageH - height) / 2, w: width, h: height)
    result.rect = box
  of Fit.NaturalSize:
    let width = min(imageW, box.w)
    let height = min(imageH, box.h)
    let x = box.x + (box.w - imageW) / 2
    let y = box.y + (box.h - imageH) / 2
    result.rect = Rect(x: max(x, box.x), y: max(y, box.y),
      w: width, h: height)
    result.src = scene.Rect(x: source.x + result.rect.x - x,
      y: source.y + result.rect.y - y, w: width, h: height)

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
              scale, opacity: float32) =
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
    image: image, src: src, color: sceneColor(node.imageTint),
    grayscale: node.grayscale, opacity: opacity))

proc paintBitmap(s: scene.Scene; node: ElementNode; rect, root: Rect;
                 scale, opacity: float32) =
  if node.bitmap == nil or node.bitmap.image == nil:
    return
  let box = Rect(x: rect.x + node.pad[3] + node.border[3],
    y: rect.y + node.pad[0] + node.border[0],
    w: max(rect.w - node.contentInsetX, 0'f32),
    h: max(rect.h - node.contentInsetY, 0'f32))
  let fitted = fitImage(box, node.bitmapSource, node.fit)
  if fitted.rect.w <= 0 or fitted.rect.h <= 0:
    return
  let pixelRect = fitted.rect.sceneRect(root, scale)
  if pixelRect.empty:
    return
  let enlarged = fitted.rect.w * scale >= fitted.src.w or
    fitted.rect.h * scale >= fitted.src.h
  var src = fitted.src
  if node.flipX:
    src.x += src.w
    src.w = -src.w
  if node.flipY:
    src.y += src.h
    src.h = -src.h
  s.ops.add(scene.Op(kind: scene.opImage, rect: pixelRect,
    radii: node.radius.scaledEdges(scale), continuous: continuousCorners,
    image: node.bitmap.image, src: src,
    pixelated: node.bitmap.pixelated and enlarged,
    color: sceneColor(node.imageTint), grayscale: node.grayscale,
    opacity: opacity))

proc pixelTransform(layout: LayoutResult; slot: int;
                    scale: float32): scene.Affine =
  if slot >= layout.worldTransforms.len:
    return
  let world = layout.worldTransforms[slot]
  if not world.`set`:
    return
  let rootX = layout.root.x
  let rootY = layout.root.y
  let divisor = world.w(rootX, rootY)
  if divisor == 0 or not divisor.finite:
    return scene.Affine(`set`: true)
  let a = (world.a - rootX * world.g) / divisor
  let b = (world.b - rootY * world.g) / divisor
  let c = (world.c - rootX * world.h) / divisor
  let d = (world.d - rootY * world.h) / divisor
  let x = scale * (world.a * rootX + world.c * rootY + world.x -
    rootX * divisor) / divisor
  let y = scale * (world.b * rootX + world.d * rootY + world.y -
    rootY * divisor) / divisor
  let g = world.g / (scale * divisor)
  let h = world.h / (scale * divisor)
  validateTransformValues(a, b, c, d, x, y, g, h)
  result = scene.projective(a, b, c, d, x, y, g, h)

proc applyLayoutTransform(frame: scene.Scene; first: int;
                          layout: LayoutResult; slot: int; scale: float32) =
  let transform = layout.pixelTransform(slot, scale)
  if not transform.`set`:
    return
  for i in first ..< frame.ops.len:
    if frame.ops[i].kind in {scene.opPushClip, scene.opPopClip}:
      continue
    let composed = scene.mul(transform, frame.ops[i].transform)
    validateTransform(composed)
    frame.ops[i].transform = composed

proc clipOp(layout: LayoutResult; slot: int; scale: float32): scene.Op =
  let node = layout.owner.nodes[slot]
  let box = layout.rects[slot]
  var clip = Rect(x: box.x + node.border[3],
    y: box.y + node.border[0],
    w: max(box.w - node.border[1] - node.border[3], 0'f32),
    h: max(box.h - node.border[0] - node.border[2], 0'f32))
  let clipsX = node.scrollState != nil or node.clipX
  let clipsY = node.scrollState != nil or node.clipY
  var radii = [
    max(node.radius[0] - max(node.border[0], node.border[3]), 0'f32),
    max(node.radius[1] - max(node.border[0], node.border[1]), 0'f32),
    max(node.radius[2] - max(node.border[2], node.border[1]), 0'f32),
    max(node.radius[3] - max(node.border[2], node.border[3]), 0'f32)]
  if not clipsX:
    clip.x = layout.root.x - 1_000_000'f32
    clip.w = 2_000_000'f32
  if not clipsY:
    clip.y = layout.root.y - 1_000_000'f32
    clip.h = 2_000_000'f32
  if not (clipsX and clipsY):
    radii = [0'f32, 0, 0, 0]
  result = scene.Op(kind: scene.opPushClip,
    rect: clip.sceneRect(layout.root, scale),
    radii: radii.scaledEdges(scale), continuous: continuousCorners)
  result.transform = layout.pixelTransform(slot, scale)

proc opacityOf(nodes: seq[ElementNode]; slot: int): float32 =
  result = 1
  var current = slot
  var disabledSeen = false
  while current >= 0:
    let node = nodes[current]
    if node.toolbarCollapsed:
      return 0
    if node.opacitySet:
      result *= node.opacity
      if result == 0:
        return
    result *= 1'f32 - node.poseFade
    if result == 0:
      return
    if node.disabled and not disabledSeen:
      result *= 0.5'f32
      disabledSeen = true
    current = int(node.parent)

proc paintScrollbar(sceneFrame: scene.Scene; layout: LayoutResult;
                    slot: int; rect: Rect; scale, opacity: float32) =
  if rect.w <= 0 or rect.h <= 0:
    return
  let color = layout.owner.nodes[slot].scrollbarColor
  var clips = 0
  var parent = int(layout.owner.nodes[slot].parent)
  while parent >= 0:
    if layout.owner.nodes[parent].clipsChildren:
      sceneFrame.ops.add(layout.clipOp(parent, scale))
      inc clips
    parent = int(layout.owner.nodes[parent].parent)
  let radius = min(rect.w, rect.h) / 2 * scale
  sceneFrame.ops.add(scene.Op(kind: scene.opFill,
    rect: rect.sceneRect(layout.root, scale),
    color: sceneColor(color), paint: scene.paintSolid,
    radii: [radius, radius, radius, radius],
    continuous: continuousCorners, opacity: opacity))
  sceneFrame.ops[^1].wide = sceneFrame.addWide(
    wideColors(color, transparent, transparent))
  for _ in 0..<clips:
    sceneFrame.ops.add(scene.Op(kind: scene.opPopClip))

proc paintListReorderIndicator(sceneFrame: scene.Scene; layout: LayoutResult;
                               slot: int; scale: float32) =
  let node = layout.owner.nodes[slot]
  let state = node.listState
  if state == nil or not state.reorderDragging or
      not state.reorderTargetValid or state.reorderColor.a == 0:
    return
  let box = layout.rects[slot]
  let left = box.x + node.border[3] + node.pad[3]
  let right = box.x + box.w - node.border[1] - node.pad[1]
  if right - left <= 8:
    return
  let rtl = node.rightToLeft
  let lineX = if rtl: left else: left + 4
  let lineW = max(right - left - 8, 0'f32)
  let dotX = if rtl: right - 8 else: left
  let y = state.reorderIndicatorY
  let opacity = opacityOf(layout.owner.nodes, slot)
  if opacity == 0:
    return
  var clips = 0
  var parent = slot
  while parent >= 0:
    if layout.owner.nodes[parent].clipsChildren:
      sceneFrame.ops.add(layout.clipOp(parent, scale))
      inc clips
    parent = int(layout.owner.nodes[parent].parent)
  for item in [
      Rect(x: lineX, y: y - 1, w: lineW, h: 2),
      Rect(x: dotX, y: y - 4, w: 8, h: 8)]:
    if item.w <= 0 or item.h <= 0:
      continue
    let radius = if item.w < item.h: item.w / 2 else: item.h / 2
    sceneFrame.ops.add(scene.Op(kind: scene.opFill,
      rect: item.sceneRect(layout.root, scale),
      color: sceneColor(state.reorderColor), paint: scene.paintSolid,
      radii: [radius * scale, radius * scale, radius * scale, radius * scale],
      continuous: continuousCorners, opacity: opacity))
    sceneFrame.ops[^1].wide = sceneFrame.addWide(
      wideColors(state.reorderColor, transparent, transparent))
  for _ in 0..<clips:
    sceneFrame.ops.add(scene.Op(kind: scene.opPopClip))

proc paintFocusRingRect(sceneFrame: scene.Scene; layout: LayoutResult;
                        slot: int; boundsDip: Rect; scale: float32;
                        inset: bool) =
  let node = layout.owner.nodes[slot]
  let color = node.focusRingColor
  if color.a == 0:
    return
  let bounds = boundsDip.sceneRect(layout.root, scale)
  let expand = 3'f32.scaled(scale)
  let width = 2'f32.scaled(scale)
  var rect = bounds
  if not inset:
    rect.x -= expand
    rect.y -= expand
    rect.w += expand * 2
    rect.h += expand * 2
  if not rect.x.finite or not rect.y.finite or not rect.w.finite or
      not rect.h.finite:
    raise newException(ValueError, "ui: focus ring exceeds the float range")
  var radii = node.radius.scaledEdges(scale)
  for radius in radii.mitems:
    radius += expand
    if not radius.finite:
      raise newException(ValueError, "ui: focus ring radius exceeds the float range")
  let opacity = opacityOf(layout.owner.nodes, slot)
  if opacity == 0:
    return
  var clips = 0
  var parent = int(node.parent)
  while parent >= 0:
    if layout.owner.nodes[parent].clipsChildren:
      sceneFrame.ops.add(layout.clipOp(parent, scale))
      inc clips
    parent = int(layout.owner.nodes[parent].parent)
  var op = scene.Op(kind: scene.opFill, rect: rect,
    color: sceneColor(transparent), paint: scene.paintSolid,
    radii: radii, border: [width, width, width, width],
    continuous: continuousCorners, borderColor: sceneColor(color),
    opacity: opacity)
  op.wide = sceneFrame.addWide(wideColors(transparent, transparent, color))
  sceneFrame.ops.add(op)
  for _ in 0..<clips:
    sceneFrame.ops.add(scene.Op(kind: scene.opPopClip))

proc paintFocusRing(sceneFrame: scene.Scene; layout: LayoutResult;
                    slot: int; scale: float32; inset = false) =
  let node = layout.owner.nodes[slot]
  if node.textInline:
    for rect in node.textInlineRects:
      sceneFrame.paintFocusRingRect(layout, slot, rect, scale, inset)
  else:
    sceneFrame.paintFocusRingRect(layout, slot, layout.rects[slot], scale,
      inset)

proc collectPaintOrder(nodes: seq[ElementNode]; slot: int;
                       order: var seq[int]) =
  order.add(slot)
  var child = int(nodes[slot].firstChild)
  while child >= 0:
    if not nodes[child].absolute:
      collectPaintOrder(nodes, child, order)
    child = int(nodes[child].nextSibling)
  child = int(nodes[slot].firstChild)
  while child >= 0:
    if nodes[child].absolute:
      collectPaintOrder(nodes, child, order)
    child = int(nodes[child].nextSibling)

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

  layout.owner.paintSlots.setLen(0)
  if layout.owner.nodes.len > 0:
    collectPaintOrder(layout.owner.nodes, 0, layout.owner.paintSlots)

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

      for slot in layout.owner.paintSlots:
        if layout.backfaceBlocked[slot]:
          continue
        let node = layout.owner.nodes[slot]
        let opacity = opacityOf(layout.owner.nodes, slot)
        if opacity == 0:
          continue
        let fill = if node.hasGradient: node.gradient.fromColor else: node.background
        let fill2 = if node.hasGradient: node.gradient.toColor else: transparent
        let fillVisible = if node.textInline:
            false
          elif node.hasGradient:
            fill.a > 0 or fill2.a > 0
          else:
            fill.a > 0
        let borderVisible = not node.textInline and
          node.borderColor.a > 0 and scene.hasBorder(node.border)
        if not fillVisible and not borderVisible and node.shadows.len == 0 and
            not node.hasText and node.bitmap == nil and node.vector == nil and
            node.drawFn == nil:
          continue

        let rect = layout.rects[slot].sceneRect(layout.root, scale)
        if rect.empty:
          continue
        var clipCount = 0
        var isTooltip = node.tooltipOverlay
        var parent = int(node.parent)
        while parent >= 0:
          if layout.owner.nodes[parent].tooltipOverlay:
            isTooltip = true
          if layout.owner.nodes[parent].clipsChildren and not isTooltip:
            result.ops.add(layout.clipOp(parent, scale))
            inc clipCount
          parent = int(layout.owner.nodes[parent].parent)
        let firstNodeOp = result.ops.len
        for shadow in node.shadows:
          if not node.textInline and not shadow.inset:
            result.paintShadow(node, layout.rects[slot], layout.root,
                               scale, opacity, shadow)
        if fillVisible or borderVisible:
          var op = scene.Op(kind: scene.opFill, rect: rect,
            color: sceneColor(fill), color2: sceneColor(fill2),
            paint: scene.paintSolid,
            radii: node.radius.scaledEdges(scale),
            border: node.border.scaledEdges(scale),
            continuous: continuousCorners,
            borderColor: sceneColor(node.borderColor),
            dashed: node.borderStyle == BorderStyle.Dashed,
            opacity: opacity)
          if node.hasGradient:
            let gradient = sceneGradient(rect, node.gradient)
            op.paint = gradient.paint
            op.gradient = gradient.points
          var wide = fill.wideColors(fill2, node.borderColor)
          if not borderVisible:
            wide.border = [0'f32, 0, 0, 0]
            wide.`set` = wide.`set` and not scene.wideBorder
          if not fillVisible:
            wide.color = [0'f32, 0, 0, 0]
            wide.color2 = [0'f32, 0, 0, 0]
            wide.`set` = wide.`set` and not scene.wideColor and
              not scene.wideColor2
          op.wide = result.addWide(wide)
          result.ops.add(op)
        for shadow in node.shadows:
          if not node.textInline and shadow.inset:
            result.paintShadow(node, layout.rects[slot], layout.root,
                               scale, opacity, shadow)
        let clipFieldText = node.textClient of TextFieldClient and
          (node.clipX or node.clipY)
        if clipFieldText:
          result.ops.add(layout.clipOp(slot, scale))
        result.paintTextSelection(layout.owner, node, layout.rects[slot],
                                  layout.root, scale, opacity)
        result.paintText(node, layout.owner.nodes.effectiveTextColor(slot),
          layout.rects[slot], layout.root, scale, opacity, system)
        result.paintTextCaret(node, layout.rects[slot], layout.root,
                              scale, opacity)
        if clipFieldText:
          result.ops.add(scene.Op(kind: scene.opPopClip))
        result.paintBitmap(node, layout.rects[slot], layout.root, scale,
                           opacity)
        result.paintSvg(node, layout.rects[slot], layout.root, scale, opacity)
        if node.drawFn != nil:
          var painter = Painter(frame: result, textSystem: system,
            theme: layout.owner.themeSnapshot,
            localeTag: layout.owner.localeSnapshot, root: layout.root,
            scale: scale, opacity: opacity)
          node.drawFn(painter, layout.rects[slot])
        result.applyLayoutTransform(firstNodeOp, layout, slot, scale)
        for _ in 0..<clipCount:
          result.ops.add(scene.Op(kind: scene.opPopClip))

      for slot in layout.owner.paintSlots:
        if layout.backfaceBlocked[slot]:
          continue
        let node = layout.owner.nodes[slot]
        if not node.focused or not (node.textClient of TextFieldClient):
          continue
        let client = TextFieldClient(node.textClient)
        if not client.multiline or not (node.clipX or node.clipY):
          continue
        let firstCaretOp = result.ops.len
        result.ops.add(layout.clipOp(slot, scale))
        result.paintTextCaret(node, layout.rects[slot], layout.root,
                              scale, opacityOf(layout.owner.nodes, slot))
        result.ops.add(scene.Op(kind: scene.opPopClip))
        result.applyLayoutTransform(firstCaretOp, layout, slot, scale)

      for slot in layout.owner.paintSlots:
        if layout.backfaceBlocked[slot]:
          continue
        let node = layout.owner.nodes[slot]
        let state = node.scrollState
        if state == nil or
            (not state.scrollbarDragging and
              slot notin layout.owner.hoveredSlots):
          continue
        let bars = layout.scrollbars(slot)
        let opacity = opacityOf(layout.owner.nodes, slot)
        let firstScrollbarOp = result.ops.len
        if bars.vertical:
          paintScrollbar(result, layout, slot, bars.verticalThumb, scale,
            opacity)
        if bars.horizontal:
          paintScrollbar(result, layout, slot, bars.horizontalThumb, scale,
            opacity)
        result.applyLayoutTransform(firstScrollbarOp, layout, slot, scale)

      for slot in layout.owner.paintSlots:
        if layout.backfaceBlocked[slot]:
          continue
        let node = layout.owner.nodes[slot]
        let firstDecorationOp = result.ops.len
        if node.listState != nil and node.listRowIndex == -1:
          result.paintListReorderIndicator(layout, slot, scale)
        if node.listRowFocusVisible:
          result.paintFocusRing(layout, slot, scale, inset = true)
        elif node.focusVisible and node.focusable and
            not node.focusRingDisabled:
          result.paintFocusRing(layout, slot, scale)
        result.applyLayoutTransform(firstDecorationOp, layout, slot, scale)

      if not system.full() or attempt == 2:
        break
      system.makeRoom()
  finally:
    system.endFrame()
