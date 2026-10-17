import std/[assertions, algorithm]
import ../src/mynim/internal/bsdiff

proc bytes(value: string): seq[byte] =
  for ch in value:
    result.add byte(ord(ch))

proc naiveSuffixArray(data: seq[byte]): seq[int32] =
  for index in 0 .. data.len:
    result.add int32(index)
  result.sort(proc(left, right: int32): int =
    var a = int(left)
    var b = int(right)
    while a < data.len and b < data.len:
      if data[a] != data[b]:
        return cmp(data[a], data[b])
      inc a
      inc b
    if a == data.len and b == data.len: return 0
    if a == data.len: return -1
    1)

block suffix_array:
  let input = bytes("banana")
  let expected = @[6'i32, 5, 3, 1, 0, 4, 2]
  doAssert suffixArray(input) == expected

block suffix_array_matches_reference:
  var seed = 29
  for length in 0 .. 96:
    var input = newSeq[byte](length)
    for index in 0 ..< input.len:
      seed = (seed * 48271) mod 2147483647
      input[index] = byte((seed shr 8) and 0xff)
    doAssert suffixArray(input) == naiveSuffixArray(input),
      "suffix array differs from reference at length " & $length

block diff_patch_cases:
  var base = newSeq[byte](100_000)
  for i in 0 ..< base.len:
    base[i] = byte((i * 73 + i div 19) and 0xff)
  var edited = base
  for i in countup(101, edited.high, 997):
    edited[i] = edited[i] + 1

  let insertion = bytes("prefix") & base & bytes("suffix")
  let moved = base[50_000 ..< 90_000] & base[0 ..< 50_000] & base[90_000 .. ^1]
  let cases = [
    (newSeq[byte](), newSeq[byte]()),
    (newSeq[byte](), bytes("new content")),
    (bytes("old content"), newSeq[byte]()),
    (base, base),
    (base, edited),
    (base, insertion),
    (base, moved),
    (bytes("unrelated old bytes"), bytes("different new bytes"))]
  for (oldData, newData) in cases:
    let compressedPatch = diff(oldData, newData)
    let output = patch(oldData, compressedPatch, newData.len)
    doAssert output == newData

  doAssert diff(base, edited).len < edited.len div 10
  doAssertRaises ValueError:
    discard patch(base, diff(base, edited), edited.len - 1)
