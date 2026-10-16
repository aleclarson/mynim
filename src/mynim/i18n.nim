## Package i18n reads the languages people read and picks, of those an
## app is written in, the one that suits them best, and says an app's
## messages in it.
##
## PORT STATUS: locale normalization and regional week/hour preferences
## use CLDR data. Message, number and date formatting are still being ported.

import std/[strutils, tables, times, atomics]
import ./i18n/cldr_regions as cldr

type
  Region* = object
    ## How a reader writes dates, times and numbers: the regional
    ## formats of their system, with the changes they made to them.
    ## locale is the locale of the formats, a BCP 47 tag such as "en-GB"
    ## or "de-DE", or "" when the system names none.
    locale*: string
    ## firstWeekday is the day calendars start their weeks on.
    firstWeekday*: WeekDay
    ## hourCycle is 12 for times with AM and PM, 24 for times without,
    ## or 0 when it is not known. The zero Region's weekday is ignored.
    hourCycle*: int

const
  ## The pseudo locales, which the generated catalog tests translate
  ## to.
  pseudoAccented* = "en-XA"
  pseudoDoubled* = "en-XB"
  pseudoBrackets* = "en-XC"

proc isPseudo*(locale: string): bool =
  ## Whether locale is a pseudo locale.
  let normalized = normalize(locale)
  normalized == pseudoAccented or normalized == pseudoDoubled or
    normalized == pseudoBrackets

# modifierScripts are the scripts the modifiers of POSIX locales name.
const modifierScripts = {
  "latin": "Latn", "cyrillic": "Cyrl", "arabic": "Arab",
}.toTable

proc normalize*(locale: string): string =
  ## Returns locale as a BCP 47 tag in its canonical form, or "" when
  ## it names no language, as "C", "POSIX" or "". It reads BCP 47 tags
  ## in any case ("en-us" is "en-US"), POSIX locales ("zh_CN.UTF-8" is
  ## "zh-CN", "sr_RS@latin" is "sr-Latn-RS") and the old codes of a
  ## language ("iw" is "he", "in" is "id").
  var locale = locale.strip()
  var modifier = ""
  let at = locale.find('@')
  if at >= 0:
    modifier = locale[at + 1..^1]
    locale = locale[0..<at]
  let dot = locale.find('.')
  if dot >= 0:
    locale = locale[0..<dot]
  if locale == "" or locale.toUpperAscii() in ["C", "POSIX"]:
    return ""
  # POSIX separators to BCP 47.
  locale = locale.replace('_', '-')
  let parts = locale.split('-')
  if parts.len == 0 or parts[0].len == 0:
    return ""
  # Old language codes.
  var lang = parts[0].toLowerAscii()
  lang = case lang
    of "iw": "he"
    of "in": "id"
    of "ji": "yi"
    else: lang
  if lang.len < 2 or lang.len > 8:
    return ""
  var res = lang
  var script = ""
  var region = ""
  for p in parts[1..^1]:
    # A singleton begins a BCP 47 extension or private-use sequence.
    # Its two-character keys (for example "fw" and "hc") are not regions.
    if p.len == 1:
      break
    if p.len == 4 and p.allCharsInSet({'a'..'z', 'A'..'Z'}):
      script = p[0].toUpperAscii() & p[1..^1].toLowerAscii()
    elif (p.len == 2 and p.allCharsInSet({'a'..'z', 'A'..'Z'})) or
        (p.len == 3 and p.allCharsInSet({'0'..'9'})):
      region = p.toUpperAscii()
    # Variants are not needed for canonicalizing the base locale.
  if modifier.toLowerAscii() in modifierScripts:
    script = modifierScripts[modifier.toLowerAscii()]
  if script != "": res.add "-" & script
  if region != "": res.add "-" & region
  res

var localeState {.global.}: Atomic[pointer]
  ## the language the app shows, kept as a shared cstring

proc `locale`*(): string =
  ## The language the app shows, as "en" or "zh-Hans", as set by
  ## the app or matched from the system's.
  let p = localeState.load(moAcquire)
  if p == nil: "" else: $cast[cstring](p)

proc setLocale*(tag: string) =
  ## Sets the language the app shows. (Package mynim calls this.)
  let p = cast[ptr cstring](allocShared0(sizeof(cstring)))
  p[] = cstring(tag)
  var old = localeState.load(moAcquire)
  while not localeState.compareExchange(old, cast[pointer](p[]), moRelease, moAcquire):
    discard
  discard old

proc direction*(tag: string): string =
  ## "ltr" or "rtl": the direction the language is written in. The
  ## minimal port knows the RTL language codes.
  let normalized = normalize(tag)
  let lang = if normalized == "": "" else: normalized.split('-')[0]
  if lang in ["ar", "fa", "he", "ur", "sd", "ps", "ug", "yi", "dv",
              "ku", "ckb"]: "rtl" else: "ltr"

proc likelySubtag(tag: string): string =
  ## Returns the CLDR likely-subtag expansion for the canonical base tag.
  let key = normalize(tag)
  if key == "": return ""
  var low = 0
  var high = cldr.likelySubtags.len
  while low < high:
    let mid = low + (high - low) div 2
    if cldr.likelySubtags[mid].key < key:
      low = mid + 1
    else:
      high = mid
  if low < cldr.likelySubtags.len and cldr.likelySubtags[low].key == key:
    return cldr.likelySubtags[low].value
  ""

proc localeParts(tag: string): tuple[language, script, region: string] =
  let normalized = normalize(tag)
  if normalized == "": return
  let parts = normalized.split('-')
  result.language = parts[0]
  for p in parts[1..^1]:
    if p.len == 4:
      result.script = p
    elif p.len == 2 or (p.len == 3 and p.allCharsInSet({'0'..'9'})):
      result.region = p

proc likelyParts(tag: string): tuple[language, script, region: string] =
  let normalized = normalize(tag)
  if normalized == "": return
  var expanded = likelySubtag(normalized)
  if expanded == "":
    let parts = localeParts(normalized)
    if parts.script != "":
      expanded = likelySubtag(parts.language & "-" & parts.script)
    if expanded == "":
      expanded = likelySubtag(parts.language)
  if expanded != "":
    return localeParts(expanded)

proc unicodeKey(tag, wanted: string): string =
  ## Reads a Unicode locale extension key such as "fw" or "hc".
  let parts = tag.replace('_', '-').split('-')
  var start = -1
  for i in 1..<parts.len:
    if parts[i].toLowerAscii() == "u" and parts[i].len == 1:
      start = i + 1
      break
  if start < 0: return ""
  var i = start
  while i < parts.len and parts[i].len != 1:
    if parts[i].len != 2:
      inc i # Unicode extension attributes precede its keys.
      continue
    let key = parts[i].toLowerAscii()
    inc i
    var values: seq[string]
    while i < parts.len and parts[i].len > 2:
      values.add parts[i].toLowerAscii()
      inc i
    if key == wanted:
      return values.join("-")
  ""

proc regionOf(tag: string): string =
  let parts = localeParts(tag)
  if parts.region != "": return parts.region
  let likely = likelyParts(tag)
  if likely.region != "": return likely.region
  "001"

proc preferredHour(language, region: string): char =
  for key in [language & "-" & region, region, "001"]:
    var low = 0
    var high = cldr.hourData.len
    while low < high:
      let mid = low + (high - low) div 2
      if cldr.hourData[mid].key < key:
        low = mid + 1
      else:
        high = mid
    if low < cldr.hourData.len and cldr.hourData[low].key == key:
      return cldr.hourData[low].value
  'H'

proc cldrWeekDay(index: int): WeekDay =
  case index
  of 0: dSun
  of 1: dMon
  of 2: dTue
  of 3: dWed
  of 4: dThu
  of 5: dFri
  of 6: dSat
  else: dMon

proc cldrWeekDayIndex(day: WeekDay): int =
  case day
  of dSun: 0
  of dMon: 1
  of dTue: 2
  of dWed: 3
  of dThu: 4
  of dFri: 5
  of dSat: 6

proc formatLocale*(r: Region; lang: string): string =
  ## The locale a reader of lang with these regional formats writes
  ## numbers and dates in, with the regional settings as Unicode keys.
  var t = normalize(lang)
  if t == "" or isPseudo(lang): t = "en"
  if r.locale != "":
    let rt = normalize(r.locale)
    if rt != "":
      let targetRegion = localeParts(rt).region
      if targetRegion != "":
        let original = localeParts(t)
        var script = original.script
        if script == "":
          let originalLikely = likelyParts(t)
          let targetLikely = likelyParts(original.language & "-" & targetRegion)
          if originalLikely.script != targetLikely.script:
            script = originalLikely.script
        t = original.language
        if script != "": t.add "-" & script
        t.add "-" & targetRegion
  var ext: seq[string]
  if r.hourCycle == 12 or r.hourCycle == 24:
    ext.add "fw"
    ext.add ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][
      cldrWeekDayIndex(r.firstWeekday)]
    ext.add "hc"
    ext.add(if r.hourCycle == 12: "h12" else: "h23")
  if ext.len == 0: return t
  t & "-u-" & ext.join("-")

var appCatalogLanguages {.global.}: seq[string]

proc registerLanguages*(tags: seq[string]) =
  ## Registers the languages an app's catalog adds (i18n.Register's
  ## effect on Languages); the full catalog machinery lands with the
  ## rest of the i18n port.
  appCatalogLanguages = tags

proc languages*(): seq[string] =
  ## The languages of the registered catalogs (i18n.Languages).
  appCatalogLanguages

proc firstWeekday*(tag: string): WeekDay =
  ## The day the locale's calendars start weeks on, including its
  ## Unicode "fw" override, from CLDR supplemental week data.
  let override = unicodeKey(tag, "fw")
  if override != "":
    case override
    of "sun": return dSun
    of "mon": return dMon
    of "tue": return dTue
    of "wed": return dWed
    of "thu": return dThu
    of "fri": return dFri
    of "sat": return dSat
    else: discard
  let region = regionOf(tag)
  var low = 0
  var high = cldr.weekData.len
  while low < high:
    let mid = low + (high - low) div 2
    if cldr.weekData[mid].key < region:
      low = mid + 1
    else:
      high = mid
  if low < cldr.weekData.len and cldr.weekData[low].key == region:
    return cldrWeekDay(int(cldr.weekData[low].value and 0x0f'u8))
  dMon # The CLDR 001 default.

proc hourCycle*(tag: string): int =
  ## 12 or 24 by CLDR, including the Unicode "hc" override.
  case unicodeKey(tag, "hc")
  of "h11", "h12": return 12
  of "h23", "h24": return 24
  else: discard
  let parts = localeParts(tag)
  let preference = preferredHour(parts.language, regionOf(tag))
  if preference == 'h' or preference == 'K': 12 else: 24

proc `match`*(want, supported: seq[string]): string =
  ## The supported tag want likes best (i18n's match): an exact
  ## normalized tag first, then its language with a different
  ## region, then the language itself.
  var norm: seq[string]
  for t in supported:
    let n = normalize(t)
    if n != "": norm.add n
  for w0 in want:
    let w = normalize(w0)
    if w == "": continue
    if w in norm: return w
    let wl = w.split('-')[0]
    var langMatch = ""
    for t in norm:
      if t.split('-')[0] == wl:
        langMatch = t
        break
    if langMatch != "": return langMatch
  ""
