## effect.go: the drawer kept scene to scene, effect backdrops and the
## effect render path.

type
  drawer = object
    ## What draw keeps from scene to scene: the renderers of the bands
    ## and the team drawing them, the backdrop of an effect, and the
    ## effects' CPU twins.
    rs: seq[renderer]
    bands: team
    job: bandJob
    bd: backdrop
    fx: Table[uint, scene.EffectPixels]

  bandJob = object
    ## What the bands of drawOps draw: operations first to last of s
    ## within area, in bands of rows rows.
    renderers: seq[renderer]
    dst: ptr Image
    s: scene.Scene
    area: image.Rectangle
    bounds: seq[image.Rectangle]
    first, last: int
    rows: int
    px: scene.EffectPixels
    b: scene.BackdropImage

  backdrop = object
    ## Computes the backdrop of an effect, as the GPU renderers do in
    ## textures, rounded to 8 bits at each step.
    img: scene.BackdropImage
    ## tmp holds the rows blurred, before the columns are.
    tmp: seq[float32]
    weights: seq[float32]

    ## lines does the passes of read on several cores, each line of
    ## pass over dst (line).
    lines: team
    dst: ptr Image
    pass: int

## The passes of backdrop.read.
const
  averagePass = 0
  rowsPass = 1
  columnsPass = 2

## texelWork is how many texels times taps are worth waking other cores
## for.
const texelWork = 64 shl 10

proc texel(v: float32): float32 {.inline.} =
  ## v as an 8-bit channel of a texture holds it.
  float32(to8(v)) / 255

proc pixels(d: var drawer; e: ref scene.Effect): scene.EffectPixels =
  ## What draws e on the CPU, made the first time, or nil for an
  ## effect without.
  if e.isNil or e.pixels.isNil:
    return nil
  let k = cast[uint](e)
  result = d.fx.getOrDefault(k)
  if result.isNil:
    result = e.pixels()
    d.fx[k] = result

proc average(bd: var backdrop; dst: ptr Image; j: int) =
  ## Computes row j of the texels: the average of each square of the
  ## area, those along its far edges repeating its last pixels, as a
  ## texture's edges do.
  let
    img = bd.img
    k = img.backdrop.down
    inv = 1 / float32(k * k)
  for i in 0 ..< img.w:
    var c: array[4, float32]
    for dy in 0 ..< k:
      let y = min(img.backdrop.area.min.y + j * k + dy,
                  img.backdrop.area.max.y - 1)
      let row = y * dst.stride
      for dx in 0 ..< k:
        let x = min(img.backdrop.area.min.x + i * k + dx,
                    img.backdrop.area.max.x - 1)
        let p = row + 4 * x
        ## BGRA to RGBA.
        c[0] += float32(dst.pix[p + 2]) / 255
        c[1] += float32(dst.pix[p + 1]) / 255
        c[2] += float32(dst.pix[p]) / 255
        c[3] += float32(dst.pix[p + 3]) / 255
    let o = 4 * (j * img.w + i)
    for ch in 0 ..< 4:
      img.pix[o + ch] = texel(c[ch] * inv)

proc blur(bd: var backdrop; dst, src: var seq[float32]; step, next, n,
          line: int) =
  ## Blurs line of src into dst: n texels step apart, from line×next,
  ## clamping at its ends.
  let
    rad = bd.img.backdrop.radius
    w = bd.weights
  ## Every texel takes every weight, those past the ends on the last
  ## texel.
  var sum = w[0]
  for o in 1 .. rad:
    sum += 2 * w[o]
  let base = line * next
  for i in 0 ..< n:
    let p = base + i * step
    var
      c0 = src[p] * w[0]
      c1 = src[p + 1] * w[0]
      c2 = src[p + 2] * w[0]
      c3 = src[p + 3] * w[0]
    if i >= rad and i + rad < n:
      for o in 1 .. rad:
        let
          a = base + (i - o) * step
          b = base + (i + o) * step
          wo = w[o]
        c0 += (src[a] + src[b]) * wo
        c1 += (src[a + 1] + src[b + 1]) * wo
        c2 += (src[a + 2] + src[b + 2]) * wo
        c3 += (src[a + 3] + src[b + 3]) * wo
    else:
      for o in 1 .. rad:
        let
          a = base + max(i - o, 0) * step
          b = base + min(i + o, n - 1) * step
          wo = w[o]
        c0 += (src[a] + src[b]) * wo
        c1 += (src[a + 1] + src[b + 1]) * wo
        c2 += (src[a + 2] + src[b + 2]) * wo
        c3 += (src[a + 3] + src[b + 3]) * wo
    let d = base + i * step
    dst[d] = texel(c0 / sum)
    dst[d + 1] = texel(c1 / sum)
    dst[d + 2] = texel(c2 / sum)
    dst[d + 3] = texel(c3 / sum)

proc line(bd: var backdrop; member, i: int) =
  ## Does line i of the pass.
  let img = bd.img
  case bd.pass
  of averagePass:
    bd.average(bd.dst, i)
  of rowsPass:
    bd.blur(bd.tmp, img.pix, 4, 4 * img.w, img.w, i)
  else:
    bd.blur(img.pix, bd.tmp, 4 * img.w, 4, img.h, i)

proc backdropLineWork(context: pointer; member, part: int)
    {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    line(cast[ptr backdrop](context)[], member, part)

proc run(bd: var backdrop; pass, n, work: int) =
  ## Does lines 0 to n-1 of pass, each work texels times taps, on
  ## several cores when they are worth it.
  bd.pass = pass
  let workers = max(min(min(countProcessors(), n * work div texelWork),
                        maxWorkers), 1)
  if workers == 1:
    for i in 0 ..< n:
      bd.line(0, i)
    return
  bd.lines.work = backdropLineWork
  bd.lines.context = addr bd
  try:
    bd.lines.run(workers, n)
  finally:
    bd.lines.work = nil
    bd.lines.context = nil

proc read(bd: var backdrop; dst: ptr Image; b: scene.Backdrop) =
  ## Computes the backdrop b of dst.
  let img = bd.img
  img.backdrop = b
  (img.w, img.h) = b.size()
  let n = 4 * img.w * img.h
  if img.pix.len < n:
    img.pix = newSeq[float32](n)
    bd.tmp = newSeq[float32](n)
  img.pix.setLen(n)
  bd.tmp.setLen(n)
  if n == 0:
    return
  bd.dst = dst
  let k = b.down
  bd.run(averagePass, img.h, img.w * k * k)
  if b.radius == 0:
    return
  bd.weights.setLen(0)
  for i in 0 .. b.radius:
    bd.weights.add(scene.blurWeight(i, b.sigma))
  let taps = 2 * b.radius + 1
  bd.run(rowsPass, img.h, img.w * taps)
  bd.run(columnsPass, img.w, img.h * taps)

proc effect(r: var renderer; op: scene.Op; px: scene.EffectPixels;
            b: scene.BackdropImage) =
  ## Draws an effect with px, which begin readied for op, over its
  ## backdrop b (nil for an effect reading none), within its shape,
  ## whose corners are continuous when the op's are, while the effect
  ## works with circular ones.
  if op.rect.empty():
    return
  let opacity = opacityOf(op.opacity)
  let radii = scene.corners(op.rect, op.radii, op.continuous)
  var box = newShape(op.rect, radii)
  let round = hasRadii(radii)
  let (x0, y0, x1, y1) = r.pixelBounds(op.rect)
  for y in y0 ..< y1:
    let row = y * r.dst.stride
    let py = float32(y) + 0.5
    let (cl, ch) = r.clipSolid(y)
    let (ol, oh) = solidSpan(box, float32(y), float32(y + 1))
    for x in x0 ..< x1:
      let px0 = float32(x) + 0.5
      var cov = opacity
      if x < ol or x >= oh or not round:
        cov *= coverage(box, px0, py)
      if x < cl or x >= ch:
        cov *= r.clipCoverage(x, y)
      if cov <= 0:
        continue
      let c = px.color(px0, py, b)
      let po = row + 4 * x
      if cov >= 1 and c[3] >= 1:
        ## Opaque.
        r.dst.pix[po + 0] = to8(c[2])
        r.dst.pix[po + 1] = to8(c[1])
        r.dst.pix[po + 2] = to8(c[0])
        r.dst.pix[po + 3] = 255
        continue
      blend(r.dst.pix.toOpenArray(po, po + 3), c, cov)
