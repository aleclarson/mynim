## Fenwick index for measured and estimated paragraph heights.

type
  ParagraphHeightTotals* = object
    measured*: float64
    unknown*: int

  ParagraphHeightIndex* = object
    measured: seq[float64]
    unknown: seq[int]
    estimate: float64

proc len*(index: ParagraphHeightIndex): int =
  if index.measured.len == 0: 0 else: index.measured.len - 1

proc reset*(index: var ParagraphHeightIndex; heights: openArray[float32]) =
  ## Rebuilds the index; zero or negative heights use the current estimate.
  let n = heights.len
  if capacity(index.measured) > 4 * (n + 1):
    index.measured = @[]
    index.unknown = @[]
  index.measured.setLen(n + 1)
  index.unknown.setLen(n + 1)
  for i in 0..<n + 1:
    index.measured[i] = 0
    index.unknown[i] = 0
  for i, height in heights:
    if height > 0:
      index.measured[i + 1] = float64(height)
    else:
      index.unknown[i + 1] = 1
  for i in 1..n:
    let parent = i + (i and -i)
    if parent <= n:
      index.measured[parent] += index.measured[i]
      index.unknown[parent] += index.unknown[i]

proc setEstimate*(index: var ParagraphHeightIndex; height: float64) =
  ## Sets the height assigned to paragraphs that have not been laid out.
  index.estimate = max(height, 0.0)

proc estimate*(index: ParagraphHeightIndex): float64 = index.estimate

proc add*(index: var ParagraphHeightIndex; paragraph: int;
          measuredDelta: float64; unknownDelta: int) =
  ## Applies a measured-height and unknown-count change at one paragraph.
  doAssert paragraph >= 0 and paragraph < index.len
  var i = paragraph + 1
  while i < index.measured.len:
    index.measured[i] += measuredDelta
    index.unknown[i] += unknownDelta
    i += i and -i

proc top*(index: ParagraphHeightIndex; paragraph: int): float64 =
  ## Returns the estimated vertical offset before a paragraph.
  var i = max(0, min(paragraph, index.len))
  var measured = 0.0
  var unknown = 0
  while i > 0:
    measured += index.measured[i]
    unknown += index.unknown[i]
    i -= i and -i
  measured + float64(unknown) * index.estimate

proc at*(index: ParagraphHeightIndex; y: float64): int =
  ## Returns the paragraph containing y, clamping past-end positions to the last.
  let n = index.len
  if n == 0:
    return 0
  var step = 1
  while step <= n div 2:
    step *= 2
  var position = 0
  var measured = 0.0
  var unknown = 0
  while step > 0:
    let next = position + step
    if next <= n:
      let nextMeasured = measured + index.measured[next]
      let nextUnknown = unknown + index.unknown[next]
      if nextMeasured + float64(nextUnknown) * index.estimate <= y:
        position = next
        measured = nextMeasured
        unknown = nextUnknown
    step = step shr 1
  min(position, n - 1)

proc totals*(index: ParagraphHeightIndex): ParagraphHeightTotals =
  ## Returns the measured-height sum and count of paragraphs still estimated.
  var i = index.len
  while i > 0:
    result.measured += index.measured[i]
    result.unknown += index.unknown[i]
    i -= i and -i
