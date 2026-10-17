## Package i18n reads the languages people read and picks, of those an
## app is written in, the one that suits them best, and says an app's
## messages in it.
##
## PORT STATUS: regional preferences, localized number formatting, plural
## rules, names, and common date skeletons use CLDR data. ICU message
## parsing, choice evaluation, number styles, date/time styles, and the
## en-XA/ar-XB pseudo locales are supported, along with runtime catalog
## lookup and locale fallback. Full date pattern matching and generated typed
## catalog accessors are still being ported.

import std/[strutils, tables, times, atomics, unicode, math, json, algorithm,
  locks]
import ./i18n/cldr_regions as cldr
import ./i18n/cldr_parents as parentData
import ./i18n/cldr_format_data as formatData
import ./i18n/message as messageFormat
import ./i18n/plural as pluralRuntime
export messageFormat

type
  Plural* = pluralRuntime.Plural
  PluralOperands* = pluralRuntime.PluralOperands

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

  NumberOptions* = object
    ## Options for localized decimal and percent formatting.
    percent*: bool
      ## Multiplies by 100 and uses the locale's percent pattern.
    integer*: bool
      ## Rounds to an integer, using half-even rounding when requested by ICU.
    minFractionDigits*: int
    maxFractionDigits*: int
      ## A zero maximum selects the locale pattern's default.
    minIntegerDigits*: int
    noGrouping*: bool
    halfEven*: bool

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

  CatalogFile* = object
    ## One ARB-style catalog: a canonical BCP 47 locale and its JSON text.
    locale*: string
    contents*: string

  Catalog* = ref object
    sourceTag: string
    namespaceTag: string
    localeTags: seq[string]
    messages: Table[string, Table[string, messageFormat.Message]]

const
  pluralZero* = pluralRuntime.pluralZero
  pluralOne* = pluralRuntime.pluralOne
  pluralTwo* = pluralRuntime.pluralTwo
  pluralFew* = pluralRuntime.pluralFew
  pluralMany* = pluralRuntime.pluralMany
  pluralOther* = pluralRuntime.pluralOther

  ## The pseudo locales, which the generated catalog tests translate
  ## to.
  pseudoAccented* = "en-XA"
  pseudoDoubled* = "en-XB"
  pseudoBrackets* = "en-XC"
  pseudoBidi* = "ar-XB"

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

proc isPseudo*(locale: string): bool =
  ## Whether locale is a pseudo locale.
  let normalized = normalize(locale)
  normalized in [pseudoAccented, pseudoDoubled, pseudoBrackets, pseudoBidi]

proc pluralName*(plural: Plural): string = pluralRuntime.pluralName(plural)

proc parsePlural*(name: string): tuple[value: Plural, ok: bool] =
  pluralRuntime.parsePlural(name)

proc parsePluralOperands*(value: string):
    tuple[operands: PluralOperands, ok: bool] =
  pluralRuntime.parsePluralOperands(value)

proc newPluralOperands*(value: string): PluralOperands =
  pluralRuntime.newPluralOperands(value)

proc newPluralOperands*[T: SomeInteger](value: T): PluralOperands =
  pluralRuntime.newPluralOperands(value)

proc newPluralOperands*[T: SomeFloat](value: T): PluralOperands =
  pluralRuntime.newPluralOperands(value)

proc pluralCategory*(locale: string; operands: PluralOperands): Plural =
  pluralRuntime.cardinalCategory(normalize(locale), operands)

proc ordinalCategory*(locale: string; operands: PluralOperands): Plural =
  pluralRuntime.ordinalCategory(normalize(locale), operands)

proc pluralCategories*(locale: string): seq[Plural] =
  pluralRuntime.pluralCategories(normalize(locale))

proc ordinalCategories*(locale: string): seq[Plural] =
  pluralRuntime.ordinalCategories(normalize(locale))

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
var catalogRegistryLock {.global.}: Lock
var registeredCatalogs {.global.}: seq[Catalog]
initLock(catalogRegistryLock)

proc registerLanguages*(tags: seq[string]) =
  ## Registers app catalog languages for generated-accessor integrations.
  withLock catalogRegistryLock:
    appCatalogLanguages.setLen(0)
    for tag in tags:
      let normalized = normalize(tag)
      if normalized != "" and normalized notin appCatalogLanguages:
        appCatalogLanguages.add normalized

proc languages*(): seq[string] =
  ## The unique languages shipped by registered app catalogs, sorted.
  var hasCatalogs = false
  withLock catalogRegistryLock:
    for tag in appCatalogLanguages: result.add tag
    for catalog in registeredCatalogs:
      hasCatalogs = true
      for tag in catalog.localeTags:
        if tag notin result: result.add tag
  if hasCatalogs: result.sort()

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

type
  NumberPattern = object
    prefix, suffix, negativePrefix, negativeSuffix: string
    primaryGroup, secondaryGroup: int
    minimumInteger, minimumFraction, maximumFraction: int

  NumberSystem = object
    digits: array[10, string]
    latin: bool
    decimalSeparator, groupSeparator, minusSign, plusSign, percentSign: string
    infinity, nan: string
    minimumGrouping: int
    decimal, percent: NumberPattern

proc numberAffix(text: string; system: NumberSystem): string =
  var i = 0
  var quoted = false
  while i < text.len:
    if text[i] == '\'':
      if i + 1 < text.len and text[i + 1] == '\'':
        result.add '\''
        i += 2
      else:
        quoted = not quoted
        inc i
    elif quoted:
      let size = text.runeLenAt(i)
      result.add text[i ..< i + size]
      i += size
    else:
      case text[i]
      of '%':
        result.add system.percentSign
        inc i
      of '-':
        result.add system.minusSign
        inc i
      of '+':
        result.add system.plusSign
        inc i
      else:
        let size = text.runeLenAt(i)
        result.add text[i ..< i + size]
        i += size

proc splitNumberPattern(text: string; system: NumberSystem):
    tuple[prefix, number, suffix: string] =
  var first = -1
  var past = -1
  var quoted = false
  var i = 0
  while i < text.len:
    let ch = text[i]
    if ch == '\'':
      if i + 1 < text.len and text[i + 1] == '\'':
        i += 2
        continue
      quoted = not quoted
    elif not quoted and ch in {'#', '0', ',', '.', '@'}:
      if first < 0: first = i
      past = i + 1
    inc i
  if first < 0:
    return (numberAffix(text, system), "", "")
  (numberAffix(text[0 ..< first], system), text[first ..< past],
    numberAffix(text[past .. ^1], system))

proc parseNumberPattern(text: string; system: NumberSystem): NumberPattern =
  let splitAt = text.find(';')
  let positive = if splitAt < 0: text else: text[0 ..< splitAt]
  let negative = if splitAt < 0: "" else: text[splitAt + 1 .. ^1]
  let parts = splitNumberPattern(positive, system)
  result.prefix = parts.prefix
  result.suffix = parts.suffix
  let negativeParts = if negative.len > 0:
      splitNumberPattern(negative, system)
    else:
      (prefix: system.minusSign & result.prefix, number: parts.number,
        suffix: result.suffix)
  result.negativePrefix = negativeParts.prefix
  result.negativeSuffix = negativeParts.suffix
  let decimal = parts.number.find('.')
  let integerPart = if decimal < 0: parts.number else: parts.number[0 ..< decimal]
  let fractionPart = if decimal < 0: "" else: parts.number[decimal + 1 .. ^1]
  result.minimumFraction = fractionPart.count('0')
  result.maximumFraction = fractionPart.len
  let lastGroup = integerPart.rfind(',')
  if lastGroup >= 0:
    result.primaryGroup = integerPart.len - lastGroup - 1
    result.secondaryGroup = result.primaryGroup
    let previousGroup = integerPart[0 ..< lastGroup].rfind(',')
    if previousGroup >= 0:
      result.secondaryGroup = lastGroup - previousGroup - 1
  result.minimumInteger = integerPart.count('0')

proc numberSystem(locale: string; data: int): NumberSystem =
  var base = 191
  if unicodeKey(locale, "nu") == "latn" and numberSlot(data, 202) != "":
    base = 202
  var digitText = numberSlot(data, base)
  if digitText == "": digitText = "0123456789"
  var digitIndex = 0
  for rune in digitText.runes:
    if digitIndex < result.digits.len:
      result.digits[digitIndex] = toUTF8(rune)
    inc digitIndex
  if digitIndex != result.digits.len:
    for i in 0 ..< result.digits.len:
      result.digits[i] = $(char(ord('0') + i))
  result.latin = digitText == "0123456789"
  result.decimalSeparator = numberSlot(data, base + 1)
  result.groupSeparator = numberSlot(data, base + 2)
  result.minusSign = numberSlot(data, base + 3)
  result.plusSign = numberSlot(data, base + 4)
  result.percentSign = numberSlot(data, base + 5)
  result.infinity = numberSlot(data, base + 7)
  result.nan = numberSlot(data, base + 8)
  if result.decimalSeparator == "": result.decimalSeparator = "."
  if result.groupSeparator == "": result.groupSeparator = ","
  if result.minusSign == "": result.minusSign = "-"
  if result.plusSign == "": result.plusSign = "+"
  if result.percentSign == "": result.percentSign = "%"
  if result.infinity == "": result.infinity = "∞"
  if result.nan == "": result.nan = "NaN"
  result.minimumGrouping = 1
  try:
    let parsed = parseInt(numberSlot(data, 213))
    if parsed > 0: result.minimumGrouping = parsed
  except ValueError:
    discard
  var decimalPattern = numberSlot(data, base + 9)
  var percentPattern = numberSlot(data, base + 10)
  if decimalPattern == "": decimalPattern = "#,##0.###"
  if percentPattern == "": percentPattern = "#,##0%"
  result.decimal = parseNumberPattern(decimalPattern, result)
  result.percent = parseNumberPattern(percentPattern, result)

proc decimalParts(value: string): tuple[negative: bool, integer, fraction: string] =
  var value = value
  if value.startsWith("-"):
    result.negative = true
    value = value[1 .. ^1]
  elif value.startsWith("+"):
    value = value[1 .. ^1]
  let point = value.find('.')
  result.integer = if point < 0: value else: value[0 ..< point]
  result.fraction = if point < 0: "" else: value[point + 1 .. ^1]
  result.integer = result.integer.strip(leading = true, trailing = false,
    chars = {'0'})
  if result.integer.len == 0: result.integer = "0"

proc validDecimal(value: string): bool =
  if value.len == 0: return false
  var start = if value[0] in {'-', '+'}: 1 else: 0
  if start >= value.len: return false
  var point = false
  var digits = 0
  for i in start ..< value.len:
    let ch = value[i]
    if ch in {'0'..'9'}:
      inc digits
    elif ch == '.' and not point and i > start and i < value.high:
      point = true
    else:
      return false
  digits > 0

proc roundFraction(integer, fraction: string; maximum: int;
    halfEven: bool): tuple[integer, fraction: string] =
  if fraction.len <= maximum:
    return (integer, fraction)
  result.integer = integer
  result.fraction = fraction[0 ..< maximum]
  let dropped = fraction[maximum .. ^1]
  let first = dropped[0]
  var roundUp = first > '5'
  if first == '5':
    let laterNonzero = dropped.len > 1 and dropped[1 .. ^1].strip(chars = {'0'}).len > 0
    if laterNonzero or not halfEven:
      roundUp = true
    else:
      let previous = if result.fraction.len > 0: result.fraction[^1]
        else: result.integer[^1]
      roundUp = (ord(previous) - ord('0')) mod 2 != 0
  if not roundUp: return
  var digits = result.integer & result.fraction
  var i = digits.high
  while i >= 0 and digits[i] == '9':
    digits[i] = '0'
    dec i
  if i < 0:
    digits = "1" & digits
  else:
    inc digits[i]
  let integerLength = digits.len - result.fraction.len
  result.integer = digits[0 ..< integerLength]
  result.fraction = if result.fraction.len == 0: ""
    else: digits[integerLength .. ^1]

proc writeNumberDigits(system: NumberSystem; digits: string): string =
  if system.latin: return digits
  for ch in digits:
    if ch in {'0'..'9'}:
      result.add system.digits[ord(ch) - ord('0')]
    else:
      result.add ch

proc writeGroupedInteger(system: NumberSystem; pattern: NumberPattern;
    integer: string; options: NumberOptions): string =
  var integer = integer
  let minimum = max(pattern.minimumInteger, options.minIntegerDigits)
  if integer.len < minimum:
    integer = repeat('0', minimum - integer.len) & integer
  let primary = pattern.primaryGroup
  let secondary = max(1, pattern.secondaryGroup)
  if options.noGrouping or primary <= 0 or
      integer.len < primary + system.minimumGrouping:
    return writeNumberDigits(system, integer)
  var first = (integer.len - primary) mod secondary
  if first == 0: first = secondary
  var position = 0
  var width = first
  while position < integer.len:
    result.add writeNumberDigits(system, integer[position ..< position + width])
    position += width
    if position < integer.len:
      result.add system.groupSeparator
    if integer.len - position == primary:
      width = primary
    else:
      width = secondary

proc formatNumberDecimal(locale, value: string; options: NumberOptions;
    exact = false): string =
  let decimalValue = value.strip()
  if not validDecimal(decimalValue): return value
  let data = formatLocaleIndex(locale)
  let system = numberSystem(locale, data)
  var selected = if options.percent: system.percent else: system.decimal
  var minFraction = max(0, options.minFractionDigits)
  var maxFraction = options.maxFractionDigits
  if options.integer:
    minFraction = 0
    maxFraction = 0
  elif maxFraction <= 0 and minFraction == 0:
    maxFraction = selected.maximumFraction
  if maxFraction < minFraction: maxFraction = minFraction
  if exact and options.minFractionDigits == 0 and
      options.maxFractionDigits == 0 and not options.percent and
      not options.integer:
    let point = decimalValue.find('.')
    let digits = if point < 0: 0 else: decimalValue.len - point - 1
    minFraction = min(digits, 100)
    maxFraction = min(digits, 100)
  var parts = decimalParts(decimalValue)
  if options.percent:
    var shift = 2
    while shift > 0 and parts.fraction.len > 0:
      parts.integer.add parts.fraction[0]
      parts.fraction = parts.fraction[1 .. ^1]
      dec shift
    if shift > 0: parts.integer.add repeat('0', shift)
    parts.integer = parts.integer.strip(leading = true, trailing = false,
      chars = {'0'})
    if parts.integer.len == 0: parts.integer = "0"
  let rounded = roundFraction(parts.integer, parts.fraction, maxFraction,
    options.halfEven)
  parts.integer = rounded.integer
  parts.fraction = rounded.fraction
  while parts.fraction.len > minFraction and parts.fraction[^1] == '0':
    parts.fraction.setLen(parts.fraction.len - 1)
  while parts.fraction.len < minFraction:
    parts.fraction.add '0'
  result = if parts.negative: selected.negativePrefix else: selected.prefix
  result.add writeGroupedInteger(system, selected, parts.integer, options)
  if parts.fraction.len > 0:
    result.add system.decimalSeparator
    result.add writeNumberDigits(system, parts.fraction)
  result.add if parts.negative: selected.negativeSuffix else: selected.suffix

proc formatNumber*(locale: string; value: string;
    options = NumberOptions()): string =
  ## Formats a decimal string with CLDR number symbols. Decimal strings
  ## keep their written fraction digits unless the options round them.
  formatNumberDecimal(locale, value, options, exact = true)

proc formatNumber*[T: SomeInteger](locale: string; value: T;
    options = NumberOptions()): string =
  formatNumberDecimal(locale, $value, options)

proc formatNumber*[T: SomeFloat](locale: string; value: T;
    options = NumberOptions()): string =
  if classify(value) == fcNan:
    let system = numberSystem(locale, formatLocaleIndex(locale))
    let pattern = if options.percent: system.percent else: system.decimal
    return pattern.prefix & system.nan & pattern.suffix
  if classify(value) in {fcInf, fcNegInf}:
    let system = numberSystem(locale, formatLocaleIndex(locale))
    let pattern = if options.percent: system.percent else: system.decimal
    return if classify(value) == fcNegInf:
        pattern.negativePrefix & system.infinity & pattern.negativeSuffix
      else: pattern.prefix & system.infinity & pattern.suffix
  var decimal = formatFloat(float64(value), ffDecimal, -1)
  if decimal.endsWith("."): decimal.setLen(decimal.len - 1)
  formatNumberDecimal(locale, decimal, options)

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

proc icuNumberOptions(style: string): NumberOptions =
  let stems = if style.startsWith("::"):
      strutils.splitWhitespace(style[2 .. ^1])
    elif style.strip().len > 0:
      @[style.strip()]
    else:
      @[]
  for stem in stems:
    case stem
    of "integer", "precision-integer":
      result.integer = true
      result.halfEven = true
    of "percent":
      result.percent = true
      result.halfEven = true
    of "group-off":
      result.noGrouping = true
    else:
      if stem.len > 1 and stem[0] == '.' and
          stem[1 .. ^1].allCharsInSet({'0', '#'}):
        result.minFractionDigits = stem.count('0')
        result.maxFractionDigits = stem.len - 1

proc formatMessageNumber(locale, value, style: string;
    exact: bool): string =
  let options = icuNumberOptions(style)
  formatNumberDecimal(locale, value, options, exact)

proc dateStyleIndex(style: string): int =
  case style
  of "full": 0
  of "long": 1
  of "short": 3
  else: 2

proc formatMessageDate(locale: string; value: DateTime; kind, style: string):
    string =
  let data = formatLocaleIndex(locale)
  let digits = localizedDigits(locale, data)
  var pattern: string
  if style.startsWith("::"):
    pattern = datePattern(locale, data,
      DateOptions(skeleton: style[2 .. ^1].strip()))
  elif kind == "date":
    pattern = dateSlot(data, 170 + dateStyleIndex(style))
  elif kind == "time":
    pattern = dateSlot(data, 174 + dateStyleIndex(style))
  else:
    let dateIndex = dateStyleIndex("short")
    let datePattern = dateSlot(data, 170 + dateIndex)
    let timePattern = dateSlot(data, 174 + dateIndex)
    pattern = dateSlot(data, 182 + dateIndex)
    if pattern == "": pattern = dateSlot(data, 178 + dateIndex)
    if pattern == "": pattern = "{1} {0}"
    pattern = pattern.replace("{1}", datePattern).replace("{0}", timePattern)
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

type
  MessagePseudoKind = enum
    messagePseudoNone, messagePseudoAccent, messagePseudoBidi

  MessagePseudo = object
    kind: MessagePseudoKind
    textLength: int

  MessagePound = object
    active, numeric, exact: bool
    decimal: string
    raw: messageFormat.FormatArg

const
  pseudoAccents: array[20, string] = [
    "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]

proc pseudoSpace(rune: Rune): bool =
  let codepoint = int(rune)
  codepoint in [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000] or codepoint in 0x2000..0x200A

proc accentRune(rune: Rune): string =
  if int(rune) > 0x7F: return toUTF8(rune)
  case char(int(rune))
  of 'a': "å"
  of 'b': "ƀ"
  of 'c': "ç"
  of 'd': "ð"
  of 'e': "é"
  of 'f': "ƒ"
  of 'g': "ĝ"
  of 'h': "ĥ"
  of 'i': "î"
  of 'j': "ĵ"
  of 'k': "ķ"
  of 'l': "ļ"
  of 'm': "ɱ"
  of 'n': "ñ"
  of 'o': "ö"
  of 'p': "þ"
  of 'q': "ǫ"
  of 'r': "ŕ"
  of 's': "š"
  of 't': "ţ"
  of 'u': "û"
  of 'v': "ṽ"
  of 'w': "ŵ"
  of 'x': "ẋ"
  of 'y': "ý"
  of 'z': "ž"
  of 'A': "Å"
  of 'B': "Ɓ"
  of 'C': "Ç"
  of 'D': "Ð"
  of 'E': "É"
  of 'F': "Ƒ"
  of 'G': "Ĝ"
  of 'H': "Ĥ"
  of 'I': "Î"
  of 'J': "Ĵ"
  of 'K': "Ķ"
  of 'L': "Ļ"
  of 'M': "Ṁ"
  of 'N': "Ñ"
  of 'O': "Ö"
  of 'P': "Þ"
  of 'Q': "Ǫ"
  of 'R': "Ŕ"
  of 'S': "Š"
  of 'T': "Ţ"
  of 'U': "Û"
  of 'V': "Ṽ"
  of 'W': "Ŵ"
  of 'X': "Ẋ"
  of 'Y': "Ý"
  of 'Z': "Ž"
  else: toUTF8(rune)

proc pseudoText(pseudo: var MessagePseudo; text: string): string =
  case pseudo.kind
  of messagePseudoNone:
    result = text
  of messagePseudoAccent:
    for rune in text.runes:
      result.add accentRune(rune)
      inc pseudo.textLength
  of messagePseudoBidi:
    var word = ""
    for rune in text.runes:
      if pseudoSpace(rune):
        if word.len > 0:
          result.add "\u200f\u202e" & word & "\u202c\u200f"
          word.setLen(0)
        result.add toUTF8(rune)
      else:
        word.add toUTF8(rune)
    if word.len > 0:
      result.add "\u200f\u202e" & word & "\u202c\u200f"

proc pseudoPlaceholder(pseudo: MessagePseudo; value: string): string =
  if pseudo.kind == messagePseudoBidi:
    "\u200f" & value & "\u200f"
  else:
    value

proc trimMagnitude(value: string): string =
  result = value.strip(leading = true, trailing = false, chars = {'0'})
  if result.len == 0: result = "0"

proc compareMagnitude(a, b: string): int =
  let a = trimMagnitude(a)
  let b = trimMagnitude(b)
  if a.len < b.len: return -1
  if a.len > b.len: return 1
  if a < b: return -1
  if a > b: return 1
  0

proc addMagnitude(a, b: string): string =
  var left = a.high
  var right = b.high
  var carry = 0
  var reversed = ""
  while left >= 0 or right >= 0 or carry > 0:
    let x = if left >= 0: ord(a[left]) - ord('0') else: 0
    let y = if right >= 0: ord(b[right]) - ord('0') else: 0
    let sum = x + y + carry
    reversed.add char(ord('0') + sum mod 10)
    carry = sum div 10
    dec left
    dec right
  result = newString(reversed.len)
  for i, ch in reversed:
    result[reversed.high - i] = ch

proc subtractMagnitude(a, b: string): string =
  ## Subtracts nonnegative decimal b from a, where a >= b.
  var left = a.high
  var right = b.high
  var borrow = 0
  var reversed = ""
  while left >= 0:
    var digit = ord(a[left]) - ord('0') - borrow
    let other = if right >= 0: ord(b[right]) - ord('0') else: 0
    if digit < other:
      digit += 10
      borrow = 1
    else:
      borrow = 0
    reversed.add char(ord('0') + digit - other)
    dec left
    dec right
  result = newString(reversed.len)
  for i, ch in reversed:
    result[reversed.high - i] = ch
  result = trimMagnitude(result)

proc canonicalDecimal(value: string): string =
  let value = value.strip()
  if not validDecimal(value): return ""
  let parts = decimalParts(value)
  var fraction = parts.fraction
  while fraction.len > 0 and fraction[^1] == '0':
    fraction.setLen(fraction.len - 1)
  let isZero = parts.integer == "0" and fraction.len == 0
  if parts.negative and not isZero: result.add '-'
  result.add parts.integer
  if fraction.len > 0:
    result.add '.'
    result.add fraction

proc subtractPluralOffset(value: string; offset: int64): string =
  if offset <= 0: return value
  let parts = decimalParts(value)
  let scale = parts.fraction.len
  let left = trimMagnitude(parts.integer & parts.fraction)
  let right = trimMagnitude($offset & repeat('0', scale))
  var negative = parts.negative
  var magnitude: string
  if parts.negative:
    magnitude = addMagnitude(left, right)
  elif compareMagnitude(left, right) >= 0:
    magnitude = subtractMagnitude(left, right)
  else:
    magnitude = subtractMagnitude(right, left)
    negative = true
  if magnitude.len <= scale:
    magnitude = repeat('0', scale + 1 - magnitude.len) & magnitude
  let integerLength = magnitude.len - scale
  let integer = magnitude[0 ..< integerLength]
  let fraction = if scale == 0: "" else: magnitude[integerLength .. ^1]
  if negative and trimMagnitude(magnitude) != "0": result.add '-'
  result.add integer
  if scale > 0:
    result.add '.'
    result.add fraction

proc numericArgument(arg: messageFormat.FormatArg):
    tuple[value: string, exact, ok: bool] =
  case arg.kind
  of messageFormat.formatNumberArg:
    result.value = arg.text
    result.exact = arg.exact
    result.ok = validDecimal(arg.text)
  of messageFormat.formatStringArg:
    result.value = arg.text
    result.exact = true
    result.ok = validDecimal(arg.text)
  else:
    discard

proc formatArgumentValue(locale: string; arg: messageFormat.FormatArg): string =
  case arg.kind
  of messageFormat.formatStringArg: result = arg.text
  of messageFormat.formatNumberArg:
    result = formatNumberDecimal(locale, arg.text, NumberOptions(), arg.exact)
  of messageFormat.formatBooleanArg:
    result = if arg.boolean: "true" else: "false"
  of messageFormat.formatDateTimeArg:
    result = formatMessageDate(locale, arg.dateTime, "datetime", "short")
  of messageFormat.formatNullArg: result = ""

proc selectedMessageCase(cases: seq[messageFormat.MessageCase];
    key: string): messageFormat.MessageCase =
  for messageCase in cases:
    if messageCase.key == key: return messageCase
  for messageCase in cases:
    if messageCase.key == "other": return messageCase

proc selectValueKey(arg: messageFormat.FormatArg): string =
  case arg.kind
  of messageFormat.formatStringArg: result = arg.text
  of messageFormat.formatNumberArg:
    result = canonicalDecimal(arg.text)
    if result.len == 0: result = arg.text
  of messageFormat.formatBooleanArg:
    result = if arg.boolean: "true" else: "false"
  of messageFormat.formatDateTimeArg:
    result = arg.dateTime.format("yyyy-MM-dd'T'HH:mm:ss")
  of messageFormat.formatNullArg: result = ""

proc formatMessageNodes(nodes: seq[messageFormat.MessageNode];
    args: Table[string, messageFormat.FormatArg]; locale, ruleLocale: string;
    pound: MessagePound; pseudo: var MessagePseudo): string

proc formatMessageChoice(node: messageFormat.MessageNode;
    arg: messageFormat.FormatArg; args: Table[string, messageFormat.FormatArg];
    locale, ruleLocale: string; pound: MessagePound;
    pseudo: var MessagePseudo): string =
  if node.kind == messageFormat.messageSelect:
    let selected = selectedMessageCase(node.cases, selectValueKey(arg))
    return formatMessageNodes(selected.nodes, args, locale, ruleLocale, pound,
      pseudo)

  let number = numericArgument(arg)
  var selectedKey = "other"
  var nextPound = MessagePound(active: true, raw: arg)
  if number.ok:
    let originalParts = decimalParts(number.value)
    if not originalParts.negative:
      let exactNumber = canonicalDecimal(number.value)
      for messageCase in node.cases:
        if messageCase.exact.len > 0 and
            canonicalDecimal(messageCase.exact) == exactNumber:
          selectedKey = messageCase.key
          break
    let adjusted = subtractPluralOffset(number.value, node.offset)
    nextPound = MessagePound(active: true, numeric: true,
      exact: number.exact, decimal: adjusted, raw: arg)
    if selectedKey == "other":
      let categoryValue = if number.exact: adjusted else:
        formatNumberDecimal("en", adjusted,
          NumberOptions(noGrouping: true), exact = false)
      let parsed = pluralRuntime.parsePluralOperands(categoryValue)
      if parsed.ok:
        let category = if node.kind == messageFormat.messageSelectOrdinal:
            ordinalCategory(ruleLocale, parsed.operands)
          else:
            pluralCategory(ruleLocale, parsed.operands)
        selectedKey = pluralName(category)
  let selected = selectedMessageCase(node.cases, selectedKey)
  formatMessageNodes(selected.nodes, args, locale, ruleLocale, nextPound, pseudo)

proc formatMessageNodes(nodes: seq[messageFormat.MessageNode];
    args: Table[string, messageFormat.FormatArg]; locale, ruleLocale: string;
    pound: MessagePound; pseudo: var MessagePseudo): string =
  for node in nodes:
    case node.kind
    of messageFormat.messageText:
      result.add pseudoText(pseudo, node.text)
    of messageFormat.messagePound:
      if not pound.active:
        result.add '#'
      elif pound.numeric:
        result.add pseudoPlaceholder(pseudo, formatNumberDecimal(locale,
          pound.decimal, NumberOptions(), pound.exact))
      else:
        result.add pseudoPlaceholder(pseudo,
          formatArgumentValue(locale, pound.raw))
    else:
      if node.text notin args:
        result.add "{" & node.text & "}"
        continue
      let arg = args[node.text]
      case node.kind
      of messageFormat.messageArgument:
        result.add pseudoPlaceholder(pseudo, formatArgumentValue(locale, arg))
      of messageFormat.messageNumber:
        let number = numericArgument(arg)
        if number.ok:
          result.add pseudoPlaceholder(pseudo, formatMessageNumber(locale,
            number.value, node.style, number.exact))
        else:
          result.add pseudoPlaceholder(pseudo, formatArgumentValue(locale, arg))
      of messageFormat.messageDate, messageFormat.messageTime:
        if arg.kind == messageFormat.formatDateTimeArg:
          let kind = if node.kind == messageFormat.messageDate: "date" else: "time"
          result.add pseudoPlaceholder(pseudo, formatMessageDate(locale,
            arg.dateTime, kind, node.style))
        else:
          result.add pseudoPlaceholder(pseudo, formatArgumentValue(locale, arg))
      of messageFormat.messageSelect, messageFormat.messagePlural,
          messageFormat.messageSelectOrdinal:
        result.add formatMessageChoice(node, arg, args, locale, ruleLocale,
          pound, pseudo)
      of messageFormat.messageText, messageFormat.messagePound:
        discard

proc formatMessage(message: messageFormat.Message; locale, messageLocale: string;
    args: openArray[messageFormat.FormatArg]): string =
  if message.isNil: return ""
  var values = initTable[string, messageFormat.FormatArg]()
  for arg in args:
    values[arg.name] = arg
  let tag = normalize(locale)
  let pseudoLocale = isPseudo(locale)
  let ruleLocale = if normalize(messageLocale) == "": "en"
    else: normalize(messageLocale)
  let formatLocale = if pseudoLocale:
      (if ruleLocale == "": "en" else: ruleLocale)
    elif locale == "": ruleLocale
    else: locale
  var pseudo = MessagePseudo()
  if tag == pseudoAccented:
    pseudo.kind = messagePseudoAccent
  elif tag == pseudoBidi:
    pseudo.kind = messagePseudoBidi
  result = formatMessageNodes(message.nodes, values, formatLocale, ruleLocale,
    MessagePound(), pseudo)
  if pseudo.kind == messagePseudoAccent:
    let padding = (pseudo.textLength * 2 + 4) div 5
    var padded = result
    var paddedLength = 0
    var index = 0
    while paddedLength < padding:
      let word = pseudoAccents[index mod pseudoAccents.len]
      padded.add " " & word
      paddedLength += 1 + word.len
      inc index
    result = "[" & padded & "]"

proc format*(message: messageFormat.Message; locale: string;
    args: varargs[messageFormat.FormatArg]): string =
  ## Formats an ICU message using localized number/date data and CLDR plural
  ## rules. Missing arguments keep their `{name}` spelling. en-XA accents and
  ## pads message text; ar-XB adds bidirectional test markers.
  let messageLocale = if isPseudo(locale): "en" else: locale
  formatMessage(message, locale, messageLocale, args)

proc parent*(tag: string): string =
  ## Returns the CLDR parent locale, or "" when tag is its root.
  ## Unicode extensions and variants are removed before finding the parent.
  var base = tag.strip()
  let at = base.find('@')
  if at >= 0: base.setLen(at)
  let dot = base.find('.')
  if dot >= 0: base.setLen(dot)
  base = base.replace('_', '-')
  let rawParts = base.split('-')
  for i in 1 ..< rawParts.len:
    let part = rawParts[i]
    if part.len == 1: break
    let isVariant = (part.len >= 5 and part.len <= 8 and
        part.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9'})) or
      (part.len == 4 and part[0] in {'0'..'9'} and
        part.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9'}))
    if isVariant:
      return normalize(rawParts[0 ..< i].join("-"))

  let normalized = normalize(tag)
  if normalized == "": return ""
  var low = 0
  var high = parentData.parentLocales.len
  while low < high:
    let mid = low + (high - low) div 2
    if parentData.parentLocales[mid].child < normalized:
      low = mid + 1
    else:
      high = mid
  if low < parentData.parentLocales.len and
      parentData.parentLocales[low].child == normalized:
    return parentData.parentLocales[low].parent

  let separator = normalized.rfind('-')
  if separator < 0: return ""
  let language = normalized[0 ..< normalized.find('-')]
  let rest = normalized[normalized.find('-') + 1 .. ^1]
  if rest.len == 4 and rest.allCharsInSet({'a'..'z', 'A'..'Z'}):
    let usual = likelyParts(language)
    if usual.script != "" and usual.script != rest:
      return ""
  normalized[0 ..< separator]

proc parentChain(tag: string): seq[string] =
  var current = normalize(tag)
  while current != "" and result.len < 8:
    result.add current
    current = parent(current)

proc `match`*(want, supported: seq[string]): string =
  ## Returns the supported language that best matches the preferences,
  ## preferring exact and CLDR-parent matches before script-compatible
  ## language matches.
  var norm: seq[string]
  for tag in supported:
    let normalized = normalize(tag)
    if normalized != "" and normalized notin norm:
      norm.add normalized
  for preferred in want:
    let normalized = normalize(preferred)
    if normalized == "": continue
    if normalized in norm: return normalized
    for candidate in parentChain(normalized):
      if candidate in norm: return candidate
    let desired = likelyParts(normalized)
    if desired.language == "": continue
    for candidate in norm:
      let likely = likelyParts(candidate)
      if likely.language == desired.language and
          likely.script == desired.script:
        return candidate
  ""

type CatalogLookupSource = object
  catalog: Catalog
  prefix: string

proc catalogFile*(locale, contents: string): CatalogFile =
  ## Names one ARB-style JSON catalog by its canonical locale tag.
  CatalogFile(locale: locale, contents: contents)

proc catalogMessages(contents: string):
    Table[string, messageFormat.Message] =
  result = initTable[string, messageFormat.Message]()
  var document: JsonNode
  try:
    document = parseJson(contents)
  except CatchableError:
    return
  if document.kind != JObject: return
  for key, value in document:
    if key.startsWith("@") or value.kind != JString: continue
    try:
      result[key] = messageFormat.parseMessage(value.getStr())
    except CatchableError:
      discard

proc newCatalog*(source: string; files: openArray[CatalogFile]): Catalog =
  ## Builds an app catalog from canonical-locale JSON texts. Invalid JSON
  ## documents and invalid message strings are ignored and fall back as
  ## missing messages do.
  let sourceTag = normalize(source)
  if sourceTag == "" or sourceTag != source or isPseudo(sourceTag):
    raise newException(ValueError,
      "i18n: the source language " & source.escape() & " is not a language")
  result = Catalog(sourceTag: sourceTag)
  result.messages = initTable[string, Table[string, messageFormat.Message]]()
  for file in files:
    let tag = normalize(file.locale)
    if tag == "" or tag != file.locale:
      raise newException(ValueError, "i18n: " & file.locale.escape() &
        " is not named after a canonical BCP 47 tag")
    if isPseudo(tag):
      raise newException(ValueError,
        "i18n: pseudo locales come from the source language and have no files")
    if result.messages.hasKey(tag):
      raise newException(ValueError, "i18n: duplicate catalog for " & tag)
    result.messages[tag] = catalogMessages(file.contents)
    if tag != sourceTag: result.localeTags.add tag
  if not result.messages.hasKey(sourceTag):
    raise newException(ValueError,
      "i18n: the catalog has no " & sourceTag & ".json, the source messages")
  result.localeTags.sort()
  result.localeTags.insert(sourceTag, 0)

proc newLibraryCatalog*(source: string; namespace: string;
    files: openArray[CatalogFile]): Catalog =
  ## Builds a library catalog. App catalogs may override its keys as
  ## `<namespace>.<key>` without registering the library itself.
  if namespace.len == 0 or namespace.contains({' ', '.', '@'}):
    raise newException(ValueError, "i18n: invalid catalog namespace " &
      namespace.escape())
  result = newCatalog(source, files)
  result.namespaceTag = namespace

proc source*(catalog: Catalog): string =
  if catalog.isNil: "" else: catalog.sourceTag

proc namespace*(catalog: Catalog): string =
  if catalog.isNil: "" else: catalog.namespaceTag

proc languages*(catalog: Catalog): seq[string] =
  if catalog.isNil: return
  withLock catalogRegistryLock:
    for tag in catalog.localeTags: result.add tag

proc add*(catalog: Catalog; files: openArray[CatalogFile]) =
  ## Adds translations to a catalog. A locale already present is an error.
  if catalog.isNil:
    raise newException(ValueError, "i18n: cannot add to a nil catalog")
  var additions = initTable[string, Table[string, messageFormat.Message]]()
  for file in files:
    let tag = normalize(file.locale)
    if tag == "" or tag != file.locale:
      raise newException(ValueError, "i18n: " & file.locale.escape() &
        " is not named after a canonical BCP 47 tag")
    if isPseudo(tag):
      raise newException(ValueError,
        "i18n: pseudo locales come from the source language and have no files")
    if additions.hasKey(tag):
      raise newException(ValueError, "i18n: duplicate catalog for " & tag)
    additions[tag] = catalogMessages(file.contents)
  withLock catalogRegistryLock:
    for tag in additions.keys:
      if catalog.messages.hasKey(tag):
        raise newException(ValueError, "i18n: the catalog has " & tag & " already")
    for tag, messages in additions:
      catalog.messages[tag] = messages
      catalog.localeTags.add tag
    if additions.len > 0:
      let sourceTag = catalog.sourceTag
      var translations: seq[string]
      for tag in catalog.localeTags:
        if tag != sourceTag: translations.add tag
      translations.sort()
      catalog.localeTags = @[sourceTag] & translations

proc register*(catalog: Catalog) =
  ## Registers an app catalog, making its locales available to
  ## `languages()` and its namespaced keys available to library catalogs.
  if catalog.isNil:
    raise newException(ValueError, "i18n: cannot register a nil catalog")
  if catalog.namespaceTag != "":
    raise newException(ValueError, "i18n: cannot register a library catalog")
  withLock catalogRegistryLock:
    if catalog in registeredCatalogs: return
    registeredCatalogs.add catalog

proc registeredApps(): seq[Catalog] =
  withLock catalogRegistryLock:
    for catalog in registeredCatalogs: result.add catalog

proc catalogSources(catalog: Catalog): seq[CatalogLookupSource] =
  if catalog.namespaceTag == "":
    return @[CatalogLookupSource(catalog: catalog)]
  for app in registeredApps():
    result.add CatalogLookupSource(catalog: app,
      prefix: catalog.namespaceTag & ".")
  result.add CatalogLookupSource(catalog: catalog)

proc catalogCandidates(catalog: Catalog; locale: string;
    sources: seq[CatalogLookupSource]): seq[string] =
  var candidates: seq[string]
  var added = initTable[string, bool]()
  proc add(tags: seq[string]) =
    for tag in tags:
      if tag notin added:
        added[tag] = true
        candidates.add tag

  let tag = normalize(locale)
  if tag != "" and not isPseudo(locale):
    add(parentChain(tag))
    for source in sources:
      let supported = source.catalog.languages()
      if tag in supported: continue
      let selected = match(@[tag], supported)
      if selected != "": add(parentChain(selected))
  if sources.len > 1:
    add(parentChain(sources[0].catalog.sourceTag))
  add(parentChain(catalog.sourceTag))
  result = candidates

proc catalogMessage(catalog: Catalog; locale, key: string):
    messageFormat.Message

proc lookup(catalog: Catalog; locale, key: string):
    tuple[message: messageFormat.Message, language: string, found: bool] =
  if catalog.isNil: return
  let sources = catalogSources(catalog)
  for tag in catalogCandidates(catalog, locale, sources):
    for source in sources:
      let found = source.catalog.catalogMessage(tag, source.prefix & key)
      if not found.isNil:
        return (found, tag, true)

proc catalogMessage(catalog: Catalog; locale, key: string):
    messageFormat.Message =
  withLock catalogRegistryLock:
    let messages = catalog.messages.getOrDefault(locale)
    result = messages.getOrDefault(key)

proc message*(catalog: Catalog; locale, key: string):
    tuple[message: messageFormat.Message, language: string, found: bool] =
  ## Returns the best matching message and its catalog language.
  lookup(catalog, locale, key)

proc format*(catalog: Catalog; locale, key: string;
    args: varargs[messageFormat.FormatArg]): string =
  ## Formats a catalog message, falling back through CLDR parents and then
  ## to its source language. Missing keys return their key unchanged.
  let found = lookup(catalog, locale, key)
  if not found.found: return key
  let displayLocale = if locale == "": found.language else: locale
  formatMessage(found.message, displayLocale, found.language, args)

proc format*(catalog: Catalog; key: string;
    args: varargs[messageFormat.FormatArg]): string =
  ## Formats a message in the app's current locale.
  format(catalog, locale(), key, args)
