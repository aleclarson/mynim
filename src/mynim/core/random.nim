## Random tokens shared by bridge secrets and short-lived identifiers.

import std/sysrand

proc randomText*(): string =
  ## Returns 26 cryptographically unpredictable Base32 characters, matching
  ## mygo's bridge secrets, drag tokens, and notification identifiers.
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  when defined(js):
    ## The JS backend obtains these bytes directly from Web Crypto.
    let entropy = sysrand.urandom(26)
    result = newString(26)
    for i, value in entropy:
      result[i] = alphabet[int(value and 31'u8)]
  else:
    ## 128 random bits encode to 26 unpadded Base32 characters.
    let entropy = sysrand.urandom(16)
    result = newString(26)
    for i in 0 ..< result.len:
      var value = 0
      for bit in 0 ..< 5:
        let sourceBit = i * 5 + bit
        value = value shl 1
        if sourceBit < entropy.len * 8:
          value = value or int((entropy[sourceBit div 8] shr
            (7 - sourceBit mod 8)) and 1'u8)
      result[i] = alphabet[value]
