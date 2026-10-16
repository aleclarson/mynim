## Package i18n reads the languages people read and picks, of those an
## app is written in, the one that suits them best, and says an app's
## messages in it.
##
## PORT STATUS: regional preferences, CLDR names, and common date skeletons
## use CLDR data. Message/number formatting and full date pattern matching
## are still being ported.

import std/[strutils, tables, times, atomics, unicode]
import ./i18n/cldr_regions as cldr
import ./i18n/cldr_format_data as formatData

type
  NameWidth* = enum
    ## The width of a localized month, weekday, or day-period name.
    nameWide, nameAbbreviated, nameShort, nameNarrow

  DateOptions* = object
    ## Options for localized Gregorian date formatting.
    skeleton*: string
      ## CLDR fields in any order. Common forms include "yMd", "yMMMM",
      ## and "yMMMMd"; exact CLDR skeleton patterns are used when present.
    hourCycle*: int
      ## 12 or 24 to override the locale's hour cycle for hour fields.

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

proc findFormatLocale(tag: string): int =
  var low = 0
  var high = formatData.formatLocales.len
  while low < high:
    let mid = low + (high - low) div 2
    if formatData.formatLocales[mid] < tag:
      low = mid + 1
    else:
      high = mid
  if low < formatData.formatLocales.len and
      formatData.formatLocales[low] == tag:
    return low
  -1

proc addCandidate(candidates: var seq[string]; tag: string) =
  if tag == "": return
  for candidate in candidates:
    if candidate == tag: return
  candidates.add tag

proc formatLocaleIndex(tag: string): int =
  let normalized = normalize(tag)
  if normalized == "" or isPseudo(tag):
    return findFormatLocale("en")
  let parts = localeParts(normalized)
  let likely = likelyParts(normalized)
  let languageLikely = likelyParts(parts.language)
  var candidates: seq[string]
  if parts.script == "" and parts.region != "" and likely.script != "" and
      likely.script != languageLikely.script:
    addCandidate(candidates, parts.language & "-" & likely.script & "-" &
      parts.region)
  addCandidate(candidates, normalized)
  if parts.script != "":
    addCandidate(candidates, parts.language & "-" & parts.script)
  elif likely.script != "" and likely.script != languageLikely.script:
    addCandidate(candidates, parts.language & "-" & likely.script)
  addCandidate(candidates, parts.language)
  for candidate in candidates:
    let index = findFormatLocale(candidate)
    if index >= 0: return index
  findFormatLocale("en")

proc formatSlot(entries: openArray[formatData.FormatEntry];
                starts: openArray[uint32]; strings: openArray[string];
                locale, slot: int): string =
  if slot < 0 or slot > high(uint16).int or locale < 0 or
      locale >= formatData.formatParents.len:
    return ""
  var current = locale
  var remaining = formatData.formatParents.len
  while remaining > 0:
    let first = int(starts[current])
    let past = int(starts[current + 1])
    var low = first
    var high = past
    while low < high:
      let mid = low + (high - low) div 2
      if int(entries[mid].slot) < slot:
        low = mid + 1
      else:
        high = mid
    if low < past and int(entries[low].slot) == slot:
      let value = int(entries[low].value)
      if value < strings.len: return strings[value]
    if current == 0: break
    current = int(formatData.formatParents[current])
    dec remaining

proc dateSlot(locale, slot: int): string =
  formatSlot(formatData.dateEntries, formatData.dateStarts,
    formatData.dateStrings, locale, slot)

proc numberSlot(locale, slot: int): string =
  formatSlot(formatData.numberEntries, formatData.numberStarts,
    formatData.numberStrings, locale, slot)

proc monthWidthIndex(width: NameWidth): int =
  case width
  of nameAbbreviated, nameShort: 0
  of nameNarrow: 1
  of nameWide: 2

proc weekdayWidthIndex(width: NameWidth): int =
  case width
  of nameAbbreviated: 0
  of nameNarrow: 1
  of nameShort: 2
  of nameWide: 3

proc months*(locale: string; width = nameWide;
             standAlone = false): array[12, string] =
  ## Month names in locale, January first. Stand-alone names can differ
  ## from names used inside a date in some languages.
  let data = formatLocaleIndex(locale)
  let context = if standAlone: 1 else: 0
  let first = context * 36 + monthWidthIndex(width) * 12
  for i in 0..<result.len:
    result[i] = dateSlot(data, first + i)

proc weekdays*(locale: string; width = nameWide;
               standAlone = false): array[7, string] =
  ## Weekday names in locale, Sunday first, matching WeekDay's CLDR order.
  let data = formatLocaleIndex(locale)
  let context = if standAlone: 1 else: 0
  let first = 72 + context * 28 + weekdayWidthIndex(width) * 7
  for i in 0..<result.len:
    result[i] = dateSlot(data, first + i)

proc dayPeriods*(locale: string; width = nameWide):
    tuple[am, pm: string] =
  ## Localized names for the two halves of the day.
  let data = formatLocaleIndex(locale)
  let first = 128 + monthWidthIndex(width) * 12
  result.am = dateSlot(data, first)
  result.pm = dateSlot(data, first + 1)

proc preferredHourSymbol(locale: string): char =
  case unicodeKey(locale, "hc")
  of "h11": return 'K'
  of "h12": return 'h'
  of "h23": return 'H'
  of "h24": return 'k'
  else: discard
  let parts = localeParts(locale)
  preferredHour(parts.language, regionOf(locale))

proc localizedDigits(locale: string; data: int): array[10, string] =
  var text = if unicodeKey(locale, "nu") == "latn":
      numberSlot(data, 202)
    else:
      numberSlot(data, 191)
  if text == "": text = "0123456789"
  var i = 0
  for rune in text.runes:
    if i < result.len:
      result[i] = toUTF8(rune)
    inc i
  if i != result.len:
    for i in 0..<result.len:
      result[i] = $(char(ord('0') + i))

proc dateNumber(value, minDigits: int;
                 digits: array[10, string]): string =
  let ascii = $value
  for _ in 0..<max(0, minDigits - ascii.len):
    result.add digits[0]
  for ch in ascii:
    if ch in {'0'..'9'}:
      result.add digits[ord(ch) - ord('0')]
    else:
      result.add ch

proc dateField(locale: string; data: int; value: DateTime; field: char;
               width: int; digits: array[10, string]): string =
  case field
  of 'y', 'Y', 'u':
    let year = if width == 2: value.year mod 100 else: value.year
    return dateNumber(year, if width == 2: 2 else: width, digits)
  of 'M', 'L':
    let month = int(value.month)
    if width <= 2:
      return dateNumber(month, width, digits)
    let context = if field == 'L': 1 else: 0
    let nameWidth = case width
      of 3: 0
      of 5: 1
      else: 2
    return dateSlot(data, context * 36 + nameWidth * 12 + month - 1)
  of 'd':
    return dateNumber(value.monthday, width, digits)
  of 'E', 'e', 'c':
    let weekday = cldrWeekDayIndex(value.weekday)
    if field != 'E' and width <= 2:
      let first = cldrWeekDayIndex(firstWeekday(locale))
      return dateNumber((weekday - first + 7) mod 7 + 1, width, digits)
    let context = if field == 'c': 1 else: 0
    let nameWidth = case width
      of 4: 3
      of 5: 1
      of 6: 2
      else: 0
    return dateSlot(data, 72 + context * 28 + nameWidth * 7 + weekday)
  of 'G':
    let nameWidth = if width == 5: 1 elif width >= 4: 2 else: 0
    let era = if value.year <= 0: 0 else: 1
    return dateSlot(data, 164 + nameWidth * 2 + era)
  of 'a', 'b':
    let nameWidth = monthWidthIndex(if width == 5: nameNarrow
      elif width >= 4: nameWide else: nameAbbreviated)
    return dateSlot(data, 128 + nameWidth * 12 +
      (if value.hour < 12: 0 else: 1))
  of 'h':
    let hour = if value.hour mod 12 == 0: 12 else: value.hour mod 12
    return dateNumber(hour, width, digits)
  of 'H': return dateNumber(value.hour, width, digits)
  of 'K': return dateNumber(value.hour mod 12, width, digits)
  of 'k': return dateNumber(if value.hour == 0: 24 else: value.hour,
    width, digits)
  of 'm': return dateNumber(value.minute, width, digits)
  of 's': return dateNumber(value.second, width, digits)
  else:
    result = repeat(field, width)

proc appendQuoted(pattern: string; index: var int; output: var string) =
  inc index
  if index < pattern.len and pattern[index] == '\'':
    output.add '\''
    inc index
    return
  while index < pattern.len:
    if pattern[index] == '\'':
      if index + 1 < pattern.len and pattern[index + 1] == '\'':
        output.add '\''
        index += 2
      else:
        inc index
        return
    else:
      output.add pattern[index]
      inc index

proc formatPattern(locale: string; data: int; value: DateTime;
                   pattern: string; digits: array[10, string]): string =
  var i = 0
  while i < pattern.len:
    let ch = pattern[i]
    if ch == '\'':
      appendQuoted(pattern, i, result)
    elif ch in {'a'..'z', 'A'..'Z'}:
      var past = i + 1
      while past < pattern.len and pattern[past] == ch:
        inc past
      result.add dateField(locale, data, value, ch, past - i, digits)
      i = past
    else:
      result.add ch
      inc i

proc datePattern(locale: string; data: int; options: DateOptions): string =
  var skeleton = options.skeleton
  if skeleton == "": skeleton = "yMd"
  var hour = if options.hourCycle == 12: 'h'
    elif options.hourCycle == 24: 'H'
    else: preferredHourSymbol(locale)
  if options.hourCycle == 0:
    for ch in skeleton:
      if ch in {'h', 'H', 'K', 'k'}:
        hour = ch
        break
  if 'j' in skeleton:
    skeleton = skeleton.replace("j", $hour)
  elif options.hourCycle in [12, 24]:
    for ch in ['h', 'H', 'K', 'k']:
      skeleton = skeleton.replace($ch, $hour)
  for i, key in formatData.skeletons:
    if key == skeleton:
      let pattern = dateSlot(data, 214 + i)
      if pattern != "": return pattern
  if skeleton == "yMMMMd" or (skeleton.contains("d") and
      skeleton.count('M') >= 4):
    return dateSlot(data, 171) # CLDR long date pattern.
  if skeleton == "yMMMd":
    return dateSlot(data, 172) # CLDR medium date pattern.
  if skeleton == "yMd":
    return dateSlot(data, 173) # CLDR short date pattern fallback.
  for i, key in formatData.skeletons:
    if key == "yMd":
      return dateSlot(data, 214 + i)
  dateSlot(data, 171)

proc formatDate*(locale: string; value: DateTime;
                 options = DateOptions()): string =
  ## Formats a Gregorian date using CLDR names, patterns, and digits.
  ## Exact available skeleton patterns are used; yMMMMd and yMMMd use
  ## the matching long and medium CLDR date styles when no exact pattern
  ## is available. Other unmatched skeletons currently fall back to yMd;
  ## full DateTimePatternGenerator matching is still being ported.
  let data = formatLocaleIndex(locale)
  let digits = localizedDigits(locale, data)
  let pattern = datePattern(locale, data, options)
  formatPattern(locale, data, value, pattern, digits).replace("\u202f", " ")

proc formatInteger*(locale: string; value: int; minDigits = 1): string =
  ## Formats an integer without grouping, using the locale's numbering
  ## system and at least minDigits digits.
  let data = formatLocaleIndex(locale)
  dateNumber(value, minDigits, localizedDigits(locale, data))

proc timePattern*(locale: string; hourCycle = 0): string =
  ## Returns the CLDR pattern for hours and minutes. hourCycle may be 12 or
  ## 24 to override the locale's preference.
  let data = formatLocaleIndex(locale)
  datePattern(locale, data, DateOptions(skeleton: "jm",
    hourCycle: hourCycle)).replace("\u202f", " ")

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
