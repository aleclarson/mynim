## Liquid Glass as a native UI material and painter effect.

import std/[math, options, strutils, times]
import mynim/internal/scene as scene
import mynim/ui as ui

type
  GlassStyle* = enum
    Regular, Clear

  Glass* = ref object of ui.Material
    style*: GlassStyle
    tint*: ui.Color
    interactive*: bool

  Blur* = ref object of ui.Material ## Blurs the content behind an element.
    radius*: float32 ## Gaussian standard deviation in DIPs.
    mask*: Option[ui.LinearGradient] ## Varies blur by the gradient's alpha.

  ScrollEdge* = ref object of ui.Material ## Fades or frosts content at a bar.
    hard*: bool ## Blurs and tones evenly when true; otherwise fades softly.
    bottom*: bool ## Places the bar at the bottom and the effect above it.
    background*: ui.Color ## Replay color; transparent uses the theme background.

  PressedGlass = ref object of ui.Material
    glass: Glass
    grow: float32

  GlassMaterial = object
    blur: float32
    bezel, refraction: float32
    low, high, curve, saturation: float32
    tint, wideTint: array[4, float32]
    rim, rimWidth, light: float32

  GlassPixels = ref object of scene.EffectPixels
    material: GlassMaterial
    rect: scene.Rect
    radii: array[4, float32]
    lightX, lightY: float32
    toneTable: array[1025, float32]
    toneLinear: bool

  BlurLevel = object
    blur, lo, hi: float32

  BlurTone = object
    saturation, offset, mix: float32
    color: array[3, float32]

  BlurPixels = ref object of scene.EffectPixels
    line, band, tone, color: array[4, float32]

const
  pressKey = "\x00mynim.glass.press"
  toneSteps = 1024
  glassMetalSource = staticRead("glass/glass.metal")
  glassHlslSource = staticRead("glass/glass.hlsl")
  glassGlslSource = staticRead("glass/glass.glsl")
  blurMetalSource = staticRead("glass/blur.metal")
  blurHlslSource = staticRead("glass/blur.hlsl")
  blurGlslSource = staticRead("glass/blur.glsl")

proc newGlassPixels(): scene.EffectPixels = GlassPixels()
proc newBlurPixels(): scene.EffectPixels = BlurPixels()

let Effect* = block:
  var value: ref scene.Effect
  new(value)
  value.name = "glass"
  value.backdrop = true
  value.metal.source = glassMetalSource
  value.hlsl.source = glassHlslSource
  value.glsl = glassGlslSource
  value.pixels = newGlassPixels
  value

let blurEffect = block:
  var value: ref scene.Effect
  new(value)
  value.name = "blur"
  value.backdrop = true
  value.metal.source = blurMetalSource
  value.hlsl.source = blurHlslSource
  value.glsl = blurGlslSource
  value.pixels = newBlurPixels
  value

proc sqrt(value: float32): float32 =
  float32(math.sqrt(value.float64))

proc pow(value, exponent: float32): float32 =
  float32(math.pow(value.float64, exponent.float64))

proc abs(value: float32): float32 =
  if value < 0: -value else: value

proc sign(value: float32): float32 =
  if value > 0: 1
  elif value < 0: -1
  else: 0

proc lens(distance, bezel: float32): float32 =
  if bezel <= 0 or distance >= bezel:
    return 0
  let
    u = 1 - max(distance, 0'f32) / bezel
    v = 1 - u * u * u * u
    a = sqrt(v * sqrt(v))
    b = u * u * u
    n = sqrt(a * a + b * b)
    s = b / n
    c = a / n
    st = s / 1.5'f32
    ct = sqrt(1 - st * st)
  (s * ct - c * st) / (c * ct + s * st) / 1.118034'f32

proc normal(px, py: float32; rect: scene.Rect;
            radii: array[4, float32]): tuple[x, y: float32] =
  let
    hx = rect.w / 2
    hy = rect.h / 2
    cx = px - rect.x - hx
    cy = py - rect.y - hy
  var radius: float32
  if cx < 0 and cy < 0: radius = radii[0]
  elif cx >= 0 and cy < 0: radius = radii[1]
  elif cx >= 0: radius = radii[2]
  else: radius = radii[3]
  radius = min(radius * 1.5'f32, min(hx, hy))
  let
    qx = abs(cx) - (hx - radius)
    qy = abs(cy) - (hy - radius)
  if qx > 0 or qy > 0:
    let
      mx = max(qx, 0'f32)
      my = max(qy, 0'f32)
      n = sqrt(mx * mx + my * my)
    return (sign(cx) * mx / n, sign(cy) * my / n)
  if qx > qy: (sign(cx), 0'f32)
  else: (0'f32, sign(cy))

proc toneAt(color: array[3, float32]; lightness, target: float32;
            material: GlassMaterial): array[3, float32] =
  result = color
  let spread = (material.high - material.low) * material.saturation
  for channel in result.mitems:
    channel = min(max(target + (channel - lightness) * spread, 0'f32), 1'f32)

proc tone(pixels: GlassPixels; color: array[3, float32]): array[3, float32] =
  let
    material = pixels.material
    lightness = 0.2126'f32 * color[0] + 0.7152'f32 * color[1] +
      0.0722'f32 * color[2]
  var curve = min(max(lightness, 0'f32), 1'f32)
  if not pixels.toneLinear:
    let index = curve * toneSteps.float32
    let i = min(int(index), toneSteps - 1)
    let fraction = index - i.float32
    curve = pixels.toneTable[i] +
      (pixels.toneTable[i + 1] - pixels.toneTable[i]) * fraction
  let target = material.low + (material.high - material.low) * curve
  toneAt(color, lightness, target, material)

method begin*(pixels: GlassPixels; op: scene.EffectOp; rect: scene.Rect;
              radii: array[4, float32]) =
  let params = op.params
  pixels.material = GlassMaterial(
    blur: op.blur,
    bezel: params[0][0], refraction: params[0][1],
    rim: params[0][2], rimWidth: params[0][3],
    tint: params[1], low: params[2][0], high: params[2][1],
    curve: params[2][2], saturation: params[2][3])
  pixels.lightX = params[3][0]
  pixels.lightY = params[3][1]
  pixels.rect = rect
  pixels.radii = radii
  pixels.toneLinear = pixels.material.curve == 1
  if not pixels.toneLinear:
    for i in 0 .. toneSteps:
      pixels.toneTable[i] = 1 - pow(
        1 - i.float32 / toneSteps.float32, pixels.material.curve)

method color*(pixels: GlassPixels; x, y: float32;
              backdrop: scene.BackdropImage): array[4, float32] =
  let material = pixels.material
  let distance = max(-scene.sdRoundRect(pixels.rect, pixels.radii, x, y), 0'f32)
  var nx, ny: float32
  if distance < material.bezel or distance < 3 * material.rimWidth:
    (nx, ny) = normal(x, y, pixels.rect, pixels.radii)
  var sampleX = x
  var sampleY = y
  if distance < material.bezel:
    let offset = material.refraction * lens(distance, material.bezel)
    sampleX -= nx * offset
    sampleY -= ny * offset
  var color = tone(pixels, backdrop.sample(sampleX, sampleY))
  for channel in 0 .. 2:
    color[channel] += (material.tint[channel] - color[channel]) * material.tint[3]
  if material.rim > 0 and distance < 3 * material.rimWidth:
    let
      q = distance / material.rimWidth
      amount = material.rim * float32(math.exp(-(q * q).float64))
      light = abs(nx * pixels.lightX + ny * pixels.lightY)
    for channel in color.mitems:
      channel += (light - channel) * amount
  [color[0], color[1], color[2], 1'f32]

proc params(material: GlassMaterial): array[5, array[4, float32]] =
  [
    [material.bezel, material.refraction, material.rim, material.rimWidth],
    material.tint,
    [material.low, material.high, material.curve, material.saturation],
    [float32(math.cos(material.light.float64)),
      float32(math.sin(material.light.float64)), 0'f32, 0'f32],
    material.wideTint]

proc paint(painter: var ui.Painter; box: ui.Rect;
           radii: array[4, float32]; glass: Glass) =
  if glass == nil or box.w <= 0 or box.h <= 0:
    return
  let
    scale = painter.scale()
    size = min(box.w, box.h)
    bezel = min(36'f32, size / 2)
  var material = GlassMaterial(
    bezel: bezel * scale,
    refraction: 1.6'f32 * bezel * scale,
    rim: 0.35'f32,
    rimWidth: 1'f32,
    light: PI.float32 / 2)
  if glass.style == Clear:
    material.blur = scale
    material.low = 0.125'f32
    material.high = 1.082'f32
    material.curve = 1'f32
    material.saturation = 1'f32
  elif painter.theme().dark:
    material.blur = min(max(size * 0.035'f32, 1'f32), 10'f32) * scale
    material.low = 0.15'f32
    material.high = 0.51'f32
    material.curve = 2'f32
    material.saturation = 2.2'f32
  else:
    material.blur = min(max(size * 0.035'f32, 1'f32), 10'f32) * scale
    material.low = 0.541'f32
    material.high = 1'f32
    material.curve = 1.2'f32
    material.saturation = 1'f32
  if glass.tint.a > 0:
    let colors = painter.effectColor(glass.tint)
    material.tint = colors.srgb
    material.wideTint = colors.wide
    material.tint[3] *= 0.88'f32
    material.wideTint[3] *= 0.88'f32
  painter.effect(Effect, box, radii, material.blur, material.params())

method buildMaterial*(glass: Glass; element: ui.Element): ui.Material =
  if glass == nil or not glass.interactive:
    return glass
  let target = if element.pressed(): 1'f32 else: 0'f32
  PressedGlass(glass: glass,
    grow: element.animate(pressKey, target,
      initDuration(milliseconds = 150)))

method paintMaterial*(glass: Glass; painter: var ui.Painter; box: ui.Rect;
                      radii: array[4, float32]) =
  painter.paint(box, radii, glass)

method paintMaterial*(glass: PressedGlass; painter: var ui.Painter;
                      box: ui.Rect; radii: array[4, float32]) =
  let
    dx = 1.1'f32 * glass.grow
    dy = 0.45'f32 * glass.grow
  var grown = radii
  for radius in grown.mitems:
    if radius > 0:
      radius += dy
  painter.paint(ui.Rect(x: box.x - dx, y: box.y - dy,
    w: box.w + 2 * dx, h: box.h + 2 * dy), grown, glass.glass)

proc paint*(painter: var ui.Painter; rect: ui.Rect; radius: float32;
            glass: Glass) =
  ## Paints a rounded pane of glass from a custom draw callback.
  painter.paint(rect, [radius, radius, radius, radius], glass)

proc `$`*(glass: Glass): string =
  if glass == nil:
    return "glass"
  result = "glass"
  if glass.style == Clear:
    result.add(" clear")
  if glass.tint.a > 0:
    result.add(" tint(#" & toHex(glass.tint.r.int, 2).toLowerAscii() &
      toHex(glass.tint.g.int, 2).toLowerAscii() &
      toHex(glass.tint.b.int, 2).toLowerAscii() &
      toHex(glass.tint.a.int, 2).toLowerAscii() & ")")
  if glass.interactive:
    result.add(" interactive")

const
  finestLevel = 2'f32
  softEdge = 0.85'f32
  hardEdgeBlur = 6.4'f32

proc roundPixel(value: float32): float32 =
  float32(round(value.float64))

proc floorPixel(value: float32): float32 =
  float32(floor(value.float64))

proc ceilPixel(value: float32): float32 =
  float32(ceil(value.float64))

proc blurLevels(least, most: float32): seq[BlurLevel] =
  let minimum = max(least, 0'f32)
  if most <= minimum:
    if minimum > 0:
      result.add(BlurLevel(blur: minimum, lo: -1, hi: 0))
    return

  var
    highs = @[most]
    current = most
  while current > finestLevel and current / 2 > minimum:
    current /= 2
    highs.add(current)

  var low = minimum
  if minimum > 0:
    result.add(BlurLevel(blur: minimum, lo: -1, hi: 0))
  for i in countdown(highs.high, 0):
    let high = highs[i]
    result.add(BlurLevel(blur: sqrt(high * high - low * low),
      lo: low, hi: high))
    low = high

proc maskLine(rect: scene.Rect; gradient: ui.LinearGradient): array[4, float32] =
  let
    angle = gradient.angle.float64 * PI / 180
    dx = float32(sin(angle))
    dy = -float32(cos(angle))
    half = (abs(rect.w * dx) + abs(rect.h * dy)) / 2
    cx = rect.x + rect.w / 2
    cy = rect.y + rect.h / 2
    x0 = cx - dx * half
    y0 = cy - dy * half
    x1 = cx + dx * half
    y1 = cy + dy * half
  var start = gradient.start
  var stop = gradient.stop
  if start == 0 and stop == 0:
    stop = 1
  var sx = x0 + (x1 - x0) * start
  var sy = y0 + (y1 - y0) * start
  var ex = x0 + (x1 - x0) * stop
  var ey = y0 + (y1 - y0) * stop
  if stop - start < 0.5'f32 / max(2 * half, 1'f32):
    ex = sx + dx * 0.5'f32
    ey = sy + dy * 0.5'f32
  [sx, sy, ex, ey]

proc blurWanted(rect: scene.Rect; line: array[4, float32];
                at0, at1, least: float32): tuple[rect: scene.Rect, ok: bool] =
  if at0 == at1:
    return (rect, at0 > least)

  let
    dx = line[2] - line[0]
    dy = line[3] - line[1]
    t = (least - at0) / (at1 - at0)
  var
    nx = dx
    ny = dy
    c = line[0] * dx + line[1] * dy + t * (dx * dx + dy * dy)
  if at1 < at0:
    nx = -nx
    ny = -ny
    c = -c

  let corners = [
    [rect.x, rect.y],
    [rect.x + rect.w, rect.y],
    [rect.x + rect.w, rect.y + rect.h],
    [rect.x, rect.y + rect.h]]
  var
    x0 = high(float32)
    y0 = high(float32)
    x1 = -high(float32)
    y1 = -high(float32)
  template addPoint(x, y: float32) =
    x0 = min(x0, x)
    y0 = min(y0, y)
    x1 = max(x1, x)
    y1 = max(y1, y)

  for i, a in corners:
    let
      b = corners[(i + 1) mod corners.len]
      fa = nx * a[0] + ny * a[1] - c
      fb = nx * b[0] + ny * b[1] - c
    if fa > 0:
      addPoint(a[0], a[1])
    if (fa > 0) != (fb > 0):
      let k = fa / (fa - fb)
      addPoint(a[0] + (b[0] - a[0]) * k,
        a[1] + (b[1] - a[1]) * k)

  if x0 > x1 or y0 > y1:
    return (scene.Rect(), false)
  x0 = max(floorPixel(x0), rect.x)
  y0 = max(floorPixel(y0), rect.y)
  x1 = min(ceilPixel(x1), rect.x + rect.w)
  y1 = min(ceilPixel(y1), rect.y + rect.h)
  if x1 <= x0 or y1 <= y0:
    return (scene.Rect(), false)
  (scene.Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), true)

proc blurOps(rect: scene.Rect; square: bool; most: float32;
             mask: Option[ui.LinearGradient]):
             seq[tuple[rect: scene.Rect, op: scene.EffectOp]] =
  if rect.empty or most <= 0:
    return
  var line: array[4, float32]
  var at0 = most
  var at1 = most
  if mask.isSome:
    let gradient = mask.get
    line = maskLine(rect, gradient)
    at0 = most * gradient.fromColor.a.float32 / 255
    at1 = most * gradient.toColor.a.float32 / 255
  for level in blurLevels(min(at0, at1), max(at0, at1)):
    var levelRect = rect
    var visible = true
    if square and level.lo >= 0:
      (levelRect, visible) = blurWanted(rect, line, at0, at1, level.lo)
    if visible:
      let params: array[5, array[4, float32]] = [
        line,
        [at0, at1, level.lo, level.hi],
        [0'f32, 0, 0, 0],
        [0'f32, 0, 0, 0],
        [0'f32, 0, 0, 0]]
      result.add((levelRect, scene.EffectOp(effect: blurEffect,
        blur: level.blur, params: params)))

proc sampleRgba(backdrop: scene.BackdropImage; x, y: float32): array[4, float32] =
  let (x, y) = backdrop.transform.point(x, y)
  let
    down = backdrop.backdrop.down.float32
    u = (x - backdrop.backdrop.area.min.x.float32) / down - 0.5'f32
    v = (y - backdrop.backdrop.area.min.y.float32) / down - 0.5'f32
    fu = floorPixel(u)
    fv = floorPixel(v)
    tx = u - fu
    ty = v - fv
    x0 = min(max(int(fu), 0), backdrop.w - 1)
    y0 = min(max(int(fv), 0), backdrop.h - 1)
    x1 = min(max(int(fu) + 1, 0), backdrop.w - 1)
    y1 = min(max(int(fv) + 1, 0), backdrop.h - 1)
  for i in 0 ..< 4:
    let
      p00 = backdrop.pix[4 * (y0 * backdrop.w + x0) + i]
      p10 = backdrop.pix[4 * (y0 * backdrop.w + x1) + i]
      p01 = backdrop.pix[4 * (y1 * backdrop.w + x0) + i]
      p11 = backdrop.pix[4 * (y1 * backdrop.w + x1) + i]
      top = p00 * (1 - tx) + p10 * tx
      bottom = p01 * (1 - tx) + p11 * tx
    result[i] = top * (1 - ty) + bottom * ty

method begin*(pixels: BlurPixels; op: scene.EffectOp; rect: scene.Rect;
              radii: array[4, float32]) =
  pixels.line = op.params[0]
  pixels.band = op.params[1]
  pixels.tone = op.params[2]
  pixels.color = op.params[3]

method color*(pixels: BlurPixels; x, y: float32;
              backdrop: scene.BackdropImage): array[4, float32] =
  let
    line = pixels.line
    band = pixels.band
    dx = line[2] - line[0]
    dy = line[3] - line[1]
    length = dx * dx + dy * dy
  var t: float32
  if length > 0:
    t = min(max(((x - line[0]) * dx + (y - line[1]) * dy) /
      max(length, 0.0001'f32), 0'f32), 1'f32)
  let blur = band[0] * (1 - t) + band[1] * t
  let weight = min(max((blur - band[2]) / (band[3] - band[2]), 0'f32), 1'f32)
  if weight <= 0:
    return [0'f32, 0, 0, 0]

  var color = sampleRgba(backdrop, x, y)
  let tone = pixels.tone
  let lightness = 0.2126'f32 * color[0] + 0.7152'f32 * color[1] +
    0.0722'f32 * color[2]
  for i in 0 ..< 3:
    color[i] = min(max(lightness + (color[i] - lightness) *
      (1 + tone[0]) + tone[1] * color[3], 0'f32), color[3])
  for i in 0 ..< 4:
    color[i] += (pixels.color[i] - color[i]) * tone[2]
    color[i] *= weight
  color

proc blur(painter: var ui.Painter; box: ui.Rect;
          radii: array[4, float32]; value: Blur) =
  if value == nil or box.w <= 0 or box.h <= 0:
    return
  let scale = painter.scale()
  var rect = scene.Rect(x: roundPixel(box.x * scale),
    y: roundPixel(box.y * scale))
  rect.w = roundPixel((box.x + box.w) * scale) - rect.x
  rect.h = roundPixel((box.y + box.h) * scale) - rect.y
  for (levelRect, op) in blurOps(rect, radii == [0'f32, 0, 0, 0],
      value.radius * scale, value.mask):
    painter.effect(blurEffect,
      ui.Rect(x: levelRect.x / scale, y: levelRect.y / scale,
        w: levelRect.w / scale, h: levelRect.h / scale),
      radii, op.blur, op.params)

method paintMaterial*(value: Blur; painter: var ui.Painter; box: ui.Rect;
                      radii: array[4, float32]) =
  painter.blur(box, radii, value)

proc toned(color: array[3, float32]; saturation, offset: float32): array[3, float32] =
  result = color
  let lightness = 0.2126'f32 * color[0] + 0.7152'f32 * color[1] +
    0.0722'f32 * color[2]
  for channel in result.mitems:
    channel = min(max(lightness + (channel - lightness) * saturation + offset,
      0'f32), 1'f32)

proc params(tone: BlurTone): tuple[p2, p3: array[4, float32]] =
  ([tone.saturation, tone.offset, tone.mix, 0'f32],
    [tone.color[0], tone.color[1], tone.color[2], 1'f32])

proc fillGradient(painter: var ui.Painter; box: ui.Rect;
                  radii: array[4, float32]; gradient: ui.LinearGradient) =
  if radii[0] == radii[1] and radii[1] == radii[2] and radii[2] == radii[3]:
    painter.fillGradient(box, gradient, radii[0])
    return
  let
    x0 = box.x
    y0 = box.y
    x1 = box.x + box.w
    y1 = box.y + box.h
  const k = 0.5523'f32
  let
    tl = radii[0]
    tr = radii[1]
    br = radii[2]
    bl = radii[3]
  let path = ui.newPath()
  discard path.moveTo(x0 + tl, y0).lineTo(x1 - tr, y0)
  discard path.cubeTo(x1 - tr + k * tr, y0, x1, y0 + tr - k * tr,
    x1, y0 + tr).lineTo(x1, y1 - br)
  discard path.cubeTo(x1, y1 - br + k * br, x1 - br + k * br, y1,
    x1 - br, y1).lineTo(x0 + bl, y1)
  discard path.cubeTo(x0 + bl - k * bl, y1, x0, y1 - bl + k * bl,
    x0, y1 - bl).lineTo(x0, y0 + tl)
  discard path.cubeTo(x0, y0 + tl - k * tl, x0 + tl - k * tl, y0,
    x0 + tl, y0).close()
  painter.fillPathGradient(path, gradient)

method paintMaterial*(value: ScrollEdge; painter: var ui.Painter;
                      box: ui.Rect; radii: array[4, float32]) =
  if value == nil or box.w <= 0 or box.h <= 0:
    return
  let background = if value.background.a == 0:
    painter.theme().background
  else:
    value.background
  if not value.hard:
    let gradient = ui.LinearGradient(
      fromColor: background.alpha(softEdge),
      toColor: background.alpha(0),
      angle: if value.bottom: 0'f32 else: 180'f32)
    painter.fillGradient(box, radii, gradient)
    return

  let scale = painter.scale()
  let blurRadius = hardEdgeBlur * scale
  let color = toned([background.r.float32 / 255, background.g.float32 / 255,
    background.b.float32 / 255], 0.947'f32, 0.03'f32)
  let (p2, p3) = BlurTone(saturation: 0.25'f32, offset: 0.03'f32,
    mix: 0.8245'f32, color: color).params()
  painter.effect(blurEffect, box, radii, blurRadius, [
    [0'f32, 0, 0, 0],
    [blurRadius, blurRadius, -1'f32, 0],
    p2,
    p3,
    [0'f32, 0, 0, 0]])

  var line = if painter.theme().dark:
    ui.rgba(255, 255, 255, 0.07'f32)
  else:
    ui.rgba(0, 0, 0, 0.1'f32)
  let height = max(0.5'f32, 1 / scale)
  line = line.alpha(0.5'f32 / height)
  let y = if value.bottom: box.y - height else: box.y + box.h
  painter.fill(ui.Rect(x: box.x, y: y, w: box.w, h: height), line, 0)

proc compact(value: float32): string =
  result = $value
  if result.endsWith(".0"):
    result.setLen(result.len - 2)

proc `$`*(value: Blur): string =
  if value == nil:
    return "blur(0)"
  result = "blur(" & compact(value.radius) & ")"
  if value.mask.isSome:
    let mask = value.mask.get
    let fromAlpha = int(round(mask.fromColor.a.float64 / 2.55))
    let toAlpha = int(round(mask.toColor.a.float64 / 2.55))
    result.add(" mask(" & $fromAlpha & "%→" & $toAlpha & "% " &
      compact(mask.angle) & "°)")

proc `$`*(value: ScrollEdge): string =
  result = if value != nil and value.hard: "scroll-edge hard"
    else: "scroll-edge soft"
  if value != nil and value.bottom:
    result.add(" bottom")
