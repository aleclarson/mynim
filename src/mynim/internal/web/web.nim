## web.nim: the backend itself — the event hooks of the page, the window
## registry, and the inert controllers of what browsers do not have.
##
## Go's backend waits on channels because JavaScript's callbacks arrive on
## goroutines of their own. Under emscripten they run on the browser's
## main thread, which is the app's, so sync is a call and the run loop is
## the browser's: Run leaves the program live for events, and Quit ends it.

method name*(b: webBackend): string = "js/webgl2"

method init*(b: webBackend, h: AppHandler, opts: AppOptions) =
  jsInit()
  if jsGet(jsGlobal(), "document").jsIsUndefined:
    raise newException(PlatformError,
                       "mynim: no document to draw in (a worker?)")
  b.h = h
  installFiles()
  let nav = jsGet(jsGlobal(), "navigator")
  let platformName = jsGet(nav, "platform")
  b.mac = not jsIsUndefined(platformName) and
    jsString(platformName).len >= 3 and
    jsString(platformName)[0 ..< 3] == "Mac"
  let changed = b.funcOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    b.sync(proc() = h.themeChanged())
    jsUndef)
  for q in ["(prefers-color-scheme: dark)",
            "(prefers-reduced-motion: reduce)",
            "(prefers-contrast: more)"]:
    discard jsCall(jsCall(jsGlobal(), "matchMedia",
                          [jsValueOf(q)]), "addEventListener",
                   [jsValueOf("change"), changed])
  # The languages the user reads: the browser's.
  discard jsCall(jsGlobal(), "addEventListener",
    [jsValueOf("languagechange"), b.funcOf(
      proc(this: JsValue, args: seq[JsValue]): JsValue =
        b.sync(proc() = h.localeChanged())
        jsUndef)])
  # The page's own choice of appearance (themeAttr), as a page framing
  # the app sets it, since frames take the media's.
  let opts = jsObj()
  jsSet(opts, "attributes", jsTrueV)
  let filter = jsArrayOf(@[jsValueOf(themeAttr)])
  jsSet(opts, "attributeFilter", filter)
  discard jsCall(
    jsNew(jsGet(jsGlobal(), "MutationObserver"), [changed]),
    "observe",
    [jsGet(jsGet(jsGlobal(), "document"), "documentElement"), opts])

method run*(b: webBackend) =
  b.h.ready()
  # Leave the program live for the events of the page: the browser's
  # loop is the run loop.
  exitWithLiveRuntime()

method quit*(b: webBackend) =
  if not b.quitFlag:
    b.quitFlag = true
    b.h.terminating()
    forceExit(0)

method isMainThread*(b: webBackend): bool = true

method signal*(b: webBackend) =
  # Work posted wakes the frame loop; dispatch when it next yields to
  # the page, and straight away while a popup menu pumps.
  if b.signaled == 0:
    b.signaled = 1
    discard jsCall(jsGlobal(), "setTimeout",
      [b.funcOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
        b.signaled = 0
        if not b.quitFlag:
          b.h.dispatch()
        jsUndef), jsValueOf(0)])

method step*(b: webBackend) =
  ## Waits for the next of the page's events, which the popup menus'
  ## nested loop pumps. ASYNCIFY turns the sleep into a yield of the
  ## wasm frame, so events arrive meanwhile.
  if b.signaled != 0:
    b.signaled = 0
    b.h.dispatch()
  else:
    emscriptenSleep(50)

method wake*(b: webBackend) = discard

method newWindow*(b: webBackend, opts: WindowOptions,
                  h: WindowHandler): tuple[w: Window, err: ref CatchableError] =
  if not opts.surface:
    return (nil, newException(PlatformError,
      "mynim: browsers show windows of native UI (WindowOptions.content) only"))
  let w = newWebWindow(b, opts, h)
  if w.isNil:
    return (nil, newException(PlatformError, "mynim: no canvas"))
  b.windows.add w
  (w, nil)

proc removeWindow*(b: webBackend, w: webWindow) =
  for i, x in b.windows:
    if x == w:
      b.windows.delete(i)
      return

method setApplicationMenu*(b: webBackend, m: Menu) = discard
method updateMenuItem*(b: webBackend, item: MenuItem) = discard
method app*(b: webBackend): AppController = webApp()
method dialogs*(b: webBackend): Dialogs = webDialogs()
method clipboard*(b: webBackend): Clipboard = webClipboard(b: b)
method shell*(b: webBackend): Shell = webShell()
method screen*(b: webBackend): Screen = webScreen()
method theme*(b: webBackend): Theme = webTheme(b: b)
method power*(b: webBackend): Power = webPower()
method network*(b: webBackend): Network = webNetwork(b: b)
method secrets*(b: webBackend): Secrets = webSecrets()
method newTray*(b: webBackend, h: TrayHandler):
    tuple[t: Tray, err: ref CatchableError] =
  (nil, errWeb())
method registerHotkey*(b: webBackend, id: int, accelerator: string) =
  raise errWeb()
method unregisterHotkey*(b: webBackend, id: int) = discard
method notificationsSupported*(b: webBackend): bool = false
method webViewSupported*(b: webBackend): bool = false
method removeNotification*(b: webBackend, id: string) = discard
method removeAllNotifications*(b: webBackend) = discard
method showNotification*(b: webBackend, n: Notification,
                         done: proc(err: ref CatchableError)) =
  done(errWeb())
method applications*(b: webBackend):
    tuple[apps: seq[Application], err: ref CatchableError] =
  (@[], errWeb())
method newFileWatch*(b: webBackend, notify: proc(n: FileWatchNotice)):
    tuple[w: FileWatch, err: ref CatchableError] =
  (nil, errUnsupported())
method replaceFile*(b: webBackend, target, replacement: string) =
  raise errUnsupported()

## --- app ---

method setActivationPolicy*(a: webApp, policy: string) = discard
method activate*(a: webApp) = discard
method hide*(a: webApp) = discard
method unhide*(a: webApp) = discard
method isHidden*(a: webApp): bool =
  jsBool(jsGet(jsGet(jsGlobal(), "document"), "hidden"))
method setBadge*(a: webApp, badge: string) = discard
method badge*(a: webApp): string = ""
method bounce*(a: webApp, critical: bool): int = 0
method cancelBounce*(a: webApp, id: int) = discard
method setDockIcon*(a: webApp, png: seq[byte]) = raise errWeb()
method showAboutPanel*(a: webApp, opts: AboutPanelOptions) = discard
method package*(a: webApp): tuple[info: PackageInfo, ok: bool] =
  (PackageInfo(), false)
method registerURLScheme*(a: webApp, scheme, id, name: string) =
  raise errWeb()
method unregisterURLScheme*(a: webApp, scheme, id, name: string) =
  raise errWeb()
method isURLSchemeRegistered*(a: webApp, scheme, id, name: string): bool =
  false
method setOpenAtLogin*(a: webApp, open: bool, id, name, arg: string) =
  raise errWeb()
method openAtLogin*(a: webApp, id, name, arg: string): bool = false
method openedAtLogin*(a: webApp): bool = false
method setDockMenu*(a: webApp, m: Menu) = discard
method clearBrowsingData*(a: webApp, done: proc(err: ref CatchableError)) =
  done(errWeb())
method addRecentDocument*(a: webApp, path: string) = raise errWeb()
method clearRecentDocuments*(a: webApp) = raise errWeb()
method setJumpListTasks*(a: webApp, tasks: seq[JumpListTask]) = raise errWeb()

## preferredLanguages returns the browser's languages,
## navigator.languages.
method preferredLanguages*(a: webApp): seq[string] =
  let nav = jsGet(jsGlobal(), "navigator")
  let list = jsGet(nav, "languages")
  if jsType(list) == jsObject:
    for i in 0 ..< jsLen(list):
      let l = jsGetIx(list, i)
      if jsType(l) == jsStringT:
        result.add jsString(l)
  if result.len == 0:
    let l = jsGet(nav, "language")
    if jsType(l) == jsStringT:
      result.add jsString(l)

## region returns the formats of the browser's locale, as Intl resolves
## it: its first day of the week where the browser tells it (Intl.Locale's
## getWeekInfo, or weekInfo before), and its hour cycle.
method region*(a: webApp): Region =
  result = Region(firstWeekday: -1)
  let intl = jsGet(jsGlobal(), "Intl")
  if jsType(intl) != jsObject:
    return
  let fopts = jsObj()
  jsSet(fopts, "hour", jsValueOf("numeric"))
  let opts = jsCall(
    jsNew(jsGet(intl, "DateTimeFormat"), [jsUndef, fopts]),
    "resolvedOptions", [])
  let l = jsGet(opts, "locale")
  if jsType(l) == jsStringT:
    result.locale = jsString(l)
  case jsString(jsGet(opts, "hourCycle"))
  of "h11", "h12": result.hourCycle = 12
  of "h23", "h24": result.hourCycle = 24
  else: discard
  if result.locale == "" or jsType(jsGet(intl, "Locale")) != jsFunction:
    return
  try:
    let locale = jsNew(jsGet(intl, "Locale"), [jsValueOf(result.locale)])
    var info = jsUndef
    if jsType(jsGet(locale, "getWeekInfo")) == jsFunction:
      info = jsCall(locale, "getWeekInfo", [])
    else:
      info = jsGet(locale, "weekInfo")
    if jsType(info) == jsObject and
        jsType(jsGet(info, "firstDay")) == jsNumber:
      result.firstWeekday = jsInt(jsGet(info, "firstDay")) mod 7
        # 7 is Sunday
  except CatchableError:
    discard

## localeKey is the key of localStorage the app's language is kept under.
const localeKey = "mygo:locale"

method savedLocale*(a: webApp): tuple[tag: string, kept: bool] =
  try:
    let v = jsCall(jsGet(jsGlobal(), "localStorage"), "getItem",
                   [jsValueOf(localeKey)])
    if jsType(v) == jsStringT:
      result.tag = jsString(v)
  except CatchableError:
    discard # storage the page may not use
  result.kept = true

method saveLocale*(a: webApp, tag: string): bool =
  try:
    let storage = jsGet(jsGlobal(), "localStorage")
    if tag == "":
      discard jsCall(storage, "removeItem", [jsValueOf(localeKey)])
    else:
      discard jsCall(storage, "setItem",
                     [jsValueOf(localeKey), jsValueOf(tag)])
  except CatchableError:
    discard
  true

## setLanguages makes the app's language the page's (<html lang>), which
## browsers draw the text of canvases and read the page aloud in, and its
## direction the page's (<html dir>).
method setLanguages*(a: webApp, tags: seq[string], rtl: bool) =
  let root = jsGet(jsGet(jsGlobal(), "document"), "documentElement")
  if tags.len > 0:
    jsSet(root, "lang", jsValueOf(tags[0]))
  jsSet(root, "dir", jsValueOf(if rtl: "rtl" else: "ltr"))

method listCookies*(a: webApp,
    done: proc(c: seq[Cookie], err: ref CatchableError)) =
  done(@[], errUnsupported())
method setCookie*(a: webApp, cookie: Cookie,
                  done: proc(err: ref CatchableError)) =
  done(errUnsupported())
method deleteCookie*(a: webApp, key: CookieKey,
                     done: proc(err: ref CatchableError)) =
  done(errUnsupported())

## --- dialogs ---

method showOpenDialog*(d: webDialogs, parent: Window, opts: OpenDialogOptions,
    cb: proc(paths: seq[string], err: ref CatchableError)) =
  cb(@[], errWeb())
method showSaveDialog*(d: webDialogs, parent: Window, opts: SaveDialogOptions,
    cb: proc(path: string, err: ref CatchableError)) =
  cb("", errWeb())

## showMessageBox asks with the browser's own dialogs: an alert for one
## button, a confirm for more, whose OK is the first button and Cancel
## the cancel button.
method showMessageBox*(d: webDialogs, parent: Window, opts: MessageBoxOptions,
    cb: proc(res: MessageBoxResult, err: ref CatchableError)) =
  var text = opts.message
  if opts.detail != "":
    text &= "\n\n" & opts.detail
  if opts.buttons.len <= 1:
    discard jsCall(jsGlobal(), "alert", [jsValueOf(text)])
    cb(MessageBoxResult(), nil)
    return
  var res = opts.cancelID
  if jsBool(jsCall(jsGlobal(), "confirm", [jsValueOf(text)])):
    res = 0
    if res == opts.cancelID:
      res = 1
  cb(MessageBoxResult(response: res,
                      checkboxChecked: opts.checkboxChecked), nil)

## --- clipboard ---
##
## webClipboard keeps the text copied, and writes it to the system's
## clipboard as well, which browsers allow while the user acts (a key
## copying). Reading the system's clipboard takes a paste event, which
## gives the surface its text (surface.paste).

method readText*(c: webClipboard): string =
  c.b.clip

method writeText*(c: webClipboard, text: string) =
  c.b.clip = text
  c.b.clipData = textData(text)
  let cb2 = jsGet(jsGet(jsGlobal(), "navigator"), "clipboard")
  if not jsIsUndefined(cb2):
    let p = jsCall(cb2, "writeText", [jsValueOf(text)])
    discard jsCall(p, "catch",
      [jsNew(jsGet(jsGlobal(), "Function"), [jsValueOf("")])])
      # without the user acting

method readData*(c: webClipboard, formats: seq[Format]):
    tuple[d: Data, err: ref CatchableError] =
  let d = c.b.clipData
  var reps: seq[Representation]
  for f in formats:
    let (b, e) = d.read(f)
    if e.isNil:
      reps.add bytes(f, b)
  if formats.len == 0:
    return (d, nil)
  if reps.len == 0:
    return (Data(), nil)
  (newData(newItem(reps)), nil)

## writeData keeps data's text formats, which the copy event under way
## gives the browser (surface.copy), and writes its plain text to the
## system's clipboard, which browsers allow while the user acts.
method writeData*(c: webClipboard, d: Data, released: proc()) =
  let (t, e1) = d.read(Text)
  if not e1.isNil:
    released()
    raise errWeb()
  let (d2, e2) = d.materialize(d.formats())
  if not e2.isNil:
    released()
    raise e2
  c.writeText(bytesToString(t))
  c.b.clipData = d2
  if not released.isNil:
    released()

method formats*(c: webClipboard): seq[Format] =
  if c.b.clip == "" and c.b.clipData.items().len == 0:
    return @[]
  c.b.clipData.formats()

method flush*(c: webClipboard) = discard
method readHTML*(c: webClipboard): string = ""
method writeHTML*(c: webClipboard, html: string) = discard
method readImage*(c: webClipboard): seq[byte] = @[]
method writeImage*(c: webClipboard, png: seq[byte]) = raise errWeb()
method clear*(c: webClipboard) = c.writeText("")
method availableFormats*(c: webClipboard): seq[string] = @["text/plain"]

## --- shell ---

method openExternal*(s: webShell, url: string): ref CatchableError =
  discard jsCall(jsGlobal(), "open",
    [jsValueOf(url), jsValueOf("_blank"), jsValueOf("noopener")])
  nil
method openPath*(s: webShell, path: string) = raise errWeb()
method showItemInFolder*(s: webShell, path: string) = discard
method trashItem*(s: webShell, path: string) = raise errWeb()
method beep*(s: webShell) = discard
method fileIcon*(s: webShell, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  (@[], errWeb())
method openApplication*(s: webShell, path: string) = raise errWeb()

## --- screen ---

proc devicePixelRatio(): float64 =
  let r = jsGet(jsGlobal(), "devicePixelRatio")
  if jsType(r) == jsNumber and jsFloat(r) > 0:
    jsFloat(r)
  else:
    1

method displays*(s: webScreen): seq[Display] =
  let scr = jsGet(jsGlobal(), "screen")
  @[Display(id: 1,
            bounds: Rect(width: jsInt(jsGet(scr, "width")),
                         height: jsInt(jsGet(scr, "height"))),
            workArea: Rect(width: jsInt(jsGet(scr, "availWidth")),
                           height: jsInt(jsGet(scr, "availHeight"))),
            scaleFactor: devicePixelRatio(), primary: true)]

method cursorPoint*(s: webScreen): Point = Point()

proc matches(query: string): bool =
  jsBool(jsGet(jsCall(jsGlobal(), "matchMedia",
                      [jsValueOf(query)]), "matches"))

## --- theme ---
##
method isDark*(t: webTheme): bool =
  case t.b.source
  of "dark": return true
  of "light": return false
  else: discard
  case jsString(jsCall(jsGet(jsGet(jsGlobal(), "document"),
                                 "documentElement"),
                       "getAttribute", [jsValueOf(themeAttr)]))
  of "dark": true
  of "light": false
  else: matches("(prefers-color-scheme: dark)")

method setSource*(t: webTheme, source: string) =
  t.b.source = source
  t.b.h.themeChanged()

method uiFont*(t: webTheme): string = ""
method fontRendering*(t: webTheme): FontRendering = FontRendering()

method preferences*(t: webTheme): Preferences =
  Preferences(
    reduceMotion: matches("(prefers-reduced-motion: reduce)"),
    highContrast: matches("(prefers-contrast: more)"),
    textScale: 1)

## --- power ---

method watch*(p: webPower) = discard
method keepAwake*(p: webPower, display: bool, reason: string): ReleaseProc =
  proc() = discard
method onBattery*(p: webPower): bool = false
method idleTime*(p: webPower): Duration = initDuration()

## --- network ---

method status*(n: webNetwork): NetworkStatus =
  NetworkStatus(online: jsBool(jsGet(jsGet(jsGlobal(), "navigator"),
                                     "onLine")))

method watch*(n: webNetwork) =
  let changed = n.b.funcOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    n.b.sync(proc() = n.b.h.networkChanged(n.status()))
    jsUndef)
  for event in ["online", "offline"]:
    discard jsCall(jsGlobal(), "addEventListener",
                   [jsValueOf(event), changed])

## --- secrets ---

method setSecret*(s: webSecrets, service, account: string, secret: seq[byte]) =
  raise errUnsupported()
method secret*(s: webSecrets, service, account: string):
    tuple[secret: seq[byte], err: ref CatchableError] =
  (@[], errUnsupported())
method deleteSecret*(s: webSecrets, service, account: string) =
  raise errUnsupported()
