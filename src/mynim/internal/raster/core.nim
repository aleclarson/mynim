## raster.go: Image, the renderers' state, coverage math, blending and
## the painter.

type
  Image* = object
    ## A premultiplied BGRA bitmap, the layout Windows DIBs, cairo
    ## and Core Graphics take.
    w*, h*, stride*: int
    pix*: seq[byte]

proc newImage*(w, h: int): Image =
  Image(w: w, h: h, stride: 4 * w, pix: newSeq[byte](4 * w * h))

proc resize*(m: var Image; w, h: int) =
  ## Makes the image w×h, reusing its memory when it can.
  m.w = w
  m.h = h
  m.stride = 4 * w
  if m.pix.len >= 4 * w * h:
    m.pix.setLen(4 * w * h)
  else:
    m.pix = newSeq[byte](4 * w * h)

proc rgba*(m: Image): seq[byte] =
  ## The pixels as premultiplied RGBA, as image.RGBA holds them.
  result = newSeq[byte](4 * m.w * m.h)
  for y in 0 ..< m.h:
    for x in 0 ..< m.w:
      let si = y * m.stride + 4 * x
      let di = y * 4 * m.w + 4 * x
      result[di] = m.pix[si + 2]
      result[di + 1] = m.pix[si + 1]
      result[di + 2] = m.pix[si]
      result[di + 3] = m.pix[si + 3]

type shape = object
  ## A rounded rectangle, with radii as scene.corners gives them, as
  ## the renderer draws it, with its continuous corners, which every
  ## pixel near an edge needs, worked out once.
  r: scene.Rect
  ## radii are positive, continuous or not.
  radii: array[4, float32]
  continuous: bool
  corners: array[4, contCorner]

proc newShape(rc: scene.Rect; radii: array[4, float32]): shape =
  result = shape(r: rc, radii: radii)
  if radii[0] >= 0 and radii[1] >= 0 and radii[2] >= 0 and radii[3] >= 0:
    return
  result.continuous = true
  for i in 0 ..< 4:
    result.radii[i] = abs(radii[i])
  for i in 0 ..< 4:
    ## The corners sharing its horizontal and its vertical edge.
    let
      h = [1, 0, 3, 2][i]
      v = [3, 2, 1, 0][i]
    result.corners[i] = newContCorner(result.radii[i], result.radii[h],
                                      result.radii[v], rc.w, rc.h)

proc areaCoverage(rc: scene.Rect; px, py: float32): float32 =
  ## The area of the pixel centered at (px, py) inside the rectangle,
  ## near square corners: exact for lines thinner than a pixel too.
  let cx = min(rc.x + rc.w, px + 0.5) - max(rc.x, px - 0.5)
  let cy = min(rc.y + rc.h, py + 0.5) - max(rc.y, py - 0.5)
  clamp01(cx) * clamp01(cy)

proc contDist(s: var shape; px, py: float32): tuple[d: float32,
    curved: bool] =
  ## The value of a shape with continuous corners at (px, py), the
  ## largest of its corners' and the rectangle's signed distance, and
  ## whether a corner's curve reaches it.
  let
    rc = s.r
    left = px - rc.x
    right = rc.x + rc.w - px
    top = py - rc.y
    bottom = rc.y + rc.h - py
  var d = max(max(-left, -right), max(-top, -bottom))
  var curved = false
  const uv = [[0, 1], [2, 1], [2, 3], [0, 3]]
  let sxy = [left, right, top, bottom]
  for i in 0 ..< 4:
    let
      c = addr s.corners[i]
      u = sxy[uv[i][0]]
      v = sxy[uv[i][1]]
    if c.r <= 0 or u >= c.e or v >= c.e:
      continue
    d = max(d, c[].dist(u, v))
    curved = true
  (d, curved)

proc coverage(s: var shape; px, py: float32): float32 =
  ## How much of the pixel centered at (px, py) the rounded rectangle
  ## covers, from the signed distance to its edge.
  if s.continuous:
    let (d, curved) = s.contDist(px, py)
    if not curved:
      return areaCoverage(s.r, px, py)
    if abs(d) > 2:
      return if d < 0: 1 else: 0
    const h = 1'f32 / 16
    let
      (dx, _) = s.contDist(px + h, py)
      (dy, _) = s.contDist(px, py + h)
    return clamp01(0.5 - d * h / max(abs(dx - d) + abs(dy - d), 1e-6))
  let
    rc = s.r
    hx = rc.w / 2
    hy = rc.h / 2
    qx = px - rc.x - hx
    qy = py - rc.y - hy
  var rad: float32
  if qx < 0 and qy < 0: rad = s.radii[0]
  elif qx >= 0 and qy < 0: rad = s.radii[1]
  elif qx >= 0: rad = s.radii[2]
  else: rad = s.radii[3]
  if rad <= 0:
    return areaCoverage(rc, px, py)
  let
    ax = abs(qx) - hx + rad
    ay = abs(qy) - hy + rad
  var d: float32
  if ax > 0 and ay > 0:
    d = sqrt(ax * ax + ay * ay) - rad
  else:
    d = max(ax, ay) - rad
  clamp01(0.5 - d)

proc inset(s: var shape; i: int; v: float32): float32 =
  ## How far corner i of the rounded rectangle narrows a row v pixels
  ## from its horizontal edge, at the least.
  if s.continuous:
    let (_, bound) = s.corners[i].inset(v)
    return bound
  let rad = s.radii[i]
  if rad <= 0 or v >= rad:
    return 0
  if v <= 0:
    return rad
  let dy = rad - v
  rad - sqrt(max(rad * rad - dy * dy, 0'f32))

proc solidSpan(s: var shape; y0, y1: float32): tuple[lo, hi: int] =
  ## The pixels of the row between y0 and y1 that the rounded
  ## rectangle covers entirely; lo >= hi when there are none.
  let rc = s.r
  if y0 < rc.y or y1 > rc.y + rc.h:
    return (0, 0)
  let
    top = y0 - rc.y
    bottom = rc.y + rc.h - y1
    left = rc.x + max(s.inset(0, top), s.inset(3, bottom))
    right = rc.x + rc.w - max(s.inset(1, top), s.inset(2, bottom))
  (int(ceil(left)), int(floor(right)))

type
  clip = object
    shape: shape
    transform, inverse: scene.Affine
    valid: bool
    round: bool
    ## spans is where in spanBuf the clip, with continuous corners,
    ## keeps the spans clipSolid found for the rows of the area, lo and
    ## hi a row (noSpan until found), or -1.
    spans: int

  renderer = object
    dst: ptr Image
    s: scene.Scene
    clips: seq[clip]
    ## area is the part of dst to draw.
    area: image.Rectangle
    ## bounds is the intersection of the clip rectangles, in whole
    ## pixels.
    x0, y0, x1, y1: int
    ## profile is scratch space for shadows.
    profile: seq[float32]
    ## spanBuf holds the clips' spans (clip.spans).
    spanBuf: seq[int32]

const noSpan = low(int32)

proc hasRadii(radii: array[4, float32]): bool =
  radii[0] != 0 or radii[1] != 0 or radii[2] != 0 or radii[3] != 0

proc updateBounds(r: var renderer) =
  r.x0 = r.area.min.x
  r.y0 = r.area.min.y
  r.x1 = r.area.max.x
  r.y1 = r.area.max.y
  for c in r.clips.mitems:
    let b = c.transform.bounds(c.shape.r)
    if not c.valid:
      r.x1 = r.x0
      r.y1 = r.y0
      return
    r.x0 = max(r.x0, int(floor(b.x)))
    r.y0 = max(r.y0, int(floor(b.y)))
    r.x1 = min(r.x1, int(ceil(b.x + b.w)))
    r.y1 = min(r.y1, int(ceil(b.y + b.h)))

proc pixelBounds(r: var renderer; rc: scene.Rect): tuple[x0, y0, x1,
    y1: int] =
  ## The pixels a rectangle touches within the clip.
  (max(r.x0, int(floor(rc.x))), max(r.y0, int(floor(rc.y))),
   min(r.x1, int(ceil(rc.x + rc.w))), min(r.y1, int(ceil(rc.y + rc.h))))

proc transformedCoverage(s: var shape; m, inv: scene.Affine; x,
                         y: float32): float32

proc clipCoverage(r: var renderer; x, y: int): float32 =
  ## How much of pixel (x, y) the clips let through, given the clip
  ## rectangles' pixel bounds already apply.
  result = 1
  for i in 0 ..< r.clips.len:
    let c = addr r.clips[i]
    let
      px = float32(x) + 0.5
      py = float32(y) + 0.5
    if c.transform.`set`:
      if not c.valid:
        return 0
      result *= transformedCoverage(c.shape, c.transform, c.inverse, px, py)
    elif c.round:
      result *= coverage(c.shape, px, py)
    else:
      ## Partial pixels at fractional clip edges.
      result *= clamp01(min(px - c.shape.r.x, c.shape.r.x + c.shape.r.w - px) + 0.5) *
        clamp01(min(py - c.shape.r.y, c.shape.r.y + c.shape.r.h - py) + 0.5)
    if result == 0:
      return 0

proc clipSolid(r: var renderer; y: int): tuple[lo, hi: int] =
  ## The pixels of row y that the clips let through entirely, so that
  ## clipCoverage need not run for them.
  result = (r.x0, r.x1)
  for i in 0 ..< r.clips.len:
    let c = addr r.clips[i]
    if c.transform.`set`:
      return (result.lo, result.lo)
    var l, h: int
    let k = c.spans + 2 * (y - r.area.min.y)
    if c.spans >= 0 and y >= r.area.min.y and y < r.area.max.y:
      if r.spanBuf[k] == noSpan:
        (l, h) = solidSpan(c.shape, float32(y), float32(y + 1))
        r.spanBuf[k] = int32(l)
        r.spanBuf[k + 1] = int32(h)
      else:
        l = int(r.spanBuf[k])
        h = int(r.spanBuf[k + 1])
    else:
      (l, h) = solidSpan(c.shape, float32(y), float32(y + 1))
    result = (max(result.lo, l), min(result.hi, h))

proc blend(p: var openArray[byte]; c: array[4, float32]; cov: float32) =
  ## Composites a premultiplied color with coverage cov over the
  ## pixel.
  let a = c[3] * cov
  if a <= 0:
    return
  let inv = 1 - a
  p[0] = to8(c[2] * cov + float32(p[0]) / 255 * inv)
  p[1] = to8(c[1] * cov + float32(p[1]) / 255 * inv)
  p[2] = to8(c[0] * cov + float32(p[2]) / 255 * inv)
  p[3] = to8(a + float32(p[3]) / 255 * inv)

proc blendSubpixel(p: var openArray[byte]; c, a: array[3, float32];
                   w: float32) =
  ## Composites a straight color c over a pixel with the coverage a
  ## of each subpixel, times w, each channel by its own: as renderers
  ## blend subpixel glyphs with a second color for the source's alpha.
  let
    wr = a[0] * w
    wg = a[1] * w
    wb = a[2] * w
    wa = (wr + wg + wb) / 3
  p[0] = to8(c[2] * wb + float32(p[0]) / 255 * (1 - wb))
  p[1] = to8(c[1] * wg + float32(p[1]) / 255 * (1 - wg))
  p[2] = to8(c[0] * wr + float32(p[2]) / 255 * (1 - wr))
  p[3] = to8(wa + float32(p[3]) / 255 * (1 - wa))

proc unpremul(c: array[4, float32]): array[3, float32] =
  ## The straight color of a premultiplied one.
  if c[3] <= 0:
    return [0'f32, 0, 0]
  [c[0] / c[3], c[1] / c[3], c[2] / c[3]]

proc over(src, dst: byte; inv: uint32): byte {.inline.} =
  ## src + dst×inv/255, rounded, for 8-bit premultiplied channels.
  let t = uint32(dst) * inv + 128
  byte(min(uint32(src) + (t + t shr 8) shr 8, 255))

proc blendSpan(row: var openArray[byte]; x0, x1: int; c: array[4, float32];
               cov: float32) =
  ## Composites a premultiplied color with coverage cov over a run of
  ## pixels.
  if x1 <= x0:
    return
  let a = c[3] * cov
  if a <= 0:
    return
  let px = [to8(c[2] * cov), to8(c[1] * cov), to8(c[0] * cov), to8(a)]
  let run = cast[ptr UncheckedArray[byte]](addr row[4 * x0])
  let n = 4 * (x1 - x0)
  if px[3] == 255:
    ## Opaque: copy the first pixel, then ever longer runs of them.
    copyMem(run, unsafeAddr px[0], 4)
    var k = 4
    while k < n:
      copyMem(addr run[k], run, min(n - k, k))
      k *= 2
    return
  let inv = 255 - uint32(px[3])
  var i = 0
  while i < n:
    run[i] = over(px[0], run[i], inv)
    run[i + 1] = over(px[1], run[i + 1], inv)
    run[i + 2] = over(px[2], run[i + 2], inv)
    run[i + 3] = over(px[3], run[i + 3], inv)
    i += 4

proc erase(p: var openArray[byte]; cov: float32) =
  ## Takes the coverage cov of a premultiplied pixel away.
  let inv = 1 - cov
  for i in 0 ..< 4:
    p[i] = to8(float32(p[i]) / 255 * inv)

proc mixMask(src, dst: byte; coverage: uint32): byte {.inline.} =
  let v = uint32(src) * coverage + uint32(dst) * (255 - coverage) + 128
  byte((v + v shr 8) shr 8)

type painter = object
  ## Computes the fill of an op at pixel centers: its color, or its
  ## gradient or stripes, premultiplied and times the op's opacity.
  paint: scene.Paint
  c1, c2: array[4, float32] ## premultiplied
  lab1, lab2: array[3, float32] ## premultiplied Oklab
  g: array[4, float32]
  origin: array[2, float32]

proc toLinear(c: float32): float32 =
  if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)

proc toSRGB(c: float32): float32 =
  if c <= 0.0031308: c * 12.92
  else: 1.055 * pow(max(c, 0'f32), 1 / 2.4) - 0.055

proc oklab(c: scene.Color): array[3, float32] =
  ## Converts an sRGB color to Oklab, as the shaders do.
  let
    r = toLinear(float32(c.r) / 255)
    g = toLinear(float32(c.g) / 255)
    b = toLinear(float32(c.b) / 255)
    l = cbrt(0.4122214708'f32 * r + 0.5363325363'f32 * g + 0.0514459929'f32 * b)
    m = cbrt(0.2119034982'f32 * r + 0.6806995451'f32 * g + 0.1073969566'f32 * b)
    s = cbrt(0.0883024619'f32 * r + 0.2817188376'f32 * g + 0.6299787005'f32 * b)
  [0.2104542553'f32 * l + 0.7936177850'f32 * m - 0.0040720468'f32 * s,
   1.9779984951'f32 * l - 2.4285922050'f32 * m + 0.4505937099'f32 * s,
   0.0259040371'f32 * l + 0.7827717662'f32 * m - 0.8086757660'f32 * s]

proc fromOklab(lab: array[3, float32]): array[3, float32] =
  ## Converts an Oklab color to sRGB components, unclamped.
  let
    l = lab[0] + 0.3963377774'f32 * lab[1] + 0.2158037573'f32 * lab[2]
    m = lab[0] - 0.1055613458'f32 * lab[1] - 0.0638541728'f32 * lab[2]
    s = lab[0] - 0.0894841775'f32 * lab[1] - 1.2914855480'f32 * lab[2]
    l3 = l * l * l
    m3 = m * m * m
    s3 = s * s * s
  [toSRGB(4.0767416621'f32 * l3 - 3.3077115913'f32 * m3 + 0.2309699292'f32 * s3),
   toSRGB(-1.2684380046'f32 * l3 + 2.6097574011'f32 * m3 - 0.3413193965'f32 * s3),
   toSRGB(-0.0041960863'f32 * l3 - 0.7034186147'f32 * m3 + 1.7076147010'f32 * s3)]

proc newPainter(op: scene.Op; opacity: float32): painter =
  result = painter(paint: op.paint, c1: op.color.premul(opacity),
                   c2: op.color2.premul(opacity), g: op.gradient,
                   origin: [op.rect.x, op.rect.y])
  if result.paint == scene.paintOklab:
    result.lab1 = oklab(op.color)
    result.lab2 = oklab(op.color2)
    for i in 0 ..< 3:
      result.lab1[i] *= result.c1[3]
      result.lab2[i] *= result.c2[3]

proc solid(p: painter): bool = p.paint == scene.paintSolid

proc visible(p: painter): bool =
  p.c1[3] > 0 or (not p.solid() and p.c2[3] > 0)

proc at(p: var painter; px, py: float32): array[4, float32] =
  ## The fill at a pixel center.
  case p.paint
  of scene.paintSolid:
    return p.c1
  of scene.paintStripes:
    let
      s = (px - p.origin[0]) * p.g[0] + (py - p.origin[1]) * p.g[1]
      period = p.g[3]
      phase = s - period * floor(s / period)
      cov = clamp01(0.5 - min(max(-phase, phase - p.g[2]), period - phase))
    var c: array[4, float32]
    for i in 0 ..< 4:
      c[i] = p.c1[i] * cov + p.c2[i] * (1 - cov)
    return c
  else:
    discard
  let
    g = p.g
    dx = g[2] - g[0]
    dy = g[3] - g[1]
  var t = 0'f32
  let l = dx * dx + dy * dy
  if l > 0:
    t = clamp01(((px - g[0]) * dx + (py - g[1]) * dy) / max(l, 0.0001))
  let a = p.c1[3] * (1 - t) + p.c2[3] * t
  if p.paint == scene.paintLinear:
    return [p.c1[0] * (1 - t) + p.c2[0] * t,
            p.c1[1] * (1 - t) + p.c2[1] * t,
            p.c1[2] * (1 - t) + p.c2[2] * t, a]
  if a <= 0:
    return [0'f32, 0, 0, 0]
  var lab: array[3, float32]
  for i in 0 ..< 3:
    lab[i] = (p.lab1[i] * (1 - t) + p.lab2[i] * t) / a
  let rgb = fromOklab(lab)
  [clamp01(rgb[0]) * a, clamp01(rgb[1]) * a, clamp01(rgb[2]) * a, a]

proc dash(r: scene.Rect; w: array[4, float32]; px, py: float32): float32 =
  ## How much of a dashed border of widths w (top, right, bottom,
  ## left) around r shows at a pixel center, as the shaders compute
  ## it: each side, which the pixel belongs to when it is nearest that
  ## side's edge in widths of its border, has an odd number of dashes
  ## and gaps of equal length, about three widths, starting and ending
  ## with a dash.
  let
    qx = px - r.x
    qy = py - r.y
    d = proc(dist, width: float32): float32 =
      if width > 0: dist / width else: 1e9'f32
    dt = d(qy, w[0])
    dr = d(r.w - qx, w[1])
    db = d(r.h - qy, w[2])
    dl = d(qx, w[3])
  var s, length, bw: float32
  if dt <= dr and dt <= db and dt <= dl:
    (s, length, bw) = (qx, r.w, w[0])
  elif dr <= db and dr <= dl:
    (s, length, bw) = (qy, r.h, w[1])
  elif db <= dl:
    (s, length, bw) = (r.w - qx, r.w, w[2])
  else:
    (s, length, bw) = (r.h - qy, r.h, w[3])
  let
    n = max(1'f32, floor((length / (3 * bw) + 1) * 0.5 + 0.5))
    seg = length / (2 * n - 1)
    k = floor(s / seg)
    f = s - k * seg
  var edge = min(f, seg - f)
  if k - 2 * floor(k * 0.5) < 0.5:
    edge = -edge
  clamp01(0.5 - edge)

proc opacityOf(v: float32): float32 {.inline.} =
  if v == 0: 1 else: v

proc gaussian(x, sigma: float32): float32 =
  exp(-(x * x) / (2 * sigma * sigma)) / (sqrt(2 * PI).float32 * sigma)

proc erf(x: float32): float32 =
  ## The error function within 5e-4, as the GPU renderers do
  ## (Abramowitz and Stegun 7.1.27).
  let a = abs(x)
  var t = 1 + (0.278393'f32 + (0.230389'f32 + 0.078108'f32 * (a * a)) * a) * a
  t *= t
  let e = 1 - 1 / (t * t)
  if x < 0: -e else: e

proc abs32(v: float32): float32 {.inline.} = abs(v)

proc unflipped(r: scene.Rect): scene.Rect =
  ## The rectangle a source rectangle covers, which has a negative
  ## width or height along an axis it flips.
  result = r
  if result.w < 0:
    result.x = result.x + result.w
    result.w = -result.w
  if result.h < 0:
    result.y = result.y + result.h
    result.h = -result.h

proc pixelated(t, d: float32): float32 =
  ## Moves t, a coordinate in an image's pixels, so that sampling it
  ## bilinearly draws each pixel as a square of its color, blended
  ## with the next only across the pixel of the frame, d of the
  ## image's pixels wide, that their edge crosses, as the GPU
  ## renderers do (Ebitengine's FilterPixelated).
  let
    c = t - 0.5
    i = floor(c)
    f = (c - i - 0.5) / min(max(d, 1e-5'f32), 1'f32) + 0.5
  i + clamp01(f) + 0.5

proc sample(img: scene.Image; u, v: float32; src: scene.Rect): array[4, float32] =
  ## A premultiplied pixel at (u, v) with bilinear filtering, clamped
  ## to src.
  let
    u = u - 0.5
    v = v - 0.5
    x0 = int(floor(u))
    y0 = int(floor(v))
    tx = u - float32(x0)
    ty = v - float32(y0)
    minX = int(src.x)
    minY = int(src.y)
    maxX = min(int(ceil(src.x + src.w)) - 1, img.w - 1)
    maxY = min(int(ceil(src.y + src.h)) - 1, img.h - 1)
  proc at(x, y: int): int =
    let
      x = max(minX, min(x, maxX))
      y = max(minY, min(y, maxY))
    (y * img.w + x) * 4
  let
    p00 = at(x0, y0)
    p10 = at(x0 + 1, y0)
    p01 = at(x0, y0 + 1)
    p11 = at(x0 + 1, y0 + 1)
  for i in 0 ..< 4:
    let
      top = float32(img.pix[p00 + i]) * (1 - tx) + float32(img.pix[p10 + i]) * tx
      bot = float32(img.pix[p01 + i]) * (1 - tx) + float32(img.pix[p11 + i]) * tx
    result[i] = (top * (1 - ty) + bot * ty) / 255

proc sampleOp(op: scene.Op; u, v, du, dv: float32): array[4, float32] =
  ## Reads op's image at (u, v), where a pixel spans du by dv of its
  ## pixels, as op samples, grays and tints it.
  var (u, v) = (u, v)
  if op.pixelated:
    u = pixelated(u, du)
    v = pixelated(v, dv)
  result = sample(op.image, u, v, unflipped(op.src))
  if op.grayscale:
    let l = 0.2126'f32 * result[0] + 0.7152'f32 * result[1] + 0.0722'f32 * result[2]
    result[0] = l
    result[1] = l
    result[2] = l
  if op.color != scene.Color():
    let a = float32(op.color.a) / 255
    result[0] *= float32(op.color.r) / 255 * a
    result[1] *= float32(op.color.g) / 255 * a
    result[2] *= float32(op.color.b) / 255 * a
    result[3] *= a
