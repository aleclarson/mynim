## raster.go: the operation renderers, the render pass and Render.

proc clear(r: var renderer; c: scene.Color) =
  let
    p = c.premul(1)
    px = [to8(p[2]), to8(p[1]), to8(p[0]), to8(p[3])]
    a = r.area
  for x in a.min.x ..< a.max.x:
    let o = a.min.y * r.dst.stride + 4 * x
    copyMem(addr r.dst.pix[o], unsafeAddr px[0], 4)
  let rowLen = 4 * (a.max.x - a.min.x)
  for y in a.min.y + 1 ..< a.max.y:
    copyMem(addr r.dst.pix[y * r.dst.stride + 4 * a.min.x],
            addr r.dst.pix[a.min.y * r.dst.stride + 4 * a.min.x], rowLen)

proc fill(r: var renderer; op: scene.Op) =
  if op.rect.empty():
    return
  let opacity = opacityOf(op.opacity)
  let radii = scene.corners(op.rect, op.radii, op.continuous)
  var outer = newShape(op.rect, radii)
  var pt = newPainter(op, opacity)
  let border = op.borderColor.premul(opacity)
  var bw = op.border
  if op.borderColor.a == 0:
    bw = default(array[4, float32])
  let hasBorder = scene.hasBorder(bw)
  var inner = outer
  if hasBorder:
    let (ir, irad) = scene.innerRadii(op.rect, radii, bw)
    inner = newShape(ir, irad)
  let
    hasFill = pt.visible()
    solid = pt.solid()
    (x0, y0, x1, y1) = r.pixelBounds(op.rect)
  for y in y0 ..< y1:
    let row = y * r.dst.stride
    let py = float32(y) + 0.5
    let (cl, ch) = r.clipSolid(y)
    let (ol, oh) = solidSpan(outer, float32(y), float32(y + 1))
    var (il, ih) = (ol, oh)
    if hasBorder:
      (il, ih) = (0, 0)
      if not inner.r.empty():
        (il, ih) = solidSpan(inner, float32(y), float32(y + 1))
    ## The middle run, inside the clips, the shape and its border, is
    ## plain fill.
    let
      sl = max(max(il, cl), x0)
      sh = min(min(ih, ch), x1)
    if sl < sh and hasFill and solid:
      blendSpan(r.dst.pix.toOpenArray(row, r.dst.pix.high), sl, sh, pt.c1, 1)
    var x = x0
    while x < x1:
      if x >= sl and x < sh:
        if not hasFill or solid:
          x = sh ## past the run, which is done
          continue
        let po = row + 4 * x
        blend(r.dst.pix.toOpenArray(po, po + 3), pt.at(float32(x) + 0.5, py), 1)
        inc x
        continue
      let px0 = float32(x) + 0.5
      var clipCov = 1'f32
      if x < cl or x >= ch:
        clipCov = r.clipCoverage(x, y)
        if clipCov == 0:
          inc x
          continue
      var oc = 1'f32
      if x < ol or x >= oh:
        oc = coverage(outer, px0, py)
        if oc == 0:
          inc x
          continue
      let po = row + 4 * x
      if hasFill:
        blend(r.dst.pix.toOpenArray(po, po + 3), pt.at(px0, py), oc * clipCov)
      if hasBorder:
        var ic = 0'f32
        if not inner.r.empty():
          ic = coverage(inner, px0, py)
        var bc = oc - ic
        if bc > 0 and op.dashed:
          bc *= dash(op.rect, bw, px0, py)
        if bc > 0:
          blend(r.dst.pix.toOpenArray(po, po + 3), border, bc * clipCov)
      inc x

proc hole(r: var renderer; op: scene.Op) =
  ## Makes a rounded rectangle transparent within the clips: each
  ## pixel keeps what its coverage leaves of it, as renderers blend
  ## with a destination factor of one minus the coverage and none of
  ## the source.
  if op.rect.empty():
    return
  let opacity = opacityOf(op.opacity)
  var shape = newShape(op.rect, scene.corners(op.rect, op.radii,
                                              op.continuous))
  let (x0, y0, x1, y1) = r.pixelBounds(op.rect)
  for y in y0 ..< y1:
    let row = y * r.dst.stride
    let py = float32(y) + 0.5
    let (cl, ch) = r.clipSolid(y)
    let (ol, oh) = solidSpan(shape, float32(y), float32(y + 1))
    let
      sl = max(max(ol, cl), x0)
      sh = min(min(oh, ch), x1)
    if sl < sh and opacity >= 1:
      zeroMem(addr r.dst.pix[row + 4 * sl], 4 * (sh - sl))
    elif sl < sh:
      for x in sl ..< sh:
        let po = row + 4 * x
        erase(r.dst.pix.toOpenArray(po, po + 3), opacity)
    var x = x0
    while x < x1:
      if x >= sl and x < sh:
        x = sh ## past the run, which is done
        continue
      var cov = r.clipCoverage(x, y)
      if cov == 0:
        inc x
        continue
      if x < ol or x >= oh:
        cov *= coverage(shape, float32(x) + 0.5, py)
      if cov > 0:
        let po = row + 4 * x
        erase(r.dst.pix.toOpenArray(po, po + 3), cov * opacity)
      inc x

proc shadow(r: var renderer; op: scene.Op) =
  ## Draws a Gaussian-blurred rounded rectangle, integrating the blur
  ## along y numerically and along x exactly (Evan Wallace's method),
  ## outside the box casting it, if any.
  let sigma = op.blur / 2
  let casts = not op.`cast`.empty()
  if sigma < 0.5 and not casts:
    var f = op
    f.kind = scene.opFill
    f.border = default(array[4, float32])
    f.paint = scene.paintSolid
    r.fill(f)
    return
  let opacity = opacityOf(op.opacity)
  let c = op.color.premul(opacity)
  let radii = scene.corners(op.rect, op.radii, op.continuous)
  var shadowBox = newShape(op.rect, radii)
  var caster = newShape(op.`cast`, scene.corners(op.`cast`, op.castRadii,
                                                 op.continuous))
  proc outside(x, y: int): float32 =
    1 - coverage(caster, float32(x) + 0.5, float32(y) + 0.5)
  if sigma < 0.5:
    ## The box itself, outside the box casting it.
    let (x0, y0, x1, y1) = r.pixelBounds(op.rect)
    for y in y0 ..< y1:
      let row = y * r.dst.stride
      for x in x0 ..< x1:
        let v = coverage(shadowBox, float32(x) + 0.5,
                         float32(y) + 0.5) * outside(x, y)
        if v > 0:
          let po = row + 4 * x
          blend(r.dst.pix.toOpenArray(po, po + 3), c, v * r.clipCoverage(x, y))
    return
  let corner = max(max(abs(radii[0]), abs(radii[1])),
                   max(abs(radii[2]), abs(radii[3])))
  ## Continuous corners narrow the box over the end of their curves.
  let continuous = op.continuous and corner > 0
  var cc: contCorner
  if continuous:
    cc = newContCorner(corner, corner, corner, op.rect.w, op.rect.h)
  let
    ext = 3 * sigma
    box = scene.Rect(x: op.rect.x - ext, y: op.rect.y - ext,
                     w: op.rect.w + 2 * ext, h: op.rect.h + 2 * ext)
    (x0, y0, x1, y1) = r.pixelBounds(box)
  if x0 >= x1 or y0 >= y1:
    return
  let
    cx = op.rect.x + op.rect.w / 2
    cy = op.rect.y + op.rect.h / 2
    hx = op.rect.w / 2
    hy = op.rect.h / 2
    k = sqrt(0.5'f32) / sigma
  ## The shadow is the box blurred along y, at four samples, of a box
  ## blurred exactly along x whose width the corners narrow. Where no
  ## corner narrows it, a row is one horizontal profile scaled, and in
  ## the middle of a row, far from the narrowed edges, the profile is
  ## 1.
  if r.profile.len < x1 - x0:
    r.profile = newSeq[float32](x1 - x0)
  r.profile.setLen(x1 - x0)
  for x in x0 ..< x1:
    let px = float32(x) + 0.5 - cx
    r.profile[x - x0] = 0.5 * (erf((px + hx) * k) - erf((px - hx) * k))
  let far = 2.6 / k ## where erf passes 0.9997
  ## kx0..kx1 and ky0..ky1 are the pixels the box casting the shadow
  ## touches.
  var kx0, ky0, kx1, ky1: int
  if casts:
    kx0 = int(floor(op.`cast`.x))
    ky0 = int(floor(op.`cast`.y))
    kx1 = int(ceil(op.`cast`.x + op.`cast`.w))
    ky1 = int(ceil(op.`cast`.y + op.`cast`.h))
  for y in y0 ..< y1:
    let
      py = float32(y) + 0.5 - cy
      low = py - hy
      high = py + hy
      start = min(max(-ext, low), high)
      `end` = min(max(ext, low), high)
      step = (`end` - start) / 4
    var
      weight, half: array[4, float32]
      sum = 0'f32
      narrowest = hx
      yy = start + step * 0.5
    for i in 0 ..< 4:
      weight[i] = gaussian(yy, sigma) * step
      sum += weight[i]
      half[i] = hx
      let v = hy - abs(py - yy)
      if continuous:
        if v < cc.e:
          let (at, _) = cc.inset(v)
          half[i] = hx - at
          narrowest = min(narrowest, half[i])
      else:
        let delta = min(hy - corner - abs(py - yy), 0)
        if delta < 0:
          half[i] = hx - corner + sqrt(max(0'f32, corner * corner - delta * delta))
          narrowest = min(narrowest, half[i])
      yy += step
    if sum <= 0.002:
      continue
    let straight = narrowest == hx
    let row = y * r.dst.stride
    let (cl, ch) = r.clipSolid(y)
    let
      ml = max(max(int(ceil(cx - narrowest + far - 0.5)), x0), cl)
      mh = min(min(int(floor(cx + narrowest - far - 0.5)) + 1, x1), ch)
    ## On the row, the box casting the shadow touches kl..kh, which
    ## the middle leaves out, and hides it in sl..sh.
    var kl, kh, sl, sh: int
    if casts and y >= ky0 and y < ky1:
      kl = kx0
      kh = kx1
      (sl, sh) = solidSpan(caster, float32(y), float32(y + 1))
    if kl < kh:
      blendSpan(r.dst.pix.toOpenArray(row, r.dst.pix.high), ml, min(mh, kl), c, sum)
      blendSpan(r.dst.pix.toOpenArray(row, r.dst.pix.high), max(ml, kh), mh, c, sum)
    else:
      blendSpan(r.dst.pix.toOpenArray(row, r.dst.pix.high), ml, mh, c, sum)
    var x = x0
    while x < x1:
      if x >= ml and x < mh and (x < kl or x >= kh):
        x = mh
        continue
      if x >= sl and x < sh:
        x = sh
        continue
      var v: float32
      if straight:
        v = r.profile[x - x0] * sum
      else:
        let px = float32(x) + 0.5 - cx
        for i in 0 ..< 4:
          v += weight[i] * 0.5 * (erf((px + half[i]) * k) - erf((px - half[i]) * k))
      if x >= kl and x < kh:
        v *= outside(x, y)
      if v <= 0.002:
        inc x
        continue
      if x < cl or x >= ch:
        v *= r.clipCoverage(x, y)
      let po = row + 4 * x
      blend(r.dst.pix.toOpenArray(po, po + 3), c, v)
      inc x

proc insetShadow(r: var renderer; op: scene.Op) =
  ## Draws an inner shadow: inside the box Cast, what the hole Rect,
  ## blurred as shadow blurs a box, leaves uncovered.
  let (x0, y0, x1, y1) = r.pixelBounds(op.`cast`)
  if x0 >= x1 or y0 >= y1:
    return
  let opacity = opacityOf(op.opacity)
  let c = op.color.premul(opacity)
  var box = newShape(op.`cast`, scene.corners(op.`cast`, op.castRadii,
                                              op.continuous))
  let radii = scene.corners(op.rect, op.radii, op.continuous)
  var hole = newShape(op.rect, radii)
  let empty = op.rect.empty()
  let sigma = op.blur / 2
  if sigma < 0.5 or empty:
    for y in y0 ..< y1:
      let row = y * r.dst.stride
      ## Nothing shows where the hole covers the row's pixels
      ## entirely, as it does most of a large box.
      var sl, sh: int
      if not empty:
        (sl, sh) = solidSpan(hole, float32(y), float32(y + 1))
      var x = x0
      while x < x1:
        if x >= sl and x < sh:
          x = sh
          continue
        let
          px = float32(x) + 0.5
          py = float32(y) + 0.5
        var v = coverage(box, px, py)
        if not empty:
          v *= 1 - coverage(hole, px, py)
        if v > 0:
          let po = row + 4 * x
          blend(r.dst.pix.toOpenArray(po, po + 3), c, v * r.clipCoverage(x, y))
        inc x
    return
  ## The hole blurred as shadow blurs a box, four samples along y and
  ## exactly along x.
  let
    corner = max(max(abs(radii[0]), abs(radii[1])),
                 max(abs(radii[2]), abs(radii[3])))
    continuous = op.continuous and corner > 0
  var cc: contCorner
  if continuous:
    cc = newContCorner(corner, corner, corner, op.rect.w, op.rect.h)
  let
    ext = 3 * sigma
    cx = op.rect.x + op.rect.w / 2
    cy = op.rect.y + op.rect.h / 2
    hx = op.rect.w / 2
    hy = op.rect.h / 2
    k = sqrt(0.5'f32) / sigma
    far = 2.6 / k ## where erf passes 0.9997
  for y in y0 ..< y1:
    let
      py = float32(y) + 0.5 - cy
      low = py - hy
      high = py + hy
      start = min(max(-ext, low), high)
      `end` = min(max(ext, low), high)
      step = (`end` - start) / 4
    var
      weight, half: array[4, float32]
      sum = 0'f32
      narrowest = hx
      yy = start + step * 0.5
    for i in 0 ..< 4:
      weight[i] = gaussian(yy, sigma) * step
      sum += weight[i]
      half[i] = hx
      let v = hy - abs(py - yy)
      if continuous:
        if v < cc.e:
          let (at, _) = cc.inset(v)
          half[i] = hx - at
          narrowest = min(narrowest, half[i])
      else:
        let delta = min(hy - corner - abs(py - yy), 0)
        if delta < 0:
          half[i] = hx - corner + sqrt(max(0'f32, corner * corner - delta * delta))
          narrowest = min(narrowest, half[i])
      yy += step
    let row = y * r.dst.stride
    let (cl, ch) = r.clipSolid(y)
    ## In the middle of the row, far from the hole's edges, the hole
    ## covers sum of each pixel, and nothing shows where that is all.
    var (ml, mh) = (x1, x1)
    if 1 - sum <= 0.002:
      ml = max(int(ceil(cx - narrowest + far - 0.5)), x0)
      mh = min(int(floor(cx + narrowest - far - 0.5)) + 1, x1)
    var x = x0
    while x < x1:
      if x >= ml and x < mh:
        x = mh
        continue
      let px = float32(x) + 0.5
      var covered = 0'f32
      for i in 0 ..< 4:
        covered += weight[i] * 0.5 *
          (erf((px - cx + half[i]) * k) - erf((px - cx - half[i]) * k))
      var v = (1 - covered) * coverage(box, px, float32(y) + 0.5)
      if v <= 0.002:
        inc x
        continue
      if x < cl or x >= ch:
        v *= r.clipCoverage(x, y)
      let po = row + 4 * x
      blend(r.dst.pix.toOpenArray(po, po + 3), c, v)
      inc x

proc maskOpaque(r: var renderer; a: scene.Atlas; g: scene.Glyph; gx,
                gy: int; box: image.Rectangle) =
  ## Draws ordinary opaque text with 8-bit coverage. Integer blending
  ## avoids converting every destination channel to and from floats;
  ## rounded clip edges still use the general coverage calculation.
  let c = g.color
  for y in box.min.y ..< box.max.y:
    let
      (cl, ch) = r.clipSolid(y)
      at = (int(g.v) + y - gy) * a.w + int(g.u) + box.min.x - gx
      row = y * r.dst.stride + 4 * box.min.x
    for i in 0 ..< box.max.x - box.min.x:
      let m = a.pix[at + i]
      if m == 0:
        continue
      let x = box.min.x + i
      let po = row + 4 * i
      if x < cl or x >= ch:
        blend(r.dst.pix.toOpenArray(po, po + 3), c.premul(1), r.clipCoverage(x, y) * (float32(m) / 255))
        continue
      if m == 255:
        r.dst.pix[po + 0] = c.b
        r.dst.pix[po + 1] = c.g
        r.dst.pix[po + 2] = c.r
        r.dst.pix[po + 3] = 255
        continue
      let weight = uint32(m)
      r.dst.pix[po + 0] = mixMask(c.b, r.dst.pix[po + 0], weight)
      r.dst.pix[po + 1] = mixMask(c.g, r.dst.pix[po + 1], weight)
      r.dst.pix[po + 2] = mixMask(c.r, r.dst.pix[po + 2], weight)
      r.dst.pix[po + 3] = over(m, r.dst.pix[po + 3], 255 - weight)

proc glyphs(r: var renderer; op: scene.Op) =
  var pt: ptr painter
  var p: painter
  if op.paint == scene.paintLinear or op.paint == scene.paintOklab:
    p = newPainter(op, opacityOf(op.opacity))
    pt = addr p
  let text = r.s.text
  for g in r.s.glyphs[int(op.first) ..< int(op.last)]:
    var atlas = r.s.maskAtlas
    if g.colored or g.subpixel:
      atlas = r.s.colorAtlas
    if atlas.isNil:
      continue
    let
      gx = int(round(g.x))
      gy = int(round(g.y))
      x0 = max(gx, r.x0)
      y0 = max(gy, r.y0)
      x1 = min(gx + int(g.uw), r.x1)
      y1 = min(gy + int(g.vh), r.y1)
    if x0 >= x1 or y0 >= y1:
      continue
    var tint = g.color.premul(1)
    let alpha = float32(g.color.a) / 255
    var
      contrast = text.contrast
      boost = 0'f32
    if g.subpixel:
      contrast = text.subpixelContrast
    if g.thin:
      boost = scene.thinBoost
    let correct = contrast != 0 or boost != 0 or
      text.gammaRatios != default(array[4, float32])
    if not g.colored and not g.subpixel and pt.isNil and not correct and
        g.color.a == 255:
      r.maskOpaque(atlas, g, gx, gy, image.rect(x0, y0, x1, y1))
      continue
    for y in y0 ..< y1:
      let
        row = y * r.dst.stride
        (cl, ch) = r.clipSolid(y)
        ay = int(g.v) + y - gy
      for x in x0 ..< x1:
        let ax = int(g.u) + x - gx
        var cov = 1'f32
        if x < cl or x >= ch:
          cov = r.clipCoverage(x, y)
          if cov == 0:
            continue
        let po = row + 4 * x
        if g.colored:
          let s = (ay * atlas.w + ax) * 4
          let c = [float32(atlas.pix[s]) / 255 * alpha,
                   float32(atlas.pix[s + 1]) / 255 * alpha,
                   float32(atlas.pix[s + 2]) / 255 * alpha,
                   float32(atlas.pix[s + 3]) / 255 * alpha]
          blend(r.dst.pix.toOpenArray(po, po + 3), c, cov)
        elif g.subpixel:
          let s = (ay * atlas.w + ax) * 4
          if (atlas.pix[s] or atlas.pix[s + 1] or atlas.pix[s + 2]) == 0:
            continue
          if not pt.isNil:
            tint = pt[].at(float32(x) + 0.5, float32(y) + 0.5)
          let c = unpremul(tint)
          var a = [float32(atlas.pix[s]) / 255,
                   float32(atlas.pix[s + 1]) / 255,
                   float32(atlas.pix[s + 2]) / 255]
          if correct:
            a = scene.subpixelCoverage(a, c, contrast, boost,
                                       text.gammaRatios)
          blendSubpixel(r.dst.pix.toOpenArray(po, po + 3), c, a, tint[3] * cov)
        else:
          let m = atlas.pix[ay * atlas.w + ax]
          if m == 0:
            continue
          if not pt.isNil:
            tint = pt[].at(float32(x) + 0.5, float32(y) + 0.5)
          var a = float32(m) / 255
          if correct:
            a = scene.textCoverage(a, unpremul(tint), contrast, boost,
                                   text.gammaRatios)
          blend(r.dst.pix.toOpenArray(po, po + 3), tint, cov * a)

proc image(r: var renderer; op: scene.Op) =
  let img = op.image
  if img.isNil or img.w == 0 or img.h == 0 or op.rect.empty() or
      unflipped(op.src).empty():
    return
  let
    opacity = opacityOf(op.opacity)
    radii = scene.corners(op.rect, op.radii, op.continuous)
  var box = newShape(op.rect, radii)
  let
    round = hasRadii(radii)
    sx = op.src.w / op.rect.w
    sy = op.src.h / op.rect.h
    (x0, y0, x1, y1) = r.pixelBounds(op.rect)
  for y in y0 ..< y1:
    let row = y * r.dst.stride
    let py = float32(y) + 0.5
    let (cl, ch) = r.clipSolid(y)
    let (ol, oh) = solidSpan(box, float32(y), float32(y + 1))
    for x in x0 ..< x1:
      let px = float32(x) + 0.5
      var cov = opacity
      if x < ol or x >= oh or not round:
        cov *= coverage(box, px, py)
      if x < cl or x >= ch:
        cov *= r.clipCoverage(x, y)
      if cov <= 0:
        continue
      let c = sampleOp(op, op.src.x + (px - op.rect.x) * sx,
                       op.src.y + (py - op.rect.y) * sy,
                       abs32(sx), abs32(sy))
      let po = row + 4 * x
      blend(r.dst.pix.toOpenArray(po, po + 3), c, cov)

proc render(r: var renderer; dst: ptr Image; s: scene.Scene;
            area: image.Rectangle; bounds: seq[image.Rectangle];
            first, last: int; px: scene.EffectPixels;
            b: scene.BackdropImage) =
  ## Draws the pixels of s within area, operations first to last but
  ## those whose bounds miss it, over the clear color from the first;
  ## those before only clip. px draws operation first when it is an
  ## effect, over the backdrop b.
  r.dst = dst
  r.s = s
  r.clips.setLen(0)
  r.spanBuf.setLen(0)
  r.area = area.intersect(image.rect(0, 0, dst.w, dst.h))
  if r.area.empty():
    return
  if first == 0:
    r.clear(s.clear)
  r.updateBounds()
  for i in 0 ..< last:
    let op = addr s.ops[i]
    if op.kind != scene.opPushClip and op.kind != scene.opPopClip and
        (i < first or not bounds[i].overlaps(r.area)):
      continue
    case op.kind
    of scene.opFill:
      if op.transform.`set`:
        r.transformed(op[], nil, nil)
      else:
        r.fill(op[])
    of scene.opShadow:
      if op.transform.`set`:
        r.transformed(op[], nil, nil)
      elif op.inset:
        r.insetShadow(op[])
      else:
        r.shadow(op[])
    of scene.opGlyphs:
      var transformed = op.transform.`set`
      for g in s.glyphs[int(op.first) ..< int(op.last)]:
        transformed = transformed or g.transform.`set`
      if transformed:
        r.transformedGlyphs(op[])
      else:
        r.glyphs(op[])
    of scene.opImage:
      if op.transform.`set`:
        r.transformed(op[], nil, nil)
      else:
        r.image(op[])
    of scene.opHole:
      if op.transform.`set`:
        r.transformed(op[], nil, nil)
      else:
        r.hole(op[])
    of scene.opEffect:
      if i == first and not px.isNil:
        if op.transform.`set`:
          r.transformed(op[], px, b)
        else:
          r.effect(op[], px, b)
    of scene.opPushClip:
      let radii = scene.corners(op.rect, op.radii, op.continuous)
      var c = clip(shape: newShape(op.rect, radii),
                   round: hasRadii(radii), spans: -1)
      c.transform = op.transform
      (c.inverse, c.valid) = op.transform.inverse()
      if c.shape.continuous and not c.transform.`set`:
        ## Continuous corners take long to find the spans of, which
        ## every operation within the clip needs.
        c.spans = r.spanBuf.len
        let n = 2 * (r.area.max.y - r.area.min.y)
        r.spanBuf.setLen(c.spans + n)
        for i in c.spans ..< r.spanBuf.len:
          r.spanBuf[i] = noSpan
      r.clips.add(c)
      r.updateBounds()
    of scene.opPopClip:
      if r.clips.len > 0:
        if r.clips[^1].spans >= 0:
          r.spanBuf.setLen(r.clips[^1].spans)
        r.clips.setLen(r.clips.len - 1)
        r.updateBounds()

proc band(d: var drawer; member, part: int) =
  ## Draws band part of d.job with the renderer of member.
  let j = addr d.job
  var band = j.area
  band.min.y = j.area.min.y + part * j.rows
  band.max.y = min(band.min.y + j.rows, j.area.max.y)
  d.rs[member].render(j.dst, j.s, band, j.bounds, j.first, j.last,
                      j.px, j.b)

proc drawOps(d: var drawer; dst: ptr Image; s: scene.Scene;
             area: image.Rectangle; bounds: seq[image.Rectangle];
             first, last: int; px: scene.EffectPixels;
             b: scene.BackdropImage) =
  ## Draws operations first to last of s within area, as draw does,
  ## over the pixels the operations before them drew, or over the
  ## scene's clear color from the first; px draws operation first when
  ## it is an effect, over the backdrop b.
  if first >= last and first > 0:
    return
  var rows = bandRows
  if not px.isNil:
    rows = effectRows
  let bands = (area.dy() + rows - 1) div rows
  let n = max(min(min(countProcessors(),
                      area.dx() * area.dy() div workArea),
                  bands), 1)
  let n2 = min(n, maxWorkers)
  while d.rs.len < n2:
    d.rs.add(renderer())
  if n2 == 1:
    d.rs[0].render(dst, s, area, bounds, first, last, px, b)
    return
  d.job = bandJob(dst: dst, s: s, area: area, bounds: bounds,
                  first: first, last: last, rows: rows, px: px, b: b)
  d.bands.`do` = proc(member, part: int) {.gcsafe.} =
    {.cast(gcsafe).}:
      d.band(member, part)
  d.bands.run(n2, bands)
  d.job = bandJob()

proc draw*(d: var drawer; dst: ptr Image; s: scene.Scene;
           area: image.Rectangle; bounds: seq[image.Rectangle]) =
  ## Draws the pixels of s within area into dst, with the renderers of
  ## d.rs, made as needed, leaving out the operations whose bounds
  ## miss the band drawn.
  ##
  ## Each effect is readied (EffectPixels.begin) before its pixels,
  ## and one reading its backdrop reads pixels other bands draw: the
  ## operations up to each effect in the area are drawn first, then
  ## its backdrop is read (d.bd), then the effect and the operations
  ## up to the next. The area holds the backdrops of the effects in
  ## it (Renderer.diff).
  let area = area.intersect(image.rect(0, 0, dst.w, dst.h))
  ## px draws operation first, an effect over the backdrop b.
  var
    first = 0
    px: scene.EffectPixels
    b: scene.BackdropImage
  for i in 0 ..< s.ops.len:
    let op = addr s.ops[i]
    if op.kind != scene.opEffect or int(op.first) >= s.effects.len or
        not bounds[i].overlaps(area):
      continue
    let fx = addr s.effects[int(op.first)]
    let next = d.pixels(fx.effect)
    if next.isNil:
      continue
    d.drawOps(dst, s, area, bounds, first, i, px, b)
    b = nil
    if fx.effect.backdrop:
      d.bd.read(dst, scene.backdropOf(op.transform.bounds(op.rect),
                                      fx.blur, dst.w, dst.h))
      d.bd.img.transform = op.transform
      b = d.bd.img
    next.begin(fx[], op.rect, scene.fitRadii(op.rect, op.radii))
    first = i
    px = next
  d.drawOps(dst, s, area, bounds, first, s.ops.len, px, b)

