## app.nim (app.go): the backend's lifecycle — COM and DPI setup, the
## hidden application window, the message loop and the app controller.

proc newBackend*(): WinBackend

proc newMenuTable*(): menuTable
proc activateCommonControls*()
proc registerClasses*()
proc createWindow*(exStyle: uint32, class, title: string,
  style: uint32, x, y, w, h: int32, parent: uint): uint
proc registerWindowMessage*(name: string): uint32
proc sanitize*(name: string): string

const
  appClass* = "MyGoApp"
  windowClass* = "MyGoWindow"
  captionClass* = "MyGoCaption"
  flyoutShadowClass* = "MyGoFlyoutShadow"
  wmTimer* = 0x0113'u32
  timerCompose* = 1'u

method name*(b: WinBackend): string = "windows/webview2"

method isMainThread*(b: WinBackend): bool =
  currentThreadID() == mainThreadID

method init*(b: WinBackend, h: AppHandler, opts: AppOptions) =
  b.h = h
  b.name = opts.name
  theBackend = b
  discard procCoInitializeEx(0, coinitApartmentThreaded)
  if has(procSetProcessDpiAwarenessContext):
    discard procSetProcessDpiAwarenessContext(
      dpiAwarenessContextPerMonitorAwareV2)
  activateCommonControls()
  registerClasses()
  b.appHwnd = createWindow(0, appClass, "", wsOverlapped, 0, 0, 0, 0, 0)
  if b.appHwnd == 0:
    raise newException(CatchableError,
      "mynim: cannot create the application window")
  b.taskbarCreated = registerWindowMessage("TaskbarCreated")
  b.taskbarButtonCreated = registerWindowMessage("TaskbarButtonCreated")
  b.applyMenuTheme() ## for the menus of trays too, before any window
  ## Clipboard and drag/drop share startup-created OLE callback tables.
  dropOnceDo()

## startEnvironment starts creating the WebView2 environment, the first
## time a window that shows a web page is created, and returns why it
## cannot, such as a missing WebView2 Runtime. Windows that show native
## UI need none: an app whose windows all do runs without the runtime.
proc startEnvironment*(b: WinBackend): ref CatchableError =
  if b.envStarted:
    return nil
  var dir = getEnv("LOCALAPPDATA")
  if dir == "":
    dir = getTempDir()
  let userData = dir / sanitize(b.name) / "WebView2"
  discard existsOrCreateDir(userData)
  var language = ""
  if b.languages.len > 0:
    language = b.languages[0]
  let err = createEnvironment(userData, language,
    proc(env: uint, err: ref CatchableError) =
      b.env = env
      b.envErr = err
      if not err.isNil:
        stderr.writeLine err.msg
      let waiters = b.envWaiters
      b.envWaiters = @[]
      for fn in waiters:
        fn())
  ## A runtime installed later is found by the next window.
  b.envStarted = err.isNil
  err

## whenEnvironment runs fn once the WebView2 environment, which
## startEnvironment started, exists (or failed).
proc whenEnvironment*(b: WinBackend, fn: proc() {.closure.}) =
  if b.env != 0 or not b.envErr.isNil:
    fn()
    return
  b.envWaiters.add fn

proc sanitize*(name: string): string =
  var out0 = newSeq[Rune]()
  for r in name.runes:
    var c = r
    if int(c) < 32 or char(int(c)) in {'<', '>', ':', '"', '/', '\\',
        '|', '?', '*'}:
      c = Rune('_')
    out0.add c
  if out0.len == 0:
    return "MyGo"
  $out0

method run*(b: WinBackend) =
  b.running = true
  postMessage(b.appHwnd, wmAppReady, 0, 0)
  var m: w32Msg
  while true:
    if int32(procGetMessageW(cast[uint](addr m), 0, 0, 0)) <= 0:
      break
    discard procTranslateMessage(cast[uint](addr m))
    discard procDispatchMessageW(cast[uint](addr m))
  b.running = false

## Quit ends the event loop. Modal loops (dialogs, menus) end too: they
## forward WM_QUIT to the loop they run in.
method quit*(b: WinBackend) = discard procPostQuitMessage(0)

method signal*(b: WinBackend) =
  if b.appHwnd == 0:
    return
  var expected = false
  if not b.signaled.compareExchange(expected, true,
      moSequentiallyConsistent):
    return
  postMessage(b.appHwnd, wmAppDispatch, 0, 0)

method step*(b: WinBackend) =
  discard procMsgWaitForMultipleObjectsEx(0, 0, 500, qsAllInput,
    mwmoInputAvailable)
  var m: w32Msg
  while true:
    if procPeekMessageW(cast[uint](addr m), 0, 0, 0, pmRemove) == 0:
      return
    if m.message == wmQuit:
      ## for the loop running outside
      discard procPostQuitMessage(m.wParam)
      return
    discard procTranslateMessage(cast[uint](addr m))
    discard procDispatchMessageW(cast[uint](addr m))

method wake*(b: WinBackend) =
  if b.appHwnd != 0:
    postMessage(b.appHwnd, wmAppWake, 0, 0)

method app*(b: WinBackend): AppController = appController(b: b)

var wndProcCallback: pointer
proc wndProc(hwnd, m, wp, lp: uint): uint {.stdcall.}

proc registerClasses*() =
  if not wndProcCallback.isNil:
    return
  wndProcCallback = cast[pointer](wndProc)
  let cursor = procLoadCursorW(0, idcArrow)
  ## the icon resource `nim-xplat build` embeds
  let icon = procLoadIconW(instance(), 1)
  for name in [appClass, windowClass, captionClass, flyoutShadowClass]:
    var style = 0x0003'u32 ## CS_HREDRAW | CS_VREDRAW
    if name == captionClass:
      style = 0x0008 ## CS_DBLCLKS: a double click on the top edge
    elif name == flyoutShadowClass:
      style = style or 0x00020000 ## CS_DROPSHADOW
    var wc = wndClassEx(style: style, wndProc: wndProcCallback,
      instance: instance(), cursor: cursor, icon: icon, iconSm: icon,
      className: u16(name))
    wc.size = uint32(sizeof(wc))
    if procRegisterClassExW(cast[uint](addr wc)) == 0:
      raise newException(CatchableError,
        "mynim: cannot register the window class")

proc createWindow*(exStyle: uint32, class, title: string,
    style: uint32, x, y, w, h: int32, parent: uint): uint =
  procCreateWindowExW(uint(exStyle), cast[uint](u16(class)),
    cast[uint](u16(title)), uint(style), uint(uint32(x)),
    uint(uint32(y)), uint(uint32(w)), uint(uint32(h)), parent, 0,
    instance(), 0)

proc registerWindowMessage*(name: string): uint32 =
  uint32(procRegisterWindowMessageW(cast[uint](u16(name))))

proc wndProc(hwnd, m, wp, lp: uint): uint {.stdcall.} =
  let b = theBackend
  if not b.isNil:
    if hwnd == b.appHwnd:
      let (r, ok) = b.appMessage(uint32(m), wp, lp)
      if ok:
        return r
    elif b.windows.hasKey(hwnd):
      let w = b.windows[hwnd]
      if not w.isNil:
        let (r, ok) = w.message(uint32(m), wp, lp)
        if ok:
          return r
    elif b.captions.hasKey(hwnd):
      let c = b.captions[hwnd]
      if not c.isNil:
        let (r, ok) = c.message(hwnd, uint32(m), wp, lp)
        if ok:
          return r
    elif b.surfaces.hasKey(hwnd):
      let s = b.surfaces[hwnd]
      if not s.isNil:
        let (r, ok) = s.message(hwnd, uint32(m), wp, lp)
        if ok:
          return r
  procDefWindowProcW(hwnd, m, wp, lp)

## appMessage handles the messages of the application window.
proc appMessage*(b: WinBackend, m: uint32, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  case m
  of wmAppReady:
    b.h.ready()
    return (0'u, true)
  of wmAppDispatch:
    b.signaled.store(false)
    b.h.dispatch()
    return (0'u, true)
  of wmAppWake:
    return (0'u, true)
  of wmAppTray:
    b.trayMessage(uint32(wp), uint32(loword(lp)))
    return (0'u, true)
  of wmHotkey:
    b.h.hotkeyPressed(int(wp))
    return (0'u, true)
  of wmPowerBroadcast, wmWTSSessionChange:
    b.powerMessage(m, wp)
    ## TRUE for power broadcasts, and default handling
    return (1'u, false)
  of wmSettingChange:
    if lp != 0 and wstr(cast[pointer](lp)) == settingImmersiveColorSet:
      b.applyTheme()
      b.h.themeChanged()
    elif lp != 0 and wstr(cast[pointer](lp)) == settingIntl:
      ## The display languages or the regional formats.
      b.h.localeChanged()
    elif preferencesChanged(wp, lp):
      b.h.themeChanged()
    return (0'u, false)
  of wmDisplayChange:
    b.h.displaysChanged()
    return (0'u, false)
  of wmTimer:
    if wp == timerCompose:
      b.recompose()
      return (0'u, true)
  of wmAppDeviceRemoved:
    b.deviceRemoved(wp)
    return (0'u, true)
  of wmAppNetwork:
    b.h.networkChanged(b.network().status())
    return (0'u, true)
  of wmQueryEndSession:
    return (1'u, true)
  of wmEndSession:
    if wp != 0:
      b.h.terminating()
    return (0'u, true)
  else:
    discard
  if m == b.taskbarCreated and m != 0:
    ## Explorer restarted: the notification area forgot our icons.
    for _, t in b.trays:
      t.add()
    return (0'u, true)
  (0'u, false)

## activateCommonControls activates version 6 of the common controls
## (themed controls, task dialogs) for executables without a manifest
## asking for it, like `mygo run` builds: shell32.dll carries such a
## manifest as resource 124.
proc activateCommonControls*() =
  if not has(procCreateActCtxW):
    return
  type actCtx = object
    size, flags: uint32
    source: pointer
    processorArchitecture, langID: uint16
    assemblyDirectory: pointer
    resourceName: uint
    applicationName: pointer
    module: uint
  const
    actCtxFlagResourceNameValid = 0x008'u32
    actCtxFlagAssemblyDirectoryValid = 0x004'u32
  var ctx = actCtx(
    flags: actCtxFlagResourceNameValid or
      actCtxFlagAssemblyDirectoryValid,
    source: u16(sysDir & r"\shell32.dll"),
    assemblyDirectory: u16(sysDir),
    resourceName: 124)
  ctx.size = uint32(sizeof(ctx))
  let h = procCreateActCtxW(cast[uint](addr ctx))
  if h == uint.high: ## INVALID_HANDLE_VALUE
    return
  var cookie: uint
  discard procActivateActCtx(h, cast[uint](addr cookie))

method setActivationPolicy*(a: appController, p: string) = discard

method activate*(a: appController) =
  for _, w in a.b.windows:
    if w.isVisible():
      w.focus()
      return

method hide*(a: appController) =
  a.b.hidden = @[]
  for _, w in a.b.windows:
    if w.isVisible():
      a.b.hidden.add w
      w.hide()

method unhide*(a: appController) =
  for w in a.b.hidden:
    if not w.closed:
      w.showInactive()
  a.b.hidden = @[]

method isHidden*(a: appController): bool = a.b.hidden.len > 0
method setBadge*(a: appController, label: string) = a.b.badge = label
method badge*(a: appController): string = a.b.badge

const
  flashwStop* = 0'u32
  flashwTray* = 0x2'u32
  flashwAll* = 0x3'u32
  flashwTimerNoFG* = 0xC'u32

method bounce*(a: appController, critical: bool): int =
  var flags = flashwTray or flashwTimerNoFG
  if critical:
    flags = flashwAll or flashwTimerNoFG
  for _, w in a.b.windows:
    var fi = flashWInfo(hwnd: w.hwnd, flags: flags)
    fi.size = uint32(sizeof(fi))
    discard procFlashWindowEx(cast[uint](addr fi))
  1

method cancelBounce*(a: appController, id: int) =
  for _, w in a.b.windows:
    var fi = flashWInfo(hwnd: w.hwnd, flags: flashwStop)
    fi.size = uint32(sizeof(fi))
    discard procFlashWindowEx(cast[uint](addr fi))

## setDockMenu does nothing: there is no Dock.
method setDockMenu*(a: appController, m: Menu) = discard

method setDockIcon*(a: appController, png: seq[byte]):
    ref CatchableError =
  let (icon, err) = iconFromPNG(png, 0)
  if not err.isNil:
    return err
  if a.b.icon != 0:
    discard procDestroyIcon(a.b.icon)
  a.b.icon = icon
  for _, w in a.b.windows:
    w.setIcon(icon)
  nil

method showAboutPanel*(a: appController, o: AboutPanelOptions) =
  var detail = o.applicationVersion
  if o.version != "":
    detail &= " (" & o.version & ")"
  for s in [o.copyright, o.credits]:
    if s != "":
      detail &= "\n" & s
  let tx = currentTexts()
  let title = tx.about.replace("\x00", o.applicationName)
  discard a.b.messageBox(0, MessageBoxOptions(`type`: "info",
    title: title, message: o.applicationName, detail: detail,
    buttons: @[tx.ok]))

## package reads the version resource `nim-xplat build` embeds in the
## executable.
method `package`*(a: appController): tuple[info: PackageInfo,
    ok: bool] =
  let exe = getAppFilename()
  if exe == "":
    return (PackageInfo(), false)
  let size = procGetFileVersionInfoSizeW(cast[uint](u16(exe)), 0)
  if size == 0:
    return (PackageInfo(), false)
  var data = newSeq[byte](size)
  if procGetFileVersionInfoW(cast[uint](u16(exe)), 0, size,
      cast[uint](addr data[0])) == 0:
    return (PackageInfo(), false)
  proc value(path: string): tuple[p: uint, n: uint32] =
    var p: uint
    var n: uint32
    if procVerQueryValueW(cast[uint](addr data[0]),
        cast[uint](u16(path)), cast[uint](addr p),
        cast[uint](addr n)) == 0 or n == 0:
      return (0'u, 0'u32)
    (p, n)
  ## The strings of the app's own language, the first of its
  ## translations: en-US and Unicode (040904b0) before it shipped
  ## others.
  var table = "040904b0"
  let (tp, tn) = value(r"\VarFileInfo\Translation")
  if tn >= 4:
    let lang = cast[ptr uint16](cast[pointer](tp))[]
    let codePage = cast[ptr uint16](cast[pointer](tp + 2))[]
    table = toHex(int(lang), 4) & toHex(int(codePage), 4).toLowerAscii
  proc query(key: string): string =
    let (p, _) = value(r"\StringFileInfo\" & table & r"\" & key)
    if p != 0:
      return wstr(cast[pointer](p))
    ""
  var info = PackageInfo(name: query("ProductName"),
    version: query("ProductVersion"),
    identifier: query("MyGoIdentifier"))
  if info.identifier == "":
    ## not built by nim-xplat build
    return (PackageInfo(), false)
  (info, true)

## clearBrowsingData clears the profile the app's web views share.
method clearBrowsingData*(a: appController,
    done: proc(err: ref CatchableError) {.closure.}) =
  var web: uint
  for _, w in a.b.windows:
    if w.webview != 0:
      web = w.webview
      break
  if web == 0:
    done(newException(CatchableError,
      "mynim: clearing browsing data needs an open window"))
    return
  let wv13 = queryInterface(web, addr iidICoreWebView2_13)
  if wv13 == 0:
    done(newException(CatchableError,
      "mynim: clearing browsing data needs a newer WebView2 Runtime"))
    return
  var profile: uint
  discard comCall(wv13, wv13GetProfile, cast[uint](addr profile))
  release(wv13)
  let p2 = queryInterface(profile, addr iidICoreWebView2Profile2)
  release(profile)
  if p2 == 0:
    done(newException(CatchableError,
      "mynim: clearing browsing data needs a newer WebView2 Runtime"))
    return
  defer: release(p2)
  let hr = withHandler(proc(result, a2: uint) =
      if failed(result):
        done(hresultError("clearing browsing data", result))
        return
      done(nil),
    proc(h: uint): uint = comCall(p2, profile2ClearBrowsingDataAll, h))
  if failed(hr):
    done(hresultError("clearing browsing data", hr))
