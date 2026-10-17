import std/[assertions, strutils]
import ../src/mynim/internal/deflate

proc toBytes(value: string): seq[byte] =
  for ch in value:
    result.add byte(ord(ch))

block raw_fixed_huffman_roundtrip:
  var samples = @[
    "",
    "abc",
    "abcabcabcabcabcabcabcabc",
    "The quick brown fox jumps over the lazy dog. ".repeat(100)]
  var patterned = newStringOfCap(32_000)
  for i in 0 ..< 32_000:
    patterned.add char((i * 17 + i div 23) and 0xff)
  samples.add patterned
  for sample in samples:
    let raw = deflateRaw(toBytes(sample))
    let decoded = inflateRaw(raw, sample.len)
    doAssert decoded == toBytes(sample)

  let repeated = deflateRaw(toBytes("x".repeat(10_000)))
  doAssert repeated.len < 100
  doAssertRaises ValueError:
    discard inflateRaw(repeated, 9_999)
