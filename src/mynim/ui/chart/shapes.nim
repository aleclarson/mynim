## Paths for lines, areas, and pie sectors in native charts.

import std/math
import mynim/ui as ui
import ./pie

type
  Curve* = enum
    ## Joins data points with straight lines.
    curveLinear
    ## Uses monotone cubic interpolation that stays within neighboring values.
    curveMonotone
    ## Holds each value until the following point.
    curveStepAfter
    ## Takes each value from the preceding point.
    curveStepBefore
    ## Changes values halfway between neighboring points.
    curveStep

  Point = array[2, float32]

  CurveSegment = object
    cubic: bool
    control1, control2, to: Point

proc x*(rect: ui.Rect; fraction: float32): float32 =
  ## Maps a fraction to the x coordinate of a plot rectangle.
  rect.x + fraction * rect.w

proc y*(rect: ui.Rect; fraction: float32): float32 =
  ## Maps an upward-growing fraction to the y coordinate of a plot rectangle.
  rect.y + (1 - fraction) * rect.h

proc abs(value: float32): float32 =
  if value < 0: -value else: value

proc monotoneSlope(a, b, c: Point): float32 =
  let h0 = b[0] - a[0]
  let h1 = c[0] - b[0]
  if h0 == 0 or h1 == 0:
    return 0
  let s0 = (b[1] - a[1]) / h0
  let s1 = (c[1] - b[1]) / h1
  let p = (s0 * h1 + s1 * h0) / (h0 + h1)
  if (s0 < 0) != (s1 < 0) or s0 == 0 or s1 == 0:
    return 0
  let m = min(min(abs(s0), abs(s1)), 0.5'f32 * abs(p))
  if s0 < 0: -2 * m else: 2 * m

proc endSlope(a, b: Point; neighbor: float32): float32 =
  let dx = b[0] - a[0]
  if dx == 0:
    return neighbor
  (3 * (b[1] - a[1]) / dx - neighbor) / 2

proc curveSegments(points: openArray[Point]; curve: Curve): seq[CurveSegment] =
  let count = points.len
  if curve == curveMonotone and count >= 3:
    var slopes = newSeq[float32](count)
    for i in 1 ..< count - 1:
      slopes[i] = monotoneSlope(points[i - 1], points[i], points[i + 1])
    slopes[0] = endSlope(points[0], points[1], slopes[1])
    slopes[count - 1] = endSlope(points[count - 2], points[count - 1],
      slopes[count - 2])
    for i in 1 ..< count:
      let first = points[i - 1]
      let last = points[i]
      let dx = (last[0] - first[0]) / 3
      result.add CurveSegment(cubic: true,
        control1: [first[0] + dx, first[1] + dx * slopes[i - 1]],
        control2: [last[0] - dx, last[1] - dx * slopes[i]], to: last)
    return

  if curve in {curveStepAfter, curveStepBefore, curveStep}:
    for i in 1 ..< count:
      let first = points[i - 1]
      let last = points[i]
      case curve
      of curveStepAfter:
        result.add CurveSegment(to: [last[0], first[1]])
      of curveStepBefore:
        result.add CurveSegment(to: [first[0], last[1]])
      of curveStep:
        let middle = (first[0] + last[0]) / 2
        result.add CurveSegment(to: [middle, first[1]])
        result.add CurveSegment(to: [middle, last[1]])
      else:
        discard
      result.add CurveSegment(to: last)
  else:
    for i in 1 ..< count:
      result.add CurveSegment(to: points[i])

proc addSegments(path: ui.Path; segments: openArray[CurveSegment]) =
  for segment in segments:
    if segment.cubic:
      discard path.cubeTo(segment.control1[0], segment.control1[1],
        segment.control2[0], segment.control2[1], segment.to[0], segment.to[1])
    else:
      discard path.lineTo(segment.to[0], segment.to[1])

proc defined(xs, ys: openArray[float32]; index: int): bool =
  classify(xs[index]) != fcNan and classify(ys[index]) != fcNan

proc definedArea(xs, lowValues, highValues: openArray[float32];
                 index: int): bool =
  let lowValue = if lowValues.len == 0: 0'f32 else: lowValues[index]
  classify(xs[index]) != fcNan and classify(highValues[index]) != fcNan and
    classify(lowValue) != fcNan

proc line*(rect: ui.Rect; xs, ys: openArray[float32];
           curve = curveLinear): ui.Path =
  ## Builds the path of a line; NaN coordinates split it into subpaths.
  result = ui.newPath()
  let count = min(xs.len, ys.len)
  var index = 0
  while index < count:
    while index < count and not defined(xs, ys, index):
      inc index
    let start = index
    while index < count and defined(xs, ys, index):
      inc index
    if index <= start:
      continue
    var points = newSeq[Point](index - start)
    for i in start ..< index:
      points[i - start] = [rect.x(xs[i]), rect.y(ys[i])]
    discard result.moveTo(points[0][0], points[0][1])
    result.addSegments(curveSegments(points, curve))

proc area*(rect: ui.Rect; xs, lowValues, highValues: openArray[float32];
           curve = curveLinear): ui.Path =
  ## Builds a closed area between two lines; an empty lower line uses y=0.
  result = ui.newPath()
  var count = min(xs.len, highValues.len)
  if lowValues.len > 0:
    count = min(count, lowValues.len)
  var index = 0
  while index < count:
    while index < count and not definedArea(xs, lowValues, highValues, index):
      inc index
    let start = index
    while index < count and definedArea(xs, lowValues, highValues, index):
      inc index
    if index <= start:
      continue
    var top = newSeq[Point](index - start)
    var bottom = newSeq[Point](index - start)
    for i in start ..< index:
      let lowValue = if lowValues.len == 0: 0'f32 else: lowValues[i]
      top[i - start] = [rect.x(xs[i]), rect.y(highValues[i])]
      bottom[i - start] = [rect.x(xs[i]), rect.y(lowValue)]
    discard result.moveTo(top[0][0], top[0][1])
    result.addSegments(curveSegments(top, curve))
    let last = bottom[^1]
    discard result.lineTo(last[0], last[1])
    let segments = curveSegments(bottom, curve)
    for i in countdown(segments.len - 1, 0):
      let fromPoint = if i > 0: segments[i - 1].to else: bottom[0]
      if segments[i].cubic:
        discard result.cubeTo(segments[i].control2[0], segments[i].control2[1],
          segments[i].control1[0], segments[i].control1[1],
          fromPoint[0], fromPoint[1])
      else:
        discard result.lineTo(fromPoint[0], fromPoint[1])
    discard result.close()

proc polarPoint(cx, cy, radius: float32; angle: float64): Point =
  let (x, y) = pie.polar(cx, cy, radius, angle)
  [x, y]

proc arc(path: ui.Path; cx, cy, radius: float32; start, stop: float64) =
  let count = int(ceil(abs(stop - start) / (PI / 2)))
  if count == 0:
    return
  let step = (stop - start) / count.float64
  let factor = float32(4.0 / 3 * tan(step / 4))
  for i in 0 ..< count:
    let a0 = start + i.float64 * step
    let a1 = start + (i + 1).float64 * step
    let first = polarPoint(cx, cy, radius, a0)
    let last = polarPoint(cx, cy, radius, a1)
    let tangent0 = [float32(cos(a0)), float32(sin(a0))]
    let tangent1 = [float32(cos(a1)), float32(sin(a1))]
    discard path.cubeTo(first[0] + factor * radius * tangent0[0],
      first[1] + factor * radius * tangent0[1],
      last[0] - factor * radius * tangent1[0],
      last[1] - factor * radius * tangent1[1], last[0], last[1])

proc sector*(cx, cy, inner, outer: float32; slice: PieSlice): ui.Path =
  ## Builds a pie wedge or donut sector with the slice's gap.
  result = ui.newPath()
  if outer <= 0 or slice.`end` <= slice.start:
    return
  let inner = max(0'f32, min(inner, outer))
  let gap = slice.pad * sqrt(float64(inner * inner + outer * outer))
  proc angles(radius: float32): tuple[start, stop: float64] =
    var start = slice.start
    var stop = slice.`end`
    if gap > 0 and radius > 0:
      let inset = arcsin(min(1.0, gap / 2 / radius.float64))
      if stop - start > 2 * inset:
        return (start + inset, stop - inset)
      let middle = (start + stop) / 2
      return (middle, middle)
    (start, stop)

  let (start, stop) = angles(outer)
  let first = polarPoint(cx, cy, outer, start)
  discard result.moveTo(first[0], first[1])
  result.arc(cx, cy, outer, start, stop)
  if inner > 0:
    let (innerStart, innerStop) = angles(inner)
    let innerPoint = polarPoint(cx, cy, inner, innerStop)
    discard result.lineTo(innerPoint[0], innerPoint[1])
    result.arc(cx, cy, inner, innerStop, innerStart)
  else:
    discard result.lineTo(cx, cy)
  discard result.close()
