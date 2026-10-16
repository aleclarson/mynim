## Numeric and band scales for native UI charts.

import std/[math, strutils]

type
  Span* = object
    ## A stretch along an axis, as fractions from its start to its end.
    lo*, hi*: float32

  Tick* = object
    ## A scale value and its position and label on an axis.
    at*: float32
    value*: float64
    label*: string

  TickFormat* = proc(value: float64): string {.closure.}

  Linear* = object
    ## Maps numbers from lo to hi along a plot.
    lo*, hi*: float64
    clamp*: bool
    format*: TickFormat

  Band* = object
    ## Divides a plot into one band for each label.
    labels*: seq[string]
    inner*, outer*: float32
    align*: float32

proc mid*(span: Span): float32 =
  ## Returns the middle of the span.
  (span.lo + span.hi) / 2

proc newLinear*(lo, hi: float64): Linear =
  ## Returns a scale from lo to hi.
  Linear(lo: lo, hi: hi)

proc extent*(values: varargs[float64]): tuple[lo, hi: float64] =
  ## Returns the smallest and largest values, or 0 and 1 when there are none.
  if values.len == 0:
    return (0, 1)
  result = (Inf, NegInf)
  for value in values:
    if classify(value) != fcNan:
      result.lo = min(result.lo, value)
      result.hi = max(result.hi, value)
  if result.lo > result.hi:
    result = (0, 1)

proc at*(scale: Linear; value: float64): float32 =
  ## Returns where value falls along the plot.
  if scale.hi == scale.lo:
    return 0.5'f32
  var fraction = (value - scale.lo) / (scale.hi - scale.lo)
  if scale.clamp:
    fraction = max(0.0, min(1.0, fraction))
  fraction.float32

proc span*(scale: Linear; a, b: float64): Span =
  ## Returns the stretch between a and b, as the height of a bar.
  Span(lo: scale.at(a), hi: scale.at(b))

proc invert*(scale: Linear; fraction: float32): float64 =
  ## Returns the value at a fraction along the plot.
  result = scale.lo + fraction.float64 * (scale.hi - scale.lo)
  if scale.clamp:
    result = max(min(scale.lo, scale.hi), min(max(scale.lo, scale.hi), result))

const
  e10 = sqrt(50.0)
  e5 = sqrt(10.0)
  e2 = sqrt(2.0)

proc tickSpec(lo, hi, count: float64):
    tuple[first, last, increment: float64] =
  let step = (hi - lo) / max(0.0, count)
  if step <= 0 or classify(step) in {fcNan, fcInf, fcNegInf}:
    return
  let power = floor(log10(step))
  let exponent = step / pow(10.0, power)
  var factor = 1.0
  if exponent >= e10:
    factor = 10
  elif exponent >= e5:
    factor = 5
  elif exponent >= e2:
    factor = 2

  if power < 0:
    result.increment = pow(10.0, -power) / factor
    result.first = round(lo * result.increment)
    result.last = round(hi * result.increment)
    if result.first / result.increment < lo:
      result.first += 1
    if result.last / result.increment > hi:
      result.last -= 1
    result.increment = -result.increment
  else:
    result.increment = pow(10.0, power) * factor
    result.first = round(lo / result.increment)
    result.last = round(hi / result.increment)
    if result.first * result.increment < lo:
      result.first += 1
    if result.last * result.increment > hi:
      result.last -= 1

  if result.last < result.first and count >= 0.5 and count < 2:
    return tickSpec(lo, hi, count * 2)

proc tickIncrement(lo, hi, count: float64): float64 =
  tickSpec(lo, hi, count).increment

proc tickStep(lo, hi, count: float64): float64 =
  let reverse = hi < lo
  let first = min(lo, hi)
  let last = max(lo, hi)
  result = tickIncrement(first, last, count)
  if result < 0:
    result = 1 / -result
  if reverse:
    result = -result

proc tickNumber(value: float64; decimals: int): string =
  result = formatFloat(value, ffDecimal, decimals)
  if decimals == 0 and result.endsWith("."):
    result.setLen(result.len - 1)

proc linearTicks(lo, hi, count: float64): seq[float64] =
  if count <= 0 or classify(lo) in {fcNan, fcInf, fcNegInf} or
      classify(hi) in {fcNan, fcInf, fcNegInf}:
    return
  if lo == hi:
    return @[lo]
  let reverse = hi < lo
  let firstValue = min(lo, hi)
  let lastValue = max(lo, hi)
  let (first, last, increment) = tickSpec(firstValue, lastValue, count)
  if last < first or classify(increment) in {fcNan, fcInf, fcNegInf}:
    return
  let n = int(last - first) + 1
  result = newSeq[float64](n)
  for i in 0 ..< n:
    let k = if reverse: n - 1 - i else: i
    if increment < 0:
      result[i] = (first + k.float64) / -increment
    else:
      result[i] = (first + k.float64) * increment

proc nice*(scale: Linear; count: int): Linear =
  ## Extends the domain to round values, aiming for about count ticks.
  result = scale
  if count <= 0 or scale.lo == scale.hi or
      classify(scale.lo) in {fcNan, fcInf, fcNegInf} or
      classify(scale.hi) in {fcNan, fcInf, fcNegInf}:
    return
  var lo = scale.lo
  var hi = scale.hi
  let reverse = hi < lo
  if reverse:
    swap(lo, hi)
  var previous = 0.0
  for _ in 0 ..< 10:
    let step = tickIncrement(lo, hi, count.float64)
    if step == previous:
      break
    if step > 0:
      lo = floor(lo / step) * step
      hi = ceil(hi / step) * step
    elif step < 0:
      lo = ceil(lo * step) / step
      hi = floor(hi * step) / step
    else:
      return
    previous = step
  if reverse:
    swap(lo, hi)
  result.lo = lo
  result.hi = hi

proc ticks*(scale: Linear; count: int): seq[Tick] =
  ## Returns about count rounded tick values within the domain.
  let values = linearTicks(scale.lo, scale.hi, count.float64)
  var format = scale.format
  if format == nil:
    let step = abs(tickStep(scale.lo, scale.hi, count.float64))
    var decimals = 0
    if step > 0 and step < 1:
      decimals = max(0, int(-floor(log10(step) + 1e-9)))
      let magnitude = pow(10.0, decimals.float64)
      if step * magnitude != round(step * magnitude):
        inc decimals
    format = proc(value: float64): string =
      let normalized = if value == 0: 0.0 else: value
      tickNumber(normalized, decimals)
  for value in values:
    result.add Tick(at: scale.at(value), value: value, label: format(value))

proc newBand*(labels: varargs[string]): Band =
  ## Returns a band scale with no padding between its labels.
  Band(labels: @labels, align: 0.5'f32)

proc padding*(scale: Band; inner, outer: float32): Band =
  ## Sets the padding as fractions of a band's step.
  result = scale
  result.inner = max(0'f32, min(1'f32, inner))
  result.outer = max(0'f32, outer)

proc step(scale: Band): tuple[distance, start: float32] =
  let n = scale.labels.len.float32
  result.distance = 1 / max(1'f32, n - scale.inner + 2 * scale.outer)
  result.start = (1 - result.distance * (n - scale.inner)) * scale.align

proc width*(scale: Band): float32 =
  ## Returns the width of a band as a fraction of the plot.
  scale.step().distance * (1 - scale.inner)

proc band*(scale: Band; index: int): Span =
  ## Returns the stretch of the indexed band.
  let (distance, start) = scale.step()
  result.lo = start + distance * index.float32
  result.hi = result.lo + scale.width()

proc at*(scale: Band; index: int): float32 =
  ## Returns the middle of the indexed band.
  scale.band(index).mid()

proc index*(scale: Band; fraction: float32): tuple[index: int, ok: bool] =
  ## Returns the band whose step contains fraction.
  let (distance, start) = scale.step()
  if scale.labels.len == 0:
    return (0, false)
  let position = (fraction - start + distance * scale.inner / 2) / distance
  if position < 0 or position >= scale.labels.len.float32:
    return (0, false)
  (int(position), true)

proc ticks*(scale: Band): seq[Tick] =
  ## Returns a tick at the center of each band, labeled with its value.
  for i, label in scale.labels:
    result.add Tick(at: scale.at(i), value: i.float64, label: label)
