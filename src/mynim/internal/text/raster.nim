## raster.go + join.go: glyph rasterization into the atlases.

proc shadeFor*(f: Font, shade: Shade): Shade =
  ## The shade that glyphs of f for text of shade are drawn for.
  if shade == Thick and f.thickens:
    return Thick
  if not f.shaded:
    return 0
  if shade == Flat:
    return Flat
  min(shade, Shade(Shades - 1))

var linearT: array[256, float32]
for i in 0 ..< 256:
  ## linear maps sRGB values to linear light.
  let v = float64(i) / 255
  if v <= 0.04045:
    linearT[i] = float32(v / 12.92)
  else:
    linearT[i] = float32(pow((v + 0.055) / 1.055, 2.4))

proc shadeOf*(r, g, b: uint8): Shade =
  ## The shade of text of an sRGB color: its relative luminance rounded
  ## to a quarter, as Core Text rounds it, and at most 3/4.
  let y = 0.2126 * linearT[r] + 0.7152 * linearT[g] + 0.0722 * linearT[b]
  Shade(min(y * Shades + 0.5, float32(Shades - 1)))

proc beginFrame*(s: System) =
  ## Starts painting a frame: the masks drawn for the previous frame
  ## alone are forgotten.
  s.mu.acquire()
  defer: s.mu.release()
  s.maskAtlas.resetTransient()
  s.transient.clear()
  s.full = [false, false]
  s.want = [0, 0]
  s.wantSize = [image.pt(0, 0), image.pt(0, 0)]
  s.rooms = 0

proc full*(s: System): bool =
  ## Whether an atlas filled up during the frame being painted and left
  ## out glyphs or masks it draws. makeRoom then makes room for them.
  s.mu.acquire()
  defer: s.mu.release()
  s.full[0] or s.full[1]

proc makeRoom(s: System, color: bool, want: int, size: image.Point,
              grow: bool) =
  var a = s.maskAtlas
  if color:
    a = s.colorAtlas
  var keep: seq[atlasEntry]
  var need = want
  if not color:
    for _, g in s.transient:
      need += (int(g.w) + 1) * (int(g.h) + 1)
    s.transient.clear()
    a.resetTransient()
    var dropK: seq[uint64]
    for k, e in s.masks:
      if e.used != s.frame:
        dropK.add k
      else:
        keep.add e
    for k in dropK:
      s.masks.del k
  var dropG: seq[glyphKey]
  for k, e in s.glyphs:
    if not e.img.ok or e.img.inColor() != color:
      continue # blank glyphs take no room
    if e.used != s.frame:
      dropG.add k
    else:
      keep.add e
  for k in dropG:
    s.glyphs.del k
  var dropR: seq[runKey]
  for k, e in s.runs:
    if e.img.inColor() != color:
      continue
    if e.used != s.frame:
      dropR.add k
    else:
      keep.add e
  for k in dropR:
    s.runs.del k
  var rects = newSeq[image.Rectangle](keep.len)
  for i, e in keep:
    rects[i] = image.rect(int(e.img.x), int(e.img.y),
                          int(e.img.x) + int(e.img.w),
                          int(e.img.y) + int(e.img.h))
    need += (int(e.img.w) + 1) * (int(e.img.h) + 1)
  ## Shelves waste room: keep the atlas at most half full.
  if grow:
    discard a.grow()
  while (need * 2 > a.w * a.h or size.x > a.w or size.y > a.h) and a.grow():
    discard
  let (pos, ok) = a.repack(rects)
  if not ok:
    a.reset()
    var dropG2: seq[glyphKey]
    for k, e in s.glyphs:
      if e.img.ok and e.img.inColor() == color:
        dropG2.add k
    for k in dropG2:
      s.glyphs.del k
    var dropR2: seq[runKey]
    for k, e in s.runs:
      if e.img.inColor() == color:
        dropR2.add k
    for k in dropR2:
      s.runs.del k
    if not color:
      s.masks.clear()
    return
  for i, e in keep:
    e.img.x = uint16(pos[i].x)
    e.img.y = uint16(pos[i].y)

proc makeRoom*(s: System) =
  ## Makes room in the atlases that filled up: it keeps what the frame
  ## being painted drew, growing the atlas when that and what the frame
  ## still needs take much of it, or when room made for the frame before
  ## did not suffice, and forgets everything else. Everything kept moves,
  ## so the frame must be painted again.
  s.mu.acquire()
  defer: s.mu.release()
  inc s.rooms
  let grow = s.rooms > 1
  for i in 0 .. 1:
    if s.full[i]:
      s.makeRoom(i == 1, s.want[i], s.wantSize[i], grow)
  s.full = [false, false]
  s.want = [0, 0]
  s.wantSize = [image.pt(0, 0), image.pt(0, 0)]

proc place(s: System, f: Font, scale: float32, subpixel: bool,
           x: float32): tuple[q, n: int, carry: float32] =
  ## Where the system's text stack draws a glyph of f whose pen is at x:
  ## at position q of the n within a pixel, carry pixels right of the
  ## pixel x is in.
  let pk = placeKey(font: f, scale: uint32(scale * 256 + 0.5),
                    subpixel: subpixel)
  var pl: placement
  if s.places.hasKey(pk):
    pl = s.places[pk]
  else:
    let (n, round) = s.engine().positions(f, scale, subpixel)
    pl = placement(n: max(n, 1), round: round)
    s.places[pk] = pl
  let frac = float64(x) - floor(float64(x))
  if pl.round:
    let q = int(floor(frac * float64(pl.n) + 0.5))
    if q == pl.n:
      return (0, pl.n, 1'f32)
    return (q, pl.n, 0'f32)
  (min(int(frac * float64(pl.n)), pl.n - 1), pl.n, 0'f32)

proc leftOut(s: System, color: bool, w, h: int) =
  let i = ord(color)
  s.full[i] = true
  s.want[i] += (w + 1) * (h + 1)
  s.wantSize[i].x = max(s.wantSize[i].x, w + 1)
  s.wantSize[i].y = max(s.wantSize[i].y, h + 1)
  inc s.failed

proc alloc(s: System, color: bool, w, h: int): tuple[x, y: int, ok: bool] =
  ## Finds lasting room in an atlas, or records that it is full.
  var a = s.maskAtlas
  if color:
    a = s.colorAtlas
  ## The first bitmap can size an empty atlas without invalidating any
  ## glyphs already painted.
  if a.version == 0:
    while (w + 1 > a.w or h + 1 > a.h) and a.grow():
      discard
  let (x, y, ok) = a.alloc(w, h)
  if ok:
    return (x, y, true)
  s.leftOut(color, w, h)
  (0, 0, false)

proc rasterize(s: System, f: Font, id: uint32, scale, dx: float32,
               shade: Shade, subpixel: bool): GlyphImage =
  let b = s.engine().glyph(f, id, scale, dx, shade, subpixel)
  if b.w <= 0 or b.h <= 0 or b.w > 2048 or b.h > 2048:
    return GlyphImage()
  let inColor = b.color or b.subpixel
  let (x, y, ok) = s.alloc(inColor, b.w, b.h)
  if not ok:
    return GlyphImage()
  if inColor:
    s.colorAtlas.put(x, y, b.w, b.h, b.pix, 4 * b.w)
  else:
    s.maskAtlas.put(x, y, b.w, b.h, b.pix, b.w)
  GlyphImage(ok: true, colored: b.color, subpixel: b.subpixel,
             thin: f.thin and not b.color,
             x: uint16(x), y: uint16(y), w: uint16(b.w), h: uint16(b.h),
             left: float32(b.left), top: float32(b.top))

proc glyph*(s: System, f: Font, id: uint32, scale, x: float32,
            shade: Shade, opaque: bool): GlyphImage =
  ## Rasterizes glyph id of a font at scale pixels per DIP whose pen is
  ## x device pixels from the left, for text of a shade, placed as the
  ## system's text stack places glyphs. Glyphs on opaque backgrounds may
  ## be subpixel ones, when the system's settings ask for it.
  s.mu.acquire()
  defer: s.mu.release()
  if f.isNil:
    return GlyphImage()
  let shade = f.shadeFor(shade)
  let subpixel = opaque and s.subpixel
  let (q, n, carry) = s.place(f, scale, subpixel, x)
  let key = glyphKey(font: f, id: id, scale: uint32(scale * 256 + 0.5),
                     subX: uint8(q), shade: shade, subpixel: subpixel)
  var e: atlasEntry
  if s.glyphs.hasKey(key):
    e = s.glyphs[key]
  else:
    let failed = s.failed
    let g = s.rasterize(f, id, scale, float32(q) / float32(n), shade, subpixel)
    e = atlasEntry(img: g, used: s.frame)
    if s.failed == failed: # not left out of a full atlas
      s.glyphs[key] = e
  e.used = s.frame
  result = e.img
  result.left += carry

proc baseline*(s: System, y: float32): float32 =
  ## Where the system's text stack draws a baseline that is y device
  ## pixels from the top: on a whole pixel.
  s.mu.acquire()
  defer: s.mu.release()
  s.engine().baseline(y)

proc textParams*(s: System): scene.TextParams =
  ## How renderers correct the coverage of glyphs, as the system's
  ## settings say, for the frame being painted, and has glyphs on opaque
  ## backgrounds take subpixel antialiasing if they ask for it.
  s.mu.acquire()
  defer: s.mu.release()
  let (p, subpixel) = s.engine().textParams()
  s.subpixel = subpixel
  p

proc mask*(s: System, key: uint64,
           draw: proc(): tuple[w, h: int, pix: seq[byte]]): GlyphImage =
  ## A coverage mask cached under key in the mask atlas, drawing it when
  ## it is not: draw returns its size and one byte per pixel.
  ##
  ## A mask a frame draws for the first time may be one frame of an
  ## animation, never drawn again: it lasts for that frame only, in the
  ## atlas's transient room, and is cached once a later frame draws it
  ## too.
  s.mu.acquire()
  defer: s.mu.release()
  if s.masks.hasKey(key):
    let e = s.masks[key]
    e.used = s.frame
    return e.img
  if s.transient.hasKey(key):
    return s.transient[key]
  let last = s.recent.getOrDefault(key)
  let lasting = s.recent.hasKey(key) and last != s.frame
  let (w, h, pix) = draw()
  if w <= 0 or h <= 0:
    return GlyphImage()
  var x, y: int
  var ok: bool
  if lasting:
    (x, y, ok) = s.maskAtlas.alloc(w, h)
  else:
    (x, y, ok) = s.maskAtlas.allocTransient(w, h)
  if not ok:
    s.leftOut(false, w, h)
    return GlyphImage()
  s.maskAtlas.put(x, y, w, h, pix, w)
  let g = GlyphImage(ok: true, x: uint16(x), y: uint16(y),
                     w: uint16(w), h: uint16(h))
  if lasting:
    s.recent.del key
    s.masks[key] = atlasEntry(img: g, used: s.frame)
  else:
    s.transient[key] = g
    s.recent[key] = s.frame
  g

## --- join.go ---

proc joinsGlyphs*(s: System): bool =
  ## Whether glyphs of a run whose edges share pixels look as the
  ## system's text stack draws them only joined (glyphRun), with their
  ## coverage added before blending (cairo, GTK), rather than blended
  ## each in turn as renderers do (Core Graphics, Direct2D).
  s.mu.acquire()
  defer: s.mu.release()
  s.engine().join()

proc shares*(s: System, a: GlyphImage, ax, ay: float32, b: GlyphImage,
             bx, by: float32): bool =
  ## Whether glyphs a and b, their bitmaps' top-left corners at (ax, ay)
  ## and (bx, by) device pixels, both cover a pixel.
  if not a.ok or not b.ok or a.colored or b.colored or
      a.subpixel != b.subpixel:
    return false
  let ra = image.rect(int(ax), int(ay), int(ax) + int(a.w), int(ay) + int(a.h))
  let rb = image.rect(int(bx), int(by), int(bx) + int(b.w), int(by) + int(b.h))
  let r = ra.intersect(rb)
  if r.empty():
    return false
  s.mu.acquire()
  defer: s.mu.release()
  var at = s.maskAtlas
  if a.subpixel:
    at = s.colorAtlas
  let covers = proc(g: GlyphImage, x, y: int): bool =
    let i = (int(g.y) + y) * at.w + int(g.x) + x
    if at.bpp == 1:
      return at.pix[i] != 0
    let p = i * 4
    at.pix[p] != 0 or at.pix[p + 1] != 0 or at.pix[p + 2] != 0
  for y in r.min.y ..< r.max.y:
    for x in r.min.x ..< r.max.x:
      if covers(a, x - ra.min.x, y - ra.min.y) and
          covers(b, x - rb.min.x, y - rb.min.y):
        return true
  false

proc addGlyphs(s: System, gs: seq[GlyphImage], xs: openArray[float32],
               origin: float64): bitmap =
  ## Adds the coverage of glyphs placed alone, their pens at xs,
  ## clamped, as cairo composites the glyphs of a run, into a bitmap
  ## placed from the pixel origin.
  var box: image.Rectangle
  var rects = newSeq[image.Rectangle](gs.len)
  var have = false
  for i, g in gs:
    if not g.ok:
      continue
    let x = int(floor(float64(xs[i])) - origin) + int(g.left)
    rects[i] = image.rect(x, int(g.top), x + int(g.w), int(g.top) + int(g.h))
    box = if have: box.`union`(rects[i]) else: rects[i]
    have = true
  if not have or box.empty():
    return bitmap()
  let subpixel = gs[0].subpixel
  var at = s.maskAtlas
  var bpp = 1
  if subpixel:
    at = s.colorAtlas
    bpp = 4
  let w = box.dx()
  let h = box.dy()
  var sum = newSeq[uint16](w * h * bpp)
  for i, g in gs:
    if not g.ok:
      continue
    let r = rects[i]
    for y in 0 ..< int(g.h):
      let src = ((int(g.y) + y) * at.w + int(g.x)) * bpp
      let dst = ((r.min.y - box.min.y + y) * w + r.min.x - box.min.x) * bpp
      for k in 0 ..< int(g.w) * bpp:
        sum[dst + k] += uint16(at.pix[src + k])
  var pix = newSeq[byte](sum.len)
  for i, v in sum:
    pix[i] = uint8(min(v, 255))
  bitmap(left: box.min.x, top: box.min.y, w: w, h: h, pix: pix,
         subpixel: subpixel)

proc glyphRun*(s: System, f: Font, ids: openArray[uint32],
               xs: openArray[float32], scale: float32, shade: Shade,
               opaque: bool): GlyphImage =
  ## Glyphs ids of a font, their pens at xs device pixels from the left,
  ## joined as the system's text stack draws a run whose antialiased
  ## edges share pixels (joinsGlyphs): their coverage added and
  ## clamped. Left is relative to the pixel the first pen is in.
  if ids.len == 0 or ids.len != xs.len:
    return GlyphImage()
  var gs = newSeq[GlyphImage](ids.len)
  for i in 0 ..< ids.len:
    gs[i] = s.glyph(f, ids[i], scale, xs[i], shade, opaque)
  s.mu.acquire()
  defer: s.mu.release()
  if f.isNil:
    return GlyphImage()
  let shade = f.shadeFor(shade)
  let subpixel = opaque and s.subpixel
  let origin = floor(float64(xs[0]))
  var key = ""
  key.add $uint64(uint32(scale * 256 + 0.5))
  key.add char(ord('0') + int(shade))
  if subpixel:
    key.add 's'
  for i in 0 ..< ids.len:
    let (q, _, carry) = s.place(f, scale, subpixel, xs[i])
    key.add ' '
    key.add $uint64(ids[i])
    key.add '@'
    key.add $int(floor(float64(xs[i])) - origin + float64(carry))
    key.add '+'
    key.add $q
  let rk = runKey(font: f, key: key)
  if s.runs.hasKey(rk):
    let e = s.runs[rk]
    e.used = s.frame
    return e.img
  let b = s.addGlyphs(gs, xs, origin)
  if b.w <= 0 or b.h <= 0 or b.w > 4096 or b.h > 2048:
    return GlyphImage()
  let inColor = b.subpixel
  let (x, y, ok) = s.alloc(inColor, b.w, b.h)
  if not ok:
    return GlyphImage()
  if inColor:
    s.colorAtlas.put(x, y, b.w, b.h, b.pix, 4 * b.w)
  else:
    s.maskAtlas.put(x, y, b.w, b.h, b.pix, b.w)
  let g = GlyphImage(ok: true, subpixel: b.subpixel, thin: f.thin,
                     x: uint16(x), y: uint16(y), w: uint16(b.w),
                     h: uint16(b.h), left: float32(b.left),
                     top: float32(b.top))
  s.runs[rk] = atlasEntry(img: g, used: s.frame)
  g
