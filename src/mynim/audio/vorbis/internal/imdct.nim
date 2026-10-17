## Vorbis inverse MDCT and windowing, ported from github.com/jfreymuth/vorbis.
## Copyright (c) 2016 Johann Freymuth. Licensed under the MIT License.

import std/math
import ./bitreader

type
  ImdctLookup* = object
    a, b, c: seq[float32]

  WindowType* = object
    size*, prev*, next*: int

proc generateImdctLookup*(size: int): ImdctLookup =
  result.a = newSeq[float32](size div 2)
  result.b = newSeq[float32](size div 2)
  result.c = newSeq[float32](size div 4)
  let n = float64(size)
  for k in 0 ..< size div 4:
    let fk = float64(k)
    result.a[2 * k] = float32(cos(4 * fk * PI / n))
    result.a[2 * k + 1] = float32(-sin(4 * fk * PI / n))
    result.b[2 * k] = float32(cos((2 * fk + 1) * PI / n / 2))
    result.b[2 * k + 1] = float32(sin((2 * fk + 1) * PI / n / 2))
  for k in 0 ..< size div 8:
    let fk = float64(k)
    result.c[2 * k] = float32(cos(2 * (2 * fk + 1) * PI / n))
    result.c[2 * k + 1] = float32(-sin(2 * (2 * fk + 1) * PI / n))

proc reverseBits(value: uint32; count: int): int =
  var remaining = value
  for _ in 0 ..< count:
    result = (result shl 1) or int(remaining and 1)
    remaining = remaining shr 1

proc imdct*(lookup: ImdctLookup; input, output: var seq[float32]) =
  let n = input.len * 2
  let n2 = n div 2
  let n4 = n div 4
  let n8 = n div 8
  let n3_4 = n - n4

  for j in 0 ..< n8:
    let a0 = lookup.a[n2 - 2 * j - 1]
    let a1 = lookup.a[n2 - 2 * j - 2]
    let a2 = lookup.a[n4 - 2 * j - 1]
    let a3 = lookup.a[n4 - 2 * j - 2]
    let a4 = lookup.a[n2 - 4 - 4 * j]
    let a5 = lookup.a[n2 - 3 - 4 * j]
    let v0 = (-input[4 * j + 3]) * a0 + (-input[4 * j + 1]) * a1
    let v1 = (-input[4 * j + 3]) * a1 - (-input[4 * j + 1]) * a0
    let v2 = input[n2 - 4 * j - 4] * a2 + input[n2 - 4 * j - 2] * a3
    let v3 = input[n2 - 4 * j - 4] * a3 - input[n2 - 4 * j - 2] * a2
    output[n4 + 2 * j + 1] = v3 + v1
    output[n4 + 2 * j] = v2 + v0
    output[2 * j + 1] = (v3 - v1) * a4 - (v2 - v0) * a5
    output[2 * j] = (v2 - v0) * a4 + (v3 - v1) * a5

  let ld = ilog(n) - 1
  for l in 0 ..< ld - 3:
    let k0 = n shr (l + 3)
    let k1 = 1 shl (l + 3)
    let rlimit = n shr (l + 4)
    let s2limit = 1 shl (l + 2)
    for r in 0 ..< rlimit:
      let a0 = lookup.a[r * k1]
      let a1 = lookup.a[r * k1 + 1]
      var i0 = n2 - 1 - 2 * r
      var i1 = n2 - 2 - 2 * r
      var i2 = n2 - 1 - k0 - 2 * r
      var i3 = n2 - 2 - k0 - 2 * r
      for _ in countup(0, s2limit - 1, 2):
        let v0 = output[i0]
        let v1 = output[i1]
        let v2 = output[i2]
        let v3 = output[i3]
        output[i0] = v0 + v2
        output[i1] = v1 + v3
        output[i2] = (v0 - v2) * a0 - (v1 - v3) * a1
        output[i3] = (v1 - v3) * a0 + (v0 - v2) * a1
        i0 -= 2 * k0
        i1 -= 2 * k0
        i2 -= 2 * k0
        i3 -= 2 * k0

  for i in 0 ..< n8:
    let j = reverseBits(uint32(i), ld - 3)
    if i < j:
      swap(output[4 * j], output[4 * i])
      swap(output[4 * j + 1], output[4 * i + 1])
      swap(output[4 * j + 2], output[4 * i + 2])
      swap(output[4 * j + 3], output[4 * i + 3])

  for k in 0 ..< n8:
    input[n2 - 1 - 2 * k] = output[4 * k]
    input[n2 - 2 - 2 * k] = output[4 * k + 1]
    input[n4 - 1 - 2 * k] = output[4 * k + 2]
    input[n4 - 2 - 2 * k] = output[4 * k + 3]

  var i0 = 0
  var i1 = 1
  var i2 = n2 - 2
  var i3 = n2 - 1
  for _ in 0 ..< n8:
    let v0 = input[i0]
    let v1 = input[i1]
    let v2 = input[i2]
    let v3 = input[i3]
    let c0 = lookup.c[i0]
    let c1 = lookup.c[i1]
    output[i0] = (v0 + v2 + c1 * (v0 - v2) + c0 * (v1 + v3)) / 2
    output[i2] = (v0 + v2 - c1 * (v0 - v2) - c0 * (v1 + v3)) / 2
    output[i1] = (v1 - v3 + c1 * (v1 + v3) - c0 * (v0 - v2)) / 2
    output[i3] = (-v1 + v3 + c1 * (v1 + v3) - c0 * (v0 - v2)) / 2
    i0 += 2
    i1 += 2
    i2 -= 2
    i3 -= 2

  for k in 0 ..< n4:
    let b0 = lookup.b[2 * k]
    let b1 = lookup.b[2 * k + 1]
    let v0 = output[2 * k]
    let v1 = output[2 * k + 1]
    input[k] = v0 * b0 + v1 * b1
    input[n2 - 1 - k] = v0 * b1 - v1 * b0

  for i in 0 ..< n4:
    output[i] = input[i + n4]
    output[n - i - 1] = -input[n - i - n3_4 - 1]
  for i in n4 ..< n3_4:
    output[i] = -input[n3_4 - i - 1]

proc windowFunc(value: float32): float32 =
  let sinValue = sin(float64(value))
  float32(sin(PI / 2 * sinValue * sinValue))

proc makeWindow*(size: int): seq[float32] =
  result = newSeq[float32](size)
  for i in 0 ..< size:
    result[i] = windowFunc((float32(i) + 0.5'f32) / float32(size div 2) *
      PI.float32 / 2)

proc applyWindow*(lookup: array[2, seq[float32]]; largeBlock: int;
    window: WindowType; samples: var seq[seq[float32]]) =
  let center = window.size div 2
  let prevOffset = window.size div 4 - window.prev div 4
  let nextOffset = window.size div 4 - window.next div 4
  let prevType = if window.prev == largeBlock: 1 else: 0
  let nextType = if window.next == largeBlock: 1 else: 0
  for ch in 0 ..< samples.len:
    for i in 0 ..< prevOffset:
      samples[ch][i] = 0
    for i in 0 ..< window.prev div 2:
      samples[ch][prevOffset + i] *= lookup[prevType][i]
    for i in 0 ..< window.next div 2:
      samples[ch][center + nextOffset + i] *=
        lookup[nextType][window.next div 2 + i]
    for i in window.size - nextOffset ..< window.size:
      samples[ch][i] = 0
