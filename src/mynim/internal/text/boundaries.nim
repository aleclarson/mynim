## edit.go (part): grapheme and word boundaries in text.

type Boundaries* = object
  seg: Segmenter
  runes: seq[Rune]
  ## graphemes holds the start of every grapheme, then runes.len.
  graphemes: seq[int]

proc reset*(b: var Boundaries, runes: openArray[Rune]) =
  ## Prepares b for runes.
  b.runes = @runes
  b.graphemes.setLen(0)
  b.seg.init(runes)
  var it = b.seg.graphemeIterator()
  while it.next():
    b.graphemes.add it.grapheme().offset
  b.graphemes.add b.runes.len

proc graphemeOffsets*(b: Boundaries): seq[int] =
  ## A copy of the grapheme starts and text's end for a retained
  ## shaped-text layout.
  b.graphemes

proc nextGrapheme*(b: Boundaries, i: int): int =
  ## The end of the grapheme starting at or containing i.
  for g in b.graphemes:
    if g > i:
      return g
  b.runes.len

proc prevGrapheme*(b: Boundaries, i: int): int =
  ## The start of the grapheme before i.
  result = 0
  for g in b.graphemes:
    if g >= i:
      return
    result = g

proc isDigitRune(r: Rune): bool =
  ## unicode.IsDigit: decimal digits (category Nd), the common blocks.
  let c = int32(r)
  (c >= ord('0') and c <= ord('9')) or
    (c >= 0x660 and c <= 0x669) or (c >= 0x6F0 and c <= 0x6F9) or
    (c >= 0x7C0 and c <= 0x7C9) or (c >= 0x966 and c <= 0x96F) or
    (c >= 0x9E6 and c <= 0x9EF) or (c >= 0xA66 and c <= 0xA6F) or
    (c >= 0xAE6 and c <= 0xAEF) or (c >= 0xB66 and c <= 0xB6F) or
    (c >= 0xBE6 and c <= 0xBEF) or (c >= 0xC66 and c <= 0xC6F) or
    (c >= 0xCE6 and c <= 0xCEF) or (c >= 0xD66 and c <= 0xD6F) or
    (c >= 0xE50 and c <= 0xE59) or (c >= 0xED0 and c <= 0xED9) or
    (c >= 0xF20 and c <= 0xF29) or (c >= 0x1040 and c <= 0x1049) or
    (c >= 0x17E0 and c <= 0x17E9) or (c >= 0x1810 and c <= 0x1819) or
    (c >= 0x1946 and c <= 0x194F) or (c >= 0x19D0 and c <= 0x19D9) or
    (c >= 0x1A80 and c <= 0x1A89) or (c >= 0x1A90 and c <= 0x1A99) or
    (c >= 0x1B50 and c <= 0x1B59) or (c >= 0x1BB0 and c <= 0x1BB9) or
    (c >= 0x1C40 and c <= 0x1C49) or (c >= 0x1C50 and c <= 0x1C59) or
    (c >= 0xA620 and c <= 0xA629) or (c >= 0xA8D0 and c <= 0xA8D9) or
    (c >= 0xA900 and c <= 0xA909) or (c >= 0xA9D0 and c <= 0xA9D9) or
    (c >= 0xA9F0 and c <= 0xA9F9) or (c >= 0xAA50 and c <= 0xAA59) or
    (c >= 0xABF0 and c <= 0xABF9) or (c >= 0xFF10 and c <= 0xFF19)

proc isWordRune(r: Rune): bool =
  isAlpha(r) or isDigitRune(r) or int32(r) == ord('_')

proc nextWord*(b: Boundaries, i: int): int =
  ## The end of the word after i, skipping what is between.
  var i = i
  let n = b.runes.len
  while i < n and not isWordRune(b.runes[i]):
    inc i
  while i < n and isWordRune(b.runes[i]):
    inc i
  i

proc prevWord*(b: Boundaries, i: int): int =
  ## The start of the word before i.
  var i = i
  while i > 0 and not isWordRune(b.runes[i - 1]):
    dec i
  while i > 0 and isWordRune(b.runes[i - 1]):
    dec i
  i

proc wordAt*(b: Boundaries, i: int): tuple[start, `end`: int] =
  ## The word, or the run of other runes, around i.
  let n = b.runes.len
  if n == 0:
    return (0, 0)
  let i = min(i, n - 1)
  let word = isWordRune(b.runes[i])
  var start = i
  var `end` = i
  while start > 0 and isWordRune(b.runes[start - 1]) == word and
      b.runes[start - 1] != Rune(0x0A):
    dec start
  while `end` < n and isWordRune(b.runes[`end`]) == word and
      b.runes[`end`] != Rune(0x0A):
    inc `end`
  (start, `end`)

proc lineBreaks*(seg: var Segmenter, breaks: var seq[bool],
                 text: openArray[Rune]): seq[bool] =
  ## For each rune of text and for its end, whether a line may break
  ## before it, in breaks, with seg; both are reused.
  breaks.setLen(text.len + 1)
  for i in 0 .. text.len:
    breaks[i] = false
  seg.init(text)
  var it = seg.lineIterator()
  while it.next():
    let l = it.line()
    breaks[l.offset + l.text.len] = true
  breaks
