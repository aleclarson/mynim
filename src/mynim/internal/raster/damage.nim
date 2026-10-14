## damage.go: Renderer — draws successive scenes into an Image,
## redrawing only where a scene differs from the one before, plus
## canvas.go's drawCanvases.

type
  Renderer* = object
    ## Draws the successive scenes of a window into Image, redrawing
    ## only where a scene differs from the one before: a blinking
    ## caret, a ticking clock or a button under the pointer redraws
    ## only itself.
    ##
    ## It compares the operations of the two scenes from both ends, so
    ## a change in the middle of the display list redraws the boxes of
    ## the operations that changed, clipped as they draw. Glyphs whose
    ## pixels changed in an atlas, and images whose pixels changed,
    ## count as changed.
    image*: Image

    ## d draws the bands of large damage.
    d: drawer
    ## valid tells that the last scene, of w×h pixels, is remembered
    ## to compare the next with.
    valid: bool
    w, h: int
    clear: scene.Color
    ops: seq[scene.Op]
    glyphs: seq[scene.Glyph]
    effects: seq[scene.EffectOp]
    ## bounds is where each operation of the last scene drew;
    ## versions has the versions of its images.
    bounds, next: seq[image.Rectangle]
    versions: seq[uint64]
    mask, color: atlasMark
    damage: seq[image.Rectangle]
    clips: seq[image.Rectangle]

  atlasMark = object
    ## The state of an atlas a scene drew from.
    atlas: scene.Atlas
    gen, version: uint64

proc drawCanvases(s: scene.Scene)

proc changes(m: atlasMark; a: scene.Atlas): tuple[rects: seq[
    image.Rectangle], ok: bool] =
  ## The rectangles of a that changed since the mark, or false when
  ## everything may have.
  if a.isNil or m.atlas.isNil:
    return (default(seq[image.Rectangle]), a == m.atlas)
  if a != m.atlas:
    return (default(seq[image.Rectangle]), false)
  let (rects, full) = a.changes(m.gen, m.version)
  (rects, not full)

proc set(m: var atlasMark; a: scene.Atlas) =
  m.atlas = a
  if not a.isNil:
    m.gen = a.generation()
    m.version = a.version

proc resize(r: var Renderer; w, h: int) =
  ## Makes image w×h, reusing its memory when it can.
  let n = 4 * w * h
  if r.image.pix.len < n:
    r.image.pix = newSeq[byte](n)
  r.image.pix.setLen(n)
  r.image.w = w
  r.image.h = h
  r.image.stride = 4 * w

proc release*(r: var Renderer) =
  ## Frees the image and what render remembers: the next render draws
  ## everything. image must not be used meanwhile.
  r = Renderer()

proc area(rects: seq[image.Rectangle]): int =
  for d in rects:
    result += d.dx() * d.dy()

proc addRect(damage: seq[image.Rectangle];
             b: image.Rectangle): seq[image.Rectangle] =
  ## Adds a rectangle to damage, merged with one it touches.
  result = damage
  if b.empty():
    return
  for i in 0 ..< result.len:
    if result[i].inset(-8).overlaps(b):
      result[i] = result[i].union(b)
      return
  result.add(b)
  if result.len > 8:
    var u = result[0]
    for d in result[1 ..^ 1]:
      u = u.union(d)
    result = @[u]

proc outset(rc: scene.Rect; d: float32): image.Rectangle =
  image.rect(int(floor(rc.x - d)), int(floor(rc.y - d)),
             int(ceil(rc.x + rc.w + d)), int(ceil(rc.y + rc.h + d)))

proc opBounds(r: var Renderer; s: scene.Scene;
              `out`: seq[image.Rectangle]): seq[image.Rectangle] =
  ## Appends where each operation of s draws, within the clips around
  ## it.
  result = `out`
  var clip = image.rect(0, 0, s.width, s.height)
  r.clips.setLen(0)
  for i in 0 ..< s.ops.len:
    let op = addr s.ops[i]
    var b: image.Rectangle
    case op.kind
    of scene.opFill, scene.opImage, scene.opEffect, scene.opHole:
      b = outset(op.transform.bounds(op.rect), 1)
    of scene.opShadow:
      if op.inset:
        b = outset(op.transform.bounds(op.`cast`), 1)
      else:
        let e = 1.5 * op.blur + 1
        let box = scene.Rect(x: op.rect.x - e, y: op.rect.y - e,
                             w: op.rect.w + 2 * e, h: op.rect.h + 2 * e)
        b = outset(op.transform.bounds(box), 1)
    of scene.opGlyphs:
      for g in s.glyphs[int(op.first) ..< int(op.last)]:
        b = b.union(outset(op.transform.mul(g.transform).bounds(
          scene.Rect(x: g.x, y: g.y, w: g.w, h: g.h)), 1))
    of scene.opPushClip:
      ## A clip that changes changes everything it cuts.
      b = outset(op.transform.bounds(op.rect), 1)
      r.clips.add(clip)
      clip = clip.intersect(b)
    of scene.opPopClip:
      if r.clips.len > 0:
        clip = r.clips[^1]
        r.clips.setLen(r.clips.len - 1)
    result.add(b.intersect(clip))

proc same(r: var Renderer; i: int; s: scene.Scene; j: int;
          maskRects, colorRects: seq[image.Rectangle]): bool =
  ## Whether operation i of the last scene draws what operation j of
  ## s does.
  var
    a = r.ops[i]
    b = s.ops[j]
  ## Glyphs and effects are compared by what first and last point at.
  let
    sa = a.first
    sb = b.first
  var
    ga: seq[scene.Glyph]
    gb: seq[scene.Glyph]
  if a.kind == scene.opGlyphs and b.kind == scene.opGlyphs:
    ga = r.glyphs[int(a.first) ..< int(a.last)]
    gb = s.glyphs[int(b.first) ..< int(b.last)]
  a.first = 0
  a.last = 0
  b.first = 0
  b.last = 0
  ## The CPU draws the sRGB colors, not those outside its gamut, which
  ## wide points at in each scene's own table.
  a.wide = 0
  b.wide = 0
  if a != b:
    return false
  case b.kind
  of scene.opGlyphs:
    if ga.len != gb.len:
      return false
    for k in 0 ..< gb.len:
      let g = gb[k]
      if ga[k] != g:
        var x = ga[k]
        x.wide = g.wide
        if x != g:
          return false
      var rects = maskRects
      if g.colored:
        rects = colorRects
      let at = image.rect(int(g.u), int(g.v), int(g.u) + int(g.uw),
                          int(g.v) + int(g.vh))
      for c in rects:
        if c.overlaps(at):
          return false
  of scene.opImage:
    if not b.image.isNil and b.image.version != r.versions[i]:
      return false
  of scene.opEffect:
    if int(sa) >= r.effects.len or int(sb) >= s.effects.len or
        r.effects[int(sa)] != s.effects[int(sb)]:
      return false
  else:
    discard
  true

proc addBackdrops(r: var Renderer; s: scene.Scene) =
  ## Adds to the damage the effects of s that read their backdrops it
  ## meets, with those backdrops: draw reads a backdrop after drawing
  ## the operations before its effect within the area drawn, which
  ## must hold all of it, and then no other area may draw the effect.
  ## So the damage becomes rectangles apart from each other.
  if s.effects.len == 0 or r.damage.len == 0:
    return
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< s.ops.len:
      let op = addr s.ops[i]
      if op.kind != scene.opEffect or int(op.first) >= s.effects.len or
          r.next[i].empty():
        continue
      let fx = addr s.effects[int(op.first)]
      if fx.effect.isNil or not fx.effect.backdrop:
        continue
      let need = scene.backdropOf(op.transform.bounds(op.rect), fx.blur,
                                  s.width, s.height).area.union(r.next[i])
      for d in r.damage:
        if d.overlaps(need) and not (need in d):
          r.damage = addRect(r.damage, need)
          changed = true
          break
    ## Rectangles that overlap become one.
    var i = 0
    while i < r.damage.len:
      var j = i + 1
      while j < r.damage.len:
        if r.damage[i].overlaps(r.damage[j]):
          r.damage[i] = r.damage[i].union(r.damage[j])
          r.damage.delete(j)
          changed = true
          j = i
        inc j
      inc i

proc diff(r: var Renderer; s: scene.Scene): bool =
  ## Sets the damage between the last scene and s, and reports false
  ## when s must be drawn whole.
  let (maskRects, ok1) = r.mask.changes(s.maskAtlas)
  if not ok1:
    return false
  let (colorRects, ok2) = r.color.changes(s.colorAtlas)
  if not ok2:
    return false
  let same = proc(i, j: int): bool =
    r.same(i, s, j, maskRects, colorRects)
  let
    n = r.ops.len
    m = s.ops.len
  var pre = 0
  while pre < n and pre < m and same(pre, pre):
    inc pre
  var suf = 0
  while suf < n - pre and suf < m - pre and same(n - 1 - suf, m - 1 - suf):
    inc suf
  r.damage.setLen(0)
  if n == m:
    for k in pre ..< n - suf:
      if not same(k, k):
        r.damage = addRect(r.damage, r.bounds[k])
        r.damage = addRect(r.damage, r.next[k])
  else:
    for i in pre ..< n - suf:
      r.damage = addRect(r.damage, r.bounds[i])
    for j in pre ..< m - suf:
      r.damage = addRect(r.damage, r.next[j])
  r.addBackdrops(s)
  ## Past half the window, drawing it whole costs about the same.
  area(r.damage) * 2 < s.width * s.height

proc whole(r: var Renderer; s: scene.Scene): bool =
  ## Sets the damage of s against the last scene, and reports whether
  ## s must be drawn whole: there is none, or s changes too much of
  ## it.
  r.next = r.opBounds(s, r.next[0 ..< 0])
  not r.valid or s.width != r.w or s.height != r.h or
    s.clear != r.clear or not r.diff(s)

proc invalidate*(r: var Renderer) =
  ## Makes the next render draw everything.
  r.valid = false

proc remember(r: var Renderer; s: scene.Scene) =
  ## Keeps what render needs of s to compare the next scene with.
  r.valid = true
  r.w = s.width
  r.h = s.height
  r.clear = s.clear
  r.ops = s.ops
  r.glyphs = s.glyphs
  r.effects = s.effects
  swap(r.bounds, r.next)
  r.versions.setLen(0)
  for i in 0 ..< s.ops.len:
    var v = 0'u64
    if not s.ops[i].image.isNil:
      v = s.ops[i].image.version
    r.versions.add(v)
  r.mask.set(s.maskAtlas)
  r.color.set(s.colorAtlas)

proc render*(r: var Renderer; s: scene.Scene): seq[image.Rectangle] =
  ## Draws s, and returns the rectangles of image it changed. s may
  ## change once render returns.
  drawCanvases(s)
  if r.whole(s) or r.image.w != s.width or r.image.h != s.height:
    ## A new size, or image was released (release).
    r.resize(s.width, s.height)
    r.damage = @[image.rect(0, 0, s.width, s.height)]
  for d in r.damage:
    r.d.draw(addr r.image, s, d, r.next)
  r.remember(s)
  r.damage

proc drawCanvases(s: scene.Scene) =
  ## Draws into their pixels the canvases s draws anew or shows,
  ## those changed since, each before the canvases and the scene that
  ## show it (canvas.go).
  s.eachCanvas(proc(c: scene.Image) =
    if c.pixVersion == c.version and c.pix.len == 4 * c.w * c.h:
      return
    let cs = c.scene
    cs.width = c.w
    cs.height = c.h
    var img = newImage(c.w, c.h)
    var r: Renderer
    r.d.draw(addr img, cs, image.rect(0, 0, c.w, c.h), r.opBounds(cs, default(seq[image.Rectangle])))
    if c.pix.len != 4 * c.w * c.h:
      c.pix = newSeq[byte](4 * c.w * c.h)
    ## From BGRA to the RGBA of images.
    var i = 0
    while i + 3 < img.pix.len:
      c.pix[i] = img.pix[i + 2]
      c.pix[i + 1] = img.pix[i + 1]
      c.pix[i + 2] = img.pix[i]
      c.pix[i + 3] = img.pix[i + 3]
      i += 4
    c.pixVersion = c.version
  )

proc render*(dst: var Image; s: scene.Scene) =
  ## Draws s into dst, which must be s.width×s.height.
  drawCanvases(s)
  var r: Renderer
  r.d.draw(addr dst, s, image.rect(0, 0, dst.w, dst.h),
           r.opBounds(s, default(seq[image.Rectangle])))
