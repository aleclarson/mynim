import std/[assertions, sets]
import mynim/core/random

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

block random_text_matches_upstream_shape:
  var seen = initHashSet[string]()
  for _ in 0 ..< 128:
    let token = randomText()
    doAssert token.len == 26
    for character in token:
      doAssert alphabet.contains(character)
    seen.incl(token)
  doAssert seen.len == 128
