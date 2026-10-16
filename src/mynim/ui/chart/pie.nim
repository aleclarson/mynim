## Divides a circle among values and locates points within its slices.

import std/math

type
  PieSlice* = object
    ## An angular part of a pie, clockwise from twelve o'clock.
    start*, `end`*, pad*: float64

proc pie*(values: openArray[float64]; pad: float64): seq[PieSlice] =
  ## Divides a circle among positive values, leaving pad radians per slice.
  var total = 0.0
  for value in values:
    if value > 0:
      total += value
  let count = values.len.float64
  let gap = max(0.0, min(pad, 2 * PI / max(count, 1.0)))
  let scale = if total > 0: (2 * PI - count * gap) / total else: 0.0
  var angle = 0.0
  for value in values:
    var next = angle + gap
    if value > 0:
      next += value * scale
    result.add PieSlice(start: angle, `end`: next, pad: gap)
    angle = next

proc mid*(slice: PieSlice): float64 =
  ## Returns the angle halfway through a slice.
  (slice.start + slice.`end`) / 2

proc polar*(cx, cy, radius: float32; angle: float64): tuple[x, y: float32] =
  ## Returns a point at angle around center, with zero at twelve o'clock.
  result.x = cx + radius * float32(sin(angle))
  result.y = cy - radius * float32(cos(angle))

proc sliceAt*(slices: openArray[PieSlice]; x, y, inner, outer: float32):
    tuple[index: int, ok: bool] =
  ## Returns the slice under a point relative to the pie center.
  let distance = hypot(x.float64, y.float64).float32
  if distance < inner or distance > outer:
    return (0, false)
  var angle = arctan2(x.float64, -y.float64)
  if angle < 0:
    angle += 2 * PI
  for i, slice in slices:
    if angle >= slice.start and angle < slice.`end`:
      return (i, true)
  (0, false)
