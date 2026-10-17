## Bounded bsdiff patches used by signed update deltas.

import ./deflate

type DiffBlock = object
  diffLen, extraLen, seek: int

proc appendUvarint(target: var seq[byte]; value: uint64) =
  var remaining = value
  while remaining >= 0x80:
    target.add byte((remaining and 0x7f) or 0x80)
    remaining = remaining shr 7
  target.add byte(remaining)

proc appendVarint(target: var seq[byte]; value: int64) =
  var encoded = uint64(value) shl 1
  if value < 0:
    encoded = not encoded
  target.appendUvarint(encoded)

proc readUvarint(data: openArray[byte]; pos: var int;
    value: var uint64): bool =
  value = 0
  for shift in countup(0, 63, 7):
    if pos >= data.len: return false
    let current = data[pos]
    inc pos
    if shift == 63 and current > 1: return false
    value = value or (uint64(current and 0x7f) shl shift)
    if current < 0x80: return true
  false

proc readVarint(data: openArray[byte]; pos: var int;
    value: var int64): bool =
  var encoded: uint64
  if not readUvarint(data, pos, encoded): return false
  let decoded = int64(encoded shr 1)
  value = if (encoded and 1) == 0: decoded else: not decoded
  true

proc split(sa, rank: var seq[int32]; start, size, width: int32)

proc suffixArray*(data: openArray[byte]): seq[int32] =
  ## Larsson and Sadakane's qsufsort, as used by bsdiff.
  if data.len > high(int32).int - 1:
    raise newException(ValueError, "bsdiff: input is too large")
  let n = int32(data.len)
  result = newSeq[int32](data.len + 1)
  var rank = newSeq[int32](data.len + 1)
  var buckets: array[256, int32]
  for value in data:
    inc buckets[int(value)]
  for i in 1 ..< 256:
    buckets[i] += buckets[i - 1]
  for i in countdown(255, 1):
    buckets[i] = buckets[i - 1]
  buckets[0] = 0
  for i, value in data:
    inc buckets[int(value)]
    result[int(buckets[int(value)])] = int32(i)
  result[0] = n
  for i, value in data:
    rank[i] = buckets[int(value)]
  rank[int(n)] = 0
  for i in 1 ..< 256:
    if buckets[i] == buckets[i - 1] + 1:
      result[int(buckets[i])] = -1
  result[0] = -1

  var width = int32(1)
  while result[0] != -(n + 1):
    var run = int32(0)
    var i = int32(0)
    while i < n + 1:
      if result[int(i)] < 0:
        run -= result[int(i)]
        i -= result[int(i)]
      else:
        if run != 0:
          result[int(i - run)] = -run
        let size = rank[int(result[int(i)])] + 1 - i
        split(result, rank, i, size, width)
        i += size
        run = 0
    if run != 0:
      result[int(i - run)] = -run
    width *= 2
  for i in 0 .. int(n):
    result[int(rank[i])] = int32(i)

proc split(sa, rank: var seq[int32]; start, size, width: int32) =
  var first = start
  var count = size
  while count >= 16:
    let pivot = rank[int(sa[int(first + count div 2)] + width)]
    var less, equal: int32
    for i in first ..< first + count:
      let key = rank[int(sa[int(i)] + width)]
      if key < pivot:
        inc less
      elif key == pivot:
        inc equal
    less += first
    equal += less
    var i = first
    var j, k = int32(0)
    while i < less:
      let key = rank[int(sa[int(i)] + width)]
      if key < pivot:
        inc i
      elif key == pivot:
        swap(sa[int(i)], sa[int(less + j)])
        inc j
      else:
        swap(sa[int(i)], sa[int(equal + k)])
        inc k
    while less + j < equal:
      if rank[int(sa[int(less + j)] + width)] == pivot:
        inc j
      else:
        swap(sa[int(less + j)], sa[int(equal + k)])
        inc k
    if less > first:
      split(sa, rank, first, less - first, width)
    for offset in 0 ..< equal - less:
      rank[int(sa[int(less + offset)])] = equal - 1
    if less == equal - 1:
      sa[int(less)] = -1
    count = first + count - equal
    first = equal

  if count <= 0: return
  var k = first
  while k < first + count:
    var moved = int32(1)
    var x = rank[int(sa[int(k)] + width)]
    var i = int32(1)
    while k + i < first + count:
      let key = rank[int(sa[int(k + i)] + width)]
      if key < x:
        x = key
        moved = 0
      if key == x:
        swap(sa[int(k + moved)], sa[int(k + i)])
        inc moved
      inc i
    for offset in 0 ..< moved:
      rank[int(sa[int(k + offset)])] = k + moved - 1
    if moved == 1:
      sa[int(k)] = -1
    k += moved

proc matchLen(oldData, newData: openArray[byte]; oldPos, newPos: int): int =
  let limit = min(oldData.len - oldPos, newData.len - newPos)
  while result < limit and oldData[oldPos + result] == newData[newPos + result]:
    inc result

proc compareSuffix(oldData, newData: openArray[byte]; oldPos, newPos: int): int =
  var i = 0
  while oldPos + i < oldData.len and newPos + i < newData.len:
    if oldData[oldPos + i] != newData[newPos + i]:
      return cmp(oldData[oldPos + i], newData[newPos + i])
    inc i
  if oldPos + i == oldData.len and newPos + i == newData.len: return 0
  if oldPos + i == oldData.len: return -1
  1

proc search(sa: openArray[int32]; oldData, newData: openArray[byte];
    newPos: int): tuple[length, pos: int] =
  var low = 0
  var high = sa.len - 1
  while high - low >= 2:
    let mid = low + (high - low) div 2
    if compareSuffix(oldData, newData, int(sa[mid]), newPos) < 0:
      low = mid
    else:
      high = mid
  let lowLength = matchLen(oldData, newData, int(sa[low]), newPos)
  let highLength = matchLen(oldData, newData, int(sa[high]), newPos)
  if lowLength > highLength:
    (lowLength, int(sa[low]))
  else:
    (highLength, int(sa[high]))

proc diff*(oldData, newData: openArray[byte]): seq[byte] =
  ## Returns a compressed bsdiff stream that produces newData from oldData.
  let sa = suffixArray(oldData)
  var blocks: seq[DiffBlock]
  var difference, extra: seq[byte]
  var scan, pos, length = 0
  var lastScan, lastPos, lastOffset = 0
  while scan < newData.len:
    var oldScore = 0
    scan += length
    var searchScan = scan
    while scan < newData.len:
      (length, pos) = search(sa, oldData, newData, scan)
      while searchScan < scan + length:
        if searchScan + lastOffset < oldData.len and
            oldData[searchScan + lastOffset] == newData[searchScan]:
          inc oldScore
        inc searchScan
      if (length == oldScore and length != 0) or length > oldScore + 8:
        break
      if scan + lastOffset < oldData.len and
          oldData[scan + lastOffset] == newData[scan]:
        dec oldScore
      inc scan
    if length != oldScore or scan == newData.len:
      var lenForward = 0
      var i, score, bestScore = 0
      while lastScan + i < scan and lastPos + i < oldData.len:
        if oldData[lastPos + i] == newData[lastScan + i]: inc score
        inc i
        if score * 2 - i > bestScore * 2 - lenForward:
          bestScore = score
          lenForward = i

      var lenBackward = 0
      if scan < newData.len:
        i = 1
        score = 0
        bestScore = 0
        while scan >= lastScan + i and pos >= i:
          if oldData[pos - i] == newData[scan - i]: inc score
          if score * 2 - i > bestScore * 2 - lenBackward:
            bestScore = score
            lenBackward = i
          inc i

      let overlap = lastScan + lenForward - (scan - lenBackward)
      if overlap > 0:
        score = 0
        bestScore = 0
        var lenSplit = 0
        for offset in 0 ..< overlap:
          if newData[lastScan + lenForward - overlap + offset] ==
              oldData[lastPos + lenForward - overlap + offset]:
            inc score
          if newData[scan - lenBackward + offset] ==
              oldData[pos - lenBackward + offset]:
            dec score
          if score > bestScore:
            bestScore = score
            lenSplit = offset + 1
        lenForward += lenSplit - overlap
        lenBackward -= lenSplit

      for offset in 0 ..< lenForward:
        let delta = int(newData[lastScan + offset]) -
          int(oldData[lastPos + offset])
        difference.add byte(delta and 0xff)
      let extraStart = lastScan + lenForward
      let extraPast = scan - lenBackward
      for offset in extraStart ..< extraPast:
        extra.add newData[offset]
      let patchBlock = DiffBlock(
        diffLen: lenForward,
        extraLen: extraPast - extraStart,
        seek: pos - lenBackward - (lastPos + lenForward))
      if patchBlock.diffLen == 0 and patchBlock.extraLen == 0 and
          blocks.len > 0:
        blocks[^1].seek += patchBlock.seek
      else:
        blocks.add patchBlock
      lastScan = scan - lenBackward
      lastPos = pos - lenBackward
      lastOffset = pos - scan

  var control: seq[byte]
  for part in blocks:
    control.appendUvarint(uint64(part.diffLen))
    control.appendUvarint(uint64(part.extraLen))
    control.appendVarint(int64(part.seek))
  let controlCompressed = deflateRaw(control)
  let diffCompressed = deflateRaw(difference)
  let extraCompressed = deflateRaw(extra)
  result.appendUvarint(uint64(blocks.len))
  result.appendUvarint(uint64(controlCompressed.len))
  result.appendUvarint(uint64(diffCompressed.len))
  result.add controlCompressed
  result.add diffCompressed
  result.add extraCompressed

proc patch*(oldData, patchData: openArray[byte]; outputSize: int): seq[byte] =
  ## Applies a bsdiff stream and rejects output beyond outputSize.
  const maxControlSize = 16 shl 20
  if outputSize < 0:
    raise newException(ValueError, "bsdiff: invalid output size")
  var headerPos = 0
  var blockCount, controlSize, differenceSize: uint64
  if not readUvarint(patchData, headerPos, blockCount) or
      not readUvarint(patchData, headerPos, controlSize) or
      not readUvarint(patchData, headerPos, differenceSize):
    raise newException(ValueError, "bsdiff: damaged patch header")
  if blockCount > uint64(outputSize) + 1 or
      controlSize < 2 or differenceSize < 2 or
      controlSize > uint64(patchData.len - headerPos) or
      differenceSize > uint64(patchData.len - headerPos) - controlSize:
    raise newException(ValueError, "bsdiff: damaged patch header")
  let extraOffset = headerPos + int(controlSize + differenceSize)
  let controlEnd = headerPos + int(controlSize)
  let differenceEnd = controlEnd + int(differenceSize)
  if patchData.len - extraOffset < 2:
    raise newException(ValueError, "bsdiff: damaged patch streams")
  let controlLimit = if outputSize > (maxControlSize - 64) div 30:
    maxControlSize else: max(64, outputSize * 30)
  let control = inflateRaw(patchData.toOpenArray(headerPos, controlEnd - 1),
    controlLimit)
  let difference = inflateRaw(patchData.toOpenArray(controlEnd,
    differenceEnd - 1), outputSize)
  let extra = inflateRaw(patchData.toOpenArray(extraOffset,
    patchData.high), outputSize)
  var controlPos, differencePos, extraPos = 0
  var oldPos = 0'i64
  var remaining = outputSize
  for _ in 0 ..< int(blockCount):
    var diffLen, extraLen: uint64
    var seek: int64
    if not readUvarint(control, controlPos, diffLen) or
        not readUvarint(control, controlPos, extraLen) or
        not readVarint(control, controlPos, seek) or
        diffLen > uint64(remaining) or extraLen > uint64(remaining) - diffLen or
        diffLen > uint64(difference.len - differencePos) or
        extraLen > uint64(extra.len - extraPos):
      raise newException(ValueError, "bsdiff: damaged control stream")
    remaining -= int(diffLen + extraLen)
    for _ in 0 ..< int(diffLen):
      let oldAt = oldPos
      let oldByte = if oldAt >= 0 and oldAt < int64(oldData.len):
        int(oldData[int(oldAt)]) else: 0
      result.add byte((oldByte + int(difference[differencePos])) and 0xff)
      inc oldPos
      inc differencePos
    for _ in 0 ..< int(extraLen):
      result.add extra[extraPos]
      inc extraPos
    oldPos += seek
    if oldPos < -(1'i64 shl 40) or oldPos > (1'i64 shl 40):
      raise newException(ValueError, "bsdiff: damaged old-file offset")
  if remaining != 0 or result.len != outputSize or
      controlPos != control.len or differencePos != difference.len or
      extraPos != extra.len:
    raise newException(ValueError, "bsdiff: patch has trailing or missing data")
