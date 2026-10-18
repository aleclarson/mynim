## Vector paths and their antialiased coverage masks.

import mynim/internal/vec as vectorRaster

type
  PathCommandKind = enum
    pathMove, pathLine, pathQuad, pathCubic, pathClose

  PathCommand = object
    kind: PathCommandKind
    points: array[3, array[2, float32]]

  Path* = ref object
    commands: seq[PathCommand]
    trimFrom, trimTo: float32
    trimmed: bool

  FlatPath = object
    points: seq[array[2, float32]]
    starts: seq[int]
    closed: seq[bool]
    trimmed: bool
    kept: float32

  Painter* = object
    ## A drawing surface supplied to an element's draw callback.
    frame: scene.Scene
    textSystem: textStack.System
    theme: Theme
    localeTag: string
    root: Rect
    scale, opacity: float32
    gpuFastPaths: bool

proc newPath*(): Path =
  ## Creates an empty vector path.
  new(result)
  result.trimTo = 1

proc moveTo*(path: Path; x, y: float32): Path =
  path.commands.add PathCommand(kind: pathMove,
    points: [[x, y], [0, 0], [0, 0]])
  path

proc lineTo*(path: Path; x, y: float32): Path =
  path.commands.add PathCommand(kind: pathLine,
    points: [[x, y], [0, 0], [0, 0]])
  path

proc quadTo*(path: Path; cx, cy, x, y: float32): Path =
  path.commands.add PathCommand(kind: pathQuad,
    points: [[cx, cy], [x, y], [0, 0]])
  path

proc cubeTo*(path: Path; c1x, c1y, c2x, c2y, x, y: float32): Path =
  path.commands.add PathCommand(kind: pathCubic,
    points: [[c1x, c1y], [c2x, c2y], [x, y]])
  path

proc close*(path: Path): Path =
  path.commands.add PathCommand(kind: pathClose)
  path

proc circle*(path: Path; cx, cy, radius: float32): Path =
  const k = 0.5522847498'f32
  discard path.moveTo(cx + radius, cy)
    .cubeTo(cx + radius, cy + radius * k, cx + radius * k, cy + radius,
      cx, cy + radius)
    .cubeTo(cx - radius * k, cy + radius, cx - radius, cy + radius * k,
      cx - radius, cy)
    .cubeTo(cx - radius, cy - radius * k, cx - radius * k, cy - radius,
      cx, cy - radius)
    .cubeTo(cx + radius * k, cy - radius, cx + radius, cy - radius * k,
      cx + radius, cy)
  path.close()

proc trim*(path: Path; start, stop: float32): Path =
  ## Keeps a section of the path's total length, across its subpaths.
  if classify(start) in {fcNan, fcInf, fcNegInf} or
      classify(stop) in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "ui: path trim values must be finite")
  path.trimFrom = max(0'f32, min(start, 1'f32))
  path.trimTo = max(0'f32, min(stop, 1'f32))
  path.trimmed = true
  path

proc distance(a, b: array[2, float32]): float32 =
  float32(hypot(float64(a[0] - b[0]), float64(a[1] - b[1])))

proc curveSteps(a, b, c, d: array[2, float32]): int =
  let length = distance(a, b) + distance(b, c) + distance(c, d)
  max(2, min(int(sqrt(float64(length)) * 2), 64))

proc flatPolys(path: FlatPath): int = path.starts.len

proc poly(path: FlatPath; index: int): seq[array[2, float32]] =
  let pastLast = if index + 1 < path.starts.len:
      path.starts[index + 1]
    else:
      path.points.len
  path.points[path.starts[index] ..< pastLast]

proc trim(flat: var FlatPath; start, stop: float32) =
  let oldPoints = flat.points
  let oldStarts = flat.starts
  let oldClosed = flat.closed
  flat.points = @[]
  flat.starts = @[]
  flat.closed = @[]
  let segments = proc(index: int): int =
    let count = (if index + 1 < oldStarts.len:
        oldStarts[index + 1]
      else:
        oldPoints.len) - oldStarts[index]
    count - 1 + int(oldClosed[index])

  var total = 0'f32
  for i in 0 ..< oldStarts.len:
    let start = oldStarts[i]
    let count = (if i + 1 < oldStarts.len: oldStarts[i + 1]
      else: oldPoints.len) - start
    for j in 0 ..< segments(i):
      total += distance(oldPoints[start + j], oldPoints[start + ((j + 1) mod count)])

  let low = start * total
  let high = stop * total
  flat.trimmed = true
  flat.kept = max(high - low, 0'f32)
  var at = 0'f32
  for i in 0 ..< oldStarts.len:
    var open = false
    let start = oldStarts[i]
    let count = (if i + 1 < oldStarts.len: oldStarts[i + 1]
      else: oldPoints.len) - start
    for j in 0 ..< segments(i):
      let a = oldPoints[start + j]
      let b = oldPoints[start + ((j + 1) mod count)]
      let length = distance(a, b)
      let partStart = max(low, at)
      let partEnd = min(high, at + length)
      at += length
      if length == 0 or partStart >= partEnd:
        open = open and length == 0
        continue
      let k0 = (partStart - (at - length)) / length
      let k1 = (partEnd - (at - length)) / length
      if not open:
        flat.starts.add flat.points.len
        flat.closed.add false
        flat.points.add [a[0] + (b[0] - a[0]) * k0,
                         a[1] + (b[1] - a[1]) * k0]
      flat.points.add [a[0] + (b[0] - a[0]) * k1,
                       a[1] + (b[1] - a[1]) * k1]
      open = k1 >= 1

proc flatten(path: Path; scale: float32): FlatPath =
  var begin = 0
  var isClosed = false
  var origin, pen: array[2, float32]
  template flush() =
    if result.points.len - begin > 1:
      result.starts.add begin
      result.closed.add isClosed
    else:
      result.points.setLen(begin)
    begin = result.points.len
    isClosed = false

  for command in path.commands:
    var points = command.points
    for point in points.mitems:
      point[0] *= scale
      point[1] *= scale
    case command.kind
    of pathMove:
      flush()
      origin = points[0]
      pen = origin
      result.points.add pen
    of pathLine:
      pen = points[0]
      result.points.add pen
    of pathQuad:
      let count = curveSteps(pen, points[0], points[1], points[1])
      for i in 1 .. count:
        let t = i.float32 / count.float32
        let u = 1 - t
        result.points.add [u*u*pen[0] + 2*u*t*points[0][0] + t*t*points[1][0],
                           u*u*pen[1] + 2*u*t*points[0][1] + t*t*points[1][1]]
      pen = points[1]
    of pathCubic:
      let count = curveSteps(pen, points[0], points[1], points[2])
      for i in 1 .. count:
        let t = i.float32 / count.float32
        let u = 1 - t
        let a = u*u*u
        let b = 3*u*u*t
        let c = 3*u*t*t
        let d = t*t*t
        result.points.add [a*pen[0] + b*points[0][0] + c*points[1][0] + d*points[2][0],
                           a*pen[1] + b*points[0][1] + c*points[1][1] + d*points[2][1]]
      pen = points[2]
    of pathClose:
      if result.points.len > begin:
        isClosed = true
        flush()
        pen = origin
  flush()
  if path.trimmed:
    result.trim(path.trimFrom, path.trimTo)

proc fillMask(flat: FlatPath; x0, y0: float32; width, height: int): seq[byte] =
  var raster: vectorRaster.Rasterizer
  raster.reset(width, height)
  for i in 0 ..< flat.flatPolys:
    let points = flat.poly(i)
    raster.moveTo(points[0][0] - x0, points[0][1] - y0)
    for point in points[1 ..^ 1]:
      raster.lineTo(point[0] - x0, point[1] - y0)
    raster.closePath()
  result = newSeq[byte](width * height)
  raster.mask(result, width)

proc circleMask(raster: var vectorRaster.Rasterizer; cx, cy,
                radius: float32)
proc offsetLoop(raster: var vectorRaster.Rasterizer;
                points: seq[array[2, float32]]; halfWidth: float32)

proc strokeMask(flat: FlatPath; x0, y0, halfWidth: float32;
                width, height: int): seq[byte] =
  # A stroke is a filled outline with round joins and caps.
  var raster: vectorRaster.Rasterizer
  raster.reset(width, height)
  for i in 0 ..< flat.flatPolys:
    var points: seq[array[2, float32]]
    for point in flat.poly(i):
      let moved = [point[0] - x0, point[1] - y0]
      if points.len == 0 or points[^1] != moved:
        points.add moved
    if flat.closed[i] and points.len > 2 and points[0] == points[^1]:
      points.setLen(points.len - 1)
    case points.len
    of 0:
      discard
    of 1:
      raster.circleMask(points[0][0], points[0][1], halfWidth)
    else:
      if flat.closed[i] and points.len > 2:
        raster.offsetLoop(points, halfWidth)
        var reversed = points
        reversed.reverse()
        raster.offsetLoop(reversed, halfWidth)
      else:
        for k in countdown(points.len - 2, 1):
          points.add points[k]
        raster.offsetLoop(points, halfWidth)
  result = newSeq[byte](width * height)
  raster.mask(result, width)

proc circleMask(raster: var vectorRaster.Rasterizer; cx, cy, radius: float32) =
  const k = 0.5522847498'f32
  raster.moveTo(cx + radius, cy)
  raster.cubeTo(cx + radius, cy + radius*k, cx + radius*k, cy + radius, cx, cy + radius)
  raster.cubeTo(cx - radius*k, cy + radius, cx - radius, cy + radius*k, cx - radius, cy)
  raster.cubeTo(cx - radius, cy - radius*k, cx - radius*k, cy - radius, cx, cy - radius)
  raster.cubeTo(cx + radius*k, cy - radius, cx + radius, cy - radius*k, cx + radius, cy)
  raster.closePath()

proc offsetLoop(raster: var vectorRaster.Rasterizer;
                points: seq[array[2, float32]]; halfWidth: float32) =
  let count = points.len
  if count < 2:
    return
  proc normal(index: int): tuple[dx, dy, nx, ny: float32] =
    let a = points[index]
    let b = points[(index + 1) mod count]
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let length = float32(hypot(float64(dx), float64(dy)))
    result = (dx / length, dy / length, -dy / length * halfWidth,
      dx / length * halfWidth)
  var (dx, dy, nx, ny) = normal(0)
  raster.moveTo(points[0][0] + nx, points[0][1] + ny)
  for k in 0 ..< count:
    let b = points[(k + 1) mod count]
    raster.lineTo(b[0] + nx, b[1] + ny)
    let (ex, ey, mx, my) = normal((k + 1) mod count)
    let cross = dx * ey - dy * ex
    let dot = dx * ex + dy * ey
    if cross > 0:
      raster.lineTo(b[0], b[1])
      raster.lineTo(b[0] + mx, b[1] + my)
    elif cross < 0 or dot < 0:
      let start = arctan2(float64(ny), float64(nx))
      var turn = arctan2(float64(cross), float64(dot))
      if cross == 0:
        turn = -PI
      let denominator = 2 * arccos(max(1 - 0.02 / float64(halfWidth), -1.0))
      let steps = int(ceil(abs(turn) / denominator))
      for s in 1 .. steps:
        let angle = start + turn * s.float64 / steps.float64
        raster.lineTo(b[0] + halfWidth * float32(cos(angle)),
          b[1] + halfWidth * float32(sin(angle)))
    (dx, dy, nx, ny) = (ex, ey, mx, my)
  raster.closePath()

proc capFade(flat: FlatPath; width: float32): float32 =
  if not flat.trimmed or width <= 0 or flat.kept >= width:
    return 1
  flat.kept / width
