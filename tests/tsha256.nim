import std/assertions
import ../src/mynim/internal/sha256

proc bytes(value: string): seq[byte] =
  for ch in value:
    result.add byte(ord(ch))

doAssert sha256Hex("") ==
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
doAssert sha256Hex("abc") ==
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

block streaming_hash:
  let expected = sha256Sum(bytes("abc"))
  var state = sha256Init()
  state.sha256Update(bytes("a"))
  state.sha256Update(bytes("bc"))
  doAssert state.sha256Final() == expected

  var content = newSeq[byte](4097)
  for index in 0 ..< content.len:
    content[index] = byte((index * 47 + index div 7) and 0xff)
  state = sha256Init()
  for start in countup(0, content.high, 37):
    let past = min(content.len, start + 37)
    state.sha256Update(content[start ..< past])
  doAssert state.sha256Final() == sha256Sum(content)
