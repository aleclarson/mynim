## locale.nim (locale.go): the languages and regional formats of the
## user: the display languages of Settings > Time & language, and the
## regional formats, which may be another language's.

const muiLanguageName = 0x8 ## MUI_LANGUAGE_NAME

## multiString calls a function of the MUI that writes a list of
## language names, each ending in a NUL and the list in another, into
## a buffer it is first asked the size of.
proc multiString(p: proc(a0, a1, a2, a3: uint): uint {.stdcall.}):
    seq[string] =
  var count, size: uint32
  if p(muiLanguageName, cast[uint](addr count), 0,
      cast[uint](addr size)) == 0 or size == 0:
    return @[]
  var buf = newSeq[uint16](size)
  if p(muiLanguageName, cast[uint](addr count),
      cast[uint](addr buf[0]), cast[uint](addr size)) == 0:
    return @[]
  var start = 0
  for i, c in buf:
    if c == 0:
      if i > start:
        result.add u16str(buf.toOpenArray(start, i - 1))
      start = i + 1

## PreferredLanguages returns the user's display languages, in order
## timeFormatCycle returns the hour cycle of a Windows time format: 12
## for h, 24 for H, 0 for none. Quoted text is not a field.
proc timeFormatCycle*(format: string): int =
  var quoted = false
  for c in format:
    if c == '\'':
      quoted = not quoted
    elif quoted:
      discard
    elif c == 'h':
      return 12
    elif c == 'H':
      return 24
  0

## savedLocale and saveLocale leave the app's language to the core's
## file.
method savedLocale*(a: appController): tuple[tag: string, kept: bool] =
  ("", false)
method saveLocale*(a: appController, tag: string): bool = false

## setLanguages makes the app's languages the process's preferred
## display languages, which the system's own texts, as those of
## message boxes and file dialogs, are in where Windows has them, and
## the language of the WebView2 environment, which the first web view
## creates: one created already keeps its language, as WebView2 cannot
## change it.
method setLanguages*(a: appController, tags: seq[string], rtl: bool) =
  if tags == a.b.languages:
    return
  a.b.languages = tags
  var list: seq[uint16]
  for t in tags:
    list.add utf16z(t)
  list.add 0
  var n: uint32
  discard procSetProcessPreferredUILanguages(muiLanguageName,
    cast[uint](addr list[0]), cast[uint](addr n))

## (GetUserPreferredUILanguages), or the display language alone on a
## Windows that lists none.
method preferredLanguages*(a: appController): seq[string] =
  let langs = multiString(procGetUserPreferredUILanguages)
  if langs.len > 0:
    return langs
  var buf: array[85, uint16] ## LOCALE_NAME_MAX_LENGTH
  let id = procGetUserDefaultUILanguage()
  if id != 0:
    let n = procLCIDToLocaleName(id, cast[uint](addr buf[0]),
      uint(buf.len), 0)
    if n > 0:
      return @[u16str(buf.toOpenArray(0, int(n) - 1))]
  @[]

## The items of GetLocaleInfoEx.
const
  localeSName* = 0x5c'u32
  localeSTimeFormat* = 0x1003'u32
  localeIFirstDayOfWeek* = 0x100c'u32

## localeInfo returns an item of the user's regional formats, with the
## changes they made to them.
proc localeInfo*(item: uint32): string =
  var buf: array[128, uint16]
  let n = procGetLocaleInfoEx(0, item, cast[uint](addr buf[0]),
    uint(buf.len)) ## LOCALE_NAME_USER_DEFAULT
  if n == 0:
    return ""
  u16str(buf.toOpenArray(0, int(n) - 1))

## Region reads the user's regional formats: their locale, the first
## day of the week (0 for Monday to 6 for Sunday) and the time format.
method region*(a: appController): Region =
  result = Region(locale: localeInfo(localeSName), firstWeekday: -1)
  try:
    let d = parseInt(localeInfo(localeIFirstDayOfWeek))
    if d >= 0 and d <= 6:
      result.firstWeekday = (d + 1) mod 7
  except ValueError:
    discard
  result.hourCycle = timeFormatCycle(localeInfo(localeSTimeFormat))
