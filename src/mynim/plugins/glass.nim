## Liquid Glass as a native UI material and painter effect.

import std/[math, strutils, times]
import mynim/internal/scene as scene
import mynim/ui as ui

type
  GlassStyle* = enum
    Regular, Clear

  Glass* = ref object of ui.Material
    style*: GlassStyle
    tint*: ui.Color
    interactive*: bool

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

const
  pressKey = "\x00mynim.glass.press"
  toneSteps = 1024
  glassMetalSource = staticRead("glass/glass.metal")
  glassHlslSource = staticRead("glass/glass.hlsl")
  glassGlslSource = staticRead("glass/glass.glsl")

proc newGlassPixels(): scene.EffectPixels = GlassPixels()

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
