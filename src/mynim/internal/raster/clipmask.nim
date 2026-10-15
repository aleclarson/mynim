## clipmask.go: retained clip coverage images for the GPU renderers.

type
  clipMasker = object
    dst: scene.Image
    area: image.Rectangle
    clips: seq[maskClip]
    ## transformed tells that a clip is transformed, so no run is
    ## solid.
    transformed: bool

  maskClip = object
    shape: shape
    transform, inverse: scene.Affine
    valid: bool
    ## x0, x1, y0 and y1 bound the frame pixels the clip covers at
    ## all.
    x0, x1, y0, y1: int

proc fillAlpha(pix: var openArray[byte]; a: byte) =
  ## Sets RGBA pixels to transparent black with alpha a.
  if pix.len == 0:
    return
  pix[0] = 0
  pix[1] = 0
  pix[2] = 0
  pix[3] = a
  var n = 4
  while n < pix.len:
    copyMem(addr pix[n], addr pix[0], min(n, pix.len - n))
    n *= 2

proc row(m: var clipMasker; member, y: int) =
  ## Writes row y of the mask, from area.min.y.
  let w = m.area.dx()
  let base = 4 * y * w
  let fy = y + m.area.min.y
  ## [lo, hi) are the frame pixels any clip covers, [slo, shi) those
  ## every clip without a transform covers entirely.
  var
    lo = m.area.min.x
    hi = m.area.max.x
    slo = lo
    shi = hi
  for i in 0 ..< m.clips.len:
    let c = addr m.clips[i]
    if not c.valid or fy < c.y0 or fy >= c.y1:
      lo = 0
      hi = 0
      break
    lo = max(lo, c.x0)
    hi = min(hi, c.x1)
    if c.transform.`set`:
      continue
    let (a, b) = solidSpan(c.shape, float32(fy), float32(fy + 1))
    slo = max(slo, a)
    shi = min(shi, b)
  if lo >= hi:
    zeroMem(addr m.dst.pix[base], 4 * w)
    return
  if lo - m.area.min.x > 0:
    zeroMem(addr m.dst.pix[base], 4 * (lo - m.area.min.x))
  if hi < m.area.max.x:
    zeroMem(addr m.dst.pix[base + 4 * (hi - m.area.min.x)],
            4 * (m.area.max.x - hi))
  let wy = float32(fy) + 0.5
  var x = lo
  while x < hi:
    let at = base + 4 * (x - m.area.min.x)
    if x >= slo and x < shi and not m.transformed:
      ## Every clip covers the rest of the run entirely.
      let n = 4 * (shi - x)
      fillAlpha(m.dst.pix.toOpenArray(base + at, base + at + n - 1), 255)
      x = shi
      continue
    let wx = float32(x) + 0.5
    var cov = 1'f32
    for i in 0 ..< m.clips.len:
      let c = addr m.clips[i]
      if not c.transform.`set` and x >= slo and x < shi:
        continue
      cov *= transformedCoverage(c.shape, c.transform, c.inverse, wx, wy)
      if cov == 0:
        break
    m.dst.pix[at] = 0
    m.dst.pix[at + 1] = 0
    m.dst.pix[at + 2] = 0
    m.dst.pix[at + 3] = to8(cov)
    inc x

proc clipMaskRowWork(context: pointer; member, part: int)
    {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    row(cast[ptr clipMasker](context)[], member, part)

proc clipMask*(dst: scene.Image; clips: seq[scene.ClipShape];
               area: image.Rectangle): scene.Image =
  ## Updates a retained coverage image for nested clips in area. GPU
  ## renderers cache this independently of the content within a clip,
  ## so moving content under a stationary clip costs no CPU pixel
  ## work.
  ##
  ## A row works out coverage only near the clips' edges: it is 0
  ## outside a clip's bounds and 1 within the span every clip without
  ## a transform covers entirely, filled a run at a time. Large masks
  ## take several cores.
  let
    w = area.dx()
    h = area.dy()
  result = dst
  if result.isNil:
    result = scene.newImageRgba(w, h, newSeq[byte](4 * w * h))
  elif result.w != w or result.h != h:
    result.resize(w, h)
  var m = clipMasker(dst: result, area: area,
                     clips: newSeq[maskClip](clips.len))
  for i in 0 ..< clips.len:
    let
      c = clips[i]
      mc = addr m.clips[i]
    mc.shape = newShape(c.rect, scene.corners(c.rect, c.radii,
                                              c.continuous))
    mc.transform = c.transform
    (mc.inverse, mc.valid) = c.transform.inverse()
    var b = c.rect
    if c.transform.`set`:
      b = c.transform.bounds(c.rect)
    ## Continuous corners antialias up to 2 pixels out.
    const margin = 3
    mc.x0 = int(floor(b.x)) - margin
    mc.x1 = int(ceil(b.x + b.w)) + margin
    mc.y0 = int(floor(b.y)) - margin
    mc.y1 = int(ceil(b.y + b.h)) + margin
    if c.transform.perspective():
      ## What is behind the viewer has no useful bounds.
      mc.x0 = low(int)
      mc.x1 = high(int)
      mc.y0 = low(int)
      mc.y1 = high(int)
    m.transformed = m.transformed or c.transform.`set`
  let workers = max(min(min(countProcessors(), w * h div workArea),
                        maxWorkers), 1)
  if workers == 1:
    for y in 0 ..< h:
      m.row(0, y)
  else:
    var t: team
    t.work = clipMaskRowWork
    t.context = addr m
    try:
      t.run(workers, h)
    finally:
      t.work = nil
      t.context = nil
  result.changed()
