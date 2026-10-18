## Port of internal/scene: the display list the ui package paints a
## frame into and the renderers draw: rounded rectangles with borders
## and gradients, box shadows, glyphs from a shared atlas, images,
## effects and clips, in paint order. Geometry is in device pixels
## with the origin at the top-left corner.

import std/[math, atomics, sets, algorithm, hashes]
import ../image

type
  Color* = object
    ## A straight (not premultiplied) sRGB color.
    r*, g*, b*, a*: uint8

  WideColors* = object
    ## The colors outside the sRGB gamut of an op or a glyph (see
    ## Op.wide): straight RGBA with sRGB-encoded components beyond 0
    ## to 1 (extended sRGB), for those of color, color2 and borderColor
    ## a set bit names, of which a glyph has only color, times its
    ## opacity.
    color*, color2*, border*: array[4, float32]
    `set`*: WideSet

  WideSet* = uint8

  Rect* = object
    ## A rectangle in device pixels.
    x*, y*, w*, h*: float32

  Kind* = enum
    ## The kind of an Op.
    opFill     ## a rounded rectangle with color, or paint of color and
               ## color2, and, where border is positive, a border of
               ## borderColor inside its edges, dashed or not
    opShadow   ## the blurred shadow of a rounded rectangle
    opGlyphs   ## Scene.glyphs[start:stop]
    opImage    ## src of image into rect, clipped to radii
    opPushClip ## clips the following ops to rect with radii
    opPopClip  ## restores the clip in effect
    opEffect   ## the rounded rect with an effect, Scene.effects[start]
    opHole     ## makes the rounded rect transparent within the clip

  Paint* = enum
    ## What fills an opFill besides plain color, or the masks of an
    ## opGlyphs (gradients only).
    paintSolid
    paintLinear  ## linear gradient color->color2, mixed in sRGB
    paintOklab   ## the same, mixed in Oklab (both premultiplied)
    paintStripes ## stripes of color over color2

  Affine* = object
    ## Maps drawing coordinates to frame coordinates: an affine map,
    ## or, when g or h is set, a projective one (a plane turned in 3D
    ## in perspective).
    a*, b*, c*, d*, x*, y*: float32
    g*, h*: float32
    `set`*: bool

  ClipShape* = object
    ## A clip in the coordinate system in which it was pushed.
    rect*: Rect
    radii*: array[4, float32]
    transform*: Affine
    continuous*: bool

  Op* = object
    ## One drawing operation. Which fields matter depends on kind.
    kind*: Kind
    rect*: Rect
    ## transform maps this operation's geometry to frame pixels.
    transform*: Affine
    ## radii are the corner radii: top-left, top-right, bottom-right,
    ## bottom-left.
    radii*: array[4, float32]
    ## continuous curves the rounded corners the way Apple draws them.
    continuous*: bool
    color*: Color
    paint*: Paint
    color2*: Color
    ## wide, unless 0, is 1 + the index in Scene.wide of the op's
    ## colors outside the sRGB gamut.
    wide*: uint16
    gradient*: array[4, float32]
    ## border holds the widths of the border on the top, right, bottom
    ## and left; dashed dashes it.
    border*: array[4, float32]
    borderColor*: Color
    dashed*: bool
    ## inset makes an opShadow an inner shadow.
    inset*: bool
    ## The standard deviation of an opShadow or opImage blur.
    blur*: float32
    ## cast is the box casting an opShadow, with castRadii.
    `cast`*: Rect
    castRadii*: array[4, float32]
    first*, last*: int32
    image*: Image
    src*: Rect
    grayscale*: bool
    ## pixelated samples an opImage's nearest pixel.
    pixelated*: bool
    ## opacity multiplies the op's colors; 0 means 1.
    opacity*: float32

  Glyph* = object
    ## A glyph mask or color glyph copied from an atlas into a frame.
    transform*: Affine
    x*, y*, w*, h*: float32
    u*, v*, uw*, vh*: uint16
    color*: Color
    wide*: uint16
    colored*: bool
    subpixel*: bool
    thin*: bool

  TextParams* = object
    ## Corrects the coverage of mask and subpixel glyphs for the gamma
    ## and contrast text is blended with, as Direct2D does.
    gammaRatios*: array[4, float32]
    contrast*, subpixelContrast*: float32

  Effect* = object
    ## A kind of drawing that a package outside the renderers defines:
    ## a fragment shader for each GPU renderer, and its twin for the
    ## CPU renderer.
    name*: string
    backdrop*: bool
    metal*, hlsl*: EffectCode
    glsl*: string
    pixels*: proc(): EffectPixels

  EffectCode* = object
    ## An effect's shader in a language: its source, the code compiled
    ## ahead of time from it, with the SHA-256 of that (gpu.SourceSum).
    source*: string
    compiled*: seq[byte]
    sum*: string

  EffectOp* = object
    ## The effect of an opEffect, with its parameters.
    effect*: ref Effect
    blur*: float32
    params*: array[5, array[4, float32]]

  EffectPixels* = ref object of RootObj
    ## Draws an effect on the CPU, for one renderer.

  Backdrop* = object
    ## The area averaged over squares of down pixels a side, then
    ## blurred along rows and columns. Effects read the frame behind
    ## them; image blur treats pixels beyond this area as transparent.
    area*: image.Rectangle
    down*: int
    sigma*: float32
    radius*: int

  BackdropImage* = ref object
    ## A backdrop as the CPU renderer computes it: w×h texels of
    ## premultiplied RGBA, each channel a byte over 255.
    backdrop*: Backdrop
    transform*: Affine
    w*, h*: int
    pix*: seq[float32]

  Scene* = ref object
    ## A frame's display list.
    width*, height*: int
    scale*: float32
    clear*: Color
    ops*: seq[Op]
    glyphs*: seq[Glyph]
    effects*: seq[EffectOp]
    wide*: seq[WideColors]
    text*: TextParams
    maskAtlas*, colorAtlas*: Atlas
    canvases*: seq[Image]

  Image* = ref object
    ## A bitmap a scene draws. Renderers keep a texture per image and
    ## upload it again when its version changes.
    id*: uint64
    version*: uint64
    w*, h*: int
    pix*: seq[byte]
    scene*: Scene
    pixVersion*: uint64

  Atlas* = ref object
    ## Packs small bitmaps into one larger bitmap that renderers keep
    ## as a texture, recording which rectangles changed.
    bpp*: int
    w*, h*: int
    pix*: seq[byte]
    gen*: uint64
    version*: uint64
    log*: seq[AtlasChange]
    shelves*, transient*: seq[Shelf]
    bottom*, top*: int

  AtlasChange = object
    version: uint64
    r: image.Rectangle

  Shelf = object
    y, h, x: int

const
  wideColor* = WideSet(1)
  wideColor2* = WideSet(2)
  wideBorder* = WideSet(4)

  thinBoost* = 0.5 ## the contrast Direct2D adds for thin glyphs

  maxAtlasSize* = 4096
  atlasLog = 512

proc premul*(c: Color; opacity: float32): array[4, float32] =
  ## The color premultiplied by its alpha, components 0..1, times
  ## opacity.
  let a = c.a.float32 / 255 * opacity
  [c.r.float32 / 255 * a, c.g.float32 / 255 * a, c.b.float32 / 255 * a, a]

proc empty*(r: Rect): bool = r.w <= 0 or r.h <= 0

proc intersect*(r, o: Rect): Rect =
  let x0 = max(r.x, o.x)
  let y0 = max(r.y, o.y)
  let x1 = min(r.x + r.w, o.x + o.w)
  let y1 = min(r.y + r.h, o.y + o.h)
  if x1 <= x0 or y1 <= y0:
    return Rect(x: x0, y: y0)
  Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc contains*(r: Rect; x, y: float32): bool =
  x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h

proc uniform*(w: float32): array[4, float32] = [w, w, w, w]

proc hasBorder*(w: array[4, float32]): bool =
  w[0] > 0 or w[1] > 0 or w[2] > 0 or w[3] > 0

proc absf(v: float32): float32 =
  if v < 0: -v else: v

proc fitRadii*(r: Rect; radii: array[4, float32]): array[4, float32] =
  ## Scales corner radii down so that adjacent ones fit along each
  ## side of r, as CSS does.
  result = radii
  var f = 1.0'f32
  if radii[0] + radii[1] > r.w and radii[0] + radii[1] > 0:
    f = min(f, r.w / (radii[0] + radii[1]))
  if radii[3] + radii[2] > r.w and radii[3] + radii[2] > 0:
    f = min(f, r.w / (radii[3] + radii[2]))
  if radii[0] + radii[3] > r.h and radii[0] + radii[3] > 0:
    f = min(f, r.h / (radii[0] + radii[3]))
  if radii[1] + radii[2] > r.h and radii[1] + radii[2] > 0:
    f = min(f, r.h / (radii[1] + radii[2]))
  for i in 0 ..< 4:
    result[i] = max(result[i] * f, 0)

proc corners*(r: Rect; radii: array[4, float32]; continuous: bool):
    array[4, float32] =
  ## Radii as renderers take them: fitted to r, and negative for
  ## continuous corners.
  result = fitRadii(r, radii)
  if continuous:
    for i in 0 ..< 4:
      result[i] = -result[i]

proc innerRadii*(r: Rect; radii, w: array[4, float32]):
    tuple[inner: Rect, radii: array[4, float32]] =
  ## The radii of the inner edge of a border of widths w inside a
  ## rounded rectangle r with radii, which fitRadii or corners already
  ## fitted.
  let inner = Rect(x: r.x + w[3], y: r.y + w[0],
    w: r.w - w[1] - w[3], h: r.h - w[0] - w[2])
  let continuous = radii[0] < 0 or radii[1] < 0 or radii[2] < 0 or radii[3] < 0
  var o: array[4, float32]
  const sides = [[0, 3], [0, 1], [2, 1], [2, 3]]
  for i, side in sides:
    o[i] = max(absf(radii[i]) - max(w[side[0]], w[side[1]]), 0)
  (inner, corners(inner, o, continuous))

proc gammaRatios*(gamma: float32): array[4, float32] =
  ## Direct2D's alpha correction ratios for text blended at a gamma
  ## between 1 and 2.2, as Windows Terminal computes them.
  const table = [
    [0'f32, 0, 0, 0],
    [0.0166'f32, -0.0807, 0.2227, -0.0751],
    [0.0350'f32, -0.1760, 0.4325, -0.1370],
    [0.0543'f32, -0.2821, 0.6302, -0.1876],
    [0.0739'f32, -0.3963, 0.8167, -0.2287],
    [0.0933'f32, -0.5161, 0.9926, -0.2616],
    [0.1121'f32, -0.6395, 1.1588, -0.2877],
    [0.1300'f32, -0.7649, 1.3159, -0.3080],
    [0.1469'f32, -0.8911, 1.4644, -0.3234],
    [0.1627'f32, -1.0170, 1.6051, -0.3347],
    [0.1773'f32, -1.1420, 1.7385, -0.3426],
    [0.1908'f32, -1.2652, 1.8650, -0.3476],
    [0.2031'f32, -1.3864, 1.9851, -0.3501]]
  let i = min(max(int(gamma * 10 + 0.5), 10), 22) - 10
  const norm13 = float32(float64(0x10000) / (255 * 255) * 4)
  const norm24 = float32(float64(0x100) / 255 * 4)
  let r = table[i]
  [norm13 * r[0] / 4, norm24 * r[1] / 4, norm13 * r[2] / 4, norm24 * r[3] / 4]

proc textCoverage*(a: float32; c: array[3, float32]; contrast,
    boost: float32; g: array[4, float32]): float32 =
  ## Corrects the coverage a of a glyph of straight color c, as
  ## Direct2D blends text.
  let k = contrast * min(max(3 - 4 * (0.30 * c[0] + 0.59 * c[1] +
    0.11 * c[2]), 0), 1) + boost
  let a = a * (k + 1) / (a * k + 1)
  let f = 0.25 * c[0] + 0.5 * c[1] + 0.25 * c[2]
  min(max(a + a * (1 - a) * ((g[0] * f + g[1]) * a + (g[2] * f + g[3])), 0), 1)

proc subpixelCoverage*(a, c: array[3, float32]; contrast,
    boost: float32; g: array[4, float32]): array[3, float32] =
  ## Corrects the coverage of each subpixel of a subpixel glyph of
  ## straight color c, as Direct2D blends ClearType text.
  let k = contrast * min(max(3 - 4 * (0.30 * c[0] + 0.59 * c[1] +
    0.11 * c[2]), 0), 1) + boost
  result = a
  for i in 0 ..< 3:
    let v = result[i] * (k + 1) / (result[i] * k + 1)
    result[i] = min(max(v + v * (1 - v) * ((g[0] * c[i] + g[1]) * v +
      (g[2] * c[i] + g[3])), 0), 1)

## --- transform.go ---

proc matrix*(a, b, c, d, x, y: float32): Affine =
  if a == 1 and b == 0 and c == 0 and d == 1 and x == 0 and y == 0:
    return Affine()
  Affine(a: a, b: b, c: c, d: d, x: x, y: y, `set`: true)

proc projective*(a, b, c, d, x, y, g, h: float32): Affine =
  ## The projective map of the matrix
  ##   | a c x |
  ##   | b d y |
  ##   | g h 1 |
  if a == 1 and b == 0 and c == 0 and d == 1 and x == 0 and
      y == 0 and g == 0 and h == 0:
    return Affine()
  Affine(a: a, b: b, c: c, d: d, x: x, y: y, g: g, h: h, `set`: true)

proc translation*(x, y: float32): Affine = matrix(1, 0, 0, 1, x, y)
proc scaling*(x, y: float32): Affine = matrix(x, 0, 0, y, 0, 0)
proc rotation*(degrees: float32): Affine =
  let angle = degrees mod 360
  if angle == 0: return Affine()
  if angle == 90: return matrix(0, 1, -1, 0, 0, 0)
  if angle == -90: return matrix(0, -1, 1, 0, 0, 0)
  if angle == 180 or angle == -180: return matrix(-1, 0, 0, -1, 0, 0)
  let s = sin(angle * PI / 180)
  let c = cos(angle * PI / 180)
  matrix(c.float32, s.float32, -s.float32, c.float32, 0, 0)

proc perspective*(m: Affine): bool = m.`set` and (m.g != 0 or m.h != 0)
  ## Whether m is projective, not affine.

proc toMat(m: Affine): array[3, array[3, float64]] =
  if not m.`set`:
    return [[1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]]
  [[m.a.float64, m.c.float64, m.x.float64],
   [m.b.float64, m.d.float64, m.y.float64],
   [m.g.float64, m.h.float64, 1.0]]

proc fromMat(p: array[3, array[3, float64]]): tuple[m: Affine, ok: bool] =
  let k = p[2][2]
  if abs(k) < 1e-12 or k.isNan or classify(k) == fcInf or classify(k) == fcNegInf:
    return (Affine(), false)
  let v = [p[0][0] / k, p[1][0] / k, p[0][1] / k, p[1][1] / k,
    p[0][2] / k, p[1][2] / k, p[2][0] / k, p[2][1] / k]
  for x in v:
    if x.isNan or classify(x) == fcInf or classify(x) == fcNegInf or abs(x) > high(float32).float64:
      return (Affine(), false)
  (projective(v[0].float32, v[1].float32, v[2].float32, v[3].float32,
    v[4].float32, v[5].float32, v[6].float32, v[7].float32), true)

var singular = Affine(`set`: true)

proc mul*(m, n: Affine): Affine =
  ## m*n: n acts first, then m.
  if not m.`set`: return n
  if not n.`set`: return m
  if not m.perspective() and not n.perspective():
    return matrix(m.a * n.a + m.c * n.b, m.b * n.a + m.d * n.b,
      m.a * n.c + m.c * n.d, m.b * n.c + m.d * n.d,
      m.a * n.x + m.c * n.y + m.x, m.b * n.x + m.d * n.y + m.y)
  let a = m.toMat()
  let b = n.toMat()
  var p: array[3, array[3, float64]]
  for i in 0 ..< 3:
    for j in 0 ..< 3:
      p[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]
  let (r, ok) = fromMat(p)
  if not ok: return singular
  r

proc w*(m: Affine; x, y: float32): float32 =
  ## The projective divisor of (x, y): positive in front of the viewer.
  if not m.`set`: return 1
  m.g * x + m.h * y + 1

proc point*(m: Affine; x, y: float32): tuple[x, y: float32] =
  ## Where m maps (x, y). A point behind the viewer of a projective
  ## map goes far away.
  if not m.`set`: return (x, y)
  let px = m.a * x + m.c * y + m.x
  let py = m.b * x + m.d * y + m.y
  if m.g == 0 and m.h == 0: return (px, py)
  let w = max(m.w(x, y), 1e-6)
  (px / w, py / w)

proc vectorAt*(m: Affine; x, y, dx, dy: float32): tuple[x, y: float32] =
  ## How far m moves the point (x, y) moved by (dx, dy).
  if not m.`set`: return (dx, dy)
  if m.g == 0 and m.h == 0:
    return (m.a * dx + m.c * dy, m.b * dx + m.d * dy)
  let (x0, y0) = m.point(x, y)
  let (x1, y1) = m.point(x + dx, y + dy)
  (x1 - x0, y1 - y0)

proc inverse*(m: Affine): tuple[m: Affine, ok: bool] =
  if not m.`set`: return (m, true)
  if m.g == 0 and m.h == 0:
    let det = m.a.float64 * m.d.float64 - m.b.float64 * m.c.float64
    if det == 0 or det.isNan or classify(det) == fcInf or classify(det) == fcNegInf:
      return (Affine(), false)
    let a = (m.d.float64 / det).float32
    let b = (-m.b.float64 / det).float32
    let c = (-m.c.float64 / det).float32
    let d = (m.a.float64 / det).float32
    let n = matrix(a, b, c, d, -a * m.x - c * m.y, -b * m.x - d * m.y)
    for v in [n.a, n.b, n.c, n.d, n.x, n.y]:
      if v.float64.isNan or classify(v.float64) == fcInf or classify(v.float64) == fcNegInf:
        return (Affine(), false)
    return (n, true)
  let q = m.toMat()
  template cof(r0, r1, c0, c1: int): float64 =
    q[r0][c0] * q[r1][c1] - q[r0][c1] * q[r1][c0]
  let adj = [[cof(1, 2, 1, 2), -cof(0, 2, 1, 2), cof(0, 1, 1, 2)],
    [-cof(1, 2, 0, 2), cof(0, 2, 0, 2), -cof(0, 1, 0, 2)],
    [cof(1, 2, 0, 1), -cof(0, 2, 0, 1), cof(0, 1, 0, 1)]]
  let det = q[0][0] * adj[0][0] + q[0][1] * adj[1][0] + q[0][2] * adj[2][0]
  if abs(det) < 1e-12 or det.isNan or classify(det) == fcInf or classify(det) == fcNegInf:
    return (Affine(), false)
  fromMat(adj) ## the inverse up to a factor, which fromMat drops

proc bounds*(m: Affine; r: Rect): Rect =
  if not m.`set`: return r
  let corners = [[r.x, r.y], [r.x + r.w, r.y], [r.x, r.y + r.h],
    [r.x + r.w, r.y + r.h]]
  if m.perspective():
    for p in corners:
      if m.w(p[0], p[1]) <= 1e-6:
        return Rect(x: -1e6, y: -1e6, w: 2e6, h: 2e6)
  var (x0, y0) = m.point(r.x, r.y)
  var (x1, y1) = (x0, y0)
  for i in 1 ..< 4:
    let (x, y) = m.point(corners[i][0], corners[i][1])
    x0 = min(x0, x); y0 = min(y0, y)
    x1 = max(x1, x); y1 = max(y1, y)
  Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

proc rectPoints*(m: Affine; r: Rect): array[4, array[2, float32]] =
  ## The rectangle's corners as points under m, for clipping (scene's
  ## clipToTransform).
  let cs = [[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h],
    [r.x, r.y + r.h]]
  for i, p in cs:
    let (x, y) = m.point(p[0], p[1])
    result[i] = [x, y]

## --- Scene ---

proc hash*(i: Image): Hash =
  hash(cast[uint](i))

proc eachCanvas*(s: Scene; fn: proc(c: Image)) =
  ## Calls fn with the canvases the scene draws anew or shows, each
  ## once, those a canvas shows before it.
  var seen = initHashSet[Image]()
  proc visit(c: Image) =
    if c == nil or c.scene == nil or c in seen: return
    seen.incl c
    for i in 0 ..< c.scene.ops.len:
      let op = addr c.scene.ops[i]
      if op.kind == opImage and op.image != nil and
          op.image.scene != nil:
        visit(op.image)
    fn(c)
  for c in s.canvases: visit(c)
  for i in 0 ..< s.ops.len:
    let op = addr s.ops[i]
    if op.kind == opImage and op.image != nil and op.image.scene != nil:
      visit(op.image)

proc reset*(s: Scene; width, height: int; color: Color) =
  ## Empties the scene for another frame, keeping its storage.
  s.width = width
  s.height = height
  s.clear = color
  for i in 0 ..< s.ops.len: s.ops[i] = Op()
  s.ops.setLen(0)
  s.glyphs.setLen(0)
  for i in 0 ..< s.effects.len: s.effects[i] = EffectOp()
  s.effects.setLen(0)
  s.wide.setLen(0)
  for i in 0 ..< s.canvases.len: s.canvases[i] = nil
  s.canvases.setLen(0)

var lastImageID: Atomic[uint64]

proc newCanvas*(w, h: int): Image =
  ## A w×h image that renderers draw from a scene of its own, cleared
  ## to transparent: render to texture.
  Image(id: lastImageID.fetchAdd(1) + 1, version: 1, w: w, h: h,
    scene: Scene(width: w, height: h, scale: 1))

proc newSceneImage*(img: image.Image): Image =
  ## Converts img to a premultiplied RGBA bitmap.
  let b = img.bounds()
  var rgba = RgbaImage(pix: newSeq[uint8](4 * b.dx * b.dy),
    stride: 4 * b.dx, rect: image.rect(0, 0, b.dx, b.dy), off: 0)
  image.drawSrc(rgba, image.rect(0, 0, b.dx, b.dy), img, b.min)
  Image(id: lastImageID.fetchAdd(1) + 1, version: 1,
    w: b.dx, h: b.dy, pix: rgba.pix)

proc newImageRgba*(w, h: int; pix: seq[byte]): Image =
  ## Wraps premultiplied RGBA pixels of a w×h bitmap.
  Image(id: lastImageID.fetchAdd(1) + 1, version: 1, w: w, h: h, pix: pix)

proc changed*(m: Image) = inc m.version
  ## Records that pix was modified.

proc resize*(m: Image; w, h: int) =
  ## Keeps the image's texture-cache identity while changing its size.
  m.w = w
  m.h = h
  if m.pix.len >= 4 * w * h:
    m.pix.setLen(4 * w * h)
  else:
    m.pix = newSeq[byte](4 * w * h)
  m.changed()

## --- effect.go ---

method begin*(p: EffectPixels; op: EffectOp; rect: Rect;
    radii: array[4, float32]) {.base.} =
  ## Readies drawing op, the shape rect rounded by radii (fitted),
  ## before its pixels.
  discard

method color*(p: EffectPixels; x, y: float32; b: BackdropImage):
    array[4, float32] {.base.} =
  ## The premultiplied color of the effect at the pixel center (x, y),
  ## as its shaders' effect does, over the backdrop b.
  [0'f32, 0, 0, 0]

proc backdropOf*(r: Rect; blur: float32; w, h: int): Backdrop =
  ## The backdrop of a shape r blurred by blur, in a frame of w×h
  ## pixels: what the blur reaches around it.
  let blur = max(blur, 0)
  var down = 1
  while down < 8 and blur / float32(2 * down) >= 2:
    down *= 2
  var sigma = sqrt(max(blur * blur - float32(down * down) / 12, 0)) /
    float32(down)
  if blur == 0: sigma = 0
  let radius = int(ceil(3 * sigma))
  let reach = float32(radius * down + down)
  let area = image.rect(int(floor(r.x - reach)), int(floor(r.y - reach)),
    int(ceil(r.x + r.w + reach)), int(ceil(r.y + r.h + reach)))
  Backdrop(area: area.intersect(image.rect(0, 0, w, h)),
    down: down, sigma: sigma, radius: radius)

proc size*(b: Backdrop): tuple[w, h: int] =
  ## The size of the averaged image, in texels.
  ((b.area.max.x - b.area.min.x + b.down - 1) div b.down,
   (b.area.max.y - b.area.min.y + b.down - 1) div b.down)

proc imageBlur*(area: image.Rectangle; blur: float32): Backdrop =
  ## The passes blurring an image area, transparent beyond its edges.
  result = backdropOf(Rect(), blur, 0, 0)
  result.area = area

proc imageSrc*(b: Backdrop; src: Rect): Rect =
  ## The source rectangle in the texels of an image blurred by b.
  let k = float32(b.down)
  Rect(x: (src.x - float32(b.area.min.x)) / k,
       y: (src.y - float32(b.area.min.y)) / k,
       w: src.w / k, h: src.h / k)

proc imageArea*(src: Rect; w, h: int): image.Rectangle =
  ## The pixels of an image that a source rectangle overlaps.
  var src = src
  if src.w < 0:
    src.x += src.w
    src.w = -src.w
  if src.h < 0:
    src.y += src.h
    src.h = -src.h
  image.rect(int(floor(src.x)), int(floor(src.y)),
             int(ceil(src.x + src.w)), int(ceil(src.y + src.h))).
    intersect(image.rect(0, 0, w, h))

proc blurWeight*(i: int; sigma: float32): float32 =
  ## The weight of the texel i texels away in a blur of standard
  ## deviation sigma, before the weights are divided by their sum.
  if sigma <= 0: return 1
  let x = i.float32
  exp(-(x * x) / (2 * sigma * sigma))

proc sample*(b: BackdropImage; x, y: float32): array[3, float32] =
  ## The backdrop at (x, y), in the frame's pixels, premultiplied RGB,
  ## filtered bilinearly from its texels and clamped to its edges, as
  ## the shaders' sampleBackdrop.
  let (x, y) = b.transform.point(x, y)
  let k = b.backdrop.down.float32
  let u = (x - b.backdrop.area.min.x.float32) / k - 0.5
  let v = (y - b.backdrop.area.min.y.float32) / k - 0.5
  let fu = floor(u)
  let fv = floor(v)
  let tx = u - fu
  let ty = v - fv
  let x0 = min(max(int(fu), 0), b.w - 1)
  let y0 = min(max(int(fv), 0), b.h - 1)
  let x1 = min(max(int(fu) + 1, 0), b.w - 1)
  let y1 = min(max(int(fv) + 1, 0), b.h - 1)
  for i in 0 ..< 3:
    let p00 = b.pix[4 * (y0 * b.w + x0) + i]
    let p10 = b.pix[4 * (y0 * b.w + x1) + i]
    let p01 = b.pix[4 * (y1 * b.w + x0) + i]
    let p11 = b.pix[4 * (y1 * b.w + x1) + i]
    let top = p00 * (1 - tx) + p10 * tx
    let bot = p01 * (1 - tx) + p11 * tx
    result[i] = top * (1 - ty) + bot * ty

proc sdRoundRect*(r: Rect; radii: array[4, float32]; px, py: float32):
    float32 =
  ## The signed distance from (px, py) to the edge of the rounded
  ## rectangle r with radii (fitted), negative inside, as the
  ## shaders' sdRoundRect.
  let hx = r.w / 2
  let hy = r.h / 2
  let qx = px - r.x - hx
  let qy = py - r.y - hy
  var rad: float32
  if qx < 0 and qy < 0: rad = radii[0]
  elif qx >= 0 and qy < 0: rad = radii[1]
  elif qx >= 0: rad = radii[2]
  else: rad = radii[3]
  let ax = absf(qx) - hx + rad
  let ay = absf(qy) - hy + rad
  let mx = max(ax, 0)
  let my = max(ay, 0)
  sqrt(mx * mx + my * my) + min(max(ax, ay), 0) - rad

## --- atlas.go ---

proc newAtlas*(bpp, w, h: int): Atlas =
  ## An empty w×h atlas of bpp bytes per pixel.
  Atlas(bpp: bpp, w: w, h: h, pix: newSeq[byte](w * h * bpp),
    gen: 1, top: h)

proc generation*(a: Atlas): uint64 = a.gen
  ## Changes when the atlas is resized, reset or repacked.

proc changes*(a: Atlas; gen, version: uint64):
    tuple[rects: seq[image.Rectangle], full: bool] =
  ## The rectangles changed since version, or full when the renderer
  ## must upload everything.
  if gen != a.gen: return (@[], true)
  if version == a.version: return (@[], false)
  if a.log.len == 0 or a.log[0].version > version + 1:
    return (@[], true)
  var uni: image.Rectangle
  var rects: seq[image.Rectangle]
  for c in a.log:
    if c.version > version:
      rects.add c.r
      uni = uni.union(c.r)
  if rects.len > 32:
    return (@[uni], false)
  (rects, false)

proc allocIn(a: Atlas; shelves: var seq[Shelf]; up: bool;
    w, h: int): tuple[x, y: int, ok: bool] =
  let pw = w + 1
  let ph = h + 1
  if pw > a.w or ph > a.h:
    return (0, 0, false)
  var best = -1
  for i, s in shelves:
    if s.h >= ph and s.h <= ph + ph div 4 + 2 and a.w - s.x >= pw and
        (best < 0 or s.h < shelves[best].h):
      best = i
  if best < 0:
    if a.bottom + ph > a.top:
      return (0, 0, false)
    let step = max(4, ph div 8)
    let sh = min((ph + step - 1) div step * step, a.top - a.bottom)
    var y = a.bottom
    if up:
      a.top -= sh
      y = a.top
    else:
      a.bottom += sh
    shelves.add Shelf(y: y, h: sh)
    best = shelves.len - 1
  result.x = shelves[best].x
  result.y = shelves[best].y
  shelves[best].x += pw
  result.ok = true

proc alloc*(a: Atlas; w, h: int): tuple[x, y: int, ok: bool] =
  ## Reserves a lasting w×h rectangle, keeping a pixel of padding to
  ## its right and below it. False when the atlas is full; the caller
  ## then repacks, grows or resets it.
  a.allocIn(a.shelves, false, w, h)

proc allocTransient*(a: Atlas; w, h: int): tuple[x, y: int, ok: bool] =
  ## Alloc for a rectangle needed until resetTransient.
  a.allocIn(a.transient, true, w, h)

proc resetTransient*(a: Atlas) =
  ## Frees the rectangles allocTransient reserved.
  a.transient.setLen(0)
  a.top = a.h

proc put*(a: Atlas; x, y, w, h: int; src: seq[byte]; stride: int) =
  ## Copies a w×h bitmap with rows of stride bytes to (x, y), and
  ## clears the padding after it.
  let bpp = a.bpp
  let row = w * bpp
  for j in 0 ..< h:
    let i = ((y + j) * a.w + x) * bpp
    copyMem(addr a.pix[i], unsafeAddr src[j * stride], row)
    if x + w < a.w:
      for k in 0 ..< bpp: a.pix[i + row + k] = 0
  let r = image.rect(x, y, min(x + w + 1, a.w), min(y + h + 1, a.h))
  if y + h < a.h:
    let i = ((y + h) * a.w + x) * bpp
    for k in 0 ..< (r.max.x - r.min.x) * bpp: a.pix[i + k] = 0
  inc a.version
  a.log.add AtlasChange(version: a.version, r: r)
  if a.log.len > atlasLog:
    a.log = a.log[a.log.len - atlasLog div 2 .. ^1]

proc changedAll(a: Atlas) =
  inc a.gen
  inc a.version
  a.log.setLen(0)

proc grow*(a: Atlas): bool =
  ## Doubles the atlas up to maxAtlasSize, keeping its lasting bitmaps
  ## where they are; frees the transient ones.
  if a.w >= maxAtlasSize and a.h >= maxAtlasSize: return false
  let w = min(a.w * 2, maxAtlasSize)
  let h = min(a.h * 2, maxAtlasSize)
  var pix = newSeq[byte](w * h * a.bpp)
  for j in 0 ..< a.bottom:
    copyMem(addr pix[j * w * a.bpp], addr a.pix[j * a.w * a.bpp],
      a.w * a.bpp)
  a.w = w
  a.h = h
  a.pix = pix
  a.resetTransient()
  a.changedAll()
  true

proc repack*(a: Atlas; rects: seq[image.Rectangle]):
    tuple[pos: seq[image.Point], ok: bool] =
  ## Frees the atlas and allocates rects again, tallest first, moving
  ## their pixels along. Where each went, or false when they do not
  ## fit.
  var order = newSeq[int](rects.len)
  for i in 0 ..< rects.len: order[i] = i
  order.sort(proc(i, j: int): int =
    result = cmp(rects[j].dy, rects[i].dy)
    if result == 0: result = cmp(rects[j].dx, rects[i].dx))
  var plan = Atlas(w: a.w, h: a.h, top: a.h)
  var pos = newSeq[image.Point](rects.len)
  for i in order:
    let (x, y, ok) = plan.alloc(rects[i].dx, rects[i].dy)
    if not ok: return (@[], false)
    pos[i] = image.pt(x, y)
  var saved = newSeq[seq[byte]](rects.len)
  for i, r in rects:
    let row = r.dx * a.bpp
    var b = newSeq[byte](row * r.dy)
    for j in 0 ..< r.dy:
      copyMem(addr b[j * row],
        addr a.pix[((r.min.y + j) * a.w + r.min.x) * a.bpp], row)
    saved[i] = b
  for i in 0 ..< a.pix.len: a.pix[i] = 0
  for i, r in rects:
    let row = r.dx * a.bpp
    for j in 0 ..< r.dy:
      copyMem(
        addr a.pix[((pos[i].y + j) * a.w + pos[i].x) * a.bpp],
        addr saved[i][j * row], row)
  a.shelves = plan.shelves
  a.bottom = plan.bottom
  a.resetTransient()
  a.changedAll()
  (pos, true)

proc reset*(a: Atlas) =
  ## Empties the atlas: every allocation becomes invalid.
  for i in 0 ..< a.pix.len: a.pix[i] = 0
  a.shelves.setLen(0)
  a.bottom = 0
  a.resetTransient()
  a.changedAll()
