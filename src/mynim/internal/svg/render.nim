## render.go: drawing nodes into layers of premultiplied RGBA pixels.

## renderer draws nodes into layers of premultiplied RGBA pixels, w×h.
## layer is a canvas: rows of 4×w bytes, with what was drawn into it
## within dirty.
type
  renderer = ref object
    w, h: int
    current: rgba
    z: vec.Rasterizer
    ## cov is the coverage of what is being drawn, a rectangle of the
    ## canvas.
    cov: seq[byte]
    flat, dashed, outline: polys
    stroker: stroker
    free: seq[layer]
  layer = ref object
    pix: seq[byte]
    dirty: Rectangle

proc getLayer(r: renderer): layer =
  if r.free.len > 0:
    result = r.free[^1]
    r.free.setLen(r.free.len - 1)
    return
  layer(pix: newSeq[byte](r.w * r.h * 4))

## release clears a layer for reuse.
proc release(r: renderer; l: layer) =
  let d = l.dirty
  for y in d.min.y ..< d.max.y:
    for i in (y * r.w + d.min.x) * 4 ..< (y * r.w + d.max.x) * 4:
      l.pix[i] = 0
  l.dirty = Rectangle()
  r.free.add(l)

proc div255(x: uint32): uint32 =
  ## Divides by 255, rounding, for x up to 255×255.
  (x + 128 + ((x + 128) shr 8)) shr 8

## over composites a premultiplied color over the pixel d.
proc over(d: ptr byte; r, g, b, a: uint32) =
  let ia = 255 - a
  let dp = cast[ptr UncheckedArray[byte]](d)
  dp[0] = uint8(r + div255(uint32(dp[0]) * ia))
  dp[1] = uint8(g + div255(uint32(dp[1]) * ia))
  dp[2] = uint8(b + div255(uint32(dp[2]) * ia))
  dp[3] = uint8(a + div255(uint32(dp[3]) * ia))

## premul returns c with an opacity, premultiplied, from 0 to 255.
proc premul(c: rgba; alpha: float64): array[4, uint32] =
  let a = max(0, min(1, c.a * alpha))
  proc q(v: float64): uint32 =
    uint32(max(0, min(1, v)) * a * 255 + 0.5)
  [q(c.r), q(c.g), q(c.b), uint32(a * 255 + 0.5)]

proc drawNode(r: renderer; n: node; ctm: matrix; dst: layer; alpha: float64)
proc content(r: renderer; n: node; m: matrix; dst: layer; alpha: float64)
proc applyPaint(r: renderer; dst: layer; rect: Rectangle; p: paint;
           alpha: float64; m: matrix; bbox: box)
proc composite(r: renderer; dst, src: layer; alpha: float64)
proc scaleLayer(r: renderer; l: layer; mask: openArray[byte])
proc clip(r: renderer; l: layer; cd: clipDef; m: matrix; bbox: box;
          hasBox: bool)
proc maskApply(r: renderer; l: layer; md: maskDef; m: matrix; bbox: box;
               hasBox: bool)
proc clipMask(r: renderer; cd: clipDef; m: matrix; bbox: box;
              hasBox: bool; rect: Rectangle): seq[byte]
proc clipNode(r: renderer; n: node; m: matrix; rect: Rectangle;
              mask: var seq[byte])
proc cover(r: renderer; ps: var polys; evenOdd: bool):
    tuple[rect: Rectangle, ok: bool]
proc fill(r: renderer; s: ref shape; m: matrix; dst: layer;
          alpha: float64; bbox: box)
proc stroke(r: renderer; s: ref shape; m: matrix; dst: layer;
            alpha: float64; bbox: box)
proc `at`(g: ref gradient; p: point): tuple[t: float64, ok: bool]
proc lut(g: ref gradient; current: rgba; alpha: float64;
         `out`: var array[256, array[4, uint32]])

## node draws n, whose parent's user space maps to pixels by ctm, into
## dst with an opacity.
proc drawNode(r: renderer; n: node; ctm: matrix; dst: layer; alpha: float64) =
  let a = alpha * n.opacity
  if a <= 0:
    return
  let m = ctm.mul(n.m)
  if n.clip.isNil and n.mask.isNil and (n.opacity >= 1 or n.single):
    r.content(n, m, dst, a)
    return
  ## Group opacity, clipping and masking apply to the content as a
  ## whole.
  let l = r.getLayer()
  r.content(n, m, l, 1)
  if not n.clip.isNil:
    r.clip(l, n.clip, m, n.bbox, n.hasBox)
  if not n.mask.isNil:
    r.maskApply(l, n.mask, m, n.bbox, n.hasBox)
  r.composite(dst, l, a)
  r.release(l)

proc content(r: renderer; n: node; m: matrix; dst: layer; alpha: float64) =
  let s = n.shape
  if s.isNil:
    for k in n.kids:
      r.drawNode(k, m, dst, alpha)
    return
  if s.strokeFirst:
    r.stroke(s, m, dst, alpha, n.bbox)
    r.fill(s, m, dst, alpha, n.bbox)
  else:
    r.fill(s, m, dst, alpha, n.bbox)
    r.stroke(s, m, dst, alpha, n.bbox)

proc fill(r: renderer; s: ref shape; m: matrix; dst: layer;
          alpha: float64; bbox: box) =
  if s.fill.kind == paintNone:
    return
  r.flat.reset()
  s.path.flatten(m, true, r.flat)
  let (rect, ok) = r.cover(r.flat, s.evenOdd)
  if ok:
    r.applyPaint(dst, rect, s.fill, alpha * s.fillOpacity, m, bbox)

proc stroke(r: renderer; s: ref shape; m: matrix; dst: layer;
            alpha: float64; bbox: box) =
  if s.stroke.kind == paintNone or s.width <= 0:
    return
  let scale = m.stretch()
  if not (scale > 0):
    return
  r.flat.reset()
  s.path.flatten(m, false, r.flat)
  var lines = addr r.flat
  if s.dashes.len > 0:
    r.dashed.reset()
    dash(r.flat, s.dashes, s.dashOffset, r.dashed, 1 shl 16)
    lines = addr r.dashed
  r.outline.reset()
  var st = addr r.stroker
  st.hw = s.width / 2
  st.join = s.join
  st.cap = s.cap
  st.miter = s.miter
  st.tol = 0.1 / scale
  st.`out` = addr r.outline
  st[].stroke(lines[])
  r.outline.transform(m)
  let (rect, ok) = r.cover(r.outline, false)
  if ok:
    r.applyPaint(dst, rect, s.stroke, alpha * s.strokeOpacity, m, bbox)

## cover rasterizes polygons in pixels into r.cov, returning the
## rectangle of the canvas it covers.
proc cover(r: renderer; ps: var polys; evenOdd: bool):
    tuple[rect: Rectangle, ok: bool] =
  if ps.len() == 0:
    return (Rectangle(), false)
  ## Shapes far beyond the canvas, or not finite, draw nothing.
  const far = 1 shl 24
  var
    x0 = Inf
    y0 = Inf
    x1 = NegInf
    y1 = NegInf
  for p in ps.pts:
    if not (p.x > -far and p.x < far and p.y > -far and p.y < far):
      return (Rectangle(), false)
    x0 = min(x0, p.x)
    x1 = max(x1, p.x)
    y0 = min(y0, p.y)
    y1 = max(y1, p.y)
  let rc = rect(int(floor(x0)), int(floor(y0)),
                int(ceil(x1)) + 1, int(ceil(y1)) + 1).intersect(
                rect(0, 0, r.w, r.h))
  if rc.empty:
    return (Rectangle(), false)
  let
    w = rc.dx
    h = rc.dy
  r.z.reset(w, h)
  let
    ox = float64(rc.min.x)
    oy = float64(rc.min.y)
  for i in 0 ..< ps.len():
    let pts = ps.poly(i)
    r.z.moveTo(float32(pts[0].x - ox), float32(pts[0].y - oy))
    for p in pts.toOpenArray(1, pts.len - 1):
      r.z.lineTo(float32(p.x - ox), float32(p.y - oy))
    r.z.closePath()
  if r.cov.len < w * h:
    r.cov = newSeq[byte](w * h)
  r.cov.setLen(w * h)
  if evenOdd:
    r.z.maskEvenOdd(r.cov, w)
  else:
    r.z.mask(r.cov, w)
  (rc, true)

## paint paints the coverage in r.cov, of rect, with a paint and an
## opacity. m maps the user space of the shape it covers to pixels.
proc applyPaint(r: renderer; dst: layer; rect: Rectangle; p: paint;
           alpha: float64; m: matrix; bbox: box) =
  let w = rect.dx
  case p.kind
  of paintColor, paintCurrent:
    var col = p.color
    if p.kind == paintCurrent:
      col = r.current
    let c = premul(col, alpha)
    if c[3] == 0:
      return
    for y in rect.min.y ..< rect.max.y:
      let row = (y * r.w + rect.min.x) * 4
      for x in 0 ..< w:
        let v = r.cov[(y - rect.min.y) * w + x]
        if v == 0:
          continue
        let d = row + x * 4
        if v == 255 and c[3] == 255:
          dst.pix[d] = uint8(c[0])
          dst.pix[d + 1] = uint8(c[1])
          dst.pix[d + 2] = uint8(c[2])
          dst.pix[d + 3] = 255
          continue
        let k = uint32(v)
        over(addr dst.pix[d], div255(c[0] * k), div255(c[1] * k),
             div255(c[2] * k), div255(c[3] * k))
  of paintGradient:
    let g = p.grad
    var gm = m
    if g.bbox:
      if bbox.w == 0 or bbox.h == 0:
        return ## the gradient has no box to span
      gm = gm.mul(boxMatrix(bbox))
    let (inv, ok) = gm.mul(g.m).invert()
    if not ok:
      return
    var lut: array[256, array[4, uint32]]
    g.lut(r.current, alpha, lut)
    for y in rect.min.y ..< rect.max.y:
      let row = (y * r.w + rect.min.x) * 4
      for x in 0 ..< w:
        let v = r.cov[(y - rect.min.y) * w + x]
        if v == 0:
          continue
        let (t, tok) = g.at(inv.apply(
          point(x: float64(rect.min.x + x) + 0.5, y: float64(y) + 0.5)))
        if not tok:
          continue
        let c = addr lut[int(t * 255 + 0.5)]
        let k = uint32(v)
        over(addr dst.pix[row + x * 4], div255(c[0] * k),
             div255(c[1] * k), div255(c[2] * k), div255(c[3] * k))
  else:
    return
  dst.dirty = dst.dirty.union(rect)

## at returns where a point in the gradient's space falls along it,
## spread into [0, 1]; ok is false where a radial gradient does not
## reach.
proc `at`(g: ref gradient; p: point): tuple[t: float64, ok: bool] =
  var t = 0.0
  if not g.radial:
    let
      dx = g.x2 - g.x1
      dy = g.y2 - g.y1
      d = dx * dx + dy * dy
    if d == 0:
      return (1, true) ## the last stop's color
    t = ((p.x - g.x1) * dx + (p.y - g.y1) * dy) / d
  else:
    if g.r <= 0:
      return (1, true)
    ## The largest t for which p is on the circle around
    ## f + t(c - f) of radius fr + t(r - fr).
    let
      cdx = g.cx - g.fx
      cdy = g.cy - g.fy
      pdx = p.x - g.fx
      pdy = p.y - g.fy
      dr = g.r - g.fr
      a = cdx * cdx + cdy * cdy - dr * dr
      b = pdx * cdx + pdy * cdy + g.fr * dr
      c = pdx * pdx + pdy * pdy - g.fr * g.fr
    if abs(a) < 1e-12:
      if b == 0:
        return (0, false)
      t = c / (2 * b)
    else:
      let disc = b * b - a * c
      if disc < 0:
        return (0, false)
      let s = sqrt(disc)
      let
        t0 = (b + s) / a
        t1 = (b - s) / a
      t = max(t0, t1)
      if g.fr + t * dr < 0:
        t = min(t0, t1)
        if g.fr + t * dr < 0:
          return (0, false)
  case g.spread
  of spreadReflect:
    t = abs(t) mod 2
    if t > 1:
      t = 2 - t
  of spreadRepeat:
    t -= floor(t)
  else:
    t = max(0, min(1, t))
  if not (t >= 0 and t <= 1):
    return (0, false)
  (t, true)

## lut fills out with the gradient's colors at 256 positions, with an
## opacity, premultiplied.
proc lut(g: ref gradient; current: rgba; alpha: float64;
         `out`: var array[256, array[4, uint32]]) =
  let stops = g.stops
  proc color(s: stop): rgba =
    var c = s.color
    if s.current:
      c = current
    c.a *= s.opacity
    c
  var j = 0
  for i in 0 ..< 256:
    let t = float64(i) / 255
    while j + 1 < stops.len and stops[j + 1].offset <= t:
      inc j
    var c: rgba
    if t <= stops[0].offset:
      c = color(stops[0])
    elif j == stops.len - 1:
      c = color(stops[j])
    else:
      let
        a = color(stops[j])
        b = color(stops[j + 1])
        f = (t - stops[j].offset) / (stops[j + 1].offset - stops[j].offset)
      c = rgba(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f,
               b: a.b + (b.b - a.b) * f, a: a.a + (b.a - a.a) * f)
    `out`[i] = premul(c, alpha)

## composite draws src over dst with an opacity.
proc composite(r: renderer; dst, src: layer; alpha: float64) =
  let d = src.dirty
  if d.empty:
    return
  let k = uint32(max(0, min(1, alpha)) * 255 + 0.5)
  for y in d.min.y ..< d.max.y:
    let i0 = (y * r.w + d.min.x) * 4
    for i in countup(0, (d.max.x - d.min.x) * 4 - 1, 4):
      let s = i0 + i
      if src.pix[s + 3] == 0:
        continue
      if k == 255:
        over(addr dst.pix[s], uint32(src.pix[s]), uint32(src.pix[s + 1]),
             uint32(src.pix[s + 2]), uint32(src.pix[s + 3]))
        continue
      over(addr dst.pix[s], div255(uint32(src.pix[s]) * k),
           div255(uint32(src.pix[s + 1]) * k),
           div255(uint32(src.pix[s + 2]) * k),
           div255(uint32(src.pix[s + 3]) * k))
  dst.dirty = dst.dirty.union(d)

## scaleLayer multiplies the pixels of l within its dirty rectangle by
## the values of mask, one byte per pixel of that rectangle.
proc scaleLayer(r: renderer; l: layer; mask: openArray[byte]) =
  let d = l.dirty
  let w = d.dx
  for y in d.min.y ..< d.max.y:
    let row = (y * r.w + d.min.x) * 4
    for x in 0 ..< w:
      let v = mask[(y - d.min.y) * w + x]
      let p = row + x * 4
      case v
      of 255:
        discard
      of 0:
        l.pix[p] = 0
        l.pix[p + 1] = 0
        l.pix[p + 2] = 0
        l.pix[p + 3] = 0
      else:
        let k = uint32(v)
        l.pix[p] = uint8(div255(uint32(l.pix[p]) * k))
        l.pix[p + 1] = uint8(div255(uint32(l.pix[p + 1]) * k))
        l.pix[p + 2] = uint8(div255(uint32(l.pix[p + 2]) * k))
        l.pix[p + 3] = uint8(div255(uint32(l.pix[p + 3]) * k))

## clip clips what a layer holds to a clip path, applied in the user
## space m of an element with a bounding box.
proc clip(r: renderer; l: layer; cd: clipDef; m: matrix; bbox: box;
          hasBox: bool) =
  if l.dirty.empty:
    return
  r.scaleLayer(l, r.clipMask(cd, m, bbox, hasBox, l.dirty))

## clipMask returns the coverage of a clip path over a rectangle.
proc clipMask(r: renderer; cd: clipDef; m: matrix; bbox: box;
              hasBox: bool; rect: Rectangle): seq[byte] =
  let w = rect.dx
  var mask = newSeq[byte](w * rect.dy)
  var cm = m.mul(cd.m)
  if cd.bbox:
    if not hasBox or bbox.w == 0 or bbox.h == 0:
      return mask ## nothing to clip to
    cm = cm.mul(boxMatrix(bbox))
  for k in cd.kids:
    r.clipNode(k, cm, rect, mask)
  if not cd.clip.isNil:
    let inner = r.clipMask(cd.clip, m, bbox, hasBox, rect)
    for i in 0 ..< mask.len:
      mask[i] = uint8(div255(uint32(mask[i]) * uint32(inner[i])))
  mask

## clipNode adds the coverage of a clip path's node to mask, a
## rectangle.
proc clipNode(r: renderer; n: node; m: matrix; rect: Rectangle;
              mask: var seq[byte]) =
  let m = m.mul(n.m)
  if n.shape.isNil:
    for k in n.kids:
      r.clipNode(k, m, rect, mask)
    return
  r.flat.reset()
  n.shape.path.flatten(m, true, r.flat)
  let (cr, ok) = r.cover(r.flat, n.shape.evenOdd)
  if not ok:
    return
  let `in` = cr.intersect(rect)
  let
    cw = cr.dx
    w = rect.dx
  for y in `in`.min.y ..< `in`.max.y:
    let
      src = (y - cr.min.y) * cw + `in`.min.x - cr.min.x
      dst = (y - rect.min.y) * w + `in`.min.x - rect.min.x
    for x in 0 ..< `in`.dx:
      let
        a = uint32(mask[dst + x])
        b = uint32(r.cov[src + x])
      mask[dst + x] = uint8(a + b - div255(a * b))

## maskApply masks what a layer holds with a mask, applied in the user
## space m of an element with a bounding box.
proc maskApply(r: renderer; l: layer; md: maskDef; m: matrix; bbox: box;
               hasBox: bool) =
  let d = l.dirty
  if d.empty:
    return
  var region = md.region
  var cm = m
  if md.units or md.content:
    if not hasBox or bbox.w == 0 or bbox.h == 0:
      r.scaleLayer(l, newSeq[byte](d.dx * d.dy))
      return
    if md.units:
      region = box(x: bbox.x + region.x * bbox.w,
                   y: bbox.y + region.y * bbox.h,
                   w: region.w * bbox.w, h: region.h * bbox.h)
    if md.content:
      cm = m.mul(boxMatrix(bbox))
  let ml = r.getLayer()
  for k in md.kids:
    r.drawNode(k, cm, ml, 1)
  var values = newSeq[byte](d.dx * d.dy)
  let w = d.dx
  for y in d.min.y ..< d.max.y:
    let row = (y * r.w + d.min.x) * 4
    for x in 0 ..< w:
      let p = row + x * 4
      var v = uint32(ml.pix[p + 3])
      if not md.alpha:
        ## Luminance, of premultiplied colors.
        v = (54 * uint32(ml.pix[p]) + 183 * uint32(ml.pix[p + 1]) +
             19 * uint32(ml.pix[p + 2]) + 128) shr 8
      values[(y - d.min.y) * w + x] = uint8(min(v, 255))
  r.release(ml)
  ## The mask's content shows within its region only.
  var rp: path
  rp.rect(region.x, region.y, region.w, region.h, 0, 0)
  r.flat.reset()
  rp.flatten(m, true, r.flat)
  let (cr, ok) = r.cover(r.flat, false)
  for y in d.min.y ..< d.max.y:
    for x in d.min.x ..< d.max.x:
      let i = (y - d.min.y) * w + x - d.min.x
      if not ok or not cr.contains(x, y):
        values[i] = 0
        continue
      values[i] = uint8(div255(uint32(values[i]) *
          uint32(r.cov[(y - cr.min.y) * cr.dx + x - cr.min.x])))
  r.scaleLayer(l, values)
