## lang.go: the language of a text decides the glyphs of the scripts it
## writes and the fonts the system falls back to.

proc writesHan*(lang: string): bool =
  ## Whether a language writes Han characters: Chinese, with its
  ## languages of other codes, Japanese and Korean.
  var base = toLowerAscii(lang)
  let dash = find(base, '-')
  if dash >= 0: base = base[0 ..< dash]
  let us = find(base, '_')
  if us >= 0: base = base[0 ..< us]
  base in ["zh", "ja", "ko", "yue", "cmn", "wuu", "hak", "nan", "gan",
           "hsn", "lzh", "cjy", "cpx", "czh", "czo", "mnp", "cdo"]

proc isHan*(r: Rune): bool =
  ## unicode.Is(unicode.Han, r): the ideograph blocks.
  let c = int32(r)
  (c >= 0x3400 and c <= 0x4DBF) or (c >= 0x4E00 and c <= 0x9FFF) or
    (c >= 0xF900 and c <= 0xFAFF) or (c >= 0x20000 and c <= 0x2A6DF) or
    (c >= 0x2A700 and c <= 0x2EBEF) or (c >= 0x30000 and c <= 0x3134F) or
    (c >= 0x2F800 and c <= 0x2FA1F)

proc isCJK*(r: Rune): bool =
  ## Whether r is a Han character, or a mark of punctuation or a
  ## full-width form the languages writing Han draw apart.
  let c = int32(r)
  if c < 0x2E80:
    return false
  if (c >= 0x3000 and c <= 0x303F) or (c >= 0xFF00 and c <= 0xFFEF):
    return true
  isHan(r)

proc spansHaveLang(spans: openArray[Span]): bool =
  for sp in spans:
    if sp.lang != "":
      return true
  false

proc langRuns*(text: openArray[Rune], base: string,
               spans: openArray[Span]): seq[langRun] =
  ## The runs of a text whose language the engine must be told apart
  ## from base, given the language of the spans. A run of "" is in the
  ## engine's own language. Returns empty when every rune is in base.
  if (base == "" or writesHan(base)) and not spansHaveLang(spans):
    return
  var span = 0
  var `from` = 0
  for i, r in text:
    var lang = base
    while span < spans.len and max(spans[span].`end`, `from`) <= i:
      `from` = max(spans[span].`end`, `from`)
      inc span
    if span < spans.len and spans[span].lang != "":
      lang = spans[span].lang
    if lang != "" and isCJK(r) and not writesHan(lang):
      lang = ""
    if lang != base:
      if result.len > 0 and result[^1].`end` == i and result[^1].lang == lang:
        result[^1].`end` = i + 1
      else:
        result.add langRun(start: i, `end`: i + 1, lang: lang)
