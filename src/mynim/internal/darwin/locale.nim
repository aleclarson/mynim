## locale.go: the languages and regional formats of the user, and the
## language the app chose for itself.
##
## The languages the user reads are the global AppleLanguages, which
## System Settings orders: NSLocale's preferredLanguages are the app's
## own when its defaults have an AppleLanguages, as System Settings'
## language of an app writes, and as saveLocale does. That one is what
## AppKit and WebKit show their own texts in from the next launch.

var
  prefsLoaded: bool
  cfPreferencesCopyValue: proc(key, app, user, host: pointer): pointer
    {.cdecl.}
  cfPreferencesSetValue: proc(key, value, app, user, host: pointer)
    {.cdecl.}
  cfPreferencesSynchronize: proc(app, user, host: pointer): bool {.cdecl.}
  ## The domains of CFPreferences.
  cfAnyApplication, cfCurrentApplication, cfCurrentUser, cfAnyHost: id

proc loadPreferences() =
  if prefsLoaded:
    return
  prefsLoaded = true
  cfPreferencesCopyValue = cast[typeof cfPreferencesCopyValue](
    mustDlsym(libCFH, "CFPreferencesCopyValue"))
  cfPreferencesSetValue = cast[typeof cfPreferencesSetValue](
    mustDlsym(libCFH, "CFPreferencesSetValue"))
  cfPreferencesSynchronize = cast[typeof cfPreferencesSynchronize](
    mustDlsym(libCFH, "CFPreferencesSynchronize"))
  cfAnyApplication = constString(libCFH, "kCFPreferencesAnyApplication")
  cfCurrentApplication = constString(libCFH,
                                     "kCFPreferencesCurrentApplication")
  cfCurrentUser = constString(libCFH, "kCFPreferencesCurrentUser")
  cfAnyHost = constString(libCFH, "kCFPreferencesAnyHost")

## appleLanguages reads AppleLanguages of the current user, of the app's
## own domain alone when own, else of the global domain alone.
proc appleLanguages(own: bool): seq[string] =
  loadPreferences()
  var app = cfAnyApplication
  if own:
    app = cfCurrentApplication
  withPool(proc() =
    discard cfPreferencesSynchronize(app, cfCurrentUser, cfAnyHost)
    let v = id(cfPreferencesCopyValue(nsString("AppleLanguages"), app,
                                      cfCurrentUser, cfAnyHost))
    if v.isNil:
      return
    defer: cfRelease(v)
    if not sendBool(v, "isKindOfClass:", argu(`class`("NSArray"))):
      return
    for s in arrayItems(v):
      if sendBool(s, "isKindOfClass:", argu(`class`("NSString"))):
        result.add goString(s))

method preferredLanguages*(a: appController): seq[string] =
  result = appleLanguages(false)
  if result.len > 0:
    return
  # A user who never ordered languages: the system's.
  withPool(proc() =
    for s in arrayItems(send(`class`("NSLocale"), "preferredLanguages")):
      result.add goString(s))

method savedLocale*(a: appController): tuple[tag: string, kept: bool] =
  let langs = appleLanguages(true)
  if langs.len > 0:
    return (langs[0], true)
  ("", true)

method saveLocale*(a: appController, tag: string): bool =
  loadPreferences()
  withPool(proc() =
    var value: id
    if tag != "":
      value = nsArray(nsString(tag))
    cfPreferencesSetValue(nsString("AppleLanguages"), value,
                          cfCurrentApplication, cfCurrentUser, cfAnyHost)
    discard cfPreferencesSynchronize(cfCurrentApplication, cfCurrentUser,
                                     cfAnyHost))
  true

## setLanguages does nothing: AppKit and WKWebView take the app's
## language, and its direction, from its AppleLanguages, at launch.
method setLanguages*(a: appController, tags: seq[string], rtl: bool) =
  discard

## hourCycle returns the hour cycle of a date format pattern: 12 for h
## and K, 24 for H and k, 0 for none. Quoted text is not a field.
proc hourCycle(pattern: string): int =
  var quoted = false
  for c in pattern:
    if c == '\'':
      quoted = not quoted
    elif quoted:
      discard
    elif c in {'h', 'K'}:
      return 12
    elif c in {'H', 'k'}:
      return 24
  0

## region reads the current locale, which macOS makes of the region and
## the formats the user chose, its calendar's first day of the week, and
## its hour cycle: the hour of the skeleton "j" in its date formats,
## which the 24-hour time setting changes.
method region*(a: appController): Region =
  var r = Region(firstWeekday: -1)
  withPool(proc() =
    let locale = send(`class`("NSLocale"), "autoupdatingCurrentLocale")
    r.locale = goString(send(locale, "localeIdentifier"))
    let calendar = send(`class`("NSCalendar"),
                        "autoupdatingCurrentCalendar")
    let d = sendInt(calendar, "firstWeekday")
    if d >= 1 and d <= 7:
      r.firstWeekday = d - 1
    let format = goString(send(`class`("NSDateFormatter"),
      "dateFormatFromTemplate:options:locale:",
      argu(nsString("j")), argu(0), argu(locale)))
    r.hourCycle = hourCycle(format))
  r

