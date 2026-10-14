## Package i18n reads the languages people read and picks, of those an
## app is written in, the one that suits them best, and says an app's
## messages in it.
##
## PORT STATUS: minimal — Region, normalize and locale state; enough for
## the core's menus and the surface contract. The full formatter
## (message.go, number.go, date.go, CLDR tables) lands when the render
## stack is ported; replace icuFormat in internal/l10n with it then.

import std/[strutils, tables, times, atomics]

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
    ## or 0 when it is not known, which the zero Region is: its first
    ## weekday, Sunday, means nothing then.
    hourCycle*: int

const
  ## The pseudo locales, which the generated catalog tests translate
  ## to.
  pseudoAccented* = "en-XA"
  pseudoDoubled* = "en-XB"
  pseudoBrackets* = "en-XC"

proc isPseudo*(locale: string): bool =
  ## Whether locale is a pseudo locale.
  locale == pseudoAccented or locale == pseudoDoubled or
    locale == pseudoBrackets

# modifierScripts are the scripts the modifiers of POSIX locales name.
const modifierScripts = {
  "latin": "Latn", "cyrillic": "Cyrl", "arabic": "Arab",
}.toTable

# wellKnown upgrades the tags whose script or region is implied; the
# full port reads CLDR's likely-subtags data.
const scriptForLanguage = {
  "zh": "Hans", "zh-TW": "Hant", "zh-HK": "Hant", "zh-MO": "Hant",
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
  if locale == "" or locale == "C" or locale == "POSIX":
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
    if p.len == 4:
      script = p[0].toUpperAscii() & p[1..^1].toLowerAscii()
    elif p.len == 2 or (p.len == 3 and p[0] in {'0'..'9'}):
      region = p.toUpperAscii()
    # skip variants and extensions for the minimal port
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
  let lang = tag.split('-')[0].toLowerAscii()
  if lang in ["ar", "fa", "he", "ur", "sd", "ps", "ug", "yi", "dv",
              "ku", "ckb"]: "rtl" else: "ltr"

proc formatLocale*(r: Region; lang: string): string =
  ## The locale a reader of lang with these regional formats writes
  ## numbers and dates in (minimal: the tag, or en with the region's
  ## keys). The full port composes them as Apple's Locale.current does.
  var t = normalize(lang)
  if t == "" or isPseudo(lang): t = "en"
  if r.locale != "":
    let rt = normalize(r.locale)
    if rt != "":
      let rParts = rt.split('-')
      let region = rParts[^1]
      if region.len == 2 or region.len == 3:
        t = t.split('-')[0] & "-" & region
  var ext: seq[string]
  if r.hourCycle == 12 or r.hourCycle == 24:
    ext.add "fw"
    ext.add ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][ord(r.firstWeekday) mod 7]
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
  ## The day the locale's calendars start weeks on, from CLDR's
  ## supplemental week data. The full table lands with the i18n port;
  ## firstDay=001 means Monday for most of the world, so Sunday is
  ## the conservative default until then.
  dSun

proc hourCycle*(tag: string): int =
  ## 12 or 24, 0 when the locale is not known (Region.hourCycle).
  0

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
