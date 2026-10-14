## transform.go: hit testing and the transformed render paths.

proc transformedCoverage(s: var shape; m, inv: scene.Affine; x,
                       y: float32): float32 =
  ## Integrates a shape that m transforms (inv its inverse) over a
  ## device pixel. Interior pixels take one distance test; edges use a
  ## grid in device space. What a projective map puts behind the
  ## viewer covers nothing.
  if not inv.`set`:
    return coverage(s, x, y)
  let (lx, ly) = inv.point(x, y)
  if m.perspective() and m.w(lx, ly) <= 0:
    return 0
  var d = scene.sdRoundRect(s.r, s.radii, lx, ly)
  if s.continuous:
    (d, _) = s.contDist(lx, ly)
  let (rx, ry) = inv.vectorAt(x, y, 0.5, 0.5)
  let (sx, sy) = inv.vectorAt(x, y, 0.5, -0.5)
  let reach = max(abs(rx) + abs(ry), abs(sx) + abs(sy)) * 2
  if d < -reach:
    return 1
  if d > reach:
    return 0
  const samples = 4
  var n = 0
  for j in 0 ..< samples:
    for i in 0 ..< samples:
      let (px, py) = inv.point(x + (float32(i) + 0.5) / samples - 0.5,
                               y + (float32(j) + 0.5) / samples - 0.5)
      var v = scene.sdRoundRect(s.r, s.radii, px, py)
      if s.continuous:
        (v, _) = s.contDist(px, py)
      if v <= 0:
        inc n
  float32(n) / (samples * samples)

proc contains*(r: scene.Rect; radii: array[4, float32];
               continuous: bool; x, y: float32): bool =
  ## Tests the interior of a rounded clip, using the same continuous
  ## corner geometry as rendering. Hit testing uses the shape's edge,
  ## without the pixel coverage used to smooth that edge on screen.
  if not r.contains(x, y):
    return false
  var s = newShape(r, scene.corners(r, radii, continuous))
  if s.continuous:
    let (d, _) = s.contDist(x, y)
    return d <= 0
  scene.sdRoundRect(r, s.radii, x, y) <= 0

proc transformedShadowAt(op: scene.Op; box: var shape; x,
                         y: float32): float32 =
  let sigma = op.blur / 2
  if sigma < 0.5:
    return coverage(box, x, y)
  let
    hx = op.rect.w / 2
    hy = op.rect.h / 2
  let
    x = x - op.rect.x - hx
    y = y - op.rect.y - hy
    ext = 3 * sigma
    start = min(max(-ext, y - hy), y + hy)
    `end` = min(max(ext, y - hy), y + hy)
    step = (`end` - start) / 4
    k = sqrt(0.5'f32) / sigma
    corner = max(max(box.radii[0], box.radii[1]),
                 max(box.radii[2], box.radii[3]))
  let cc = newContCorner(corner, corner, corner, op.rect.w, op.rect.h)
  var v = 0'f32
  for i in 0 ..< 4:
    let yy = start + (float32(i) + 0.5) * step
    var half = hx
    if box.continuous:
      let (at, _) = cc.inset(hy - abs(y - yy))
      half -= at
    else:
      let delta = min(hy - corner - abs(y - yy), 0)
      if delta < 0:
        half = hx - corner + sqrt(max(0'f32, corner * corner - delta * delta))
    v += gaussian(yy, sigma) * step * 0.5 * (erf((x + half) * k) - erf((x - half) * k))
  v

proc transformed(r: var renderer; op: scene.Op; px: scene.EffectPixels;
                 b: scene.BackdropImage) =
  ## Transformed inverse maps pixels into the operation's coordinates.
  ## Identity operations retain the existing span renderer.
  let (inv, ok) = op.transform.inverse()
  let inset = op.kind == scene.opShadow and op.inset
  if not ok or (not inset and op.rect.empty()) or (inset and op.`cast`.empty()):
    return
  let radii = scene.corners(op.rect, op.radii, op.continuous)
  var outer = newShape(op.rect, radii)
  var inner = outer
  var bw = op.border
  if op.borderColor.a == 0:
    bw = default(array[4, float32])
  let hasBorder = scene.hasBorder(bw)
  if hasBorder:
    let (ir, irad) = scene.innerRadii(op.rect, radii, bw)
    inner = newShape(ir, irad)
  var pt = newPainter(op, opacityOf(op.opacity))
  let border = op.borderColor.premul(opacityOf(op.opacity))
  var box = op.rect
  if inset:
    box = op.`cast`
  elif op.kind == scene.opShadow:
    let e = 1.5 * op.blur + 1
    box = scene.Rect(x: box.x - e, y: box.y - e, w: box.w + 2 * e,
                     h: box.h + 2 * e)
  box = op.transform.bounds(box)
  let (x0, y0, x1, y1) = r.pixelBounds(box)
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let clip = r.clipCoverage(x, y)
      if clip <= 0:
        continue
      let
        wx = float32(x) + 0.5
        wy = float32(y) + 0.5
        (lx, ly) = inv.point(wx, wy)
      if op.transform.perspective() and op.transform.w(lx, ly) <= 0:
        continue # behind the viewer
      let po = y * r.dst.stride + 4 * x
      if inset:
        ## Inside the box, what the hole, blurred, leaves.
        var caster = newShape(op.`cast`, scene.corners(op.`cast`, op.castRadii,
                                                       op.continuous))
        var cov = transformedCoverage(caster, op.transform, inv, wx, wy)
        if not op.rect.empty():
          var hole = transformedShadowAt(op, outer, lx, ly)
          if op.blur < 1:
            hole = transformedCoverage(outer, op.transform, inv, wx, wy)
          cov *= 1 - hole
        blend(r.dst.pix.toOpenArray(po, po + 3), op.color.premul(opacityOf(op.opacity)), cov * clip)
        continue
      if op.kind == scene.opShadow:
        var cov = transformedShadowAt(op, outer, lx, ly)
        if op.blur < 1:
          cov = transformedCoverage(outer, op.transform, inv, wx, wy)
        if not op.`cast`.empty():
          var caster = newShape(op.`cast`, scene.corners(op.`cast`, op.castRadii,
                                                         op.continuous))
          cov *= 1 - transformedCoverage(caster, op.transform, inv, wx, wy)
        blend(r.dst.pix.toOpenArray(po, po + 3), op.color.premul(opacityOf(op.opacity)), cov * clip)
        continue
      let cov = transformedCoverage(outer, op.transform, inv, wx, wy)
      if cov <= 0:
        continue
      case op.kind
      of scene.opFill:
        if pt.visible():
          blend(r.dst.pix.toOpenArray(po, po + 3), pt.at(lx, ly), cov * clip)
        if hasBorder:
          var ic = 0'f32
          if not inner.r.empty():
            ic = transformedCoverage(inner, op.transform, inv, wx, wy)
          var bc = max(cov - ic, 0)
          if op.dashed:
            bc *= dash(op.rect, bw, lx, ly)
          blend(r.dst.pix.toOpenArray(po, po + 3), border, bc * clip)
      of scene.opImage:
        if op.image.isNil or op.image.w == 0 or op.image.h == 0 or
            unflipped(op.src).empty():
          continue
        ## How far a pixel of the frame reaches in the image's, as the
        ## GPU's fwidth.
        let
          sx = op.src.w / op.rect.w
          sy = op.src.h / op.rect.h
          (ax, ay) = inv.vectorAt(wx, wy, 1, 0)
          (bx, by) = inv.vectorAt(wx, wy, 0, 1)
        let c = sampleOp(op, op.src.x + (lx - op.rect.x) * sx,
                         op.src.y + (ly - op.rect.y) * sy,
                         (abs32(ax) + abs32(bx)) * abs32(sx),
                         (abs32(ay) + abs32(by)) * abs32(sy))
        blend(r.dst.pix.toOpenArray(po, po + 3), c, cov * clip * opacityOf(op.opacity))
      of scene.opEffect:
        if not px.isNil:
          blend(r.dst.pix.toOpenArray(po, po + 3), px.color(lx, ly, b), cov * clip * opacityOf(op.opacity))
      of scene.opHole:
        erase(r.dst.pix.toOpenArray(po, po + 3), cov * clip * opacityOf(op.opacity))
      else:
        discard

proc atlasSample(a: scene.Atlas; u, v: float32; ax, ay, w,
                 h: int): array[4, float32] =
  let
    u = u - 0.5
    v = v - 0.5
    x = int(floor(u))
    y = int(floor(v))
    tx = u - float32(x)
    ty = v - float32(y)
  var c: array[4, float32]
  for j in 0 ..< 2:
    for i in 0 ..< 2:
      let
        sx = min(max(x + i, ax), ax + w - 1)
        sy = min(max(y + j, ay), ay + h - 1)
      var weight = (1 - tx) * (1 - ty)
      if i == 1:
        weight = tx * (1 - ty)
      if j == 1:
        weight = (1 - tx) * ty
        if i == 1:
          weight = tx * ty
      for k in 0 ..< a.bpp:
        c[k] += float32(a.pix[(sy * a.w + sx) * a.bpp + k]) / 255 * weight
  c

proc transformedGlyphs(r: var renderer; op: scene.Op) =
  var pt: ptr painter
  var p: painter
  if op.paint == scene.paintLinear or op.paint == scene.paintOklab:
    p = newPainter(op, opacityOf(op.opacity))
    pt = addr p
  for g in r.s.glyphs[int(op.first) ..< int(op.last)]:
    let m = op.transform.mul(g.transform)
    let (inv, ok) = m.inverse()
    if not ok:
      continue
    var atlas = r.s.maskAtlas
    if g.colored or g.subpixel:
      atlas = r.s.colorAtlas
    if atlas.isNil:
      continue
    let box = scene.Rect(x: float32(round(g.x)), y: float32(round(g.y)),
                         w: float32(g.uw), h: float32(g.vh))
    var shape = newShape(box, default(array[4, float32]))
    let (x0, y0, x1, y1) = r.pixelBounds(m.bounds(box))
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let
          wx = float32(x) + 0.5
          wy = float32(y) + 0.5
          cov = r.clipCoverage(x, y) * transformedCoverage(shape, m, inv, wx, wy)
        if cov <= 0:
          continue
        let (lx, ly) = inv.point(wx, wy)
        var a = atlasSample(atlas, float32(g.u) + lx - box.x,
                            float32(g.v) + ly - box.y, int(g.u), int(g.v),
                            int(g.uw), int(g.vh))
        var tint = g.color.premul(1)
        if not pt.isNil:
          tint = pt[].at(lx, ly)
        let po = y * r.dst.stride + 4 * x
        if g.colored:
          for i in 0 ..< 4:
            a[i] *= float32(g.color.a) / 255
          blend(r.dst.pix.toOpenArray(po, po + 3), a, cov)
          continue
        let text = r.s.text
        var
          contrast = text.contrast
          boost = 0'f32
        if g.thin:
          boost = scene.thinBoost
        if g.subpixel:
          a[0] = (a[0] + a[1] + a[2]) / 3
          contrast = text.subpixelContrast
        let coverage = scene.textCoverage(a[0], unpremul(tint), contrast,
                                          boost, text.gammaRatios)
        blend(r.dst.pix.toOpenArray(po, po + 3), tint, cov * coverage)
