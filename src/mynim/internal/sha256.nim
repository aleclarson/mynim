## SHA-256 hashing shared by generated shader checksums and signed updates.

import std/[endians, strutils]

const sha256K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
  0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
  0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
  0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
  0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
  0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
  0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
  0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
  0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256Sum*(data: openArray[byte]): array[32, byte] =
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = @data
  let bitLen = uint64(msg.len) * 8
  msg.add(0x80)
  while msg.len mod 64 != 56:
    msg.add(0)
  var tail: array[8, byte]
  bigEndian64(addr tail[0], unsafeAddr bitLen)
  for b in tail: msg.add(b)
  var w: array[64, uint32]
  for chunkStart in countup(0, msg.len - 1, 64):
    for i in 0 ..< 16:
      bigEndian32(addr w[i], unsafeAddr msg[chunkStart + i * 4])
    for i in 16 ..< 64:
      let
        s0 = (w[i - 15] shr 7 or (w[i - 15] shl 25)) xor
             (w[i - 15] shr 18 or (w[i - 15] shl 14)) xor (w[i - 15] shr 3)
        s1 = (w[i - 2] shr 17 or (w[i - 2] shl 15)) xor
             (w[i - 2] shr 19 or (w[i - 2] shl 13)) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5],
                                     h[6], h[7])
    for i in 0 ..< 64:
      let
        s1 = (e shr 6 or (e shl 26)) xor (e shr 11 or (e shl 21)) xor
             (e shr 25 or (e shl 7))
        ch = (e and f) xor ((not e) and g)
        t1 = hh + s1 + ch + sha256K[i] + w[i]
        s0 = (a shr 2 or (a shl 30)) xor (a shr 13 or (a shl 19)) xor
             (a shr 22 or (a shl 10))
        maj = (a and b) xor (a and c) xor (b and c)
        t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh
  for i in 0 ..< 8:
    bigEndian32(addr result[i * 4], addr h[i])

proc sha256Hex*(data: openArray[byte]): string =
  for b in sha256Sum(data):
    result.add(toHex(int(b), 2).toLowerAscii())

proc sha256Hex*(data: string): string =
  if data.len == 0:
    return sha256Hex(newSeq[byte]())
  sha256Hex(data.toOpenArrayByte(0, data.high))
