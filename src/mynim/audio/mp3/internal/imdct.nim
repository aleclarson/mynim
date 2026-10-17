## Layer III inverse MDCT windows from github.com/hajimehoshi/go-mp3.
## Copyright 2017 Hajime Hoshi. Licensed under Apache-2.0.

import std/math

type ImdctWindow = array[36, float32]

proc initWindows(): array[4, ImdctWindow] =
  for i in 0 ..< 36:
    result[0][i] = float32(sin(PI / 36.0 * (float64(i) + 0.5)))
  for i in 0 ..< 18:
    result[1][i] = float32(sin(PI / 36.0 * (float64(i) + 0.5)))
  for i in 18 ..< 24:
    result[1][i] = 1
  for i in 24 ..< 30:
    result[1][i] = float32(sin(PI / 12.0 *
      (float64(i) + 0.5 - 18.0)))
  for i in 0 ..< 12:
    result[2][i] = float32(sin(PI / 12.0 * (float64(i) + 0.5)))
  for i in 6 ..< 12:
    result[3][i] = float32(sin(PI / 12.0 *
      (float64(i) + 0.5 - 6.0)))
  for i in 12 ..< 18:
    result[3][i] = 1
  for i in 18 ..< 36:
    result[3][i] = float32(sin(PI / 36.0 * (float64(i) + 0.5)))

proc initCos12(): array[6, array[12, float32]] =
  const n = 12
  for i in 0 ..< 6:
    for j in 0 ..< 12:
      result[i][j] = float32(cos(PI / (2.0 * n.float64) *
        (2.0 * float64(j) + 1.0 + n.float64 / 2.0) *
        (2.0 * float64(i) + 1.0)))

proc initCos36(): array[18, array[36, float32]] =
  const n = 36
  for i in 0 ..< 18:
    for j in 0 ..< 36:
      result[i][j] = float32(cos(PI / (2.0 * n.float64) *
        (2.0 * float64(j) + 1.0 + n.float64 / 2.0) *
        (2.0 * float64(i) + 1.0)))

let
  imdctWinData = initWindows()
  cosN12 = initCos12()
  cosN36 = initCos36()

proc win*(input: openArray[float32]; blockType: int): array[36, float32] =
  if blockType < 0 or blockType >= imdctWinData.len:
    raise newException(ValueError, "mp3: invalid IMDCT block type")
  if input.len < 18:
    raise newException(ValueError, "mp3: IMDCT input must have 18 samples")
  let window = imdctWinData[blockType]
  if blockType == 2:
    const n = 12
    for i in 0 ..< 3:
      for p in 0 ..< n:
        var sum = 0'f32
        for m in 0 ..< n div 2:
          sum += input[i + 3 * m] * cosN12[m][p]
        result[6 * i + p + 6] += sum * window[p]
    return

  const n = 36
  for p in 0 ..< n:
    var sum = 0'f32
    for m in 0 ..< n div 2:
      sum += input[m] * cosN36[m][p]
    result[p] = sum * window[p]
