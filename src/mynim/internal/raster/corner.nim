## corner.go: continuous corners — Core Animation's, computed as its
## shaders compute them (QuartzCore's supercircle_sdf).

const contExtent = 1.528665'f32

type contCorner = object
  ## A continuous corner of radius r, whose curve leaves the edges e
  ## from the corner, blended toward a quarter circle by cx along its
  ## horizontal edge and cy along its vertical one; eff is where the
  ## curve's box ends as clamped.
  r, e, eff, cx, cy: float32

proc newContCorner(r, rh, rv, w, h: float32): contCorner =
  ## The corner of radius r of a rectangle w×h whose horizontal edge it
  ## shares with a corner of radius rh, and its vertical one with one of
  ## radius rv.
  let clamp = proc(side, ra, rb: float32): float32 =
    clamp01((contExtent - side / (ra + rb)) / (contExtent - 1))
  result = contCorner(r: r, e: contExtent * r, cx: clamp(w, r, rh),
                      cy: clamp(h, r, rv))
  result.eff = result.e + (r - result.e) * max(result.cx, result.cy)

proc dist(c: contCorner, u, v: float32): float32 =
  ## The corner's value at the point u inside its vertical edge and v
  ## inside its horizontal one: about the signed distance to its edge
  ## near it, positive outside.
  let ax = max(0'f32, 1 - u / c.e)
  let ay = max(0'f32, 1 - v / c.e)
  let l = sqrt(ax * ax + ay * ay)
  let hi = max(ax, ay)
  let lo = min(ax, ay)
  var rho = 0'f32
  if hi > 0:
    rho = min(lo / hi, 1)
  let p = (((-0.926054 * rho + 3.15601) * rho - 3.64122) * rho + 1.26803) *
    rho + 0.268531
  let f1 = l + 1 - 1 / (1 - rho * rho * min(l, 1) * p)
  let qx = max(0'f32, ax * contExtent - (contExtent - 1))
  let qy = max(0'f32, ay * contExtent - (contExtent - 1))
  let f2 = sqrt(qx * qx + qy * qy) * 0.654166 + 0.345834
  var s = -1'f32
  if ay > ax:
    s = 1
  let w = clamp01(0.5 - s + s * rho)
  let fx = f1 + (f2 - f1) * c.cx
  let fy = f1 + (f2 - f1) * c.cy
  let f = fx + (fy - fx) * w
  min(max(c.eff - u, c.eff - v), 0) + c.e * (f - 1)

proc inset(c: contCorner, v: float32): tuple[at, bound: float32] =
  ## How far inside its vertical edge the corner's edge is v inside its
  ## horizontal one, and a bound at least as far: where dist is 0,
  ## found by regula falsi (Illinois).
  if v >= c.e or c.r <= 0:
    return (0'f32, 0'f32)
  let circle = proc(r: float32): float32 =
    if v >= r: 0'f32 else: r - sqrt(v * (2 * r - v))
  var lo = circle(c.r)
  var hi = circle(c.e)
  var dlo = c.dist(lo, v)
  var dhi = c.dist(hi, v)
  if dlo <= 0:
    return (lo, lo)
  if dhi >= 0:
    return (hi, hi)
  var side = 0
  for _ in 0 ..< 5:
    let m = (lo * dhi - hi * dlo) / (dhi - dlo)
    let dm = c.dist(m, v)
    if dm > 0:
      lo = m
      dlo = dm
      if side == 1:
        dhi /= 2
      side = 1
    else:
      hi = m
      dhi = dm
      if side == -1:
        dlo /= 2
      side = -1
  ((lo * dhi - hi * dlo) / (dhi - dlo), hi)
