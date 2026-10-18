## Common Unicode hostname to ASCII conversion for proxy matching.
## This implements the non-transitional Punycode path for Unicode letter labels;
## it deliberately leaves unsupported or malformed labels unchanged.

import std/[strutils, unicode]

proc isContinuationByte(value: int): bool {.inline.} =
  value >= 0x80 and value <= 0xbf

proc hasValidUtf8(value: string): bool =
  var i = 0
  while i < value.len:
    let first = ord(value[i])
    if first <= 0x7f:
      inc i
    elif first >= 0xc2 and first <= 0xdf:
      if i + 1 >= value.len or not isContinuationByte(ord(value[i + 1])):
        return false
      inc i, 2
    elif first == 0xe0:
      if i + 2 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0xa0 or second > 0xbf or
          not isContinuationByte(ord(value[i + 2])): return false
      inc i, 3
    elif (first >= 0xe1 and first <= 0xec) or
        (first >= 0xee and first <= 0xef):
      if i + 2 >= value.len or
          not isContinuationByte(ord(value[i + 1])) or
          not isContinuationByte(ord(value[i + 2])): return false
      inc i, 3
    elif first == 0xed:
      if i + 2 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x80 or second > 0x9f or
          not isContinuationByte(ord(value[i + 2])): return false
      inc i, 3
    elif first == 0xf0:
      if i + 3 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x90 or second > 0xbf or
          not isContinuationByte(ord(value[i + 2])) or
          not isContinuationByte(ord(value[i + 3])): return false
      inc i, 4
    elif first >= 0xf1 and first <= 0xf3:
      if i + 3 >= value.len or
          not isContinuationByte(ord(value[i + 1])) or
          not isContinuationByte(ord(value[i + 2])) or
          not isContinuationByte(ord(value[i + 3])): return false
      inc i, 4
    elif first == 0xf4:
      if i + 3 >= value.len: return false
      let second = ord(value[i + 1])
      if second < 0x80 or second > 0x8f or
          not isContinuationByte(ord(value[i + 2])) or
          not isContinuationByte(ord(value[i + 3])): return false
      inc i, 4
    else:
      return false
  true

proc punycodeDigit(value: int64): char {.inline.} =
  if value < 26: char(ord('a') + value.int)
  else: char(ord('0') + (value.int - 26))

proc adaptBias(delta, pointCount: int64; firstTime: bool): int64 =
  var adjusted = if firstTime: delta div 700 else: delta div 2
  adjusted += adjusted div pointCount
  var k = 0'i64
  while adjusted > 455:
    adjusted = adjusted div 35
    k += 36
  k + (36 * adjusted) div (adjusted + 38)

proc encodePunycode(points: openArray[int64]): string =
  const base = 36'i64
  const tmin = 1'i64
  const tmax = 26'i64
  var basicCount = 0'i64
  for point in points:
    if point < 0x80:
      result.add char(point)
      inc basicCount
  var handled = basicCount
  if basicCount > 0 and handled < points.len.int64:
    result.add '-'

  var n = 128'i64
  var delta = 0'i64
  var bias = 72'i64
  while handled < points.len.int64:
    var nextPoint = high(int64)
    for point in points:
      if point >= n and point < nextPoint: nextPoint = point
    if nextPoint == high(int64): return ""
    let gap = nextPoint - n
    if gap > (high(int64) - delta) div (handled + 1): return ""
    delta += gap * (handled + 1)
    n = nextPoint

    for point in points:
      if point < n:
        if delta == high(int64): return ""
        inc delta
      elif point == n:
        var quotient = delta
        var k = base
        while true:
          let threshold =
            if k <= bias + tmin: tmin
            elif k >= bias + tmax: tmax
            else: k - bias
          if quotient < threshold: break
          result.add punycodeDigit(threshold +
            ((quotient - threshold) mod (base - threshold)))
          quotient = (quotient - threshold) div (base - threshold)
          k += base
        result.add punycodeDigit(quotient)
        bias = adaptBias(delta, handled + 1, handled == basicCount)
        delta = 0
        inc handled
    if handled < points.len.int64:
      if delta == high(int64) or n == high(int64): return ""
      inc delta
      inc n

proc encodeLabel(label: string): string =
  let runes = toRunes(label)
  if runes.len == 0: return ""
  var points = newSeqOfCap[int64](runes.len)
  var hasNonAscii = false
  for index, rune in runes:
    var point = int64(int(rune))
    if point < 0x80:
      let ch = char(point)
      if not (ch in {'a'..'z', 'A'..'Z', '0'..'9', '-'}): return ""
      point = ord(ch.toLowerAscii()).int64
    else:
      hasNonAscii = true
      if not (rune.isAlpha() or rune.isCombining()):
        return ""
      if index == 0 and rune.isCombining(): return ""
      point = int64(int(rune.toLower()))
    if (index == 0 or index == runes.high) and point == ord('-').int64:
      return ""
    points.add point

  if runes.len >= 4 and points[2] == ord('-').int64 and
      points[3] == ord('-').int64:
    return ""
  if hasNonAscii:
    let encoded = encodePunycode(points)
    if encoded.len == 0: return ""
    result = "xn--" & encoded
  else:
    for point in points:
      result.add char(point)
  if result.len > 63: return ""

proc toAsciiHost*(host: string): string =
  ## Converts common Unicode labels to lower-case Punycode. Invalid UTF-8,
  ## empty labels, punctuation, and unsupported IDNA code points are preserved
  ## verbatim so proxy selection can retain its ordinary exact-host behavior.
  if host.len == 0 or not hasValidUtf8(host): return host
  var nonAscii = false
  for ch in host:
    if ord(ch) >= 0x80:
      nonAscii = true
      break
  if not nonAscii: return host

  var start = 0
  while start < host.len:
    let dot = host.find('.', start)
    let finish = if dot < 0: host.len else: dot
    if finish == start: return host
    let label = encodeLabel(host[start ..< finish])
    if label.len == 0: return host
    if result.len > 0: result.add '.'
    result.add label
    if dot < 0: return
    start = dot + 1
    if start == host.len:
      result.add '.'
      return
