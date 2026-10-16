## Stacks numeric series for stacked bars and areas.

import std/math

type
  Segment* = object
    ## A value's stretch in a stack.
    lo*, hi*: float64

  Stacking* = enum
    ## Piles values from zero, with negative values extending down.
    stackStandard
    ## Piles values as shares of the absolute total.
    stackNormalized
    ## Centers the series around zero for a streamgraph.
    stackCenter

proc stack*(series: openArray[seq[float64]]; how: Stacking): seq[seq[Segment]] =
  ## Returns each value's lower and upper bounds in its column's stack.
  var columnCount = 0
  for values in series:
    columnCount = max(columnCount, values.len)

  result = newSeq[seq[Segment]](series.len)
  for i in 0 ..< series.len:
    result[i] = newSeq[Segment](columnCount)

  for column in 0 ..< columnCount:
    var up, down, total = 0.0
    for s, values in series:
      let value = if column < values.len and classify(values[column]) != fcNan:
        values[column]
      else:
        0.0
      total += abs(value)
      if how == stackCenter:
        result[s][column] = Segment(lo: up, hi: up + value)
        up += value
      elif value < 0:
        result[s][column] = Segment(lo: down + value, hi: down)
        down += value
      else:
        result[s][column] = Segment(lo: up, hi: up + value)
        up += value

    var shift = 0.0
    var scale = 1.0
    case how
    of stackCenter:
      shift = -up / 2
    of stackNormalized:
      if total > 0:
        scale = 1 / total
    of stackStandard:
      discard

    for s in 0 ..< series.len:
      result[s][column].lo = (result[s][column].lo + shift) * scale
      result[s][column].hi = (result[s][column].hi + shift) * scale
