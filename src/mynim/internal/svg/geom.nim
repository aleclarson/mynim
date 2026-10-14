## geom.go: points, boxes, matrices, the attribute scanner, paths and
## flattened polylines.

type point = object
  x, y: float64

## box is a rectangle in user units.
type box = object
  x, y, w, h: float64

proc union(b, o: box): box =
  let
    x0 = min(b.x, o.x)
    y0 = min(b.y, o.y)
    x1 = max(b.x + b.w, o.x + o.w)
    y1 = max(b.y + b.h, o.y + o.h)
  box(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

## matrix is an affine transform: it maps (x, y) to (m[0]x + m[2]y +
## m[4], m[1]x + m[3]y + m[5]), as SVG's matrix(a, b, c, d, e, f) does.
type matrix = array[6, float64]

const identity*: matrix = [1'f64, 0, 0, 1, 0, 0]

proc apply(m: matrix; p: point): point =
  point(x: m[0] * p.x + m[2] * p.y + m[4],
        y: m[1] * p.x + m[3] * p.y + m[5])

proc transform(b: box; m: matrix): box =
  ## The box around b transformed by m.
  var `out`: box
  for i, p in [point(x: b.x, y: b.y), point(x: b.x + b.w, y: b.y),
               point(x: b.x, y: b.y + b.h),
               point(x: b.x + b.w, y: b.y + b.h)]:
    let q = m.apply(p)
    if i == 0:
      `out` = box(x: q.x, y: q.y, w: 0, h: 0)
    else:
      `out` = `out`.union(box(x: q.x, y: q.y, w: 0, h: 0))
  `out`

proc mul(m, n: matrix): matrix =
  ## The transform that applies n, then m.
  [m[0] * n[0] + m[2] * n[1],
   m[1] * n[0] + m[3] * n[1],
   m[0] * n[2] + m[2] * n[3],
   m[1] * n[2] + m[3] * n[3],
   m[0] * n[4] + m[2] * n[5] + m[4],
   m[1] * n[4] + m[3] * n[5] + m[5]]

proc invert(m: matrix): tuple[m: matrix, ok: bool] =
  ## The inverse of m, or false when m flattens the plane.
  let d = m[0] * m[3] - m[1] * m[2]
  if d == 0 or d.isNaN or d == Inf or d == NegInf:
    return (identity, false)
  ([m[3] / d, -m[1] / d, -m[2] / d, m[0] / d,
    (m[2] * m[5] - m[3] * m[4]) / d,
    (m[1] * m[4] - m[0] * m[5]) / d], true)

proc stretch(m: matrix): float64 =
  ## The most m lengthens a line: its largest singular value.
  let
    a = m[0]
    b = m[1]
    c = m[2]
    d = m[3]
    e = a * a + b * b - c * c - d * d
    f = a * c + b * d
  sqrt((a * a + b * b + c * c + d * d + sqrt(e * e + 4 * f * f)) / 2)

proc translate(x, y: float64): matrix = [1'f64, 0, 0, 1, x, y]
proc scaling(x, y: float64): matrix = [x, 0, 0, y, 0'f64, 0]

proc rotation(deg: float64): matrix =
  let
    s = sin(deg * PI / 180)
    c = cos(deg * PI / 180)
  [c, s, -s, c, 0'f64, 0]

proc boxMatrix(b: box): matrix =
  ## Maps the unit square to b, for objectBoundingBox units.
  [b.w, 0'f64, 0, b.h, b.x, b.y]

type scanner = object
  ## Reads the numbers, names and separators of attribute values.
  s: string
  i: int

proc `done`(p: scanner): bool = p.i >= p.s.len

proc peek(p: scanner): byte =
  if p.i < p.s.len:
    return byte(p.s[p.i])
  0

proc eat(p: var scanner; c: byte): bool =
  if p.i < p.s.len and byte(p.s[p.i]) == c:
    inc p.i
    return true
  false

proc isSpace(c: byte): bool =
  c == byte(' ') or c == byte('\t') or c == byte('\n') or
    c == byte('\r') or c == byte('\f')

proc skipSpace(p: var scanner) =
  while p.i < p.s.len and isSpace(byte(p.s[p.i])):
    inc p.i

proc skipSep(p: var scanner) =
  ## Skips white space with at most one comma in it.
  p.skipSpace()
  if p.eat(byte(',')):
    p.skipSpace()

proc ident(p: var scanner): string =
  ## Reads a name of letters, digits, hyphens and underscores.
  let start = p.i
  while p.i < p.s.len:
    let c = byte(p.s[p.i])
    if c == byte('-') or c == byte('_') or
        (c >= byte('0') and c <= byte('9')) or
        (c >= byte('a') and c <= byte('z')) or
        (c >= byte('A') and c <= byte('Z')) or c >= 0x80:
      inc p.i
      continue
    break
  p.s[start ..< p.i]

proc number(p: var scanner): tuple[v: float64, ok: bool] =
  ## Reads a finite number: an optional sign, digits with an optional
  ## fraction, and an optional exponent.
  let
    s = p.s
    start = p.i
  var i = start
  if i < s.len and (s[i] == '+' or s[i] == '-'):
    inc i
  var digits = 0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    inc i
    inc digits
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      inc i
      inc digits
  if digits == 0:
    return (0, false)
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    ## An exponent, unless the e starts a unit such as em.
    var j = i + 1
    if j < s.len and (s[j] == '+' or s[j] == '-'):
      inc j
    if j < s.len and s[j] >= '0' and s[j] <= '9':
      while j < s.len and s[j] >= '0' and s[j] <= '9':
        inc j
      i = j
  let v = try: parseFloat(s[start ..< i]) except ValueError: return (0, false)
  if v == Inf or v == NegInf:
    return (0, false)
  p.i = i
  (v, true)

proc numbers(s: string): seq[float64] =
  ## Parses a list of numbers separated by white space or commas, up
  ## to the first that is not one.
  var p = scanner(s: s)
  while true:
    p.skipSep()
    let (v, ok) = p.number()
    if not ok:
      return
    result.add(v)

proc parseTransform(s: string): matrix =
  ## Parses a transform list, such as "translate(10 20) rotate(45)". A
  ## list in error transforms nothing, as in browsers.
  var m = identity
  var p = scanner(s: s)
  while true:
    p.skipSep()
    if p.`done`():
      return m
    let name = p.ident()
    p.skipSpace()
    if not p.eat(byte('(')):
      return identity
    var a: array[6, float64]
    var n = 0
    while true:
      p.skipSep()
      if p.eat(byte(')')):
        break
      let (v, ok) = p.number()
      if not ok or n == a.len:
        return identity
      a[n] = v
      inc n
    var t: matrix
    if name == "matrix" and n == 6:
      t = a
    elif name == "translate" and (n == 1 or n == 2):
      t = translate(a[0], a[1])
    elif name == "scale" and n == 1:
      t = scaling(a[0], a[0])
    elif name == "scale" and n == 2:
      t = scaling(a[0], a[1])
    elif name == "rotate" and n == 1:
      t = rotation(a[0])
    elif name == "rotate" and n == 3:
      t = translate(a[1], a[2]).mul(rotation(a[0])).mul(
          translate(-a[1], -a[2]))
    elif name == "skewX" and n == 1:
      t = [1'f64, 0, tan(a[0] * PI / 180), 1, 0, 0]
    elif name == "skewY" and n == 1:
      t = [1'f64, tan(a[0] * PI / 180), 0, 1, 0, 0]
    else:
      return identity
    m = m.mul(t)

type pathOp = enum
  opMove  ## a point
  opLine  ## a point
  opCubic ## two control points and the end
  opClose ## no point

type path = object
  ## A path in user units. Its curves are cubic Bézier curves:
  ## quadratic curves and arcs are converted.
  ops: seq[pathOp]
  pts: seq[point]
  ## start is the first point of the subpath, cur the pen; open is
  ## false before the first move and after a close.
  start, cur: point
  open: bool

proc moveTo(pa: var path; p: point) =
  pa.ops.add(opMove)
  pa.pts.add(p)
  pa.start = p
  pa.cur = p
  pa.open = true

proc `begin`(pa: var path) =
  ## Starts a subpath where the pen is, when drawing follows a close:
  ## the subpath after a close starts where the closed one did.
  if not pa.open:
    pa.moveTo(pa.cur)

proc lineTo(pa: var path; p: point) =
  pa.`begin`()
  pa.ops.add(opLine)
  pa.pts.add(p)
  pa.cur = p

proc cubicTo(pa: var path; c1, c2, p: point) =
  pa.`begin`()
  pa.ops.add(opCubic)
  pa.pts.add(c1)
  pa.pts.add(c2)
  pa.pts.add(p)
  pa.cur = p

proc quadTo(pa: var path; c, p: point) =
  ## Draws a quadratic curve, as the cubic curve it is.
  let a = pa.cur
  pa.cubicTo(point(x: a.x + 2.0 / 3 * (c.x - a.x),
                   y: a.y + 2.0 / 3 * (c.y - a.y)),
             point(x: p.x + 2.0 / 3 * (c.x - p.x),
                   y: p.y + 2.0 / 3 * (c.y - p.y)), p)

proc close(pa: var path) =
  if pa.open:
    pa.ops.add(opClose)
    pa.cur = pa.start
    pa.open = false

proc arcTo(pa: var path; rx, ry, rotation: float64; large, sweep: bool;
           p: point) =
  ## Draws an elliptical arc to p as cubic curves, converting SVG's
  ## endpoint parameters as appendix F.6 of SVG 1.1 says.
  let a = pa.cur
  if a == p:
    return
  var
    rx = abs(rx)
    ry = abs(ry)
  if rx == 0 or ry == 0:
    pa.lineTo(p)
    return
  let
    sn = sin(rotation * PI / 180)
    cs = cos(rotation * PI / 180)
  ## Half the chord, in the ellipse's axes.
  let
    hx = (a.x - p.x) / 2
    hy = (a.y - p.y) / 2
    x1 = cs * hx + sn * hy
    y1 = -sn * hx + cs * hy
  ## Radii too small to reach p grow.
  let l = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
  if l > 1:
    let sl = sqrt(l)
    rx *= sl
    ry *= sl
  let
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
  var k = 0.0
  if den > 0:
    k = sqrt(max(num / den, 0))
  if large == sweep:
    k = -k
  let
    cx1 = k * rx * y1 / ry
    cy1 = -k * ry * x1 / rx
    cx = cs * cx1 - sn * cy1 + (a.x + p.x) / 2
    cy = sn * cx1 + cs * cy1 + (a.y + p.y) / 2
    ux = (x1 - cx1) / rx
    uy = (y1 - cy1) / ry
    vx = (-x1 - cx1) / rx
    vy = (-y1 - cy1) / ry
  var theta = arctan2(uy, ux)
  var delta = arctan2(ux * vy - uy * vx, ux * vx + uy * vy)
  if not sweep and delta > 0:
    delta -= 2 * PI
  elif sweep and delta < 0:
    delta += 2 * PI
  ## Quarter turns at most per curve.
  let n = max(int(ceil(abs(delta) / (PI / 2) - 1e-7)), 1)
  let step = delta / float64(n)
  let t = 4.0 / 3 * tan(step / 4)
  proc `on`(ex, ey: float64): point =
    let
      x = ex * rx
      y = ey * ry
    point(x: cs * x - sn * y + cx, y: sn * x + cs * y + cy)
  for i in 0 ..< n:
    let
      s1 = sin(theta)
      c1 = cos(theta)
      s2 = sin(theta + step)
      c2 = cos(theta + step)
    var `end` = `on`(c2, s2)
    if i == n - 1:
      `end` = p
    pa.cubicTo(`on`(c1 - t * s1, s1 + t * c1),
               `on`(c2 + t * s2, s2 - t * c2), `end`)
    theta += step

## kappa places the control points of a quarter circle's cubic curve.
const kappa = 0.5522847498307936

proc ellipse(pa: var path; cx, cy, rx, ry: float64) =
  let
    kx = rx * kappa
    ky = ry * kappa
  pa.moveTo(point(x: cx + rx, y: cy))
  pa.cubicTo(point(x: cx + rx, y: cy + ky),
             point(x: cx + kx, y: cy + ry), point(x: cx, y: cy + ry))
  pa.cubicTo(point(x: cx - kx, y: cy + ry),
             point(x: cx - rx, y: cy + ky), point(x: cx - rx, y: cy))
  pa.cubicTo(point(x: cx - rx, y: cy - ky),
             point(x: cx - kx, y: cy - ry), point(x: cx, y: cy - ry))
  pa.cubicTo(point(x: cx + kx, y: cy - ry),
             point(x: cx + rx, y: cy - ky), point(x: cx + rx, y: cy))
  pa.close()

proc rect(pa: var path; x, y, w, h, rx, ry: float64) =
  ## Adds a rectangle with corners rounded rx by ry.
  if rx <= 0 or ry <= 0:
    pa.moveTo(point(x: x, y: y))
    pa.lineTo(point(x: x + w, y: y))
    pa.lineTo(point(x: x + w, y: y + h))
    pa.lineTo(point(x: x, y: y + h))
    pa.close()
    return
  let
    kx = rx * kappa
    ky = ry * kappa
    r = x + w
    b = y + h
  pa.moveTo(point(x: x + rx, y: y))
  pa.lineTo(point(x: r - rx, y: y))
  pa.cubicTo(point(x: r - rx + kx, y: y),
             point(x: r, y: y + ry - ky), point(x: r, y: y + ry))
  pa.lineTo(point(x: r, y: b - ry))
  pa.cubicTo(point(x: r, y: b - ry + ky),
             point(x: r - rx + kx, y: b), point(x: r - rx, y: b))
  pa.lineTo(point(x: x + rx, y: b))
  pa.cubicTo(point(x: x + rx - kx, y: b),
             point(x: x, y: b - ry + ky), point(x: x, y: b - ry))
  pa.lineTo(point(x: x, y: y + ry))
  pa.cubicTo(point(x: x, y: y + ry - ky),
             point(x: x + rx - kx, y: y), point(x: x + rx, y: y))
  pa.close()

proc isCommand(c: char): bool =
  case c
  of 'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q',
     'q', 'T', 't', 'A', 'a', 'Z', 'z':
    true
  else:
    false

proc parsePath(d: string): path =
  ## Parses path data up to its first error, as SVG asks.
  var p = scanner(s: d)
  var cmd, last: byte ## the command, and the last one in upper case
  var ctrl: point     ## the last control point, for S and T
  proc coord(): tuple[v: float64, ok: bool] =
    p.skipSep()
    p.number()
  proc pt(base: point): tuple[p: point, ok: bool] =
    let (x, okx) = coord()
    if not okx:
      return (point(), false)
    let (y, oky) = coord()
    (point(x: base.x + x, y: base.y + y), oky)
  proc flag(): tuple[v: bool, ok: bool] =
    p.skipSep()
    case char(p.peek())
    of '0':
      inc p.i
      (false, true)
    of '1':
      inc p.i
      (true, true)
    else:
      (false, false)
  while true:
    p.skipSpace()
    if p.`done`():
      break
    let c = p.peek()
    if isCommand(char(c)):
      cmd = c
      inc p.i
    elif cmd == 0 or cmd == byte('Z') or cmd == byte('z'):
      break ## numbers without a command
    if result.ops.len == 0 and cmd != byte('M') and cmd != byte('m'):
      break ## a path starts with a move
    var base: point
    if cmd >= byte('a'):
      base = result.cur
    let up = cmd and not byte(0x20)
    var ok = true
    case char(up)
    of 'M':
      let (a, ok2) = pt(base)
      ok = ok2
      if ok:
        result.moveTo(a)
        ## More coordinates are lines.
        cmd = byte('L') or (cmd and byte(0x20))
    of 'L':
      let (a, ok2) = pt(base)
      ok = ok2
      if ok:
        result.lineTo(a)
    of 'H':
      let (x, ok2) = coord()
      ok = ok2
      if ok:
        result.lineTo(point(x: base.x + x, y: result.cur.y))
    of 'V':
      let (y, ok2) = coord()
      ok = ok2
      if ok:
        result.lineTo(point(x: result.cur.x, y: base.y + y))
    of 'C', 'S':
      var c1 = result.cur
      if up == byte('C'):
        let (c, ok2) = pt(base)
        c1 = c
        ok = ok2
      elif last == byte('C') or last == byte('S'):
        c1 = point(x: 2 * result.cur.x - ctrl.x,
                   y: 2 * result.cur.y - ctrl.y)
      var c2, e: point
      if ok:
        let (q, ok2) = pt(base)
        c2 = q
        ok = ok2
      if ok:
        let (q, ok2) = pt(base)
        e = q
        ok = ok2
      if ok:
        result.cubicTo(c1, c2, e)
        ctrl = c2
    of 'Q', 'T':
      var c = result.cur
      if up == byte('Q'):
        let (q, ok2) = pt(base)
        c = q
        ok = ok2
      elif last == byte('Q') or last == byte('T'):
        c = point(x: 2 * result.cur.x - ctrl.x,
                  y: 2 * result.cur.y - ctrl.y)
      var e: point
      if ok:
        let (q, ok2) = pt(base)
        e = q
        ok = ok2
      if ok:
        result.quadTo(c, e)
        ctrl = c
    of 'A':
      var rx, ry, rot: float64
      var large, sweep: bool
      var e: point
      (rx, ok) = coord()
      if ok: (ry, ok) = coord()
      if ok: (rot, ok) = coord()
      if ok: (large, ok) = flag()
      if ok: (sweep, ok) = flag()
      if ok:
        let (q, ok2) = pt(base)
        e = q
        ok = ok2
      if ok:
        result.arcTo(rx, ry, rot, large, sweep, e)
    of 'Z':
      result.close()
    else:
      discard
    if not ok:
      break
    last = up

proc extrema(a, b, c, d: float64): seq[float64] =
  ## Where in (0, 1) a cubic curve's coordinate turns.
  let
    qa = -a + 3 * b - 3 * c + d
    qb = 2 * (a - 2 * b + c)
    qc = b - a
  var roots: array[2, float64]
  var n = 0
  if abs(qa) < 1e-12:
    if qb != 0:
      roots[0] = -qc / qb
      n = 1
  else:
    let disc = qb * qb - 4 * qa * qc
    if disc >= 0:
      let s = sqrt(disc)
      roots[0] = (-qb + s) / (2 * qa)
      roots[1] = (-qb - s) / (2 * qa)
      n = 2
  for i in 0 ..< n:
    let t = roots[i]
    if t > 0 and t < 1:
      result.add(t)

proc bezier(a, b, c, d: point; t: float64): point =
  let
    u = 1 - t
    k0 = u * u * u
    k1 = 3 * u * u * t
    k2 = 3 * u * t * t
    k3 = t * t * t
  point(x: k0 * a.x + k1 * b.x + k2 * c.x + k3 * d.x,
        y: k0 * a.y + k1 * b.y + k2 * c.y + k3 * d.y)

proc bounds(pa: path): tuple[b: box, found: bool] =
  ## The box around the path's geometry, in user units.
  var b: box
  var found = false
  proc add(p: point) =
    if not found:
      b = box(x: p.x, y: p.y, w: 0, h: 0)
      found = true
      return
    b = b.union(box(x: p.x, y: p.y, w: 0, h: 0))
  var cur: point
  var i = 0
  for op in pa.ops:
    case op
    of opMove:
      cur = pa.pts[i]
      inc i
    of opLine:
      add(cur)
      cur = pa.pts[i]
      add(cur)
      inc i
    of opCubic:
      let
        c1 = pa.pts[i]
        c2 = pa.pts[i + 1]
        e = pa.pts[i + 2]
      add(cur)
      add(e)
      for t in extrema(cur.x, c1.x, c2.x, e.x):
        add(bezier(cur, c1, c2, e, t))
      for t in extrema(cur.y, c1.y, c2.y, e.y):
        add(bezier(cur, c1, c2, e, t))
      cur = e
      i += 3
    of opClose:
      discard
  (b, found)

proc steps(a, b, c, d: point): int =
  ## How many lines follow a cubic curve, in pixels, to a tenth of a
  ## pixel: the error of n lines is at most 3/4 of the curve's largest
  ## second difference over n².
  let
    ddx = max(abs(a.x - 2 * b.x + c.x), abs(b.x - 2 * c.x + d.x))
    ddy = max(abs(a.y - 2 * b.y + c.y), abs(b.y - 2 * c.y + d.y))
    dd = hypot(ddx, ddy)
  if not (dd >= 0):
    return 1
  max(1, min(int(ceil(sqrt(7.5 * dd))), 1000))

type polys = object
  ## Polylines: polyline i is pts[starts[i]..<starts[i+1]], the last
  ## up to the end of pts.
  pts: seq[point]
  starts: seq[int]
  closed: seq[bool]
  ## `begin` is where the polyline being built begins, if building.
  `begin`: int
  building: bool

proc reset(ps: var polys) =
  ps.pts.setLen(0)
  ps.starts.setLen(0)
  ps.closed.setLen(0)
  ps.building = false

proc len(ps: polys): int = ps.starts.len

proc poly(ps: var polys; i: int): seq[point] =
  var last = ps.pts.len
  if i + 1 < ps.starts.len:
    last = ps.starts[i + 1]
  ps.pts[ps.starts[i] ..< last]

## `end` ends the polyline being built. One of a single point, a move
## with nothing drawn, is dropped.
proc `end`(ps: var polys; closed: bool) =
  if not ps.building:
    return
  ps.building = false
  if ps.pts.len - ps.`begin` < 2:
    ps.pts.setLen(ps.`begin`)
    return
  ps.starts.add(ps.`begin`)
  ps.closed.add(closed)

proc start(ps: var polys; p: point) =
  ## Begins a polyline at p, ending the one being built.
  ps.`end`(false)
  ps.`begin` = ps.pts.len
  ps.building = true
  ps.pts.add(p)

proc add(ps: var polys; p: point) =
  ps.pts.add(p)

proc transform(ps: var polys; m: matrix) =
  for i in 0 ..< ps.pts.len:
    ps.pts[i] = m.apply(ps.pts[i])

## maxPoints bounds the points of a flattened path: beyond it, curves
## are drawn as lines, and strokes are left out.
const maxPoints = 1 shl 20

proc flatten(pa: path; m: matrix; device: bool; `out`: var polys) =
  ## Adds the path's subpaths to out as polylines, with points enough
  ## that they stray less than a tenth of a pixel from its curves once
  ## transformed by m, the transform to pixels: in pixels with device,
  ## in user units otherwise.
  proc at(p: point): point =
    if device:
      return m.apply(p)
    p
  var cur: point
  var i = 0
  for op in pa.ops:
    case op
    of opMove:
      cur = pa.pts[i]
      inc i
      `out`.start(at(cur))
    of opLine:
      cur = pa.pts[i]
      inc i
      `out`.add(at(cur))
    of opCubic:
      let
        c1 = pa.pts[i]
        c2 = pa.pts[i + 1]
        e = pa.pts[i + 2]
      i += 3
      var n = 1
      if `out`.pts.len < maxPoints:
        n = steps(m.apply(cur), m.apply(c1), m.apply(c2), m.apply(e))
      for k in 1 ..< n:
        `out`.add(at(bezier(cur, c1, c2, e, float64(k) / float64(n))))
      `out`.add(at(e))
      cur = e
    of opClose:
      if `out`.building and `out`.pts.len - `out`.`begin` == 1:
        ## A subpath of no length, which round and square caps
        ## stroke.
        `out`.add(`out`.pts[`out`.`begin`])
      `out`.`end`(true)
  `out`.`end`(false)
