## Finds the closest ordered chart coordinate.

proc nearest*(values: openArray[float32]; value: float32): int =
  ## Returns the index nearest value, preferring the lower one on a tie.
  if values.len == 0:
    return -1
  var lo = 0
  var hi = values.len
  while lo < hi:
    let middle = (lo + hi) div 2
    if values[middle] < value:
      lo = middle + 1
    else:
      hi = middle
  if lo == values.len:
    return lo - 1
  if lo > 0 and value - values[lo - 1] <= values[lo] - value:
    return lo - 1
  lo
