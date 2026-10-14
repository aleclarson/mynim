## window.go + page.go + window_state.go — the window: creation, the
## native operations, the page API and the event callbacks the backend
## calls, and the persisted window state.

## Window is a native window showing a web page or native UI. Create
## windows with newWindow once the application is ready:
##
##   app.whenReady(proc() =
##     discard newWindow(WindowOptions(title: "My App", url: "/")))
##
## All methods are safe from any thread. Fields live in types.nim.

var windowsState {.global.}: tuple[loaded: bool,
    byKey: Table[string, WindowState], dirty: bool]
## The states of the windowStateStore, loaded on first use. Main
## thread only.

const windowStateFile = "window-state.json"
## windowState.json in pathUserData keeps the states unless
## app.setWindowStateStore set another store.

## How long a window's state must stay unchanged to be captured.
const windowStateDelay = initDuration(milliseconds = 300)

## Internal forward declarations: several of this part's procs call
## ones defined later in the file.
proc tryClose(w: Window): bool
proc destroyNow(w: Window)
proc closeState(w: Window)
proc resetPage(w: Window)
proc initState(w: Window; p: platform.WindowOptions)
proc handleSurfaceEvent(w: Window; ev: platform.SurfaceEvent): bool
proc captureContent(w: Window): tuple[png: seq[byte],
  err: ref CatchableError]
proc destroyWebViews(w: Window)
proc invalidate*(w: Window)
proc show*(w: Window)
proc loadURL*(p: Page; rawURL: string): ref CatchableError
proc loadHTML(w: Window; n: platform.Window; html, baseURL: string)
proc setFlyoutSize(w: Window; width, height: int): bool
proc uniquePath(path: string): string
proc makeWindow(opts: WindowOptions; bg: ref Background; native: uint;
  flyout: ref FlyoutOpts): Window
proc placeWebViews(w: Window; views: seq[platform.WebViewPlacement])
proc cancelDataDragNow(w: Window)
proc contentChanged(w: Window)
proc windowStateStore(a: Application): WindowStateStore
proc captureState(w: Window)
proc makeWebView(w: Window; opts: WebViewOptions; bg: ref Background):
  tuple[v: WebView, err: ref CatchableError]
proc destroyWebView(w: Window)
proc placeFlyout(w: Window)
proc locale*(a: Application): string
proc region*(a: Application): i18n.Region
proc appDir(): string
proc currentLocale(): string
proc updateLocale(a: Application; tell: bool)
proc sendLocale(w: Window)
proc pagesLocaleChanged(locale: string)
proc afterSleep(d: Duration; fn: proc() {.closure.}): StateTimer
proc reset(t: StateTimer; d: Duration)
proc stop(t: StateTimer)

## window it is in, which the core calls for drag regions (startDrag,
## titleBarDoubleClicked).
type WebViewNativeObj = ref object of platform.Window
  ## window is the window the web view is in (Go's embedded
  ## platform.Window: un-overridden methods forward to it).
  window: platform.Window
  web: platform.WebView
  ## frame is where the window's view last showed the web view, while
  ## shown; misplaced is set once a view of another window placed it,
  ## which is logged once.
  frame: platform.RectF
  shown, misplaced: bool

proc newWindow*(opts: WindowOptions): Window

proc `or`(v, fallback: int): int =
  ## The first non-zero of v and fallback (Go: or[T comparable]).
  if v == 0: fallback else: v

proc `or`(v, fallback: float64): float64 =
  if v == 0: fallback else: v

proc jsPlatform(): string =
  ## The platform name the bridge tells the page.
  when defined(macosx): "darwin"
  elif defined(windows): "win32"
  else: hostOS

## backgroundOption parses windowOptions.backgroundColor, which is
## validated in the caller's thread so mistakes point at the call.
proc backgroundOption(s: string): tuple[bg: ref Background,
    err: ref CatchableError] =
  if s == "":
    return (nil, nil)
  try:
    let bg = parseBackground(s)
    ((ref Background)(light: bg.light, dark: bg.dark), nil)
  except CatchableError as e:
    (nil, e)

## backgroundColor returns the window's background for the current
## appearance, or nil. Main thread only.
proc backgroundColor(w: Window): ref platform.Color =
  if w.background == nil:
    return nil
  var c = w.background.light
  if w.background.dark != c and backend().theme().isDark():
    c = w.background.dark
  (ref platform.Color)(r: c.r, g: c.g, b: c.b, a: c.a)

## updateBackgrounds gives windows with a light and a dark background
## the one of the current appearance. Main thread only.
proc updateBackgrounds() =
  for w in pageWindows():
    let bg = w.background
    if w.native != nil and bg != nil and bg.light != bg.dark:
      w.native.setBackgroundColor(w.backgroundColor()[])

## pageScripts are the scripts a page of the window gets at document
## start: the bridge, the preferences of the page and the preload
## script.
proc pageScripts(w: Window): seq[platform.UserScript]

proc platformOptions(w: Window; o: WindowOptions): platform.WindowOptions =
  ## Translates the window's options for the backend. Main thread only.
  let po = o.page
  var p = platform.WindowOptions(
    title: o.title,
    x: o.x, y: o.y,
    width: `or`(o.width, 800), height: `or`(o.height, 600),
    center: o.x == 0 and o.y == 0,
    useContentSize: o.useContentSize,
    minSize: platform.Size(width: o.minWidth, height: o.minHeight),
    maxSize: platform.Size(width: o.maxWidth, height: o.maxHeight),
    resizable: not o.disableResize,
    movable: not o.disableMove,
    minimizable: not o.disableMinimize,
    maximizable: not o.disableMaximize,
    closable: not o.disableClose,
    focusable: true,
    fullscreenable: not o.disableFullScreen,
    alwaysOnTop: o.alwaysOnTop,
    fullScreen: o.fullScreen,
    maximized: o.maximized,
    skipTaskbar: o.skipTaskbar,
    autoHideMenu: o.autoHideMenuBar,
    hasShadow: not o.disableShadow,
    frameless: o.frameless,
    transparent: o.transparent,
    titleBarStyle: string(o.titleBarStyle),
    titleBarHeight: max(o.titleBarHeight, 0),
    vibrancy: string(o.vibrancy),
    opacity: o.opacity,
    modal: o.modal,
    userAgent: po.userAgent,
    zoom: po.zoomFactor,
    schemes: protocol.schemes(),
    panel: o.panel)
  if o.panel:
    p.minimizable = false
    p.maximizable = false
    p.fullscreenable = false
    p.alwaysOnTop = true
    p.skipTaskbar = true
  if p.title == "":
    p.title = app.name()
  if p.opacity <= 0 or p.opacity > 1:
    p.opacity = 1
  if p.zoom <= 0:
    p.zoom = 1
  case po.devTools
  of devToolsEnabled:
    p.devTools = true
  of devToolsAuto:
    p.devTools = isDev()
  of devToolsDisabled:
    discard
  if o.trafficLightPosition != nil:
    p.trafficLightPosition = (ref platform.Point)(
      x: o.trafficLightPosition.x, y: o.trafficLightPosition.y)
  if o.parent != nil and o.parent.native != nil:
    p.parent = o.parent.native
  w.preload = po.preloadScript
  p.userScripts = w.pageScripts()
  p

## restoreWindowState applies the state saved under key to p, if the
## window would show on a connected display. Otherwise the window keeps
## its saved size, as far as the display allows, and is centered.
proc restoreWindowState(key: string; p: var platform.WindowOptions) =
  loadWindowStates()
  if not windowsState.byKey.hasKey(key):
    return
  let st = windowsState.byKey[key]
  if st.width <= 0 or st.height <= 0:
    return
  let r = Rectangle(x: st.x, y: st.y, width: st.width, height: st.height)
  let displays = backend().screen().displays()
  p.useContentSize = false
  p.maximized = st.maximized
  p.fullScreen = st.fullScreen
  if onDisplay(r, displays):
    p.x = r.x; p.y = r.y; p.width = r.width; p.height = r.height
    p.center = false
    return
  p.width = r.width
  p.height = r.height
  for d in displays:
    if d.primary:
      p.width = min(r.width, d.workArea.width)
      p.height = min(r.height, d.workArea.height)
  p.center = true

## onDisplay reports whether at least a corner of r shows on a connected
## display, that is, whether the window of r would be reachable.
proc onDisplay(r: Rectangle; displays: seq[platform.Display]): bool =
  for d in displays:
    let a = d.workArea
    ## Any overlap of 64 px, a corner's worth, makes the window
    ## reachable.
    if r.x < a.x + a.width and r.x + r.width > a.x and
        r.y < a.y + a.height and r.y + 64 > a.y:
      return true
  false

## newWindow creates the window on the main thread.
proc makeWindow(opts: WindowOptions; bg: ref Background; native: uint;
    flyout: ref FlyoutOpts): Window =
  windows.mu.acquire()
  inc windows.nextID
  let id = windows.nextID
  windows.mu.release()

  let w = Window(id: id, parent: opts.parent,
    trustedOrigins: opts.page.trustedOrigins, secret: randomText(),
    stateKey: opts.stateKey, background: bg, content: opts.content,
    panel: opts.panel and flyout == nil)
  w.mu.initLock()
  w.outMu.initLock()
  w.pg = Page(w: w)
  w.hiddenTitleBar = not opts.frameless and
    (opts.titleBarStyle == titleBarHidden or
     opts.titleBarStyle == titleBarHiddenInset)
  w.resetPage()
  var popts = w.platformOptions(opts)
  popts.backgroundColor = w.backgroundColor()
  popts.surface = opts.content != nil
  if opts.transparent:
    ## Backends keep transparent windows clear; so do theme changes.
    w.background = nil
  popts.native = native
  if flyout != nil:
    w.flyout = flyout.flyout
    if flyout.tray != nil:
      if flyout.tray.native == nil:
        raise newException(ValueError,
          "mynim: newFlyout: the tray was destroyed")
      w.flyout.tray = flyout.tray.native
    w.flyoutSize = platform.Size(width: popts.width, height: popts.height)
    popts.flyout = w.flyout
    popts.focusable = w.flyout.focusable
    popts.center = false
  w.devTools = popts.devTools
  if w.stateKey != "":
    restoreWindowState(w.stateKey, popts)
  w.title = popts.title
  let (nw, err) = backend().newWindow(popts, windowHandler(w))
  if err != nil:
    raise newException(ValueError, "mynim: cannot create window: " & err.msg)
  w.native = nw
  if w.stateKey != "":
    w.initState(popts)
  if w.content != nil:
    w.attachContent()

  windows.mu.acquire()
  windows.list.add w
  windows.mu.release()

  fire1(app.onWindowCreated, w)
  if opts.url != "" and w.content == nil:
    discard w.pg.loadURL(opts.url)
  if not opts.hidden:
    w.show()
  w

## createWindow creates a window, or a flyout, once the application is
## ready.
proc createWindow(caller: string; opts: WindowOptions; bg: ref Background;
    flyout: ref FlyoutOpts): Window =
  if not isMainThread():
    app.waitReady()
  elif not app.isReady():
    raise newException(ValueError, "mynim: " & caller &
      " called before the application is ready; create windows in app.whenReady")
  result = onMainValue(proc(): Window = makeWindow(opts, bg, 0, flyout))
  if result == nil:
    ## The event loop has already stopped.
    result = Window()
    result.destroyed.store(true)

proc newWindow*(opts: WindowOptions): Window =
  ## Creates a window. It must be called after the application is
  ## ready (see app.whenReady); when called from another thread it
  ## waits for that.
  let (bg, err) = backgroundOption(opts.backgroundColor)
  if err != nil:
    raise err
  createWindow("newWindow", opts, bg, nil)

## windows returns all open windows in creation order.
proc allWindows*(): seq[Window] =
  windows.mu.acquire()
  result = windows.list
  windows.mu.release()

proc focusedWindow*(): Window =
  ## The focused window of this application, or nil.
  windows.mu.acquire()
  result = windows.focused
  windows.mu.release()

proc windowByID*(id: int): Window =
  ## The window with the given id, or nil.
  windows.mu.acquire()
  defer: windows.mu.release()
  for w in windows.list:
    if w.id == id:
      return w
  nil

proc id*(w: Window): int =
  ## The unique id of the window. The page sees it as
  ## window.mynim.windowId.
  w.id

proc isDestroyed*(w: Window): bool = w.destroyed.load()
  ## Whether the window has been closed.

proc parent*(w: Window): Window = w.parent

## do runs fn with the native window on the main thread, unless the
## window has been destroyed.
proc withNative(w: Window; fn: proc(n: platform.Window) {.closure.}) =
  onMain(proc() =
    if w.native != nil:
      fn(w.native))

## get is do for functions returning a value.
proc get[T](w: Window; fn: proc(n: platform.Window): T): T =
  onMainValue(proc(): T =
    if w.native == nil:
      default(T)
    else:
      fn(w.native))

## page runs fn with the native window, unless the window shows
## Content and so has no page.
proc page(w: Window; fn: proc(n: platform.Window) {.closure.}) =
  if w.content != nil:
    return
  w.withNative(fn)

## pageGet is page for functions returning a value.
proc pageGet[T](w: Window; fn: proc(n: platform.Window): T): T =
  if w.content != nil:
    return default(T)
  get(w, fn)

## top returns the window showing the page: the window of a web view,
## else the window itself.
proc top(w: Window): Window =
  if w.host != nil: w.host else: w

## --- window operations ---

proc close*(w: Window) =
  ## Closes the window as if the user clicked its close button, so
  ## onClose listeners can cancel it.
  onMain(proc() = discard w.tryClose())

## tryClose runs on the main thread and reports whether the window was
## closed.
proc tryClose(w: Window): bool =
  if w.native == nil:
    return true
  var e = CloseEvent(window: w)
  fire1(w.onClose, e)
  if e.preventable.prevented:
    return false
  w.destroy()
  true

proc destroy*(w: Window) =
  ## Closes the window without emitting onClose.
  onMain(proc() = w.destroyNow())

proc destroyNow(w: Window) =
  if w.native != nil:
    w.closeState()
    w.native.close()
    ## Backends report closed synchronously, but be defensive.
    windowHandler(w).closed()

proc show*(w: Window) =
  ## Shows and focuses the window.
  onMain(proc() =
    if w.native == nil:
      return
    let visible = w.native.isVisible()
    w.native.show()
    w.shown = true
    if not visible:
      fire(w.onShow))

proc showInactive*(w: Window) =
  ## Shows the window without focusing it.
  onMain(proc() =
    if w.native == nil:
      return
    let visible = w.native.isVisible()
    w.native.showInactive()
    w.shown = true
    if not visible:
      fire(w.onShow))

proc hide*(w: Window) =
  ## Hides the window.
  onMain(proc() =
    if w.native == nil or not w.native.isVisible():
      return
    w.native.hide()
    fire(w.onHide))

proc isPanel*(w: Window): bool =
  ## Whether the window was created with WindowOptions.panel.
  w.panel

proc isVisible*(w: Window): bool =
  ## Whether the window is shown.
  get(w, proc(n: platform.Window): bool = n.isVisible())

proc focus*(w: Window) =
  ## Focuses the window.
  w.withNative(proc(n: platform.Window) = n.focus())

proc blur*(w: Window) =
  ## Removes focus from the window.
  w.withNative(proc(n: platform.Window) = n.blur())

proc isFocused*(w: Window): bool =
  ## Whether the window has keyboard focus.
  get(w, proc(n: platform.Window): bool = n.isFocused())

proc minimize*(w: Window) =
  ## Minimizes the window.
  w.withNative(proc(n: platform.Window) = n.minimize())

proc isMinimized*(w: Window): bool =
  ## Whether the window is minimized.
  get(w, proc(n: platform.Window): bool = n.isMinimized())

proc maximize*(w: Window) =
  ## Maximizes the window.
  w.withNative(proc(n: platform.Window) = n.maximize())

proc unmaximize*(w: Window) =
  ## Restores a maximized window.
  w.withNative(proc(n: platform.Window) = n.unmaximize())

proc toggleMaximize*(w: Window) =
  ## Maximizes the window or restores it if it is maximized.
  w.withNative(proc(n: platform.Window) =
    if n.isMaximized(): n.unmaximize() else: n.maximize())

proc isMaximized*(w: Window): bool =
  ## Whether the window is maximized.
  get(w, proc(n: platform.Window): bool = n.isMaximized())

proc restore*(w: Window) =
  ## Restores a minimized window.
  w.withNative(proc(n: platform.Window) = n.restore())

proc setFullScreen*(w: Window; v: bool) =
  ## Enters or leaves full screen.
  w.withNative(proc(n: platform.Window) = n.setFullScreen(v))

proc toggleFullScreen*(w: Window) =
  ## Enters full screen or leaves it.
  w.withNative(proc(n: platform.Window) = n.setFullScreen(not n.isFullScreen()))

proc isFullScreen*(w: Window): bool =
  ## Whether the window is in full screen.
  get(w, proc(n: platform.Window): bool = n.isFullScreen())

proc center*(w: Window) =
  ## Moves the window to the center of its screen.
  w.withNative(proc(n: platform.Window) = n.center())

proc applyTitle(w: Window; n: platform.Window) =
  ## Gives the native window its title, marked when the document is
  ## edited where the title bar has no other mark. Main thread only.
  var title = w.title
  if w.documentEdited and hostOS != "macosx":
    title = "*" & title
  n.setTitle(title)

proc setTitle*(w: Window; title: string) =
  ## Sets the native window title.
  w.withNative(proc(n: platform.Window) =
    w.title = title
    w.applyTitle(n))

proc title*(w: Window): string =
  ## The window title, without the mark of an edited document (see
  ## setDocumentEdited).
  get(w, proc(n: platform.Window): string = w.title)

proc setRepresentedFile*(w: Window; path: string) =
  ## Tells which file the window shows, "" for none. On macOS the
  ## title bar shows its icon, which the user can drag, and
  ## Command-clicking the title lists the folders it is in. Other
  ## platforms show nothing. Documents set it for their windows.
  var path = path
  if path != "":
    try:
      path = absolutePath(path)
    except CatchableError:
      discard
  w.withNative(proc(n: platform.Window) =
    w.representedFile = path
    n.setRepresentedFile(path))

proc representedFile*(w: Window): string =
  ## The path setRepresentedFile set.
  onMainValue(proc(): string = w.representedFile)

proc setDocumentEdited*(w: Window; edited: bool) =
  ## Tells whether the window's document has unsaved changes: a dot in
  ## the close button on macOS, and a "*" before the title on Linux
  ## and Windows. Documents set it for their windows.
  w.withNative(proc(n: platform.Window) =
    if w.documentEdited == edited:
      return
    w.documentEdited = edited
    n.setDocumentEdited(edited)
    w.applyTitle(n))

proc isDocumentEdited*(w: Window): bool =
  ## What setDocumentEdited set.
  onMainValue(proc(): bool = w.documentEdited)

proc setBounds*(w: Window; r: Rectangle) =
  ## Moves and resizes the window.
  w.withNative(proc(n: platform.Window) =
    n.setBounds(platform.Rect(x: r.x, y: r.y, width: r.width,
                              height: r.height)))

proc bounds*(w: Window): Rectangle =
  ## The position and size of the window.
  get(w, proc(n: platform.Window): Rectangle =
    let b = n.bounds()
    Rectangle(x: b.x, y: b.y, width: b.width, height: b.height))

proc setContentBounds*(w: Window; r: Rectangle) =
  ## Moves and resizes the window so the page area has the given
  ## bounds.
  w.withNative(proc(n: platform.Window) =
    n.setContentBounds(platform.Rect(x: r.x, y: r.y, width: r.width,
                                     height: r.height)))

proc contentBounds*(w: Window): Rectangle =
  ## The bounds of the page area.
  get(w, proc(n: platform.Window): Rectangle =
    let b = n.contentBounds()
    Rectangle(x: b.x, y: b.y, width: b.width, height: b.height))

proc setSize*(w: Window; width, height: int) =
  ## Resizes the window.
  w.withNative(proc(n: platform.Window) =
    if w.setFlyoutSize(width, height):
      return
    var b = n.bounds()
    b.width = width
    b.height = height
    n.setBounds(b))

proc size*(w: Window): tuple[width, height: int] =
  ## The size of the window.
  let b = w.bounds()
  (b.width, b.height)

proc setContentSize*(w: Window; width, height: int) =
  ## Resizes the window so the page area has the given size.
  w.withNative(proc(n: platform.Window) =
    if w.setFlyoutSize(width, height):
      return
    var b = n.contentBounds()
    b.width = width
    b.height = height
    n.setContentBounds(b))

proc contentSize*(w: Window): tuple[width, height: int] =
  ## The size of the page area.
  let b = w.contentBounds()
  (b.width, b.height)

proc setPosition*(w: Window; x, y: int) =
  ## Moves the window's top-left corner.
  w.withNative(proc(n: platform.Window) =
    var b = n.bounds()
    b.x = x
    b.y = y
    n.setBounds(b))

proc position*(w: Window): tuple[x, y: int] =
  ## The window's top-left corner.
  let b = w.bounds()
  (b.x, b.y)

proc setMinimumSize*(w: Window; width, height: int) =
  ## Limits how small the window can be resized; 0 means no limit.
  w.withNative(proc(n: platform.Window) =
    n.setMinimumSize(platform.Size(width: width, height: height)))

proc setMaximumSize*(w: Window; width, height: int) =
  ## Limits how large the window can be resized; 0 means no limit.
  w.withNative(proc(n: platform.Window) =
    n.setMaximumSize(platform.Size(width: width, height: height)))

proc setResizable*(w: Window; v: bool) =
  ## Sets whether the user can resize the window.
  w.withNative(proc(n: platform.Window) = n.setResizable(v))

proc isResizable*(w: Window): bool =
  ## Whether the user can resize the window.
  get(w, proc(n: platform.Window): bool = n.isResizable())

proc setMovable*(w: Window; v: bool) =
  ## Sets whether the user can move the window.
  w.withNative(proc(n: platform.Window) = n.setMovable(v))

proc isMovable*(w: Window): bool =
  ## Whether the user can move the window.
  get(w, proc(n: platform.Window): bool = n.isMovable())

proc setMinimizable*(w: Window; v: bool) =
  ## Sets whether the window can be minimized.
  w.withNative(proc(n: platform.Window) = n.setMinimizable(v))

proc isMinimizable*(w: Window): bool =
  ## Whether the window can be minimized.
  get(w, proc(n: platform.Window): bool = n.isMinimizable())

proc setMaximizable*(w: Window; v: bool) =
  ## Sets whether the window can be maximized.
  w.withNative(proc(n: platform.Window) = n.setMaximizable(v))

proc isMaximizable*(w: Window): bool =
  ## Whether the window can be maximized.
  get(w, proc(n: platform.Window): bool = n.isMaximizable())

proc setClosable*(w: Window; v: bool) =
  ## Sets whether the user can close the window.
  w.withNative(proc(n: platform.Window) = n.setClosable(v))

proc isClosable*(w: Window): bool =
  ## Whether the user can close the window.
  get(w, proc(n: platform.Window): bool = n.isClosable())

proc setAlwaysOnTop*(w: Window; v: bool) =
  ## Keeps the window above other windows.
  w.withNative(proc(n: platform.Window) = n.setAlwaysOnTop(v))

proc isAlwaysOnTop*(w: Window): bool =
  ## Whether the window stays above other windows.
  get(w, proc(n: platform.Window): bool = n.isAlwaysOnTop())

proc setBackgroundColor*(w: Window; color: string): ref CatchableError =
  ## Sets the color shown behind the page, in the syntax of
  ## WindowOptions.backgroundColor.
  let bg = try:
    parseBackground(color)
  except CatchableError as e:
    return e
  w.withNative(proc(n: platform.Window) =
    w.background = (ref Background)(light: bg.light, dark: bg.dark)
    n.setBackgroundColor(w.backgroundColor()[]))

proc setOpacity*(w: Window; v: float64) =
  ## Sets the window opacity between 0 and 1.
  w.withNative(proc(n: platform.Window) = n.setOpacity(min(max(v, 0), 1)))

proc opacity*(w: Window): float64 =
  ## The window opacity.
  get(w, proc(n: platform.Window): float64 = n.opacity())

proc setHasShadow*(w: Window; v: bool) =
  ## Sets whether the window has a shadow.
  w.withNative(proc(n: platform.Window) = n.setHasShadow(v))

proc hasShadow*(w: Window): bool =
  ## Whether the window has a shadow.
  get(w, proc(n: platform.Window): bool = n.hasShadow())

proc setIgnoreMouseEvents*(w: Window; v: bool) =
  ## Makes the window transparent to mouse events.
  w.withNative(proc(n: platform.Window) = n.setIgnoreMouseEvents(v))

proc setContentProtection*(w: Window; v: bool) =
  ## Keeps the window content out of screenshots and screen
  ## recordings.
  w.withNative(proc(n: platform.Window) = n.setContentProtection(v))

proc setVibrancy*(w: Window; v: Vibrancy) =
  ## Sets the material behind the page; vibrancyNone removes it.
  ## See WindowOptions.vibrancy.
  w.withNative(proc(n: platform.Window) = n.setVibrancy(string(v)))
  ## Native UI looks again whether the material shows.
  w.invalidate()

proc setProgressBar*(w: Window; p: ProgressBar) =
  ## Shows the progress of a task:
  ##
  ##   win.setProgressBar(ProgressBar(value: done / total))
  ##   win.setProgressBar(ProgressBar()) # done: remove it
  ##
  ## On macOS and Linux the progress belongs to the application: the
  ## window that set it last wins.
  var state = p.state
  let value = min(max(p.value, 0), 1)
  if state == progressNone and p.value > 0:
    state = progressNormal
  w.withNative(proc(n: platform.Window) = n.setProgressBar(string(state), value))

proc flashFrame*(w: Window; flash: bool) =
  ## Draws the user's attention to the window, or stops doing so.
  w.withNative(proc(n: platform.Window) = n.flashFrame(flash))

proc setSkipTaskbar*(w: Window; v: bool) =
  ## Hides the window from the taskbar, or shows it there again
  ## (Linux, Windows). See WindowOptions.skipTaskbar.
  w.withNative(proc(n: platform.Window) = n.setSkipTaskbar(v))

proc setVisibleOnAllWorkspaces*(w: Window; v: bool) =
  ## Shows the window on every workspace (macOS Spaces, Linux virtual
  ## desktops), or on the current one only.
  w.withNative(proc(n: platform.Window) = n.setVisibleOnAllWorkspaces(v))

proc setIcon*(w: Window; png: seq[byte]): ref CatchableError =
  ## Sets the icon of the window, shown in its title bar and taskbar
  ## button (Linux, Windows), from a PNG image; empty restores the
  ## application icon. macOS windows show no icon of their own.
  w.withNative(proc(n: platform.Window) = n.setIcon(png))

proc setMenu*(w: Window; m: Menu) =
  ## Sets the menu bar of this window (Linux, Windows). On macOS the
  ## menu bar belongs to the application; see app.setMenu.
  onMain(proc() =
    w.menu = m
    if w.native != nil:
      w.native.setMenu(m.snapshot()))

proc setAutoHideMenuBar*(w: Window; v: bool) =
  ## Keeps the menu bar of this window out of sight until the user
  ## presses Alt or F10, or shows it for good again (Linux, Windows).
  ## See WindowOptions.autoHideMenuBar.
  w.withNative(proc(n: platform.Window) = n.setAutoHideMenu(v))

proc nativeHandle*(w: Window): uint =
  ## The native window: NSWindow* on macOS, GtkWindow* on Linux and
  ## HWND on Windows.
  get(w, proc(n: platform.Window): uint = n.handle())

## --- Page ---

proc page*(w: Window): Page =
  ## The web page the window shows, or nil for a window that shows
  ## native UI.
  if w.content != nil: nil else: w.pg

proc window*(p: Page): Window =
  ## The window that shows the page: for the page of a web view, the
  ## window the web view is in.
  p.w.top()

proc webView*(p: Page): WebView =
  ## The web view whose page this is, nil for the page of a window.
  p.w.webView

var errNoPage = newException(ValueError,
  "mynim: the window shows Content, not a web page")
## uniquePath returns path or, when it exists, path with " (n)"
## before the extension, the first free n (window_state's
## collision-free names).
proc uniquePath(path: string): string =
  if not fileExists(path):
    return path
  let (dir, name, ext) = splitFile(path)
  for n in 1 .. 999:
    let p = dir / name & " (" & $n & ")" & ext
    if not fileExists(p):
      return p
  path

var errDestroyed = newException(ValueError,
  "mynim: window has been destroyed")

proc loadURL*(p: Page; rawURL: string): ref CatchableError =
  ## Navigates the page to url. A URL without a scheme, such as "/" or
  ## "/settings?tab=1", is a page of the app's frontend: the dev
  ## server at devUrl during `mynim dev`, the frontend built into the
  ## app otherwise (see setFrontend). Besides http(s) URLs, schemes
  ## registered with protocol.handle can be used.
  if p.w.content != nil:
    return errNoPage
  let (resolved, err) = resolveURL(rawURL)
  if err != nil:
    return err
  p.w.page(proc(n: platform.Window) =
    p.w.html = nil
    n.loadURL(resolved))

proc resolveFile(path: string): tuple[p: string, err: ref CatchableError] =
  ## The absolute path of a local HTML file: relative paths resolve
  ## against the working directory, then the directory of the
  ## executable (and the Resources directory of a macOS app bundle).
  if path.isAbsolute():
    if fileExists(path):
      return (path, nil)
    return ("", newException(IOError, "mynim: file " & path.escape() &
      " not found"))
  var candidates: seq[string]
  candidates.add getCurrentDir() / path
  let dir = getAppFilename().parentDir()
  candidates.add dir / path
  candidates.add dir / ".." / "Resources" / path
  for c in candidates:
    if fileExists(c):
      return (c, nil)
  ("", newException(IOError, "mynim: file " & path.escape() &
    " not found"))

proc loadFile*(p: Page; path: string): ref CatchableError =
  ## Loads a local HTML file. Relative paths are resolved against the
  ## working directory, then against the directory of the executable
  ## (and the Resources directory of a macOS app bundle).
  if p.w.content != nil:
    return errNoPage
  let (abs, err) = resolveFile(path)
  if err != nil:
    return err
  p.w.page(proc(n: platform.Window) =
    p.w.html = nil
    n.loadFile(abs, abs.parentDir()))

## isTrusted reports whether a page at rawURL may call bound methods.
proc isTrusted(w: Window; rawURL: string): bool =
  let u = try: parseUri(rawURL)
    except CatchableError: return false
  let scheme = u.scheme.toLowerAscii()
  if scheme == "about" or scheme == "file" or scheme == frontendScheme:
    return true
  if protocol.isHandled(scheme):
    return true
  let origin = scheme & "://" & u.hostname.toLowerAscii() &
    (if u.port != "": ":" & u.port else: "")
  if isDevOrigin(origin):
    return true
  for o in w.trustedOrigins:
    if o == "*" or o.strip(chars = {'/'}, trailing = true).
        equalsIgnoreCase(origin):
      return true
  if isDev() and (scheme == "http" or scheme == "https"):
    if u.hostname in ["localhost", "127.0.0.1", "::1"]:
      return true
  false

proc loadHTML*(p: Page; html, baseURL: string) =
  ## Loads an HTML string. Relative URLs in it resolve against
  ## baseURL, which may be empty, and the page is at baseURL, or
  ## about:blank. Reloading the page loads html again.
  p.w.page(proc(n: platform.Window) = p.w.loadHTML(n, html, baseURL))

proc loadHTML(w: Window; n: platform.Window; html, baseURL: string) =
  ## Loads html into the page and remembers it for its reloads: web
  ## views reload the page's URL instead. Main thread only.
  w.html = HtmlDocument(html: html, baseURL: baseURL)
  n.loadHTML(html, baseURL)

## isAt reports whether url, which the page committed, is the
## document's, fragments aside.
proc isAt(d: HtmlDocument; url: string): bool =
  var base = d.baseURL
  if base == "":
    base = "about:blank"
  proc trim(u: string): string =
    let i = u.find('#')
    let x = if i >= 0: u[0..<i] else: u
    x.strip(chars = {'/'}, trailing = true)
  trim(url) == trim(base)

proc reload*(p: Page) =
  ## Reloads the page.
  p.w.page(proc(n: platform.Window) = n.reload(false))

proc reloadIgnoringCache*(p: Page) =
  ## Reloads the page bypassing the cache.
  p.w.page(proc(n: platform.Window) = n.reload(true))

proc stop*(p: Page) =
  ## Stops loading the page.
  p.w.page(proc(n: platform.Window) = n.stopLoading())

proc goBack*(p: Page) =
  ## Navigates back in history.
  p.w.page(proc(n: platform.Window) = n.goBack())

proc goForward*(p: Page) =
  ## Navigates forward in history.
  p.w.page(proc(n: platform.Window) = n.goForward())

proc canGoBack*(p: Page): bool =
  ## Whether there is a previous page in history.
  pageGet(p.w, proc(n: platform.Window): bool = n.canGoBack())

proc canGoForward*(p: Page): bool =
  ## Whether there is a next page in history.
  pageGet(p.w, proc(n: platform.Window): bool = n.canGoForward())

proc url*(p: Page): string =
  ## The URL of the current page.
  pageGet(p.w, proc(n: platform.Window): string = n.url())

proc isLoading*(p: Page): bool =
  ## Whether the page is still loading.
  pageGet(p.w, proc(n: platform.Window): bool = n.isLoading())

proc setZoomFactor*(p: Page; f: float64) =
  ## Zooms the page; 1 is 100%.
  if f <= 0:
    return
  p.w.page(proc(n: platform.Window) =
    n.setZoom(f)
    p.w.sendTitleBar()) ## the controls take other CSS pixels

proc zoomFactor*(p: Page): float64 =
  ## The page zoom; 1 is 100%.
  pageGet(p.w, proc(n: platform.Window): float64 = n.zoom())

proc setUserAgent*(p: Page; ua: string) =
  ## Overrides the user agent for subsequent requests.
  p.w.page(proc(n: platform.Window) = n.setUserAgent(ua))

proc userAgent*(p: Page): string =
  ## The user agent of the page.
  pageGet(p.w, proc(n: platform.Window): string = n.userAgent())

proc openDevTools*(p: Page) =
  ## Opens the web inspector (unless disabled with
  ## PageOptions.devTools).
  p.w.page(proc(n: platform.Window) = n.openDevTools())

proc closeDevTools*(p: Page) =
  ## Closes the web inspector.
  p.w.page(proc(n: platform.Window) = n.closeDevTools())

proc isDevToolsOpened*(p: Page): bool =
  ## Whether the web inspector is open.
  pageGet(p.w, proc(n: platform.Window): bool = n.isDevToolsOpened())

proc toggleDevTools*(p: Page) =
  ## Opens or closes the web inspector.
  p.w.page(proc(n: platform.Window) =
    if n.isDevToolsOpened(): n.closeDevTools() else: n.openDevTools())

proc print*(p: Page) =
  ## Opens the print dialog for the page.
  p.w.page(proc(n: platform.Window) = n.print())

proc capturePage*(w: Window): tuple[png: seq[byte],
    err: ref CatchableError] =
  ## A PNG screenshot of the visible page. For a window showing
  ## Content it renders the content as it is.
  if w.content != nil:
    return w.captureContent()
  type R = tuple[png: seq[byte], err: ref CatchableError]
  var ch: system.Channel[R]
  ch.open(1)
  let pch = addr ch
  w.withNative(proc(n: platform.Window) =
    n.capturePage(proc(png: seq[byte]; err: ref CatchableError) =
      var v: R
      v.png = png
      v.err = err
      deliver(pch[], v)))
  if w.isDestroyed():
    return (@[], errDestroyed)
  let r = await(ch)
  (r.png, r.err)

proc eval*(p: Page; code: string): tuple[v: JsonNode,
    err: ref CatchableError] =
  ## Evaluates JavaScript in the page and returns its result, decoded
  ## from JSON. An expression's value is returned, with promises
  ## awaited:
  ##
  ##   let title = p.eval("document.title")
  ##
  ## Statements run as the body of an async function, so use return
  ## to produce a value. eval is not subject to the page's Content
  ## Security Policy.
  evalRaw(p.w, newCtx(), code)

proc evalContext*(p: Page; ctx: CancelCtx; code: string):
    tuple[v: JsonNode, err: ref CatchableError] =
  ## eval with a context that can abort the wait.
  evalRaw(p.w, ctx, code)

proc evalAs*[T](p: Page; code: string): tuple[v: T,
    err: ref CatchableError] =
  ## eval, decoding the result into a value of type T:
  ##
  ##   let title = evalAs[string](w.page(), "document.title")
  ##
  ## A nil page, as a window showing native UI has, returns an error.
  var v: T
  if p == nil:
    return (v, errNoPage)
  let (raw, err) = evalRaw(p.w, newCtx(), code)
  if err != nil or raw == nil:
    return (v, err)
  try:
    (raw.to(T), nil)
  except CatchableError as e:
    (v, e)

proc setWindowOpenHandler*(p: Page;
    fn: proc(req: WindowOpenRequest): ref WindowOptions {.closure.}) =
  ## Decides what happens on window.open() and clicks on
  ## target="_blank" links. The handler returns the options of the
  ## window to open, or nil to deny the request. Without a handler,
  ## http(s) URLs open in the default browser and everything else is
  ## denied.
  p.w.mu.acquire()
  p.w.openHandler = fn
  p.w.mu.release()

## --- page context and the message queue ---

## resetPage starts a new page context; the previous one is canceled.
proc resetPage(w: Window) =
  var ctx = newCtx().withValue(callerKey.addr, RootRef(w.top()))
  ctx = ctx.withValue(pageKey.addr, RootRef(w.pg))
  let (c, cancel) = ctx.withCancel()
  acquire(w.mu)
  let prev = w.pageCancel
  w.pageCtx = c
  w.pageCancel = cancel
  w.channels.clear() ## they close with the previous page's context
  w.closedEarly.clear()
  release(w.mu)
  if prev != nil:
    prev()

## pageContext returns the context of the current page. It is canceled
## when the page navigates away or the window is destroyed.
proc pageContext(w: Window): CancelCtx =
  acquire(w.mu)
  result = w.pageCtx
  release(w.mu)

## maxHeldEvents bounds the events kept for a page that never becomes
## ready (e.g. an image or a failed load).
const maxHeldEvents = 1024

## enqueue schedules a message for the page. Messages are batched into
## a single script evaluation per main loop iteration. Events are held
## until the DOM of the page is ready; replies to calls are sent right
## away since the page is waiting for them.
proc enqueue(w: Window; msg: Message; event: bool) =
  if w.content != nil:
    return
  acquire(w.outMu)
  if event and not w.domReady:
    if w.held.len == maxHeldEvents:
      w.held.delete(0)
    w.held.add msg
    release(w.outMu)
    return
  w.outbox.add msg
  let schedule = not w.flushing
  w.flushing = true
  release(w.outMu)
  if schedule:
    discard postMain(proc() = w.flush())

proc flush(w: Window) =
  acquire(w.outMu)
  let msgs = w.outbox
  w.outbox.setLen(0)
  w.flushing = false
  release(w.outMu)
  if w.native == nil or msgs.len == 0:
    return
  ## A script shaped like a.b(JSON) runs without being compiled:
  ## WebKit's JavaScriptCore parses the value as JSON unless the
  ## inspector is on, several times faster. Pages without the runtime
  ## only throw.
  var js = "__mynim.receive(["
  for i, m in msgs.pairs:
    if i > 0:
      js.add ','
    js.add m.head
    js.add m.value
    js.add m.tail
  js.add "])"
  w.native.eval(js)

## --- window events ---

proc onClose*(w: Window; fn: proc(e: var CloseEvent) {.closure.}):
    proc() {.closure.} =
  ## Called when the window is about to close. Call e.preventDefault
  ## to keep it open.
  w.onClose.add(fn, false)

proc onClosed*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called after the window has been closed.
  w.onClosed.add(fn, false)

proc onFocus*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window gains focus.
  w.onFocus.add(fn, false)

proc onBlur*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window loses focus.
  w.onBlur.add(fn, false)

proc onShow*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window is shown.
  w.onShow.add(fn, false)

proc onHide*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window is hidden.
  w.onHide.add(fn, false)

proc onReadyToShow*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called once, when the first page is ready to be displayed.
  ## Create the window with hidden and call show here to avoid a
  ## visual flash. A window showing Content is ready once it drew its
  ## first frame, which a hidden window may not draw until shown.
  w.onReadyToShow.add(fn, false)

proc onResize*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called after the window was resized.
  w.onResize.add(fn, false)

proc onFileDrop*(w: Window; fn: proc(e: var FileDropEvent) {.closure.}):
    proc() {.closure.} =
  ## Called when files, for example from Finder or Explorer, are
  ## dropped on the page, with their paths. The app's own pages also
  ## get them, through onFileDrop of mynim-runtime. In a window
  ## showing native UI, it gets the files no element takes
  ## (ui.Element.droppedFiles), with x and y in DIPs.
  ##
  ## The page's own drag and drop keeps working: drop events still
  ## reach it with the File objects, and drags that start in the page
  ## are left alone. Only where the page does not handle dragged
  ## files are they accepted, so that dropping them there reaches
  ## onFileDrop instead of replacing the page with the file.
  w.onFileDrop.add(fn, false)

proc onMove*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called after the window was moved.
  w.onMove.add(fn, false)

proc onMaximize*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window is maximized.
  w.onMaximize.add(fn, false)

proc onUnmaximize*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window leaves the maximized state.
  w.onUnmaximize.add(fn, false)

proc onMinimize*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window is minimized.
  w.onMinimize.add(fn, false)

proc onRestore*(w: Window; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the window is restored from minimized.
  w.onRestore.add(fn, false)

proc onEnterFullScreen*(w: Window; fn: proc() {.closure.}):
    proc() {.closure.} =
  ## Called when the window entered full screen.
  w.onEnterFullScreen.add(fn, false)

proc onLeaveFullScreen*(w: Window; fn: proc() {.closure.}):
    proc() {.closure.} =
  ## Called when the window left full screen.
  w.onLeaveFullScreen.add(fn, false)

proc onPageTitleUpdated*(p: Page; fn: proc(e: var TitleEvent) {.closure.}):
    proc() {.closure.} =
  ## Called when the page's <title> changes. Preventing the event
  ## keeps the native window title.
  p.w.onPageTitleUpdated.add(fn, false)

proc onWillNavigate*(p: Page; fn: proc(e: var NavigateEvent) {.closure.}):
    proc() {.closure.} =
  ## Called before the page navigates to another URL, for example
  ## after a link click. Preventing the event cancels the navigation.
  ## It is not called for loadURL and friends.
  p.w.onWillNavigate.add(fn, false)

proc onDidNavigate*(p: Page; fn: proc(url: string) {.closure.}):
    proc() {.closure.} =
  ## Called when a navigation committed and a new page started.
  p.w.onDidNavigate.add(fn, false)

proc onDOMReady*(p: Page; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the page's DOM is ready (DOMContentLoaded).
  p.w.onDOMReady.add(fn, false)

proc onDidFinishLoad*(p: Page; fn: proc() {.closure.}): proc() {.closure.} =
  ## Called when the page finished loading.
  p.w.onDidFinishLoad.add(fn, false)

proc onDidFailLoad*(p: Page; fn: proc(e: LoadError) {.closure.}):
    proc() {.closure.} =
  ## Called when the page failed to load.
  p.w.onDidFailLoad.add(fn, false)

proc onRenderProcessGone*(p: Page; fn: proc(reason: string) {.closure.}):
    proc() {.closure.} =
  ## Called when the web content process crashed or was killed. Call
  ## reload to recover.
  p.w.onRenderGone.add(fn, false)

proc readyToShow(w: Window) =
  if w.readyShow:
    return
  w.readyShow = true
  fire(w.onReadyToShow)

## --- windowHandler: native events ---

type WindowHandlerObj = ref object of platform.WindowHandler
  ## windowHandler's implementation.
  w: Window

proc downloadScheme(h: WindowHandlerObj; rawURL: string)

proc windowHandler(w: Window): platform.WindowHandler =
  WindowHandlerObj(w: w)

method shouldClose(h: WindowHandlerObj): bool =
  var e = CloseEvent(window: h.w)
  fire1(h.w.onClose, e)
  if not e.preventable.prevented:
    h.w.closeState()
  not e.preventable.prevented

method closed(h: WindowHandlerObj) =
  let w = h.w
  if w.native == nil:
    return
  w.cancelDataDrag()
  w.destroyWebViews()
  w.detachContent()
  w.native = nil
  w.destroyed.store(true)
  windows.mu.acquire()
  let i = windows.list.find(w)
  if i >= 0:
    windows.list.delete(i)
  if windows.focused == w:
    windows.focused = nil
  var children: seq[Window]
  for x in windows.list:
    if x.parent == w:
      children.add x
  windows.mu.release()

  ## Children close with their parent, which reports the last window
  ## once they are all gone.
  inc closingParents
  for c in children:
    c.destroyNow()
  dec closingParents
  acquire(w.mu)
  let cancel = w.pageCancel
  release(w.mu)
  if cancel != nil:
    cancel()

  fire(w.onClosed)
  if closingParents == 0 and allWindows().len == 0:
    app.lastWindowClosed()

method focused(h: WindowHandlerObj) =
  windows.mu.acquire()
  windows.focused = h.w
  windows.mu.release()
  fire(h.w.onFocus)

method blurred(h: WindowHandlerObj) =
  windows.mu.acquire()
  if windows.focused == h.w:
    windows.focused = nil
  windows.mu.release()
  fire(h.w.onBlur)

method menuItemClicked(h: WindowHandlerObj; id: int) =
  if h.w.native != nil:
    menuItemClicked(id, h.w)

method resized(h: WindowHandlerObj) =
  h.w.stateChanged()
  h.w.placeFlyouts()
  fire(h.w.onResize)

method moved(h: WindowHandlerObj) =
  h.w.stateChanged()
  h.w.placeFlyouts()
  fire(h.w.onMove)

method minimized(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onMinimize)

method restored(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onRestore)

method maximized(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onMaximize)

method unmaximized(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onUnmaximize)

method enteredFullScreen(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onEnterFullScreen)

method leftFullScreen(h: WindowHandlerObj) =
  h.w.stateChanged()
  fire(h.w.onLeaveFullScreen)

method titleBarChanged(h: WindowHandlerObj) =
  h.w.sendTitleBar()
  let c = h.w.conn
  if c != nil and c.titleBarChanged != nil:
    c.titleBarChanged()

method message(h: WindowHandlerObj; msg: string) = h.w.handleMessage(msg)

method willNavigate(h: WindowHandlerObj; nav: platform.Navigation): bool =
  let doc = h.w.html
  if nav.isMainFrame and nav.reload and doc != nil and doc.shown:
    ## The reload of a document loadHTML loaded loads it again.
    discard postMain(proc() =
      let w = h.w
      if w.html == doc and w.native != nil:
        w.loadHTML(w.native, doc.html, doc.baseURL))
    return false
  if not nav.isMainFrame or nav.unasked:
    return true
  var e = NavigateEvent(url: nav.url, userInitiated: nav.userInitiated)
  fire1(h.w.onWillNavigate, e)
  not e.preventable.prevented

method navigationStarted(h: WindowHandlerObj; url: string) = discard

method navigationCommitted(h: WindowHandlerObj; url: string) =
  let doc = h.w.html
  if doc != nil:
    if doc.shown:
      h.w.html = nil ## another document replaced it
    elif doc.isAt(url):
      doc.shown = true
  h.w.trusted = h.w.isTrusted(url)
  acquire(h.w.outMu)
  h.w.domReady = false
  release(h.w.outMu)
  h.w.resetPage()
  fire1(h.w.onDidNavigate, url)

method loadFinished(h: WindowHandlerObj) =
  fire(h.w.onDidFinishLoad)
  ## Pages without the bridge (e.g. images) never report DOM ready.
  h.w.readyToShow()

method loadFailed(h: WindowHandlerObj; url: string; code: int;
    description: string) =
  let e = LoadError(url: url, code: code, description: description)
  fire1(h.w.onDidFailLoad, e)

method titleChanged(h: WindowHandlerObj; title: string) =
  if title == "":
    return
  var e = TitleEvent(title: title)
  fire1(h.w.onPageTitleUpdated, e)
  if not e.preventable.prevented and h.w.native != nil:
    h.w.title = title
    h.w.applyTitle(h.w.native)

method newWindow(h: WindowHandlerObj; req: platform.NewWindowRequest):
    platform.Window =
  acquire(h.w.mu)
  let handler = h.w.openHandler
  release(h.w.mu)
  let r = WindowOpenRequest(url: req.url, frameName: req.frameName,
    width: req.width, height: req.height)
  if handler == nil:
    let u = try: parseUri(req.url)
      except CatchableError: Uri()
    if u.scheme == "http" or u.scheme == "https":
      goAsync(proc() =
        discard shell.openExternal(req.url))
    return nil
  let opts = handler(r)
  if opts == nil:
    return nil
  var o = opts[]
  if o.width == 0 and req.width > 0:
    o.width = req.width
    o.height = req.height
  ## The webview loads the URL itself.
  o.url = ""
  let (bg, err) = backgroundOption(o.backgroundColor)
  if err != nil:
    stderr.writeLine("mynim: window open handler: " & err.msg)
  let child = makeWindow(o, bg, req.native, nil)
  child.native

method closedByPage(h: WindowHandlerObj) =
  if h.w.host == nil: ## a web view's page does not close its window
    discard h.w.tryClose()

method renderProcessGone(h: WindowHandlerObj; reason: string) =
  fire1(h.w.onRenderGone, reason)

method permissionRequested(h: WindowHandlerObj; kinds: seq[string];
    origin: string): bool =
  acquire(h.w.mu)
  let ph = h.w.permissionHandler
  release(h.w.mu)
  if ph == nil:
    return false
  if ph == nil:
    return h.w.isTrusted(origin)
  var e = PermissionRequest(origin: origin)
  for k in kinds:
    e.permissions.add Permission(k)
  ph(e)

method schemeRequest(h: WindowHandlerObj; req: platform.SchemeRequest) =
  protocol.serve(h.w, req)

method downloadStarted(h: WindowHandlerObj; url,
    suggestedName: string): string =
  ## The default saves into pathDownloads; an onWillDownload listener
  ## may pick another.
  var name = lastPathPart(normalizedPath("/" &
    suggestedName.replace('\\', '/')))
  if name == "/" or name == "." or name == "":
    name = "download"
  var e = DownloadEvent(url: url, suggestedName: name)
  let dir = app.path(pathDownloads)
  if dir != "":
    createDir(dir)
    e.path = uniquePath(dir / name)
  fire1(h.w.onWillDownload, e)
  if e.preventable.prevented or e.path == "":
    return ""
  e.path

method downloadFinished(h: WindowHandlerObj; url, path: string;
    err: ref CatchableError) =
  var d = Download(url: url, path: path, err: err)
  fire1(h.w.onDownloadDone, d)

method schemeDownload(h: WindowHandlerObj; url: string) =
  goAsync(proc() = downloadScheme(h, url))

method surfaceEvent(h: WindowHandlerObj; ev: platform.SurfaceEvent): bool =
  h.w.handleSurfaceEvent(ev)

## filesDropped tells onFileDrop listeners, and the app's own pages,
## about dropped files.
proc filesDropped(w: Window; paths: seq[string]; x, y: int) =
  if paths.len == 0:
    return
  var x = x
  var y = y
  let n = w.native
  if n != nil and n of WebViewNativeObj:
    ## Where the web view shows in its window.
    let nv = WebViewNativeObj(n)
    x += int(nv.frame.x)
    y += int(nv.frame.y)
  var e = FileDropEvent(paths: paths, x: x, y: y)
  fire1(w.top().onFileDrop, e)
  ## Local paths are none of other pages' business.
  if w.trusted:
    let (msg, err) = encodeEvent(fileDropEvent,
      %*{"paths": paths, "x": x, "y": y})
    if err == nil:
      w.enqueue(msg, true)

## --- window state ---

proc loadWindowStates() =
  if windowsState.loaded:
    return
  windowsState.loaded = true
  let (states, err) = app.windowStateStore().loadWindowStates()
  if err != nil:
    windowsState.byKey = initTable[string, WindowState]()
  else:
    windowsState.byKey = states

## saveWindowStates saves the states if they changed. A save that
## fails keeps them for the next one, at the latest when the app
## quits.
proc saveWindowStates() =
  if not windowsState.dirty:
    return
  windowsState.dirty = app.windowStateStore().
    saveWindowStates(windowsState.byKey) != nil

## stateFile is the default WindowStateStore: window-state.json in
## pathUserData.
type StateFile = ref object of WindowStateStore

proc stateFilePath(): tuple[p: string, err: ref CatchableError] =
  try:
    (app.path(pathUserData) / windowStateFile, nil)
  except CatchableError as e:
    ("", e)

method loadWindowStates(f: StateFile):
    tuple[states: Table[string, WindowState], err: ref CatchableError] =
  let (path, err) = stateFilePath()
  if err != nil:
    return (default(Table[string, WindowState]), err)
  var data: string
  try:
    data = readFile(path)
  except CatchableError:
    return (default(Table[string, WindowState]), nil) ## no file: fine
  try:
    let j = parseJson(data)
    var t = initTable[string, WindowState]()
    for k, v in j.pairs:
      t[k] = v.to(WindowState)
    (t, nil)
  except CatchableError as e:
    ## a damaged file is ignored, and replaced by the next save
    (default(Table[string, WindowState]), nil)

method saveWindowStates(f: StateFile;
    states: Table[string, WindowState]): ref CatchableError =
  let (path, err) = stateFilePath()
  if err != nil:
    return err
  var obj = newJObject()
  for k, v in states.pairs:
    obj[k] = %v
  let data = pretty(obj)
  ## Windows cannot replace a file that another program has open,
  ## such as antivirus software scanning it: the error keeps the
  ## states for the next save.
  try:
    writeFile(path & ".tmp", data)
    moveFile(path & ".tmp", path)
    nil
  except CatchableError as e:
    e

## windowStateStore is the store of app.setWindowStateStore, or the
## file.
proc windowStateStore(a: Application): WindowStateStore =
  a.mu.acquire()
  let s = a.stateStore
  a.mu.release()
  if s == nil: StateFile() else: s

proc setWindowStateStore*(a: Application; s: WindowStateStore) =
  ## Sets where window states (WindowOptions.stateKey) are kept. Nil
  ## restores the default, window-state.json in pathUserData. Call
  ## before windows are created.
  a.mu.acquire()
  a.stateStore = s
  a.mu.release()

## initState arms the state capture of a window that restored one.
proc initState(w: Window; p: platform.WindowOptions) =
  discard w
  discard p
  ## The window started at the saved state; nothing to capture until
  ## it changes.

## stateChanged captures the window's state once it stopped changing.
proc stateChanged(w: Window) =
  if w.stateKey == "":
    return
  if w.stateTimer != nil:
    w.stateTimer.reset(windowStateDelay)
    return
  w.stateTimer = afterSleep(windowStateDelay,
    proc() = discard postMain(proc() = w.captureState()))

## captureState records the window's current state under its key.
proc captureState(w: Window) =
  let n = w.native
  if w.stateKey == "" or n == nil:
    return
  loadWindowStates()
  var st = windowsState.byKey.getOrDefault(w.stateKey)
  st.maximized = n.isMaximized()
  st.fullScreen = n.isFullScreen()
  if not st.maximized and not st.fullScreen and not n.isMinimized():
    let b = n.bounds()
    if b.width > 0 and b.height > 0:
      st.x = b.x; st.y = b.y; st.width = b.width; st.height = b.height
  if st.width <= 0 or st.height <= 0:
    return
  if not windowsState.byKey.hasKey(w.stateKey) or
      windowsState.byKey[w.stateKey] != st:
    windowsState.byKey[w.stateKey] = st
    windowsState.dirty = true

## closeState captures the state of a closing window for the last
## time, and writes the states.
proc closeState(w: Window) =
  if w.stateTimer != nil:
    w.stateTimer.stop()
    w.stateTimer = nil
  w.captureState()
  saveWindowStates()

## afterSleep runs fn after d has passed, returning a timer that can
## reset or stop it (window_state.go's time.AfterFunc).
proc afterSleep(d: Duration; fn: proc() {.closure.}): StateTimer =
  result = StateTimer()
  result.d = d
  result.fn = fn
  let t = result
  let gen = int64(0)
  goAsync(proc() =
    sleep(int(d.inMilliseconds))
    if not t.stopped.load() and t.generation.load() == gen:
      t.fn())

proc reset(t: StateTimer; d: Duration) =
  ## Re-arms the timer for d, as time.Timer.Reset does.
  t.d = d
  let gen = t.generation.fetchAdd(1) + 1
  goAsync(proc() =
    sleep(int(d.inMilliseconds))
    if not t.stopped.load() and t.generation.load() == gen:
      t.fn())

proc stop(t: StateTimer) =
  ## Cancels the timer if it has not run yet.
  t.stopped.store(true)

## --- flyouts (flyout.go) ---

## placementBottomStart and the other placements name where a flyout
## goes from its anchor.
const
  placementBottomStart* = Placement"bottom-start"
  placementBottom* = Placement"bottom"
  placementBottomEnd* = Placement"bottom-end"
  placementTopStart* = Placement"top-start"
  placementTop* = Placement"top"
  placementTopEnd* = Placement"top-end"
  placementRightStart* = Placement"right-start"
  placementRight* = Placement"right"
  placementRightEnd* = Placement"right-end"
  placementLeftStart* = Placement"left-start"
  placementLeft* = Placement"left"
  placementLeftEnd* = Placement"left-end"

## placements are the sides and alignments of the placements.
const placements = {
  Placement"": (sideBottom, alignStart),
  Placement"bottom-start": (sideBottom, alignStart),
  Placement"bottom": (sideBottom, alignCenter),
  Placement"bottom-end": (sideBottom, alignEnd),
  Placement"top-start": (sideTop, alignStart),
  Placement"top": (sideTop, alignCenter),
  Placement"top-end": (sideTop, alignEnd),
  Placement"right-start": (sideRight, alignStart),
  Placement"right": (sideRight, alignCenter),
  Placement"right-end": (sideRight, alignEnd),
  Placement"left-start": (sideLeft, alignStart),
  Placement"left": (sideLeft, alignCenter),
  Placement"left-end": (sideLeft, alignEnd),
}.toTable

proc flyoutPlatformOpts(o: FlyoutOptions): tuple[f: platform.Flyout,
    err: ref CatchableError] =
  if not placements.hasKey(o.placement):
    return (nil, newException(ValueError,
      "mynim: unknown flyout placement " & string(o.placement).escape()))
  let p = placements[o.placement]
  (platform.Flyout(
    anchor: platform.Rect(x: o.anchor.x, y: o.anchor.y,
      width: o.anchor.width, height: o.anchor.height),
    side: p[0], align: p[1],
    gap: o.gap,
    focusable: o.focusable,
    popover: o.popover), nil)

proc newFlyout*(opts: FlyoutOptions): Window =
  ## Creates a flyout: a window without a frame, a background, a
  ## shadow or a taskbar button, owned by its parent and placed next
  ## to a rectangle of it, which may extend beyond the parent but
  ## stays in the work area of a display. Its page or native UI draws
  ## all of it: give the page a background, or the native UI's root
  ## one. Like newWindow, it must be called after the application is
  ## ready.
  if (opts.parent == nil) == (opts.tray == nil):
    raise newException(ValueError, "mynim: newFlyout needs a parent or a tray")
  let (fo, err) = flyoutPlatformOpts(opts)
  if err != nil:
    raise err
  createWindow("newFlyout", WindowOptions(
    url: opts.url,
    width: `or`(opts.width, 200),
    height: `or`(opts.height, 200),
    useContentSize: true,
    frameless: true,
    transparent: true,
    disableResize: true,
    disableMinimize: true,
    disableMaximize: true,
    disableFullScreen: true,
    disableShadow: not opts.shadow,
    skipTaskbar: true,
    parent: opts.parent,
    page: opts.page,
    content: opts.content,
    hidden: opts.hidden,
  ), nil, (ref FlyoutOpts)(flyout: fo, tray: opts.tray))

proc isFlyout*(w: Window): bool =
  ## Whether newFlyout created the window.
  w.flyout != nil

proc setAnchor*(w: Window; anchor: Rectangle) =
  ## Places a flyout against another rectangle of its parent, in DIPs
  ## relative to the parent's content area, as FlyoutOptions.anchor.
  ## It does nothing for other windows.
  onMain(proc() =
    if w.flyout == nil or w.native == nil:
      return
    w.flyout.anchor = platform.Rect(x: anchor.x, y: anchor.y,
      width: anchor.width, height: anchor.height)
    w.placeFlyout())

## placeFlyout places a flyout where it goes now. Main thread only.
proc placeFlyout(w: Window) =
  if w.flyout != nil and w.native != nil:
    w.native.placeFlyout(w.flyout, w.flyoutSize)

## placeFlyouts places the flyouts of a window that moved or resized
## again, which keeps them next to their anchors and in the work
## area. Main thread only.
proc placeFlyouts(w: Window) =
  for x in allWindows():
    if x.parent == w and x.flyout != nil:
      x.placeFlyout()

## setFlyoutSize resizes a flyout, which setSize and setContentSize do
## alike, and places it again: it reports false for other windows.
## Main thread only.
proc setFlyoutSize(w: Window; width, height: int): bool =
  if w.flyout == nil:
    return false
  w.flyoutSize = platform.Size(width: max(width, 1),
                               height: max(height, 1))
  w.placeFlyout()
  true

## escape closes a flyout or a panel on an Escape its page or native
## UI did not handle, as the user closing it: menus, popovers and
## launchers close so. Its content may be building a frame: the
## window closes after it. Main thread only.
proc escape(w: Window) =
  if w.flyout != nil or w.panel:
    discard postMain(proc() = discard w.tryClose())

## --- web views (webview.go) ---

var errNoContent = newException(ValueError,
  "mynim: web views go in windows showing native UI (WindowOptions.content)")

proc newWebView*(w: Window; opts: WebViewOptions):
    tuple[v: WebView, err: ref CatchableError] =
  ## Creates a web view for the window's native UI, which shows it
  ## where its view places it with ui.WebView. The window must show
  ## Content; the web view closes with it.
  let (bg, err0) = backgroundOption(opts.backgroundColor)
  if err0 != nil:
    return (nil, err0)
  if w.content == nil:
    return (nil, errNoContent)
  var v: WebView
  var err: ref CatchableError = errDestroyed
  onMain(proc() =
    if w.native != nil and w.conn != nil:
      (v, err) = w.makeWebView(opts, bg))
  (v, err)

## makeWebView creates a web view of the window. Main thread only.
proc makeWebView(w: Window; opts: WebViewOptions; bg: ref Background):
    tuple[v: WebView, err: ref CatchableError] =
  windows.mu.acquire()
  inc windows.nextID
  let id = windows.nextID
  windows.mu.release()

  ## The web view's page lives in a Window of its own, which no list
  ## holds: everything a page does works through it as for a window.
  let pw = Window(id: id, host: w,
    trustedOrigins: opts.page.trustedOrigins, secret: randomText(),
    background: bg)
  pw.mu.initLock()
  pw.outMu.initLock()
  pw.pg = Page(w: pw)
  pw.resetPage()
  var popts = pw.platformOptions(WindowOptions(page: opts.page,
    transparent: opts.transparent))
  popts.backgroundColor = pw.backgroundColor()
  if opts.transparent:
    pw.background = nil
  pw.devTools = popts.devTools
  let (nv, err) = w.conn.surface.newWebView(popts, windowHandler(pw))
  if err != nil:
    return (nil, newException(ValueError,
      "mynim: cannot create a web view: " & err.msg))
  pw.native = WebViewNativeObj(window: w.native, web: nv)
  let v = WebView(w: pw)
  pw.webView = v

  windows.mu.acquire()
  w.webViews.add pw
  windows.mu.release()

  if opts.url != "":
    let e = pw.pg.loadURL(opts.url)
    if e != nil:
      stderr.writeLine("mynim: web view: " & e.msg)
  (v, nil)

proc page*(v: WebView): Page =
  ## The web view's page.
  if v == nil: nil else: v.w.pg

proc window*(v: WebView): Window =
  ## The window the web view is in.
  if v == nil: nil else: v.w.host

proc focus*(v: WebView) =
  ## Gives the web view the keyboard, once it shows.
  onMain(proc() =
    if v.w.native of WebViewNativeObj:
      WebViewNativeObj(v.w.native).web.focus())

proc setBackgroundColor*(v: WebView; color: string): ref CatchableError =
  ## Sets the color filling the web view until its page paints, in
  ## the syntax of WebViewOptions.backgroundColor, as when the app's
  ## own theme changes; one given with light-dark follows the
  ## appearance by itself.
  v.w.setBackgroundColor(color)

proc capturePage*(v: WebView): tuple[png: seq[byte],
    err: ref CatchableError] =
  ## A PNG screenshot of the web view's page.
  v.w.capturePage()

proc destroy*(v: WebView) =
  ## Closes the web view and its page. Its window no longer shows it
  ## where the view still places it.
  onMain(proc() = v.w.destroyWebView())

proc isDestroyed*(v: WebView): bool = v.w.destroyed.load()
  ## Whether the web view was destroyed, or its window closed.

## surfaceWebView returns the native web view for package ui to
## place, nil once destroyed or for the content of another window,
## which is logged once. Main thread only.
method surfaceWebView*(v: WebView; conn: surface.Conn): platform.WebView =
  if v == nil:
    return nil
  if not (v.w.native of WebViewNativeObj):
    return nil ## destroyed
  let n = WebViewNativeObj(v.w.native)
  if conn.window != RootRef(v.w.host):
    if not n.misplaced:
      n.misplaced = true
      stderr.writeLine("mynim: the content of window " &
        $Window(conn.window).id() & " shows a web view of window " &
        $v.w.host.id())
    return nil
  n.web

## placeWebViews shows the window's web views where its content's
## last frame shows them, and notes where each is. Main thread only.
proc placeWebViews(w: Window; views: seq[platform.WebViewPlacement]) =
  windows.mu.acquire()
  for pw in w.webViews:
    if pw.native of WebViewNativeObj:
      let n = WebViewNativeObj(pw.native)
      n.shown = false
      for p in views:
        if p.webView == n.web:
          n.frame = p.frame
          n.shown = true
  windows.mu.release()
  if w.conn != nil:
    w.conn.surface.placeWebViews(views)

## destroyWebView closes the native web view of a web view's page and
## forgets it. Main thread only.
proc destroyWebView(w: Window) =
  if not (w.native of WebViewNativeObj):
    return
  let n = WebViewNativeObj(w.native)
  n.web.close()
  w.native = nil
  w.destroyed.store(true)
  windows.mu.acquire()
  let h = w.host
  if h != nil:
    let i = h.webViews.find(w)
    if i >= 0:
      h.webViews.delete(i)
  windows.mu.release()
  acquire(w.mu)
  let cancel = w.pageCancel
  release(w.mu)
  if cancel != nil:
    cancel()

## destroyWebViews closes the web views of a window that closed.
## Main thread only.
proc destroyWebViews(w: Window) =
  windows.mu.acquire()
  let views = w.webViews
  windows.mu.release()
  for v in views:
    v.destroyWebView()

## pageWindows returns the windows with pages: every window, and the
## pages of the web views of those showing native UI.
proc pageWindows(): seq[Window] =
  windows.mu.acquire()
  var list = windows.list
  for w in windows.list:
    list.add w.webViews
  windows.mu.release()
  list

## WebViewNativeObj is the native side of a web view's page: its page
## methods are the web view's, and its window methods those of the

method surface(n: WebViewNativeObj): platform.Surface = nil
method titleBar(n: WebViewNativeObj): platform.TitleBar = platform.TitleBar()
method setTitle(n: WebViewNativeObj; t: string) = discard
method close(n: WebViewNativeObj) = n.web.close()
method focus(n: WebViewNativeObj) = n.web.focus()
method setBackgroundColor(n: WebViewNativeObj; c: platform.Color) =
  n.web.setBackgroundColor(c)
method webViewHandle(n: WebViewNativeObj): uint = n.web.webViewHandle()
method loadURL(n: WebViewNativeObj; url: string) = n.web.loadURL(url)
method loadHTML(n: WebViewNativeObj; html, baseURL: string) =
  n.web.loadHTML(html, baseURL)
method loadFile(n: WebViewNativeObj; path, readAccessDir: string) =
  n.web.loadFile(path, readAccessDir)
method reload(n: WebViewNativeObj; ignoreCache: bool) = n.web.reload(ignoreCache)
method stopLoading(n: WebViewNativeObj) = n.web.stopLoading()
method goBack(n: WebViewNativeObj) = n.web.goBack()
method goForward(n: WebViewNativeObj) = n.web.goForward()
method canGoBack(n: WebViewNativeObj): bool = n.web.canGoBack()
method canGoForward(n: WebViewNativeObj): bool = n.web.canGoForward()
method url(n: WebViewNativeObj): string = n.web.url()
method isLoading(n: WebViewNativeObj): bool = n.web.isLoading()
method eval(n: WebViewNativeObj; js: string) = n.web.eval(js)
method setUserScripts(n: WebViewNativeObj; s: seq[platform.UserScript]) =
  n.web.setUserScripts(s)
method callAsyncFunction(n: WebViewNativeObj; body: string;
    cb: proc(res: string; err: ref CatchableError) {.closure.}) =
  n.web.callAsyncFunction(body, cb)
method setZoom(n: WebViewNativeObj; factor: float64) = n.web.setZoom(factor)
method zoom(n: WebViewNativeObj): float64 = n.web.zoom()
method setUserAgent(n: WebViewNativeObj; ua: string) = n.web.setUserAgent(ua)
method userAgent(n: WebViewNativeObj): string = n.web.userAgent()
method openDevTools(n: WebViewNativeObj) = n.web.openDevTools()
method closeDevTools(n: WebViewNativeObj) = n.web.closeDevTools()
method isDevToolsOpened(n: WebViewNativeObj): bool = n.web.isDevToolsOpened()
method droppedFiles(n: WebViewNativeObj): seq[string] = n.web.droppedFiles()
method print(n: WebViewNativeObj) = n.web.print()
method capturePage(n: WebViewNativeObj;
    cb: proc(png: seq[byte]; err: ref CatchableError) {.closure.}) =
  n.web.capturePage(cb)
method printToPDF(n: WebViewNativeObj; opts: platform.PDFOptions;
    cb: proc(pdf: seq[byte]; err: ref CatchableError) {.closure.}) =
  n.web.printToPDF(opts, cb)

## --- content (content.go) ---

## attachContent connects the window's Content to its surface. Main
## thread only.
## The rest of platform.Page and platform.Window forward to the
## window the web view is in, as the embedded platform.Window does
## in Go.
method handle(n: WebViewNativeObj) : uint = n.window.handle()
method title(n: WebViewNativeObj) : string = n.window.title()
method setRepresentedFile(n: WebViewNativeObj, path: string) = n.window.setRepresentedFile(path)
method setDocumentEdited(n: WebViewNativeObj, edited: bool) = n.window.setDocumentEdited(edited)
method setBounds(n: WebViewNativeObj, r: platform.Rect) = n.window.setBounds(r)
method bounds(n: WebViewNativeObj) : platform.Rect = n.window.bounds()
method setContentBounds(n: WebViewNativeObj, r: platform.Rect) = n.window.setContentBounds(r)
method contentBounds(n: WebViewNativeObj) : platform.Rect = n.window.contentBounds()
method setMinimumSize(n: WebViewNativeObj, s: platform.Size) = n.window.setMinimumSize(s)
method setMaximumSize(n: WebViewNativeObj, s: platform.Size) = n.window.setMaximumSize(s)
method setResizable(n: WebViewNativeObj, v: bool) = n.window.setResizable(v)
method isResizable(n: WebViewNativeObj) : bool = n.window.isResizable()
method setMovable(n: WebViewNativeObj, v: bool) = n.window.setMovable(v)
method isMovable(n: WebViewNativeObj) : bool = n.window.isMovable()
method setMinimizable(n: WebViewNativeObj, v: bool) = n.window.setMinimizable(v)
method isMinimizable(n: WebViewNativeObj) : bool = n.window.isMinimizable()
method setMaximizable(n: WebViewNativeObj, v: bool) = n.window.setMaximizable(v)
method isMaximizable(n: WebViewNativeObj) : bool = n.window.isMaximizable()
method setClosable(n: WebViewNativeObj, v: bool) = n.window.setClosable(v)
method isClosable(n: WebViewNativeObj) : bool = n.window.isClosable()
method setAlwaysOnTop(n: WebViewNativeObj, v: bool) = n.window.setAlwaysOnTop(v)
method isAlwaysOnTop(n: WebViewNativeObj) : bool = n.window.isAlwaysOnTop()
method show(n: WebViewNativeObj) = n.window.show()
method showInactive(n: WebViewNativeObj) = n.window.showInactive()
method hide(n: WebViewNativeObj) = n.window.hide()
method isVisible(n: WebViewNativeObj) : bool = n.window.isVisible()
method blur(n: WebViewNativeObj) = n.window.blur()
method isFocused(n: WebViewNativeObj) : bool = n.window.isFocused()
method minimize(n: WebViewNativeObj) = n.window.minimize()
method isMinimized(n: WebViewNativeObj) : bool = n.window.isMinimized()
method maximize(n: WebViewNativeObj) = n.window.maximize()
method unmaximize(n: WebViewNativeObj) = n.window.unmaximize()
method isMaximized(n: WebViewNativeObj) : bool = n.window.isMaximized()
method restore(n: WebViewNativeObj) = n.window.restore()
method setFullScreen(n: WebViewNativeObj, v: bool) = n.window.setFullScreen(v)
method isFullScreen(n: WebViewNativeObj) : bool = n.window.isFullScreen()
method center(n: WebViewNativeObj) = n.window.center()
method setOpacity(n: WebViewNativeObj, v: float64) = n.window.setOpacity(v)
method opacity(n: WebViewNativeObj) : float64 = n.window.opacity()
method setHasShadow(n: WebViewNativeObj, v: bool) = n.window.setHasShadow(v)
method hasShadow(n: WebViewNativeObj) : bool = n.window.hasShadow()
method setIgnoreMouseEvents(n: WebViewNativeObj, v: bool) = n.window.setIgnoreMouseEvents(v)
method setContentProtection(n: WebViewNativeObj, v: bool) = n.window.setContentProtection(v)
method setVibrancy(n: WebViewNativeObj, material: string) = n.window.setVibrancy(material)
method setProgressBar(n: WebViewNativeObj, state: string, value: float64) = n.window.setProgressBar(state, value)
method flashFrame(n: WebViewNativeObj, flash: bool) = n.window.flashFrame(flash)
method setSkipTaskbar(n: WebViewNativeObj, v: bool) = n.window.setSkipTaskbar(v)
method setVisibleOnAllWorkspaces(n: WebViewNativeObj, v: bool) = n.window.setVisibleOnAllWorkspaces(v)
method setIcon(n: WebViewNativeObj, png: seq[byte]) = n.window.setIcon(png)
method setMenu(n: WebViewNativeObj, m: platform.Menu) = n.window.setMenu(m)
method setAutoHideMenu(n: WebViewNativeObj, v: bool) = n.window.setAutoHideMenu(v)
method startDrag(n: WebViewNativeObj) = n.window.startDrag()
method titleBarDoubleClicked(n: WebViewNativeObj) = n.window.titleBarDoubleClicked()
method placeFlyout(n: WebViewNativeObj, f: platform.Flyout, size: platform.Size) = n.window.placeFlyout(f, size)

proc attachContent*(w: Window) =
  let s = w.native.surface()
  if s == nil:
    raise newException(ValueError, "mynim: the backend " &
      backend().name() &
      " created no surface for the window's Content")
  w.conn = surface.Conn(
    surface: s,
    window: RootRef(w),
    clipboard: backend().clipboard(),
    startDataDrag: proc(data: Data; local: RootRef; opts: DragOptions;
        x, y: float64) = discard w.startDataDrag(data, local, opts, x, y),
    cancelDataDrag: proc() = w.cancelDataDrag(),
    startDrag: proc() =
      if w.native != nil:
        w.native.startDrag(),
    titleBarDoubleClicked: proc() =
      if w.native != nil:
        w.native.titleBarDoubleClicked(),
    escape: proc() = w.escape(),
    isDark: proc(): bool = backend().theme().isDark(),
    preferences: proc(): platform.Preferences =
      backend().theme().preferences(),
    locale: proc(): string = app.locale(),
    rightToLeft: proc(): bool = appRightToLeft(),
    region: proc(): i18n.Region = app.region(),
    uiFont: proc(): string = backend().theme().uiFont(),
    fontRendering: proc(): platform.FontRendering =
      backend().theme().fontRendering(),
    titleBar: proc(): platform.TitleBar =
      if not w.hiddenTitleBar or w.native == nil:
        platform.TitleBar()
      else:
        w.native.titleBar(),
    openURL: proc(url: string; done: proc(err: ref CatchableError)) =
      ## The system may take a while, as Windows' shell does: not in
      ## the frame.
      goAsync(proc() =
        let err = shell.openExternal(url)
        if done != nil:
          discard postMain(proc() =
            if w.native != nil:
              done(err))),
    devTools: w.devTools,
    invalidate: proc() = w.invalidate(),
    ready: proc() = w.readyToShow(),
    post: proc(fn: proc() {.closure.}) =
      discard postMain(proc() =
        if w.native != nil:
          fn()),
    placeWebViews: proc(views: seq[platform.WebViewPlacement]) =
      w.placeWebViews(views),
    popupMenu: proc(m: platform.Menu; x, y: float64;
        chosen: proc(id: int)) =
      let pos = (ref platform.Point)(x: int(round(x)), y: int(round(y)))
      let menu = newMenu(contentMenu(m, chosen))
      ## The menu waits for the user in a loop of its own: not in
      ## the event that asked for it, which the surface is handling.
      discard postMain(proc() =
        if w.native != nil:
          menu.popupMenuAt(w, pos, m.rightToLeft)))
  w.content.attachContent(w.conn)

## contentMenu returns the items of a context menu of the Content,
## whose click passes the id of the item to chosen.
proc contentMenu(m: platform.Menu; chosen: proc(id: int)): seq[MenuItem] =
  if m == nil:
    return @[]
  for p in m.items:
    let it = MenuItem(label: p.label, accelerator: p.accelerator,
      disabled: not p.enabled, hidden: not p.visible, checked: p.checked)
    case p.`type`
    of platform.menuItemSeparator:
      it.`type` = menuItemSeparator
    of platform.menuItemCheckbox:
      it.`type` = menuItemCheckbox
    of platform.menuItemRadio:
      it.`type` = menuItemRadio
    of platform.menuItemSubmenu:
      it.`type` = menuItemSubmenu
      it.submenu = contentMenu(p.submenu, chosen)
    else:
      discard
    let id = p.id
    it.click = proc(i: MenuItem; w: Window) {.closure.} = chosen(id)
    result.add it

## invalidate redraws the window's Content, as after a change of the
## state its user interface shows. It is safe from any thread; calls
## made before the next frame make one frame. It does nothing for a
## web page.
proc invalidate*(w: Window) =
  if w.content == nil or w.invalidating.exchange(true):
    return
  discard postMain(proc() =
    w.invalidating.store(false)
    w.contentChanged())

## update runs fn on the main thread, where the window's Content
## builds its user interface, then redraws the Content. Threads
## change the state the interface shows through it:
##
##   spawnThreaded(proc() =
##     let items = load()
##     win.update(proc() = appState.items = items))
##
## It returns without waiting for fn.
proc update*(w: Window; fn: proc() {.closure.}) =
  discard postMain(proc() =
    fn()
    w.contentChanged())

## contentChanged asks the Content for a frame built anew, on the
## main thread, after the app changed its state.
proc contentChanged(w: Window) =
  if w.conn == nil or w.native == nil:
    return
  if w.conn.changed != nil:
    w.conn.changed()
  else:
    w.conn.surface.requestFrame()

## captureContent renders the Content into a PNG image.
proc captureContent(w: Window): tuple[png: seq[byte],
    err: ref CatchableError] =
  var
    width, height: int
    pix: seq[byte]
  var ok = false
  onMain(proc() =
    if w.conn != nil and w.conn.capture != nil:
      (width, height, pix) = w.conn.capture()
      ok = true)
  if not ok:
    return (@[], errDestroyed)
  if width == 0 or height == 0:
    return (@[], newException(ValueError,
      "mynim: the window's content has no size"))
  let img = image.RgbaImage(pix: pix, stride: 4 * width,
    rect: image.rect(0, 0, width, height), off: 0)
  try:
    (pngEncode(img), nil)
  except CatchableError as e:
    (@[], e)

## handleSurfaceEvent passes the surface's events to the Content.
## Files the Content does not take go to onFileDrop, when it has
## listeners.
proc handleSurfaceEvent(w: Window; ev: platform.SurfaceEvent): bool =
  resolveDataDrag(ev.drag)
  let c = w.conn
  if c == nil or c.event == nil:
    return false
  if c.event(ev):
    return true
  let d = ev.drag
  if d != nil:
    case ev.kind
    of platform.dataDragLeave:
      discard w.handleSurfaceEvent(
        platform.SurfaceEvent(kind: platform.fileDragLeave))
    of platform.dataDragOver, platform.dataDrop:
      if d.hasFiles or transfer.FileList in d.offer.formats:
        d.operation = transfer.negotiate(d.offer.operations,
          transfer.Copy, d.offer.suggested)
        if d.operation == transfer.None:
          return false
        var fileEvent = platform.SurfaceEvent(
          kind: platform.fileDragOver, x: ev.x, y: ev.y)
        if ev.kind == platform.dataDrop:
          fileEvent.kind = platform.fileDrop
          var paths = ev.files
          if paths.len == 0:
            let (p, _) = d.data.files()
            paths = p
          if paths.len == 0:
            d.operation = transfer.None
            return false
          fileEvent.files = paths
        d.formats = @[transfer.FileList]
        if w.handleSurfaceEvent(fileEvent):
          return true
    else:
      discard
    d.operation = transfer.None
  case ev.kind
  of platform.fileDragOver:
    w.onFileDrop.len() > 0
  of platform.fileDrop:
    if w.onFileDrop.len() == 0:
      return false
    var e = FileDropEvent(paths: ev.files, x: int(ev.x), y: int(ev.y))
    fire1(w.onFileDrop, e)
    true
  else:
    false

## contentCommand performs an edit command (an Edit menu role:
## "copy", "paste", ...) in the window's native UI. Main thread only.
proc contentCommand(w: Window; cmd: string) =
  discard w.handleSurfaceEvent(platform.SurfaceEvent(
    kind: platform.surfaceCommand, text: cmd))

## detachContent tells the Content its window closed. Main thread
## only.
proc detachContent(w: Window) =
  let c = w.conn
  if c != nil:
    w.conn = nil
    if c.detach != nil:
      c.detach()

## contentThemeChanged tells the Contents of the windows that the
## system appearance changed. Main thread only.
proc contentThemeChanged() =
  for w in allWindows():
    let c = w.conn
    if c != nil and c.themeChanged != nil:
      c.themeChanged()

## contentLocaleChanged tells the windows of native UI that the
## language the app shows or the regional formats changed, which they
## draw anew. Main thread only.
proc contentLocaleChanged() =
  for w in allWindows():
    let c = w.conn
    if c != nil and c.localeChanged != nil:
      c.localeChanged()

## --- drag (drag.go) ---

## errDragBusy is what startDataDrag reports while another drag runs.
var errDragBusy = newException(ValueError,
  "mynim: a native data drag is already active")

## dataSource is the core's one live native drag. Main thread only.
## Its random token can resolve a value only inside this process and
## only for this session; native data never contains a pointer.
type DataSource = ref object
  w: Window
  token: string
  data: Data
  local: RootRef
  done: proc(r: transfer.Result) {.closure.}
  finished: bool
  operations: transfer.Operation

var activeDataDrag: DataSource

proc startDataDrag*(w: Window; data: Data; options: DragOptions):
    ref CatchableError =
  ## Starts a native drag from this window's current pointer gesture.
  ## The window must show native UI. It returns after scheduling the
  ## drag; options.done receives completion on the main thread. Use
  ## an element's DragData in package ui to start after the movement
  ## threshold. It is safe from any thread. An immediate validation
  ## error starts no session and does not call done.
  let (pix, width, height) = dragImage(options.preview)
  onMainValue(proc(): ref CatchableError =
    w.startDataDragPrepared(data, nil, options, -1, -1, pix, width, height))

proc cancelDataDrag*(w: Window) =
  ## Cancels a native data drag sourced by this window. It is safe
  ## from any thread and does nothing when the window has no drag.
  onMain(proc() = w.cancelDataDragNow())

proc startDataDrag(w: Window; data: Data; local: RootRef;
    options: DragOptions; x, y: float64): ref CatchableError =
  let (pix, width, height) = dragImage(options.preview)
  w.startDataDragPrepared(data, local, options, x, y, pix, width, height)

proc finish(s: DataSource; result0: transfer.Result)

proc startDataDragPrepared(w: Window; data: Data; local: RootRef;
    options: DragOptions; x, y: float64; pix: seq[byte];
    width, height: int): ref CatchableError =
  if w.native == nil:
    return errDestroyed
  if w.conn == nil:
    return newException(ValueError,
      "mynim: a data drag requires native UI")
  if activeDataDrag != nil:
    return errDragBusy
  let formats = data.formats()
  if formats.len == 0 or platform.DragSessionFormat in formats:
    return newException(ValueError,
      "mynim: a data drag needs non-reserved representations")
  let operations = options.operations.allowed()
  if operations == transfer.None:
    return newException(ValueError, "mynim: no supported drag operation")
  let src = DataSource(w: w, token: randomText(),
    data: data.snapshot(), local: local, done: options.done,
    operations: operations)
  activeDataDrag = src
  let req = platform.DragRequest(data: src.data, session: src.token,
    operations: operations,
    x: x, y: y, preview: pix, width: width, height: height,
    hotX: options.hotspot.x, hotY: options.hotspot.y,
    done: proc(r: transfer.Result) = src.finish(r))
  ## OLE tracks in a nested event loop. Enter it after the input
  ## callback returns, so UI input and frames are never suspended
  ## halfway through.
  discard postMain(proc() =
    if src.finished:
      return
    if w.native == nil:
      src.finish(transfer.Result(canceled: true))
      return
    w.conn.surface.startDataDrag(req))

## dragImage renders the drag preview image into BGRA pixels.
proc dragImage(img: image.Image): tuple[pix: seq[byte], w, h: int] =
  if img == nil:
    return (@[], 0, 0)
  let b = img.bounds()
  let w = b.dx()
  let h = b.dy()
  if w <= 0 or h <= 0 or w > 4096 or h > 4096:
    raise newException(ValueError,
      "mynim: drag preview size must be 1..4096 pixels")
  let rgba = image.RgbaImage(pix: newSeq[uint8](4 * w * h),
    stride: 4 * w, rect: image.rect(0, 0, w, h), off: 0)
  image.drawSrc(rgba, b, img, b.min)
  for i in countup(0, rgba.pix.len - 1, 4):
    swap rgba.pix[i], rgba.pix[i + 2]
  (rgba.pix, w, h)

proc finish(s: DataSource; result0: transfer.Result) =
  if s.finished:
    return
  s.finished = true
  var result = result0
  let op = result.operation
  if op != transfer.None and
      ((op != transfer.Copy and op != transfer.Move) or
       (op and s.operations) == 0):
    result = transfer.Result(err: newException(ValueError,
      "mynim: destination returned a disallowed drag operation"))
  if result.err != nil or result.canceled:
    result.operation = transfer.None
  if result.operation == transfer.None and result.err == nil:
    result.canceled = true
  if activeDataDrag == s:
    activeDataDrag = nil
  s.data = Data()
  s.local = nil
  let done = s.done
  if done != nil:
    s.done = nil
    done(result)

proc cancelDataDragNow(w: Window) =
  let s = activeDataDrag
  if s != nil and s.w == w:
    ## Invalidate the registry before callbacks or a native cancel
    ## can reenter. The backend may report completion later; finish
    ## is once.
    activeDataDrag = nil
    if w.conn != nil:
      w.conn.surface.cancelDataDrag()
    s.finish(transfer.Result(canceled: true))

## resolveDataDrag fills a drag event with the data of a live drag
## of this app, which no system mime types can carry.
proc resolveDataDrag(d: platform.DataDragEvent) =
  if d == nil:
    return
  d.local = nil
  if d.resolved:
    d.data = Data()
    d.resolved = false
  let s = activeDataDrag
  if s != nil and d.session != "" and s.token == d.session:
    d.local = s.local
    d.data = s.data
    d.resolved = true
    d.offer.formats = s.data.formats()

## --- bridge (bridge.go): eval, messages, preferences ---

## bridgeScript returns the script that installs the bridge in the
## window's pages.
proc bridgeScript(w: Window): string =
  bridge.script(bridge.Config(
    platform: jsPlatform(),
    windowID: w.top().id, ## the window a web view is in
    version: Version,
    secret: w.secret,
    locale: app.locale(),
    dir: appDir()))

## pageScripts are the scripts a page of the window gets at document
## start: the bridge, the preferences of the page and the preload
## script.
proc pageScripts(w: Window): seq[platform.UserScript] =
  result = @[platform.UserScript(source: w.bridgeScript()),
    platform.UserScript(source: preferencesScript())]
  if w.preload != "":
    result.add platform.UserScript(source: w.preload)

## localeEvent returns the message of LocaleEvent for locale.
proc makeLocaleEvent(locale: string): tuple[msg: Message,
    err: ref CatchableError] =
  encodeEvent(bridge.localeEvent,
    %bridge.Locale(locale: locale, dir: appDir()))

## sendLocale tells the page of a window the language the app shows,
## which the bridge configuration told it at document start: a page
## that started loading as the language changed may have had the one
## before. The bridge tells its listeners only of a language it did
## not have. Main thread only.
proc sendLocale(w: Window) =
  if w.content != nil or w.native == nil:
    return
  let (msg, err) = makeLocaleEvent(app.locale())
  if err == nil:
    w.enqueue(msg, true)

## pagesLocaleChanged tells the pages of every window the language the
## app shows, and makes it the one of the pages they load later. Main
## thread only.
proc pagesLocaleChanged(locale: string) =
  let (msg, err) = makeLocaleEvent(locale)
  if err != nil:
    return
  for w in pageWindows():
    if w.content != nil or w.native == nil:
      continue
    w.native.setUserScripts(w.pageScripts())
    w.enqueue(msg, true)

## pagePreferences is the page's view of the desktop's settings: the
## accent as a CSS color, and no accent at all where the desktop has
## none.
proc pagePreferences(p: ThemePreferences): bridge.Preferences =
  var accent = ""
  if p.accent.a != 0:
    accent = $p.accent
  bridge.Preferences(accent: accent, reduceMotion: p.reduceMotion,
    highContrast: p.highContrast, textScale: p.textScale)

## preferencesScript installs the desktop preferences after the
## bridge.
proc preferencesScript(): string =
  bridge.preferencesScript(pagePreferences(theme.preferences()))

## sendPreferences keeps existing pages up to date. Main thread only.
proc sendPreferences(w: Window; prefs: ThemePreferences) =
  if w.content != nil or w.native == nil:
    return
  let (msg, err) = encodeEvent(bridge.preferencesEvent,
    %pagePreferences(prefs))
  if err == nil:
    w.enqueue(msg, true)

proc sendPreferences() =
  let prefs = theme.preferences()
  for w in pageWindows():
    w.sendPreferences(prefs)

const
  ## The expression form: compile errors mean code is not an
  ## expression.
  evalExpr = "try{return JSON.stringify({ok:true,v:await(\n$#\n)})}catch(e){return JSON.stringify({ok:false,e:String(e&&e.message||e)})}"
  ## The statement form runs code as a function body.
  evalBody = "try{return JSON.stringify({ok:true,v:await(async()=>{\n$#\n})()})}catch(e){return JSON.stringify({ok:false,e:String(e&&e.message||e)})}"

## evalRaw returns the JSON result of code.
proc evalRaw(w: Window; ctx: CancelCtx; code: string):
    tuple[v: JsonNode, err: ref CatchableError] =
  if w.content != nil:
    return (nil, errNoPage)
  type R = tuple[raw: string, err: ref CatchableError]
  ## Both the cancellation and the page may answer; the first one
  ## counts and the other must not block.
  var ch: system.Channel[R]
  ch.open(2)
  let pch = addr ch
  let answer = proc(raw: string; err: ref CatchableError) {.closure.} =
    var v: R
    v.raw = raw
    v.err = err
    deliver(pch[], v)
  let stop = afterDone(ctx, proc() {.closure.} = answer("", newCanceled()))
  defer: discard stop()

  var ran = false
  w.withNative(proc(n: platform.Window) =
    ran = true
    let expr = code.strip(leading = false, chars = {' ', '\t', '\r', '\n', ';'})
    n.callAsyncFunction(evalExpr.replace("$#", expr), proc(res: string;
        err: ref CatchableError) {.closure.} =
      if err == nil:
        answer(res, nil)
        return
      if not err.msg.startsWith("SyntaxError"):
        ## It may have run (and then the page navigated or
        ## crashed): running it again could run it twice.
        answer("", err)
        return
      ## Not an expression: run it as a function body instead.
      ## The first attempt failed to compile, so nothing ran
      ## twice.
      onMain(proc() =
        if w.native == nil:
          answer("", errDestroyed)
          return
        w.native.callAsyncFunction(evalBody.replace("$#", code),
          proc(res: string; err: ref CatchableError) {.closure.} =
            answer(res, err)))))
  if not ran:
    return (nil, errDestroyed)
  let r = await(ch)
  if r.err != nil:
    return (nil, r.err)
  var outJ: JsonNode
  try:
    outJ = parseJson(r.raw)
  except CatchableError as e:
    return (nil, newException(ValueError,
      "mynim: unexpected eval result " & r.raw.escape() & ": " & e.msg))
  if not outJ{"ok"}.getBool():
    return (nil, EvalError(message: outJ{"e"}.getStr()))
  (outJ{"v"}, nil)

## sendTitleBar tells the page of a window with a hidden title bar
## the room its controls take. The backend's script tells the first
## page at document start; this keeps the current page, and later
## ones, up to date. Main thread only.
proc sendTitleBar(w: Window) =
  if w.content != nil or not w.hiddenTitleBar or w.native == nil:
    return
  let (msg, err) = encodeEvent(bridge.titleBarEvent,
    %bridge.newTitleBar(w.native.titleBar(), w.native.zoom()))
  if err == nil:
    w.enqueue(msg, true)

## handleMessage routes a message posted by the page bridge. It runs
## on the main thread.
proc handleMessage(w: Window; msg0: string) =
  var msg = msg0
  if not msg.startsWith(w.secret):
    return ## not from the bridge
  msg = msg[w.secret.len..^1]
  ## Calls are decoded and executed off the main thread. The page
  ## context is captured here so a navigation cannot slip in
  ## between.
  if msg.len > 12 and msg[0..<12] == """{"t":"call",""":
    let ctx = w.pageContext()
    let trusted = w.trusted
    goAsync(proc() = handleCall(w, ctx, msg, trusted))
    return
  var m: JsonNode
  try:
    m = parseJson(msg)
  except CatchableError:
    return
  case m{"t"}.getStr("")
  of "dom-ready":
    acquire(w.outMu)
    w.domReady = true
    w.outbox.add w.held
    w.held.setLen(0)
    release(w.outMu)
    ## The script at document start may tell a later page the room
    ## of the controls before a change.
    w.sendTitleBar()
    w.sendPreferences(theme.preferences())
    w.sendLocale()
    w.flush()
    fire(w.onDOMReady)
    w.readyToShow()
  of "drag":
    if w.native != nil:
      w.native.startDrag()
  of "dblclick":
    if w.native != nil:
      w.native.titleBarDoubleClicked()
  of "escape":
    w.escape()
  of "drop":
    if w.native != nil:
      w.filesDropped(w.native.droppedFiles(), int(m{"x"}.getFloat()),
        int(m{"y"}.getFloat()))
  of "chan-ack":
    let c = w.channel(m{"c"}.getBiggestInt(), m{"k"}.getStr())
    if c != nil:
      channelAck(c, m{"n"}.getBiggestInt())
  of "chan-close":
    w.pageClosedChannel(m{"c"}.getBiggestInt(), m{"k"}.getStr())
  else:
    discard

## findScript returns the script with which findInPage asks the
## bridge.
proc findScript(text: string; opts: FindOptions): string =
  let t = $(%text)
  let o = $(%*{"matchCase": opts.matchCase, "backward": opts.backward,
    "next": opts.findNext})
  "window.__mynim.find(" & t & ", " & o & ")"

## findInPage highlights the occurrences of text in the page, scrolls
## to the active one and reports how many there are, like the find
## bar of a browser: call it as the user types, and with findNext to
## go to the next match.
##
##   let res = win.page().findInPage("mynim", FindOptions(findNext: true))
##
## Text split by markup, such as "my<b>go</b>", is not found.
proc findInPage*(p: Page; text: string; opts: FindOptions):
    tuple[r: FindResult, err: ref CatchableError] =
  let (res, err) = evalAs[FindResult](p, findScript(text, opts))
  if err != nil:
    return (FindResult(), newException(ValueError,
      "mynim: finding in the page: " & err.msg))
  (res, nil)

## stopFindInPage removes the highlights of findInPage.
proc stopFindInPage*(p: Page) =
  p.w.page(proc(n: platform.Window) =
    n.eval("window.__mynim && window.__mynim.stopFind()"))

## --- locale (locale.go) ---

proc preferredLanguages*(a: Application): seq[string] =
  ## The languages the user reads, most preferred first, as
  ## normalized BCP 47 tags, e.g. ["zh-Hans-CN", "en-GB"]: on macOS
  ## the languages of System Settings, on Windows the display
  ## languages, on Linux LANGUAGE, then the locale of messages
  ## (LC_ALL, LC_MESSAGES, LANG), in a browser navigator.languages.
  ## The language the app chose (setLocale) never changes them.
  a.shownLocale().preferred

proc setLanguages*(a: Application; tags: varargs[string]) =
  ## Sets the languages the app is written in, its own language
  ## first, which the app falls back to: those the app's texts are
  ## translated to, e.g. "en", "de", "zh-Hans". locale picks among
  ## them. By default they are the languages of the catalogs of the
  ## app, and English alone without any. It raises on a tag that
  ## names no language.
  for t in tags:
    if i18n.normalize(t) == "":
      raise newException(ValueError, "mynim: setLanguages: " &
        t.strip() & " is not a language tag")
  acquire(locales.mu)
  locales.languages = @tags
  if tags.len == 0:
    locales.languages.setLen(0)
  release(locales.mu)
  discard postMain(proc() = a.updateLocale(true))

proc languages*(a: Application): seq[string] =
  ## The languages the app is written in, its own first
  ## (setLanguages).
  acquire(locales.mu)
  result = appLanguages(locales.languages)
  release(locales.mu)

## appLanguages returns set, else the languages of the catalogs,
## else English.
proc appLanguages(set: seq[string]): seq[string] =
  if set.len > 0:
    return set
  let langs = i18n.languages()
  if langs.len > 0:
    return langs
  @["en"]

proc locale*(a: Application): string =
  ## The language the app shows, as a tag of the languages it is
  ## written in (setLanguages), e.g. "zh-Hans": the one the user
  ## reads best of them, or the one setLocale chose, else the app's
  ## own language. The app's own texts, MyNim's controls and menus,
  ## the text engine and the pages (mynim.locale) all show it.
  a.shownLocale().locale

proc setLocale*(a: Application; tag: string) =
  ## Makes the app show the language of tag, a BCP 47 tag such as
  ## "de" or "zh-Hant-TW", of those it is written in, or "" to
  ## follow the user's languages again, which is the default. The
  ## app shows it at once: windows of native UI draw anew, menus say
  ## their items in it, pages hear the mynim:locale event and those
  ## loaded later start with it, and onLocaleChanged listeners are
  ## called. It is kept for the next launches: on macOS as the app's
  ## language in its defaults, which System Settings shows and
  ## AppKit and WebKit say their own texts in from the next launch,
  ## in browsers in localStorage, elsewhere in a file in
  ## pathUserData. The MYNIM_LOCALE environment variable (`mynim dev
  ## -lang`) chooses the language for one run and keeps nothing.
  ##
  ## The pseudo locales en-XA and ar-XB are always shown, to test
  ## what translations would do. setLocale raises on a tag that
  ## names no language. It is safe from any thread; calls made
  ## before the main thread gets to them show the last tag only.
  ## While MYNIM_LOCALE is set, calls made before the app is ready
  ## change nothing.
  var normalized = ""
  if tag.strip() != "":
    normalized = i18n.normalize(tag)
    if normalized == "":
      raise newException(ValueError, "mynim: setLocale: " &
        tag.strip() & " is not a language tag")
  acquire(locales.mu)
  inc locales.generation
  let generation = locales.generation
  release(locales.mu)
  let apply = proc() {.closure.} =
    loadLocale()
    acquire(locales.mu)
    if locales.generation != generation or
        (locales.fromEnv and not a.isReady()):
      ## A later call shows its own; MYNIM_LOCALE wins over the
      ## language the app starts with.
      release(locales.mu)
      return
    locales.override = normalized
    locales.chosen = true
    let save = not locales.fromEnv
    release(locales.mu)
    if save:
      saveLocale(normalized)
    a.updateLocale(true)
  if isMainThread():
    apply()
  else:
    discard postMain(apply)

proc onLocaleChanged*(a: Application; fn: proc(locale: string) {.closure.}):
    proc() {.closure.} =
  ## Calls fn on the main thread with the language the app shows
  ## when it changes: setLocale chose another, the languages the app
  ## is written in changed, or the user's languages changed while
  ## the app follows them. It returns a function that stops the
  ## listener.
  locales.onLocaleChanged.add(fn, false)

proc region*(a: Application): i18n.Region =
  ## The user's regional formats, as the system's settings have
  ## them, with the changes the user made: the locale of the
  ## formats, which may be another language's than the app's (an
  ## English app reading German dates for a reader in Germany), the
  ## first day of the week and the hour cycle. macOS, Windows and
  ## browsers report changes while the app runs (onRegionChanged);
  ## Linux reads the environment (LC_TIME, LC_ALL, LANG) once.
  a.shownLocale().region

proc onRegionChanged*(a: Application; fn: proc(r: i18n.Region) {.closure.}):
    proc() {.closure.} =
  ## Calls fn on the main thread with the user's regional formats
  ## when they change. It returns a function that stops the
  ## listener.
  locales.onRegionChanged.add(fn, false)

## currentLocale returns the language the app shows, from any
## thread, for the accessors of catalogs: as app.locale does once
## the app works it out on the main thread, or the language
## MYNIM_LOCALE chooses, else the app's own, before, without waiting
## for the main thread.
proc currentLocale(): string =
  let s = locales.shown.load()
  if s != nil:
    return s.locale
  app.mu.acquire()
  let running = app.running
  app.mu.release()
  if running or isMainThread():
    return app.locale()
  acquire(locales.mu)
  let langs = appLanguages(locales.languages)
  release(locales.mu)
  resolveLocale(i18n.normalize(getEnv("MYNIM_LOCALE",
    getEnv("MYGO_LOCALE"))), @[], langs)

## shownLocale returns what the app shows, working it out on the
## main thread the first time.
proc shownLocale(a: Application): ShownLocale =
  let s = locales.shown.load()
  if s != nil:
    return s
  onMainValue(proc(): ShownLocale =
    let s = locales.shown.load()
    if s != nil:
      return s
    a.updateLocale(false)
    locales.shown.load())

## startLocale tells the backend the app's languages, once it runs.
## Main thread only.
proc startLocale(a: Application) =
  acquire(locales.mu)
  if not locales.chosen:
    ## Read before run, the saved language may have been looked for
    ## under the name and paths the app had then: read it again
    ## where they put it now.
    locales.loaded = false
  release(locales.mu)
  a.updateLocale(false)
  backend().app().setLanguages(webLanguages(locales.shown.load()),
    appRightToLeft())
  ## Menus made before the app knew its language took their roles'
  ## labels in its own language.
  relabelMenus()
  acquire(locales.mu)
  let langs = appLanguages(locales.languages)
  release(locales.mu)
  for missing in missingTranslations(langs, l10n.languages,
      l10n.catalogLanguages()):
    stderr.writeLine("mynim: the app is written in " & missing[0] &
      ", but MyNim's own strings are in English there: import " &
      "mynim/locales/" & missing[1] &
      ", as the code mynim generate writes for an app's catalogs " &
      "does, or translate them with keys \"mynim.<key>\" in the " &
      "app's catalog")

## missingTranslations returns the languages of langs that MyNim's
## own strings are translated to, each in a package, but not linked,
## with the translation that suits each, as ("zh-TW", "zh-Hant").
proc missingTranslations(langs, translations,
    linked: seq[string]): seq[tuple[a, b: string]] =
  for lang in langs:
    let m = i18n.`match`(@[lang], translations)
    if m != "" and m notin linked:
      result.add (lang, m)

## localeChangedFromSystem tells the app that the user's languages or
## formats may have changed.
proc localeChangedFromSystem(a: Application) =
  discard postMain(proc() = a.updateLocale(true))

## updateLocale works out what the app shows and, when tell is set
## and it changed, tells the windows, the menus, the backend and the
## listeners. Main thread only.
proc updateLocale(a: Application; tell: bool) =
  loadLocale()
  let ctl = backend().app()
  let next = ShownLocale(
    preferred: normalizeTags(ctl.preferredLanguages()))
  acquire(locales.mu)
  next.locale = resolveLocale(locales.override, next.preferred,
    appLanguages(locales.languages))
  release(locales.mu)
  next.region = regionOf(ctl.region(), next.preferred)
  let before = locales.shown.exchange(next)
  if before == nil or before.locale != next.locale:
    platform.setTexts(platformTexts(next.locale))
  if before == nil:
    return ## nothing heard of a language before
  let localeChanged = before.locale != next.locale
  if (localeChanged or before.preferred != next.preferred) and
      a.initialized:
    ctl.setLanguages(webLanguages(next), appRightToLeft())
  let regionChanged = before.region != next.region
  if not tell or (not localeChanged and not regionChanged):
    return
  contentLocaleChanged()
  if localeChanged:
    pagesLocaleChanged(next.locale)
    relabelMenus()
    fire1(locales.onLocaleChanged, next.locale)
  if regionChanged:
    fire1(locales.onRegionChanged, next.region)

## appRightToLeft reports whether the app is laid out right to left:
## as the language it shows is written, unless MYNIM_DIRECTION
## ("rtl" or "ltr") lays it out otherwise, to try a layout without
## translating the app. Native UI, the pages (mynim.dir) and the
## backend's widgets agree.
proc appRightToLeft(): bool =
  case getEnv("MYNIM_DIRECTION", getEnv("MYGO_DIRECTION"))
  of "rtl": true
  of "ltr": false
  else:
    i18n.direction(app.locale()) == "rtl"

## appDir returns the direction of appRightToLeft as pages write it.
proc appDir(): string =
  if appRightToLeft(): "rtl" else: "ltr"

## resolveLocale returns the language of supported to show a reader
## of preferred, or of override and then preferred when the app
## chose one: the pseudo locales as they are, the best match, else
## the app's own.
proc resolveLocale(override: string; preferred,
    supported: seq[string]): string =
  var want = preferred
  if override != "":
    if i18n.isPseudo(override):
      return override
    want = @[override] & preferred
  let m = i18n.`match`(want, supported)
  if m != "":
    return m
  supported[0]

## webLanguages returns the languages for what the backend shows:
## the app's, then the user's others.
proc webLanguages(s: ShownLocale): seq[string] =
  result = @[s.locale]
  for p in s.preferred:
    if not result.anyIt(it.equalsIgnoreCase(p)):
      result.add p

## normalizeTags normalizes tags, leaving out those that name no
## language and those named before.
proc normalizeTags(tags: seq[string]): seq[string] =
  for t in tags:
    let n = i18n.normalize(t)
    if n != "" and n notin result:
      result.add n

## loadLocale reads the language the app chose in an earlier run, or
## MYNIM_LOCALE, which wins and is never saved, once. Main thread
## only.
proc loadLocale() =
  acquire(locales.mu)
  if locales.loaded:
    release(locales.mu)
    return
  locales.loaded = true
  release(locales.mu)
  var tag = getEnv("MYNIM_LOCALE", getEnv("MYGO_LOCALE"))
  var fromEnv = true
  if tag.strip() == "":
    tag = savedLocale()
    fromEnv = false
  tag = i18n.normalize(tag)
  acquire(locales.mu)
  locales.override = tag
  locales.fromEnv = fromEnv and tag != ""
  release(locales.mu)

## savedLocale returns the language the app saved, where the system
## keeps it or in the file. Main thread only.
proc savedLocale(): string =
  let (tag, kept) = backend().app().savedLocale()
  if kept:
    return tag
  readLocaleFile()

## saveLocale keeps the language the app chose, "" for none. Main
## thread only.
proc saveLocale(tag: string) =
  if not backend().app().saveLocale(tag):
    writeLocaleFile(tag)

## localeFile is the file in pathUserData that keeps the language
## the app chose (setLocale) where the system keeps none, as on
## Windows and Linux.
const localeFile = "locale"

proc localeFilePath(): string =
  ## The path of the file, without making its directory, which only
  ## saving one does.
  app.mu.acquire()
  var dir = app.paths.getOrDefault(pathUserData)
  app.mu.release()
  if dir == "":
    let (d, _) = defaultPath(pathUserData)
    dir = d
    if dir == "":
      return ""
  return dir / localeFile

proc readLocaleFile(): string =
  let path = localeFilePath()
  if path == "":
    return ""
  try:
    readFile(path).strip()
  except CatchableError:
    ""

## writeLocaleFile writes tag, or removes the file for "". A failure
## keeps what was saved: the app shows the language anyway.
proc writeLocaleFile(tag: string) =
  let path = localeFilePath()
  if path == "":
    return
  if tag == "":
    try:
      removeFile(path)
    except CatchableError:
      discard
    return
  try:
    createDir(path.parentDir())
    writeFile(path, tag)
  except CatchableError:
    discard

## regionOf returns the formats of the system, with what it does
## not say filled in from the locale of the formats or, without one,
## the language the user reads.
proc regionOf(r: platform.Region; preferred: seq[string]): i18n.Region =
  result = i18n.Region(locale: regionLocale(r.locale),
    firstWeekday: dMon, hourCycle: r.hourCycle)
  if result.locale == "" and preferred.len > 0:
    result.locale = preferred[0]
  ## What the system does not say comes from CLDR's week and time
  ## data for the locale's region (or its language's likely one).
  if r.firstWeekday >= 0 and r.firstWeekday <= 6:
    result.firstWeekday = WeekDay(r.firstWeekday)
  elif result.locale != "":
    result.firstWeekday = i18n.firstWeekday(result.locale)
  if result.hourCycle != 12 and result.hourCycle != 24:
    result.hourCycle = 24
    if result.locale != "":
      result.hourCycle = i18n.hourCycle(result.locale)

## regionLocale normalizes the locale of regional formats, whose
## region the "rg" key of macOS's locales changes: en_US@rg=gbzzzz
## has the formats of en-GB.
proc regionLocale(locale: string): string =
  var locale = locale
  let i = locale.find('@')
  if i >= 0:
    ## Keywords, as "@calendar=japanese;rg=gbzzzz".
    var rg = ""
    for kw in locale[i + 1..^1].split(';'):
      let eq = kw.find('=')
      if eq >= 0 and kw[0..<eq].equalsIgnoreCase("rg"):
        rg = kw[eq + 1..^1]
    let base = i18n.normalize(locale[0..<i])
    if rg.len >= 2 and base != "":
      var lang = base
      let r = regionCode(base)
      if r != "":
        lang = base[0..<base.len - r.len - 1]
      let n = i18n.normalize(lang & "-" & rg[0..1].toUpperAscii())
      if n != "":
        return n
    locale = locale[0..<i]
  i18n.normalize(locale)

## regionCode returns the region of a normalized tag, as "GB" of
## "en-GB", or "" without one.
proc regionCode(tag: string): string =
  let parts = tag.split('-')
  for p in parts[1..^1]:
    if (p.len == 2 and p[0] in {'A'..'Z'}) or
        (p.len == 3 and p[0] in {'0'..'9'}):
      return p
  ""
