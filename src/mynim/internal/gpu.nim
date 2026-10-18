## Package gpu turns scenes into what the GPU renderers draw: one
## instanced quad per operation, for a shader that computes rounded
## rectangles, borders, gradients, stripes, shadows and atlas coverage
## itself, in batches that share a scissor rectangle and an image.
## Every renderer (d3d11, metal, gl) draws the same instances, the way
## internal/raster draws scenes on the CPU (internal/gpu).

import std/[math, algorithm, strutils]
import scene, raster
import ../image
import sha256

proc goBytes*(name: string; b: openArray[byte]): string =
  ## The Go declaration of a variable name holding b, as code compiled
  ## ahead of time is generated.
  result = "var " & name & " = []byte{"
  for i, c in b:
    if i mod 16 == 0:
      result.add("\n\t")
    result.add("0x")
    result.add(toHex(int(c), 2).toLowerAscii())
    result.add(", ")
  result.add("\n}\n")

type Instance* = object
  ## The data of one quad, in device pixels, as the shaders read it:
  ## thirteen float4s.
  ##
  ## rect is x, y, width, height; radii the corners' radii (top-left,
  ## top-right, bottom-right, bottom-left), negative for continuous
  ## corners (scene.corners), which only Metal's shader draws, or a
  ## glyph's gamma ratios (scene.TextParams); inner those of a border's
  ## inner edge, or of the box casting a shadow, or a glyph's contrast
  ## and thin boost in inner[0] and inner[1].
  rect*, radii*, inner*: array[4, float32]
  ## color and color2 (a gradient's end) and border are straight RGBA;
  ## color tints an image (white for none).
  color*, color2*, border*: array[4, float32]
  ## grad holds a gradient's start and end points, or the stripes'
  ## unit vector across them, width and period; uv the texture
  ## rectangle, normalized, a fill's border widths (top, right,
  ## bottom, left), or the box casting a shadow, which shows only
  ## outside it (none when empty).
  ##
  ## An effect has its parameters (scene.EffectOp.params) in inner,
  ## color, color2, border and grad, and in uv where its backdrop's
  ## area starts in the frame and its size in texels.
  grad*, uv*: array[4, float32]
  ## clip and clipRadii are the innermost clip, which the shader cuts.
  clip*, clipRadii*: array[4, float32]
  ## params is the kind (0 fill, 1 shadow, 2 mask glyph, 3 color glyph,
  ## 4 image, 5 subpixel glyph, 6 effect); 1 for a dashed border, a
  ## grayscale image or an inner shadow, whose box is in rect and radii
  ## and the hole it leaves in uv and inner (none when empty); the
  ## shadow's sigma (0 for none), the paint (scene.Paint), 1 for an
  ## image sampled at its nearest texel, or the size of the squares an
  ## effect's backdrop averages; and the opacity.
  params*: array[4, float32]
  ## transform rows map local pixels to the frame. transform0[3]
  ## enables transformed antialiasing, transform1[3] selects a cached
  ## clip mask. transform2 holds the projective row's g and h, the
  ## frame point of local (x, y) being transform0's and transform1's
  ## dot products with (x, y, 1) over g*x + h*y + 1: shaders
  ## interpolate in perspective.
  transform0*, transform1*, transform2*: array[4, float32]

const instanceSize* = sizeof(Instance)

type Scissor* = object
  ## A scissor rectangle in device pixels, the layout of a Direct3D
  ## RECT.
  left*, top*, right*, bottom*: int32

proc empty*(s: Scissor): bool =
  ## Whether the rectangle has no pixels.
  s.right <= s.left or s.bottom <= s.top

type Batch* = object
  ## A run of instances that draw with the same scissor rectangle and
  ## image.
  start*, count*: int
  scissor*: Scissor
  ## image is the renderer's texture of the batch's image, or 0.
  image*: uint
  ## clipMask is a cached nested clip texture, sampled in frame
  ## coordinates.
  clipMask*: uint
  ## effect is the effect of the batch's one instance, drawn with a
  ## pipeline of its own, and backdrop, unless 0, 1 + the index in
  ## builder.backdrops of its backdrop, which the renderer reads
  ## before drawing it.
  effect*: ref scene.Effect
  backdrop*: int
  ## hole tells that the batch's instances make their shapes
  ## transparent (scene.opHole): renderers blend them with a source
  ## factor of zero.
  hole*: bool

type
  Builder* = object
    ## Builds the instances and batches of scenes, reusing its memory
    ## from frame to frame.
    instances*: seq[Instance]
    batches*: seq[Batch]
    backdrops*: seq[scene.Backdrop]
    ## wide draws the colors of scenes outside the sRGB gamut
    ## (scene.wide), for a target that keeps them, as Metal's float16
    ## drawables do; without it, their nearest sRGB colors.
    wide*: bool
    stack: seq[clip]
    ## encloses tells, for each op of the scene, that it pushes a clip
    ## with a transformed op or glyph inside it.
    encloses: seq[bool]
    pushes: seq[int]
    clipShapes: seq[scene.ClipShape]
    maskSlots: seq[clipMaskSlot]
    maskUsed: int
    frame: uint64
    imageTexture: proc(i: scene.Image): uint
    ## Makes a texture holding an image's blurred area for an opImage.
    blurredImage*: proc(i: scene.Image; b: scene.Backdrop): uint
    preparedMask: uint

  Pass* = object
    ## What a pass computing a backdrop reads, the layout of the
    ## shaders' Pass: down reads the area from origin to limit, frame
    ## pixels, at their place less shift in its source, and averages
    ## squares of down pixels a side; blur reads texels up to limit,
    ## radius of them each way along dir, weighted by a Gaussian of
    ## standard deviation sigma. mode selects transparent image bounds
    ## and, for GL, the image's row orientation.
    origin*, limit*, shift*, dir*: array[2, int32]
    down*, radius*: int32
    sigma*: float32
    mode*: int32

  clip = object
    rect: scene.Rect
    radii: array[4, float32]
    bounds: scene.Rect
    scissor: Scissor
    shape: scene.ClipShape
    ## moved tells that this clip or one it is nested in is
    ## transformed, which the scissor rectangles don't follow.
    moved: bool
    masked: bool
    maskSlot: int
    maskTexture: uint

  clipMaskSlot = object
    ## A retained clip mask. Masks outlive the frames that don't use
    ## them, up to idleMaskBytes of them, so a transform that comes
    ## and goes finds its masks again instead of rasterizing them.
    shapes: seq[scene.ClipShape]
    area: image.Rectangle
    image: scene.Image
    ## frame is the last frame that used the mask, and slot the
    ## clip's place among that frame's masked clips.
    frame: uint64
    slot: int

## idleMaskBytes is how much memory the masks no clip of the frame
## uses keep, the least recently used dropped first.
const idleMaskBytes = 32 shl 20

const
  passClear* = 1'i32
  passUnflipped* = 2'i32

proc downPass*(bk: scene.Backdrop; shift: array[2, int32]): Pass =
  ## The pass averaging the squares of bk's area, whose frame pixel
  ## (x, y) is at (x, y) less shift in the texture it reads.
  Pass(origin: [int32(bk.area.min.x), int32(bk.area.min.y)],
       limit: [int32(bk.area.max.x - 1), int32(bk.area.max.y - 1)],
       shift: shift, down: int32(bk.down))

proc blurPass*(bk: scene.Backdrop; dir: array[2, int32]): Pass =
  ## The pass blurring bk's texels along rows (dir 1, 0) or columns
  ## (0, 1).
  let (w, h) = bk.size()
  Pass(limit: [int32(w - 1), int32(h - 1)], dir: dir,
       radius: int32(bk.radius), sigma: bk.sigma)

proc imageDownPass*(bk: scene.Backdrop): Pass =
  ## A downsample pass that treats pixels beyond an image area as clear.
  result = downPass(bk, [0'i32, 0])
  result.mode = passClear

proc imageBlurPass*(bk: scene.Backdrop; dir: array[2, int32]): Pass =
  ## A blur pass that treats texels beyond an image area as clear.
  result = blurPass(bk, dir)
  result.mode = passClear

proc backdropSize*(b: Builder): tuple[w, h: int] =
  ## How large the textures of the backdrops of the last scene built
  ## must be, in texels: as the largest.
  for bk in b.backdrops:
    let (bw, bh) = bk.size()
    result = (max(result.w, bw), max(result.h, bh))

proc rect(r: scene.Rect): array[4, float32] =
  [r.x, r.y, r.w, r.h]

proc straight(c: scene.Color): array[4, float32] =
  [float32(c.r) / 255, float32(c.g) / 255, float32(c.b) / 255,
   float32(c.a) / 255]

proc wideOf(b: Builder; s: scene.Scene; i: uint16): ptr scene.WideColors =
  ## The colors outside the sRGB gamut of an op or a glyph of s whose
  ## wide is i, or nil when it has none or b does not draw them.
  if not b.wide or i == 0 or int(i) > s.wide.len:
    return nil
  unsafeAddr s.wide[i - 1]

proc wideColor(w: ptr scene.WideColors; bit: scene.WideSet;
               c: scene.Color): array[4, float32] =
  ## The color of w that bit names, or c when w has none.
  if w.isNil or (w.`set` and bit) == 0:
    return straight(c)
  if bit == scene.wideColor:
    return w.color
  if bit == scene.wideColor2:
    return w.color2
  w.border

proc opacity(o: float32): float32 {.inline.} =
  if o == 0: 1 else: o

proc clipTexture(b: var Builder; c: var clip;
                 shapes: seq[scene.ClipShape]): uint =
  if c.maskTexture != 0:
    return c.maskTexture
  let area = image.rect(int(c.scissor.left), int(c.scissor.top),
                        int(c.scissor.right), int(c.scissor.bottom))
  ## The mask of the same clip, in this frame or an earlier one; else
  ## the one the clip in its place had last frame, which it most
  ## likely is, changed; else a new one.
  var
    found = -1
    reuse = -1
  for i in 0 ..< b.maskSlots.len:
    let m = addr b.maskSlots[i]
    if m.area == area and m.shapes == shapes:
      found = i
      break
    if reuse < 0 and m.frame == b.frame - 1 and m.slot == c.maskSlot:
      reuse = i
  if found < 0:
    found = reuse
    if found < 0:
      found = b.maskSlots.len
      b.maskSlots.add(clipMaskSlot())
    let m = addr b.maskSlots[found]
    m.image = raster.clipMask(m.image, shapes, area)
    m.area = area
    m.shapes = shapes
  let m = addr b.maskSlots[found]
  m.frame = b.frame
  m.slot = c.maskSlot
  c.maskTexture = b.imageTexture(m.image)
  c.maskTexture

proc prepare(b: var Builder; `in`: var Instance; m: scene.Affine;
             c: var clip): bool =
  b.preparedMask = 0
  if c.scissor.empty() or `in`.rect[2] <= 0 or `in`.rect[3] <= 0:
    return false
  let (_, ok) = m.inverse()
  if not ok:
    return false
  `in`.transform0 = [1'f32, 0, 0, 0]
  `in`.transform1 = [0'f32, 1, 0, 0]
  `in`.transform2 = default(array[4, float32])
  if m.`set`:
    `in`.transform0 = [m.a, m.c, m.x, 1]
    `in`.transform1 = [m.b, m.d, m.y, 0]
    `in`.transform2 = [m.g, m.h, 0, 0]
  `in`.clip = rect(c.rect)
  `in`.clipRadii = c.radii
  if not c.masked:
    return true
  ## A hard clip sharing the drawing's coordinates is cheap to evaluate
  ## in the fragment shader. Keep the rounded ancestor's mask
  ## stationary even when a text input or custom clipped drawing moves
  ## within it.
  if c.shape.radii == default(array[4, float32]) and
      c.shape.transform == m and m.`set` and b.stack.len > 1:
    let parent = addr b.stack[^2]
    if parent.masked:
      b.preparedMask = b.clipTexture(parent[],
                                   b.clipShapes[0 ..< b.clipShapes.len - 1])
      if b.preparedMask == 0:
        return false
      `in`.clip = rect(c.rect)
      `in`.clipRadii = [float32(parent.scissor.left),
                        float32(parent.scissor.top),
                        float32(parent.scissor.right - parent.scissor.left),
                        float32(parent.scissor.bottom - parent.scissor.top)]
      `in`.transform1[3] = 2
      return true
  b.preparedMask = b.clipTexture(c, b.clipShapes)
  if b.preparedMask == 0:
    return false
  `in`.clip = [float32(c.scissor.left), float32(c.scissor.top),
               float32(c.scissor.right - c.scissor.left),
               float32(c.scissor.bottom - c.scissor.top)]
  `in`.clipRadii = default(array[4, float32])
  `in`.transform1[3] = 1
  true

proc dropIdleMasks(b: var Builder; idle: int) =
  ## Drops the least recently used masks this frame didn't use beyond
  ## idle bytes of them.
  b.maskSlots.sort(proc(x, y: clipMaskSlot): int =
    cmp(y.frame, x.frame))
  var idle = idle
  for i in 0 ..< b.maskSlots.len:
    let m = addr b.maskSlots[i]
    if m.frame == b.frame:
      continue
    idle -= (if m.image.isNil: 0 else: m.image.pix.len)
    if idle < 0:
      b.maskSlots.setLen(i)
      return

proc markEnclosing(b: var Builder; s: scene.Scene) =
  ## Sets b.encloses for the ops of s.
  b.encloses.setLen(s.ops.len)
  for i in 0 ..< b.encloses.len:
    b.encloses[i] = false
  b.pushes.setLen(0)
  for i in 0 ..< s.ops.len:
    let op = addr s.ops[i]
    if op.kind == scene.opPopClip:
      if b.pushes.len > 0:
        b.pushes.setLen(b.pushes.len - 1)
      continue
    var transformed = op.transform.`set`
    if op.kind == scene.opGlyphs:
      for g in s.glyphs[int(op.first) ..< int(op.last)]:
        transformed = transformed or g.transform.`set`
    ## Every clip open around it encloses it, from the innermost out
    ## to the first already marked, whose own are.
    var j = b.pushes.len - 1
    while transformed and j >= 0 and not b.encloses[b.pushes[j]]:
      b.encloses[b.pushes[j]] = true
      dec j
    if op.kind == scene.opPushClip:
      b.pushes.add(i)

proc release*(b: var Builder) =
  ## Frees the retained clipping resources and instance buffers.
  b = Builder()

proc add(b: var Builder; `in`: Instance; image: uint; m: scene.Affine) =
  ## Appends an instance within the current clip, starting a batch
  ## when the scissor rectangle or the image changes, or after an
  ## effect's.
  var `in` = `in`
  let cur = addr b.stack[^1]
  if not b.prepare(`in`, m, cur[]):
    return
  var n = b.batches.len
  if n == 0 or b.batches[n - 1].scissor != cur.scissor or
      not b.batches[n - 1].effect.isNil or b.batches[n - 1].hole or
      b.batches[n - 1].clipMask != b.preparedMask or
      (image != 0 and b.batches[n - 1].image != 0 and
       b.batches[n - 1].image != image):
    b.batches.add(Batch(start: b.instances.len, scissor: cur.scissor,
                        image: image, clipMask: b.preparedMask))
    inc n
  elif image != 0:
    b.batches[n - 1].image = image
  b.instances.add(`in`)
  inc b.batches[n - 1].count

proc addEffect(b: var Builder; s: scene.Scene; op: scene.Op) =
  ## Appends the instance of an effect within the current clip, in a
  ## batch of its own, which reads its backdrop first when it reads
  ## one.
  let cur = addr b.stack[^1]
  if cur.scissor.empty():
    return
  let fx = addr s.effects[int(op.first)]
  var `in` = Instance(
    rect: rect(op.rect),
    radii: scene.corners(op.rect, op.radii, op.continuous),
    inner: fx.params[0], color: fx.params[1], color2: fx.params[2],
    border: fx.params[3], grad: fx.params[4],
    clip: rect(cur.rect), clipRadii: cur.radii,
    params: [6'f32, 0, 1, opacity(op.opacity)])
  if not b.prepare(`in`, op.transform, cur[]):
    return
  var batch = Batch(start: b.instances.len, count: 1,
                    scissor: cur.scissor, effect: fx.effect,
                    clipMask: b.preparedMask)
  if fx.effect.backdrop:
    let bk = scene.backdropOf(op.transform.bounds(op.rect), fx.blur,
                              s.width, s.height)
    if bk.area.empty():
      return
    b.backdrops.add(bk)
    batch.backdrop = b.backdrops.len
    let (tw, th) = bk.size()
    `in`.uv = [float32(bk.area.min.x), float32(bk.area.min.y),
               float32(tw), float32(th)]
    `in`.params[2] = float32(bk.down)
  b.batches.add(batch)
  b.instances.add(`in`)

proc addHole(b: var Builder; op: scene.Op) =
  ## Appends a hole within the current clip, in a batch of holes: an
  ## opaque fill, whose coverage the renderers take away.
  let cur = addr b.stack[^1]
  var `in` = Instance(
    rect: rect(op.rect),
    radii: scene.corners(op.rect, op.radii, op.continuous),
    color: [0'f32, 0, 0, 1],
    params: [0'f32, 0, float32(scene.paintSolid), opacity(op.opacity)])
  if not b.prepare(`in`, op.transform, cur[]):
    return
  let n = b.batches.len
  if n == 0 or not b.batches[n - 1].hole or
      b.batches[n - 1].scissor != cur.scissor or
      b.batches[n - 1].clipMask != b.preparedMask:
    b.batches.add(Batch(start: b.instances.len, scissor: cur.scissor,
                        hole: true, clipMask: b.preparedMask))
  b.instances.add(`in`)
  inc b.batches[^1].count

proc build*(b: var Builder; s: scene.Scene;
            `image`: proc(i: scene.Image): uint): scene.Scene =
  ## Turns a scene directly into GPU instances, retaining local
  ## geometry and composing transforms in the vertex shader. Nested
  ## affine clips use cached masks; stationary clipping never
  ## rasterizes again as content moves. A clip is masked only when it
  ## is transformed, nested in a transformed clip, or rounded (or
  ## masked) with transformed content inside: the others cut in the
  ## shader as in a scene without transforms.
  b.markEnclosing(s)
  b.imageTexture = `image`
  b.maskUsed = 0
  inc b.frame
  b.clipShapes.setLen(0)
  b.instances.setLen(0)
  b.batches.setLen(0)
  b.backdrops.setLen(0)
  let everything = scene.Rect(x: -1e6, y: -1e6, w: 2e6, h: 2e6)
  b.stack.setLen(0)
  b.stack.add(clip(rect: everything,
                   bounds: scene.Rect(w: float32(s.width),
                                      h: float32(s.height)),
                   scissor: Scissor(left: 0, top: 0,
                                    right: int32(s.width),
                                    bottom: int32(s.height))))
  for i in 0 ..< s.ops.len:
    let op = addr s.ops[i]
    case op.kind
    of scene.opPushClip:
      let top = b.stack[^1]
      let bounds = top.bounds.intersect(op.transform.bounds(op.rect))
      ## The innermost clip shapes its edges in the shader, the
      ## others cut with the scissor rectangle.
      var c = clip(rect: op.rect,
                   radii: scene.corners(op.rect, op.radii, op.continuous),
                   bounds: bounds,
                   shape: scene.ClipShape(rect: op.rect, radii: op.radii,
                                          transform: op.transform,
                                          continuous: op.continuous),
                   maskSlot: -1)
      c.moved = top.moved or op.transform.`set`
      c.masked = c.moved or (b.encloses[i] and
        (top.masked or c.radii != default(array[4, float32])))
      if c.masked:
        c.maskSlot = b.maskUsed
        inc b.maskUsed
      b.clipShapes.add(c.shape)
      if bounds.w > 0 and bounds.h > 0:
        c.scissor = Scissor(left: int32(floor(bounds.x)),
                            top: int32(floor(bounds.y)),
                            right: int32(ceil(bounds.x + bounds.w)),
                            bottom: int32(ceil(bounds.y + bounds.h)))
      b.stack.add(c)
    of scene.opPopClip:
      if b.stack.len > 1:
        b.stack.setLen(b.stack.len - 1)
        b.clipShapes.setLen(b.clipShapes.len - 1)
    of scene.opFill:
      if op.rect.empty():
        continue
      var bw = op.border
      if op.borderColor.a == 0:
        bw = default(array[4, float32])
      let radii = scene.corners(op.rect, op.radii, op.continuous)
      var inner: array[4, float32]
      if scene.hasBorder(bw):
        inner = scene.innerRadii(op.rect, radii, bw).radii
      var dashed = 0'f32
      if op.dashed:
        dashed = 1
      let w = b.wideOf(s, op.wide)
      b.add(Instance(
        rect: rect(op.rect), radii: radii, inner: inner,
        color: wideColor(w, scene.wideColor, op.color),
        color2: wideColor(w, scene.wideColor2, op.color2),
        border: wideColor(w, scene.wideBorder, op.borderColor),
        grad: op.gradient,
        uv: bw,
        params: [0'f32, dashed, float32(op.paint), opacity(op.opacity)]),
        0, op.transform)
    of scene.opShadow:
      if op.inset:
        ## The box in rect, the hole in uv and inner, which an inner
        ## shadow's 1 in params[1] tells.
        if op.`cast`.empty():
          continue
        var sigma = op.blur / 2
        if sigma < 0.5:
          sigma = 0
        var `in` = Instance(
          rect: rect(op.`cast`),
          radii: scene.corners(op.`cast`, op.castRadii, op.continuous),
          color: wideColor(b.wideOf(s, op.wide), scene.wideColor, op.color),
          params: [1'f32, 1, sigma, opacity(op.opacity)])
        if not op.rect.empty():
          `in`.uv = rect(op.rect)
          `in`.inner = scene.corners(op.rect, op.radii, op.continuous)
        b.add(`in`, 0, op.transform)
        continue
      if op.rect.empty():
        continue
      var sigma = op.blur / 2
      if sigma < 0.5:
        sigma = 0
      var `in` = Instance(
        rect: rect(op.rect),
        radii: scene.corners(op.rect, op.radii, op.continuous),
        color: wideColor(b.wideOf(s, op.wide), scene.wideColor, op.color),
        params: [1'f32, 0, sigma, opacity(op.opacity)])
      if not op.`cast`.empty():
        `in`.uv = rect(op.`cast`)
        `in`.inner = scene.corners(op.`cast`, op.castRadii, op.continuous)
      b.add(`in`, 0, op.transform)
    of scene.opGlyphs:
      let grad = op.paint == scene.paintLinear or op.paint == scene.paintOklab
      var c1, c2: array[4, float32]
      if grad:
        let w = b.wideOf(s, op.wide)
        c1 = wideColor(w, scene.wideColor, op.color)
        c2 = wideColor(w, scene.wideColor2, op.color2)
      for g in s.glyphs[int(op.first) ..< int(op.last)]:
        var
          a = s.maskAtlas
          kind = 2'f32
          contrast = s.text.contrast
        if g.colored:
          a = s.colorAtlas
          kind = 3
        elif g.subpixel:
          a = s.colorAtlas
          kind = 5
          contrast = s.text.subpixelContrast
        if a.isNil:
          continue
        var boost = 0'f32
        if g.thin:
          boost = scene.thinBoost
        let
          aw = float32(a.w)
          ah = float32(a.h)
        var `in` = Instance(
          rect: [float32(round(g.x)), float32(round(g.y)),
                 float32(g.uw), float32(g.vh)],
          radii: s.text.gammaRatios,
          inner: [contrast, boost, 0'f32, 0],
          uv: [float32(g.u) / aw, float32(g.v) / ah,
               float32(g.u + g.uw) / aw, float32(g.v + g.vh) / ah],
          color: straight(g.color),
          params: [kind, 0'f32, 0, 1])
        let w = b.wideOf(s, g.wide)
        if not w.isNil:
          `in`.color = w.color
        if grad and not g.colored:
          `in`.color = c1
          `in`.color2 = c2
          `in`.grad = op.gradient
          `in`.params[2] = float32(op.paint)
          `in`.params[3] = opacity(op.opacity)
        b.add(`in`, 0, op.transform.mul(g.transform))
    of scene.opEffect:
      if not op.rect.empty() and int(op.first) < s.effects.len and
          not s.effects[int(op.first)].effect.isNil:
        b.addEffect(s, op[])
    of scene.opHole:
      if not op.rect.empty():
        b.addHole(op[])
    of scene.opImage:
      let img = op.image
      if img.isNil or op.rect.empty() or img.w == 0 or img.h == 0:
        continue
      var src = op.src
      var iw = float32(img.w)
      var ih = float32(img.h)
      var tex: uint
      if op.blur > 0 and not b.blurredImage.isNil:
        let bk = scene.imageBlur(scene.imageArea(op.src, img.w, img.h), op.blur)
        let (w, h) = bk.size()
        if w <= 0 or h <= 0:
          continue
        tex = b.blurredImage(img, bk)
        src = bk.imageSrc(op.src)
        iw = float32(w)
        ih = float32(h)
      else:
        tex = `image`(img)
      if tex == 0:
        continue
      var
        gray = 0'f32
        nearest = 0'f32
      if op.grayscale:
        gray = 1
      if op.pixelated:
        nearest = 1
      var tint = [1'f32, 1, 1, 1]
      if op.color != scene.Color():
        tint = straight(op.color)
      b.add(Instance(
        rect: rect(op.rect),
        radii: scene.corners(op.rect, op.radii, op.continuous),
        color: tint,
        uv: [src.x / iw, src.y / ih,
             (src.x + src.w) / iw, (src.y + src.h) / ih],
        params: [4'f32, gray, nearest, opacity(op.opacity)]),
        tex, op.transform)
  b.dropIdleMasks(idleMaskBytes)
  b.imageTexture = nil
  b.blurredImage = nil
  s

proc sourceSum*(src: string): string =
  ## The SHA-256, in hex, of shader source normalized to LF line endings.
  sha256Hex(src.replace("\r\n", "\n"))
