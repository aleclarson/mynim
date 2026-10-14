## stroke.go: stroking polylines as polygons, and dashing them.

## Line caps and joins.
const
  capButt* = 0'u8
  capRound* = 1'u8
  capSquare* = 2'u8

const
  joinMiter* = 0'u8
  joinRound* = 1'u8
  joinBevel* = 2'u8

## stroker outlines polylines as polygons that all turn the same way,
## so that the non-zero rule fills their union: a quadrilateral per
## segment, and the shapes of the joins and caps.
type stroker = object
  hw: float64 ## half the width
  join, cap: uint8
  miter: float64 ## the miter limit
  tol: float64 ## how far arcs may stray from circles
  `out`: ptr polys
  pts: seq[point]

proc full(s: stroker): bool =
  ## Reports whether the outline has all the points it may have.
  s.`out`.pts.len >= 2 * maxPoints

proc `finish`(s: var stroker)

## polygon adds a polygon to out, turned the way they all turn.
proc polygon(s: var stroker; pts: varargs[point]) =
  if s.full():
    return
  let o = s.`out`
  o[].start(pts[0])
  for i in 1 ..< pts.len:
    o[].add(pts[i])
  s.`finish`()

## `finish` ends the polygon being built, reversing it if it turns the
## other way.
proc `finish`(s: var stroker) =
  let o = s.`out`
  let `begin` = o[].`begin`
  o[].`end`(true)
  if o[].starts.len == 0 or o[].starts[^1] != `begin`:
    return
  var area = 0.0
  var a = o[].pts[^1]
  for i in `begin` ..< o[].pts.len:
    let b = o[].pts[i]
    area += a.x * b.y - b.x * a.y
    a = b
  if area < 0:
    var i = `begin`
    var j = o[].pts.len - 1
    while i < j:
      swap(o[].pts[i], o[].pts[j])
      inc i
      dec j

proc unit(a, b: point): point =
  let
    dx = b.x - a.x
    dy = b.y - a.y
    l = sqrt(dx * dx + dy * dy)
  point(x: dx / l, y: dy / l)

proc segment(s: var stroker; a, b: point) =
  let d = unit(a, b)
  let n = point(x: -d.y * s.hw, y: d.x * s.hw)
  s.polygon(point(x: a.x + n.x, y: a.y + n.y),
            point(x: b.x + n.x, y: b.y + n.y),
            point(x: b.x - n.x, y: b.y - n.y),
            point(x: a.x - n.x, y: a.y - n.y))

proc wedge(s: var stroker; c, `from`: point; sweep: float64)

## joinAt joins the segments a→p and p→b on the outer side of the turn.
proc joinAt(s: var stroker; a, p, b: point) =
  let
    d0 = unit(a, p)
    d1 = unit(p, b)
    cross = d0.x * d1.y - d0.y * d1.x
    dot = d0.x * d1.x + d0.y * d1.y
  if abs(cross) < 1e-12 and dot > 0:
    return ## straight on
  var side = s.hw
  if cross > 0:
    side = -s.hw
  let
    n0 = point(x: -d0.y * side, y: d0.x * side)
    n1 = point(x: -d1.y * side, y: d1.x * side)
    o0 = point(x: p.x + n0.x, y: p.y + n0.y)
    o1 = point(x: p.x + n1.x, y: p.y + n1.y)
  case s.join
  of joinRound:
    let turn = arctan2(abs(cross), dot)
    if s.hw * (1 - cos(turn / 2)) < s.tol:
      s.polygon(p, o0, o1)
      return
    s.wedge(p, n0, arctan2(n0.x * n1.y - n0.y * n1.x,
                           n0.x * n1.x + n0.y * n1.y))
  of joinBevel:
    s.polygon(p, o0, o1)
  else:
    ## The miter's length over the stroke's width is 1/cos(turn/2).
    let cosHalf = sqrt(max((1 + dot) / 2, 0))
    if cosHalf * s.miter < 1:
      s.polygon(p, o0, o1)
      return
    let u = unit(point(), point(x: n0.x + n1.x, y: n0.y + n1.y))
    let l = s.hw / cosHalf
    s.polygon(p, o0, point(x: p.x + u.x * l, y: p.y + u.y * l), o1)

## capAt caps the end p of a polyline whose last segment comes from
## prev.
proc capAt(s: var stroker; p, prev: point) =
  let d = unit(prev, p)
  let n = point(x: d.y * s.hw, y: -d.x * s.hw)
  case s.cap
  of capRound:
    ## Half a turn from n, through the direction d.
    s.wedge(p, n, PI)
  of capSquare:
    let e = point(x: d.x * s.hw, y: d.y * s.hw)
    s.polygon(point(x: p.x + n.x, y: p.y + n.y),
              point(x: p.x + n.x + e.x, y: p.y + n.y + e.y),
              point(x: p.x - n.x + e.x, y: p.y - n.y + e.y),
              point(x: p.x - n.x, y: p.y - n.y))
  else:
    discard

## dot draws a subpath of no length: a disc with round caps, a square
## with square caps.
proc dot(s: var stroker; p: point) =
  case s.cap
  of capRound:
    s.wedge(p, point(x: s.hw, y: 0), 2 * PI)
  of capSquare:
    let h = s.hw
    s.polygon(point(x: p.x - h, y: p.y - h),
              point(x: p.x + h, y: p.y - h),
              point(x: p.x + h, y: p.y + h),
              point(x: p.x - h, y: p.y + h))
  else:
    discard

## wedge adds the slice of the disc around c of radius hw from the
## vector from, sweeping sweep radians.
proc wedge(s: var stroker; c, `from`: point; sweep: float64) =
  if s.full():
    return
  let step = 2 * arccos(max(1 - s.tol / s.hw, -1))
  var n = 1
  if step > 0:
    n = max(1, min(int(ceil(abs(sweep) / step)), 256))
  let a0 = arctan2(`from`.y, `from`.x)
  let o = s.`out`
  let full = abs(sweep) >= 2 * PI
  if full:
    n = max(n, 8)
  ## Points between the ends lie a little outside the circle, so that
  ## the polygon covers as much as the slice of the disc does.
  let a = abs(sweep) / float64(n)
  let r = s.hw * sqrt(a / sin(a))
  if full:
    o[].start(point(x: c.x + `from`.x * r / s.hw,
                  y: c.y + `from`.y * r / s.hw))
  else:
    o[].start(c)
    o[].add(point(x: c.x + `from`.x, y: c.y + `from`.y))
  for k in 1 ..< n:
    let
      sn = sin(a0 + sweep * float64(k) / float64(n))
      cs = cos(a0 + sweep * float64(k) / float64(n))
    o[].add(point(x: c.x + cs * r, y: c.y + sn * r))
  if not full:
    let
      sn = sin(a0 + sweep)
      cs = cos(a0 + sweep)
    o[].add(point(x: c.x + cs * s.hw, y: c.y + sn * s.hw))
  s.`finish`()

proc stroke(s: var stroker; `in`: var polys) =
  for i in 0 ..< `in`.len():
    let closed = `in`.closed[i]
    var pts = s.pts
    pts.setLen(0)
    for p in `in`.poly(i):
      if pts.len == 0 or p != pts[^1]:
        pts.add(p)
    if closed and pts.len > 1 and pts[0] == pts[^1]:
      pts.setLen(pts.len - 1)
    s.pts = pts
    let n = pts.len
    if n == 1:
      s.dot(pts[0])
      continue
    var segs = n - 1
    if closed:
      segs = n
    for k in 0 ..< segs:
      s.segment(pts[k], pts[(k + 1) mod n])
    if closed:
      for k in 0 ..< n:
        s.joinAt(pts[(k + n - 1) mod n], pts[k], pts[(k + 1) mod n])
      continue
    for k in 1 ..< n - 1:
      s.joinAt(pts[k - 1], pts[k], pts[k + 1])
    s.capAt(pts[0], pts[1])
    s.capAt(pts[n - 1], pts[n - 2])

## dash cuts the polylines of `in` into the dashes of a dash array (of
## even length), starting offset into it, as open polylines in out.
## limit bounds the number of dashes.
proc dash(`in`: var polys; dashes: seq[float64]; offset: float64;
          `out`: var polys; limit0: int) =
  var limit = limit0
  var total = 0.0
  for d in dashes:
    total += d
  var offset = offset mod total
  if offset < 0:
    offset += total
  for i in 0 ..< `in`.len():
    let pts = `in`.poly(i)
    ## Every subpath starts the pattern anew, offset into it: in dash
    ## or gap k, with left of it to go.
    var k = 0
    var o = offset
    while o > dashes[k]:
      o -= dashes[k]
      k = (k + 1) mod dashes.len
    var left = dashes[k] - o
    var on = k mod 2 == 0
    if on:
      `out`.start(pts[0])
    let n = pts.len
    var segs = n - 1
    if `in`.closed[i]:
      segs = n
    for sg in 0 ..< segs:
      let
        a = pts[sg]
        b = pts[(sg + 1) mod n]
        l = hypot(b.x - a.x, b.y - a.y)
      var pos = 0.0
      while l - pos > left:
        pos += left
        let t = pos / l
        let p = point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        if on:
          `out`.add(p)
          `out`.`end`(false)
          dec limit
          if limit <= 0:
            return
        else:
          `out`.start(p)
        on = not on
        k = (k + 1) mod dashes.len
        left = dashes[k]
      left -= l - pos
      if on:
        `out`.add(b)
    `out`.`end`(false)
