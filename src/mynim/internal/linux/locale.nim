## locale.nim: the languages and regional formats of the user are those
## of the environment, as gettext and glibc read them: no setting of the
## desktop changes them while the app runs.

proc envLocale*(category: string): string
proc loadLanginfo*()
proc applyWebLanguages*(b: Backend)
proc get*(l: var langinfoLib, item, loc: uint): uint
proc hourCycleOf*(format: string): int

# Items of nl_langinfo for LC_TIME in glibc: _NL_ITEM(LC_TIME, index).
const
  tFmt* = 2 shl 16 or 42
  nlTimeWeek1stDay* = 2 shl 16 or 102
  nlTimeFirstWeekday* = 2 shl 16 or 104

## preferredLanguages returns the languages of the environment as gettext
## reads them: LANGUAGE, a list separated by colons, unless the locale is
## C, then the locale of messages, LC_ALL, LC_MESSAGES or LANG.
method preferredLanguages*(a: appController): seq[string] =
  let locale = envLocale("LC_MESSAGES")
  if locale != "":
    for l in getEnv("LANGUAGE").split(':'):
      if l != "":
        result.add l
    result.add locale

## envLocale returns the locale of a category as glibc reads the
## environment, LC_ALL, then the category's, then LANG, or "" for the C
## locale.
proc envLocale*(category: string): string =
  for env in ["LC_ALL", category, "LANG"]:
    let v = getEnv(env)
    if v != "":
      if v == "C" or v == "POSIX" or v.startsWith("C."):
        return ""
      return v
  ""

## savedLocale and saveLocale leave the app's language to the core's file.
method savedLocale*(a: appController): tuple[tag: string, kept: bool] =
  ("", false)
method saveLocale*(a: appController, tag: string): bool = false

## setLanguages gives WebKitGTK the languages, as the Accept-Language of
## its requests and the navigator.language of pages: now if it is loaded,
## else as it loads for the first web view. GTK's widgets, as menus,
## whose items take no direction from the window, are laid out in the
## direction.
method setLanguages*(a: appController, tags: seq[string], rtl: bool) =
  var dir = 1'i32 # GTK_TEXT_DIR_LTR
  if rtl: dir = 2
  if not gtkWidgetSetDefaultDirection.isNil:
    gtkWidgetSetDefaultDirection(dir)
  a.b.languages = @tags
  if not libWebKit.isNil:
    a.b.applyWebLanguages()

## applyWebLanguages gives the default web context the app's languages.
proc applyWebLanguages*(b: Backend) =
  if b.languages.len == 0 or webkitWebContextSetPreferredLanguages.isNil:
    return
  var strs = newSeq[cstring](b.languages.len + 1) # NULL-terminated
  for i, l in b.languages:
    strs[i] = cs(l)
  webkitWebContextSetPreferredLanguages(webkitWebContextGetDefault(),
    addr strs[0])

## region returns the formats of LC_TIME, as glibc has them for the
## environment's locale: the first day of the week and the hour cycle of
## its time format. A libc without them, as musl, or a locale the system
## has not generated, leaves them to the core.
method region*(a: appController): platform.Region =
  result = platform.Region(locale: envLocale("LC_TIME"), firstWeekday: -1)
  if result.locale == "":
    return
  if not langinfo.loaded:
    langinfo.loaded = true
    loadLanginfo()
  if langinfo.newlocale.isNil:
    return
  const lcTimeMask = 1'i32 shl 2 # LC_TIME is 2 in glibc and musl
  let loc = langinfo.newlocale(lcTimeMask, "", 0)
  if loc == 0:
    return # not generated
  defer: langinfo.freelocale(loc)
  let f = langinfo.get(tFmt, loc)
  if f != 0:
    result.hourCycle = hourCycleOf(goStr(cast[pointer](f)))
  # _NL_TIME_FIRST_WEEKDAY counts from _NL_TIME_WEEK_1STDAY, a date: 1
  # is the day of that date, Sunday for 19971130 and Monday for
  # 19971201, as GTK's calendar reads them.
  let first = langinfo.get(nlTimeFirstWeekday, loc)
  if first != 0:
    let day = int(cast[ptr uint8](cast[ptr uint](addr first)[])[])
    let origin = uint32(langinfo.get(nlTimeWeek1stDay, loc))
    var start = -1
    case origin
    of 19971130: start = 0
    of 19971201: start = 1
    else: discard
    if start >= 0 and day >= 1 and day <= 7:
      result.firstWeekday = (start + day - 1) mod 7



proc dlsymDefault(name: cstring): pointer =
  let h = loadLib("", globalSymbols = true)
  if h.isNil: nil else: h.symAddr(name)

proc loadLanginfo*() =
  let
    n = dlsymDefault("newlocale")
    f = dlsymDefault("freelocale")
    l = dlsymDefault("nl_langinfo_l")
  if n.isNil or f.isNil or l.isNil:
    return
  langinfo.newlocale = cast[typeof(langinfo.newlocale)](n)
  langinfo.freelocale = cast[typeof(langinfo.freelocale)](f)
  langinfo.langinfoL = l

type langinfoLFn = proc(item: cint, loc: uint): cstring {.cdecl.}

## get calls nl_langinfo_l, whose result is a string, or for some items a
## number, in a pointer.
proc get*(l: var langinfoLib, item, loc: uint): uint =
  if l.langinfoL.isNil: return 0
  let r = cast[uint](cast[langinfoLFn](l.langinfoL)(cint(item), loc))
  if r != 0 and item != uint(nlTimeWeek1stDay) and
      cast[ptr uint8](r)[] == 0:
    return 0 # an empty string: an item the libc has not
  r

## hourCycleOf returns the hour cycle of a strftime format: 12 for %I, %l
## and %r, 24 for %H, %k, %R and %T, 0 for none.
proc hourCycleOf*(format: string): int =
  var i = 0
  while i + 1 < format.len:
    if format[i] != '%':
      inc i
      continue
    inc i
    # Flags and modifiers between % and the conversion.
    while i < format.len and format[i] in {'_', '-', '0', '^', '#', 'E', 'O'}:
      inc i
    if i >= format.len: break
    case format[i]
    of 'I', 'l', 'r': return 12
    of 'H', 'k', 'R', 'T': return 24
    else: discard
    inc i
  0
