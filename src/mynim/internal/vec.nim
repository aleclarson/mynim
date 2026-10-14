## Package vec rasterizes vector paths (lines, quadratic and cubic
## Bézier curves) into anti-aliased coverage masks, with the signed
## area accumulation of font-rs: every edge adds the area it covers to
## the cells it crosses, and a running sum along each row gives the
## coverage (internal/vec).

import std/math

type Rasterizer* = object
  ## Accumulates the area of a path's edges. Reuse it with reset.
  w, h: int
  acc: seq[float32]
  penX, penY: float32
  firstX, firstY: float32
  open: bool

proc reset*(z: var Rasterizer; w, h: int) =
  ## Prepares the rasterizer for a w×h mask.
  z.w = w
  z.h = h
  if z.acc.len < w * h:
    z.acc = newSeq[float32](w * h)
  else:
    z.acc.setLen(w * h)
    for i in 0 ..< w * h:
      z.acc[i] = 0
  z.open = false

proc lineTo*(z: var Rasterizer; bx, by: float32) {.gcsafe.}

proc closePath*(z: var Rasterizer) =
  ## Draws a line back to the start of the contour.
  if z.open:
    z.lineTo(z.firstX, z.firstY)
    z.open = false

proc moveTo*(z: var Rasterizer; x, y: float32) =
  ## Starts a contour, closing the previous one.
  z.closePath()
  z.firstX = x
  z.firstY = y
  z.penX = x
  z.penY = y
  z.open = true

proc quadTo*(z: var Rasterizer; bx, by, cx, cy: float32) =
  ## Draws a quadratic Bézier curve with control point (bx, by).
  let
    ax = z.penX
    ay = z.penY
    dx = ax - 2 * bx + cx
    dy = ay - 2 * by + cy
    n = max(1, min(int(ceil(sqrt(sqrt(dx * dx + dy * dy) * 2))), 100))
  for i in 1 .. n:
    let
      t = float32(i) / float32(n)
      u = 1 - t
    z.lineTo(u * u * ax + 2 * u * t * bx + t * t * cx,
             u * u * ay + 2 * u * t * by + t * t * cy)

proc cubeTo*(z: var Rasterizer; bx, by, cx, cy, dx, dy: float32) =
  ## Draws a cubic Bézier curve with control points (bx, by) and (cx,
  ## cy).
  let
    ax = z.penX
    ay = z.penY
    ex = ax - 2 * bx + cx
    ey = ay - 2 * by + cy
    fx = bx - 2 * cx + dx
    fy = by - 2 * cy + dy
    dd = max(ex * ex + ey * ey, fx * fx + fy * fy)
    n = max(1, min(int(ceil(sqrt(sqrt(dd) * 3))), 100))
  for i in 1 .. n:
    let
      t = float32(i) / float32(n)
      u = 1 - t
      a = u * u * u
      b = 3 * u * u * t
      c = 3 * u * t * t
      d = t * t * t
    z.lineTo(a * ax + b * bx + c * cx + d * dx,
             a * ay + b * by + c * cy + d * dy)

proc add(row: var openArray[float32]; x: int; v: float32) =
  ## Adds v at x; area left of the mask counts at its first pixel and
  ## area right of it is dropped, since rows are summed from the left.
  var x = x
  if x < 0:
    x = 0
  if x < row.len:
    row[x] += v

proc lineTo*(z: var Rasterizer; bx, by: float32) =
  ## Draws a line from the pen.
  var
    ax = z.penX
    ay = z.penY
    bx = bx
    by = by
  z.penX = bx
  z.penY = by
  var dir = 1'f32
  if ay > by:
    dir = -1
    swap(ax, bx)
    swap(ay, by)
  if by - ay <= 0 or by <= 0 or ay >= float32(z.h):
    return
  let dxdy = (bx - ax) / (by - ay)
  var x = ax
  var y0 = int(floor(ay))
  var y1 = int(ceil(by))
  if y0 < 0:
    ## Skip the rows above the mask.
    x += dxdy * (0 - ay)
    ay = 0
    y0 = 0
  y1 = min(y1, z.h)
  let w = z.w
  for y in y0 ..< y1:
    let fy = float32(y)
    let dy = min(fy + 1, by) - max(fy, ay)
    let xNext = x + dy * dxdy
    let d = dy * dir
    var x0 = x
    var x1 = xNext
    if x0 > x1:
      swap(x0, x1)
    let
      x0i = int(floor(x0))
      x0f = float32(x0i)
      x1i = int(ceil(x1))
      x1c = float32(x1i)
    if x1i <= x0i + 1:
      let xmf = 0.5 * (x + xNext) - x0f
      add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x0i, d - d * xmf)
      add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x0i + 1, d * xmf)
    else:
      let s = 1 / (x1 - x0)
      let x0fr = x0 - x0f
      let omx = 1 - x0fr
      let a0 = 0.5 * s * omx * omx
      let x1fr = x1 - x1c + 1
      let am = 0.5 * s * x1fr * x1fr
      add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x0i, d * a0)
      if x1i == x0i + 2:
        add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x0i + 1,
            d * (1 - a0 - am))
      else:
        let a1 = s * (1.5 - x0fr)
        add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x0i + 1,
            d * (a1 - a0))
        for xi in x0i + 2 ..< x1i - 1:
          add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), xi, d * s)
        let a2 = a1 + s * float32(x1i - x0i - 3)
        add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x1i - 1,
            d * (1 - a2 - am))
      add(z.acc.toOpenArray(y * w, (y + 1) * w - 1), x1i, d * am)
    x = xNext

proc mask*(z: var Rasterizer; dst: var openArray[byte]; stride: int) =
  ## Writes the coverage of the accumulated path (non-zero winding) as
  ## one byte per pixel into dst, rows of stride bytes.
  z.closePath()
  for y in 0 ..< z.h:
    var acc = 0'f32
    for x in 0 ..< z.w:
      acc += z.acc[y * z.w + x]
      var a = acc
      if a < 0:
        a = -a
      if a > 1:
        a = 1
      dst[y * stride + x] = uint8(a * 255 + 0.5)

proc maskEvenOdd*(z: var Rasterizer; dst: var openArray[byte];
                  stride: int) =
  ## Mask with the even-odd rule: what the path's contours cover an
  ## odd number of times is inside it.
  z.closePath()
  for y in 0 ..< z.h:
    var acc = 0'f32
    for x in 0 ..< z.w:
      acc += z.acc[y * z.w + x]
      var a = acc
      if a < 0:
        a = -a
      ## Fold the winding number: 0, 2, 4… are outside, 1, 3, 5…
      ## inside, and coverage in between ramps.
      a -= 2 * float32(int(a / 2))
      if a > 1:
        a = 2 - a
      dst[y * stride + x] = uint8(a * 255 + 0.5)
