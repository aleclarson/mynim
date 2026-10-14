## Port of internal/fake: an in-memory platform.Backend for testing the
## public API without a GUI. Its event loop runs on the thread that
## calls run, which is treated as the main thread.

import std/[locks, tables, times, os]
import platform
import ../transfer
import ../image

type
  FakeBackend* = ref object of platform.Backend
    h*: platform.AppHandler
    mainID*: uint64
    signal*: Channel[bool]
    wakeChan*: Channel[bool]
    quitChan*: Channel[bool]
    quitFlag*: bool
    mu*: Lock
    windows*: seq[FakeWindow]
    appMenu*: platform.Menu
    popups*: seq[Popup]
    updates*: seq[platform.MenuItem]
    hotkeys*: Table[int, string]
    clipboardData*: Data
    clipboardRelease*: proc()
    ## clipboardError injects a failed write while preserving existing
    ## ownership.
    clipboardError*: ref CatchableError
    ## clipboardDuringFlush simulates a toolkit pumping a nested event
    ## loop after releasing providers but before its storage operation
    ## returns.
    clipboardDuringFlush*: proc()
    themeSource*: string
    prefs*: platform.Preferences
    prefsReads*: int
    languages*: seq[string]
    region*: ref platform.Region
    ## keepsLocale makes the backend keep the app's language, as macOS
    ## does, in savedLocale; without it the core keeps it in a file.
    keepsLocale*: bool
    savedLocale*: string
    ## uiLanguages are the languages setLanguages told last, and
    ## uiRightToLeft its direction.
    uiLanguages*: seq[string]
    uiRightToLeft*: bool
    ## watching reports whether power events were asked for; awake
    ## counts the keepAwake calls not released yet.
    watching*: bool
    awake*: int
    ## online and constrained are what network.status answers with;
    ## watchingNetwork whether network.watch was called.
    online*, constrained*: bool
    watchingNetwork*: bool
    ## fileWatches are the file watches made; fileWatchError what
    ## making one fails with; fileWatchSubtree whether they take
    ## subtree targets.
    fileWatches*: seq[FakeFileWatch]
    fileWatchError*: ref CatchableError
    fileWatchSubtree*: bool
    ## urlSchemes are the registered URL schemes, by scheme: "id name".
    urlSchemes*: Table[string, string]
    ## loginItem is the command that starts the app at login:
    ## "id name arg".
    loginItem*: string
    ## dockMenu is the menu of the Dock icon.
    dockMenu*: platform.Menu
    ## cleared counts clearBrowsingData calls.
    cleared*: int
    cookies*: Table[platform.CookieKey, platform.Cookie]
    ## recentDocuments are the paths addRecentDocument recorded, in
    ## order, without the ones clearRecentDocuments removed.
    recentDocuments*: seq[string]
    ## recentCleared counts clearRecentDocuments calls.
    recentCleared*: int
    ## jumpListTasks are the tasks of the last setJumpListTasks call.
    jumpListTasks*: seq[platform.JumpListTask]
    ## Dialog results returned by the next dialog.
    openResult*: seq[string]
    saveResult*: string
    messageResult*: platform.MessageBoxResult
    ## onOpenDialog, onSaveDialog and onMessageBox, when set, answer
    ## the dialogs instead of the results above. They run on the main
    ## thread.
    onOpenDialog*: proc(o: platform.OpenDialogOptions): seq[string]
    onSaveDialog*: proc(o: platform.SaveDialogOptions): string
    onMessageBox*: proc(o: platform.MessageBoxOptions):
        platform.MessageBoxResult
    ## notificationError, when set, is what showing a notification
    ## fails with.
    notificationError*: ref CatchableError
    ## noWebView makes webViewSupported report no system webview.
    noWebView*: bool
    notifications*: Table[string, ref platform.Notification]
    secretError*: ref CatchableError
    secrets*: Table[tuple[service, account: string], seq[byte]]

  Popup* = object
    ## A context menu shown at pos.
    menu*: platform.Menu
    pos*: ref platform.Point

  FakeWindow* = ref object of platform.Window
    b*: FakeBackend
    h*: platform.WindowHandler
    opts*: platform.WindowOptions
    ## flyout is how a flyout was placed last.
    flyout*: platform.Flyout
    mu*: Lock
    scripts*: seq[string]
    userScripts*: seq[platform.UserScript]
    hasUserScripts*: bool
    menu*: platform.Menu
    title*: string
    url*: string
    bounds*: platform.Rect
    visible*: bool
    focused*: bool
    minimized*: bool
    maximized*: bool
    full*: bool
    zoom*: float64
    closed*: bool
    devtools*: bool
    ## dropped is what droppedFiles returns, once.
    dropped*: seq[string]
    ## pdf holds the options of the last printToPDF.
    pdf*: platform.PDFOptions
    ## html holds the documents loadHTML loaded, in order.
    html*: seq[string]
    ## What the window extras were last set to.
    background*: platform.Color
    progress*: string
    progressValue*: float64
    flashing*: bool
    skipsTaskbar*: bool
    onAllWorkspaces*: bool
    autoHidesMenu*: bool
    icon*: seq[byte]
    ## representedFile and documentEdited are what setRepresentedFile
    ## and setDocumentEdited set.
    representedFile*: string
    documentEdited*: bool
    ## titleBarRoom is what titleBar returns: set for windows with a
    ## hidden title bar, changed by tests before they call
    ## h.titleBarChanged.
    titleBarRoom*: platform.TitleBar
    ## asyncFunction answers callAsyncFunction.
    asyncFunction*: proc(body: string):
        tuple[res: string, err: ref CatchableError]
    ## asyncCallback, when set, receives callAsyncFunction calls to
    ## answer through reply whenever it wants, on the main thread.
    asyncCallback*: proc(body: string;
        reply: proc(res: string, err: ref CatchableError))
    ## onEval, when set, receives the scripts passed to eval instead of
    ## recording them.
    onEval*: proc(js: string)
    surface*: FakeSurface

  FakeSurface* = ref object of platform.Surface
    w*: FakeWindow
    ## scale is the device pixels per DIP.
    scale*: float64
    mu*: Lock
    requests*: int
    frames*: int
    pixels*: seq[byte]
    pixW*, pixH*: int
    cursor*: platform.Cursor
    textInput*: platform.TextInputState
    access*: ref platform.AccessTree
    accessN*: int
    rate*: float64
    dataDrag*: ref platform.DragRequest
    dropFormats*: seq[Format]
    ## webViews are those made, order those shown in the order the
    ## content painted them, and placements counts placeWebViews.
    webViews*: seq[FakeWebView]
    order*: seq[FakeWebView]
    placements*: int

  FakeWebView* = ref object of platform.WebView
    ## A web view under a fake surface (Surface.newWebView): a window
    ## of its own for its page, which its handler hears of, without the
    ## window's methods.
    win*: FakeWindow
    host*: FakeWindow
    ## placement is where the content last showed the web view, while
    ## shown; focused tells that focus or tabInto gave it the keyboard
    ## since; tabbedBack that tabInto did so going back.
    placement*: platform.WebViewPlacement
    shown*: bool
    focused*: bool
    tabbedBack*: bool

  FakeFileWatch* = ref object of platform.FileWatch
    mu*: Lock
    targets*: Table[uint64, platform.FileWatchTarget]
    notify*: proc(n: platform.FileWatchNotice)
    closed*: bool
    ## subtree makes add accept subtree targets, as Windows does.
    subtree*: bool
    ## addHook, when set, runs in add before the target is enrolled; an
    ## error it returns is add's.
    addHook*: proc(t: platform.FileWatchTarget): ref CatchableError

  FakeApp = ref object of platform.AppController
    b: FakeBackend
  FakeDialogs = ref object of platform.Dialogs
    b: FakeBackend
  FakeClipboard = ref object of platform.Clipboard
    b: FakeBackend
  FakeShell = ref object of platform.Shell
  FakeScreen = ref object of platform.Screen
  FakeTheme = ref object of platform.Theme
    b: FakeBackend
  FakePower = ref object of platform.Power
    b: FakeBackend
  FakeNetwork = ref object of platform.Network
    b: FakeBackend
  FakeSecrets = ref object of platform.Secrets
    b: FakeBackend
  FakeTray = ref object of platform.Tray

## errNoReply makes FakeWindow.callAsyncFunction never call back, like
## a promise that never settles.
proc errNoReply*(): ref CatchableError =
  newException(CatchableError, "fake: no reply")

## Apps are the applications applications lists, which tests set.
var apps*: seq[platform.Application]

## openedPaths are the paths openApplication was given.
var openedPaths*: seq[string]

proc threadID(): uint64 =
  cast[uint64](getThreadId())

proc newFakeBackend*(): FakeBackend =
  ## A fake backend.
  result = FakeBackend()
  result.signal.open()
  result.wakeChan.open()
  result.quitChan.open()
  initLock(result.mu)

method name*(b: FakeBackend): string = "fake"

method init*(b: FakeBackend; h: platform.AppHandler;
    opts: platform.AppOptions) =
  b.h = h
  b.mainID = threadID()

method run*(b: FakeBackend) =
  b.h.ready()
  while true:
    if b.quitFlag: return
    if b.signal.tryRecv().dataAvailable:
      b.h.dispatch()
    else:
      discard b.wakeChan.tryRecv()
      # Wait a moment so a spinning fake loop doesn't burn CPU.
      sleep(1)

method quit*(b: FakeBackend) =
  b.quitFlag = true
  discard b.quitChan.trySend(true)

method isMainThread*(b: FakeBackend): bool =
  b.mainID == 0 or threadID() == b.mainID

method signal*(b: FakeBackend) =
  discard b.signal.trySend(true)

method step*(b: FakeBackend) =
  if b.signal.tryRecv().dataAvailable:
    b.h.dispatch()
  else:
    discard b.wakeChan.tryRecv()

method wake*(b: FakeBackend) =
  discard b.wakeChan.trySend(true)

## quitRequested simulates Cmd+Q and reports whether the app agreed.
proc quitRequested*(b: FakeBackend): bool =
  if b.h.quitRequested():
    b.quit()
    return true
  false

proc place*(w: FakeWindow; f: platform.Flyout; size: platform.Size)
proc allWebViews*(s: FakeSurface): seq[FakeWebView]
proc closeWebViews(w: FakeWindow)

method newWindow*(b: FakeBackend; o: platform.WindowOptions;
    h: platform.WindowHandler):
    tuple[w: platform.Window, err: ref CatchableError] =
  let w = FakeWindow(b: b, h: h, opts: o, title: o.title, zoom: o.zoom,
    bounds: platform.Rect(x: o.x, y: o.y, width: o.width,
      height: o.height), maximized: o.maximized, full: o.fullScreen)
  initLock(w.mu)
  if o.surface:
    w.surface = FakeSurface(w: w, scale: 1)
    initLock(w.surface.mu)
  if not o.frameless and
      (o.titleBarStyle == "hidden" or o.titleBarStyle == "hiddenInset"):
    ## Three buttons 46 wide at the top right, as on Windows.
    let height = if o.titleBarHeight != 0: o.titleBarHeight else: 32
    w.titleBarRoom = platform.TitleBar(height: height, right: 138)
  if o.flyout != nil:
    place(w, o.flyout, platform.Size(width: o.width, height: o.height))
  b.mu.acquire()
  b.windows.add w
  b.mu.release()
  (w, nil)

proc place*(w: FakeWindow; f: platform.Flyout; size: platform.Size) =
  var anchor = f.anchor
  if f.tray != nil:
    anchor = f.tray.bounds()
  elif w.opts.parent of FakeWindow:
    let p = cast[FakeWindow](w.opts.parent)
    let c = p.contentBounds()
    anchor.x += c.x
    anchor.y += c.y
  var scr = FakeScreen()
  let (r, _, _) = f.place(anchor, size,
    workAreaFor(anchor, scr.displays()))
  w.mu.acquire()
  w.flyout = f
  w.bounds = r
  w.mu.release()

method placeFlyout*(w: FakeWindow; f: platform.Flyout;
    size: platform.Size) =
  ## Places a flyout as the real backends do, against the parent's
  ## content area and the fake display's work area.
  if w.opts.flyout == nil: return
  place(w, f, size)
  w.h.moved()

## appMenu returns the last application menu.
proc backendAppMenu*(b: FakeBackend): platform.Menu =
  b.mu.acquire()
  result = b.appMenu
  b.mu.release()

## menuUpdates returns the items passed to updateMenuItem.
proc menuUpdates*(b: FakeBackend): seq[platform.MenuItem] =
  b.mu.acquire()
  result = b.updates
  b.mu.release()

## clickMenuItem simulates choosing a menu item.
proc clickMenuItem*(b: FakeBackend; id: int) = b.h.menuItemClicked(id)

## clickMenuItem simulates choosing an item of this window's menu.
proc clickMenuItem*(w: FakeWindow; id: int) = w.h.menuItemClicked(id)

method setApplicationMenu*(b: FakeBackend; m: platform.Menu) =
  b.mu.acquire()
  b.appMenu = m
  b.mu.release()

method popupMenu*(b: FakeBackend; m: platform.Menu; w: platform.Window;
    pos: ref platform.Point) =
  b.mu.acquire()
  b.popups.add Popup(menu: m, pos: pos)
  b.mu.release()

## allPopups returns the context menus shown, in order.
proc allPopups*(b: FakeBackend): seq[Popup] =
  b.mu.acquire()
  result = b.popups
  b.mu.release()

method updateMenuItem*(b: FakeBackend; it: platform.MenuItem) =
  b.mu.acquire()
  b.updates.add it
  b.mu.release()

method app*(b: FakeBackend): platform.AppController = FakeApp(b: b)
method dialogs*(b: FakeBackend): platform.Dialogs = FakeDialogs(b: b)
method clipboard*(b: FakeBackend): platform.Clipboard = FakeClipboard(b: b)
method shell*(b: FakeBackend): platform.Shell = FakeShell()
method screen*(b: FakeBackend): platform.Screen = FakeScreen()
method theme*(b: FakeBackend): platform.Theme = FakeTheme(b: b)
method power*(b: FakeBackend): platform.Power = FakePower(b: b)
method network*(b: FakeBackend): platform.Network = FakeNetwork(b: b)
method secrets*(b: FakeBackend): platform.Secrets = FakeSecrets(b: b)

method applications*(b: FakeBackend):
    tuple[apps: seq[platform.Application], err: ref CatchableError] =
  (apps, nil)

method newTray*(b: FakeBackend; h: platform.TrayHandler):
    tuple[t: platform.Tray, err: ref CatchableError] =
  (FakeTray(), nil)

method registerHotkey*(b: FakeBackend; id: int; acc: string) =
  b.mu.acquire()
  b.hotkeys[id] = acc
  b.mu.release()

method unregisterHotkey*(b: FakeBackend; id: int) =
  b.mu.acquire()
  b.hotkeys.del(id)
  b.mu.release()

## pressHotkey simulates a global shortcut.
proc pressHotkey*(b: FakeBackend; acc: string) =
  b.mu.acquire()
  var hid = -1
  for id, a in b.hotkeys:
    if a == acc: hid = id
  b.mu.release()
  if hid >= 0:
    b.h.hotkeyPressed(hid)

## Notifications are recorded rather than shown, so that a test can see
## what the app asked for and report a click as a platform does.
method notificationsSupported*(b: FakeBackend): bool = true

method webViewSupported*(b: FakeBackend): bool = not b.noWebView

method showNotification*(b: FakeBackend; n: platform.Notification;
    done: proc(err: ref CatchableError)) =
  b.mu.acquire()
  if b.notificationError != nil:
    let err = b.notificationError
    b.mu.release()
    done(err)
    return
  ## A copy, as a real backend keeps its own.
  b.notifications[n.id] = new platform.Notification
  b.notifications[n.id][] = n
  b.mu.release()
  done(nil)

method removeNotification*(b: FakeBackend; id: string) =
  b.mu.acquire()
  b.notifications.del(id)
  b.mu.release()

method removeAllNotifications*(b: FakeBackend) =
  b.mu.acquire()
  b.notifications.clear()
  b.mu.release()

## delivered adds a notification the platform still shows from an
## earlier run of the app.
proc delivered*(b: FakeBackend; n: platform.Notification) =
  b.showNotification(n, proc(err: ref CatchableError) = discard)

## allNotifications returns the notifications shown and not yet removed.
proc allNotifications*(b: FakeBackend): seq[ref platform.Notification] =
  b.mu.acquire()
  for _, n in b.notifications: result.add n
  b.mu.release()

## notification returns the notification with an id, or nil.
proc notification*(b: FakeBackend; id: string): ref platform.Notification =
  b.mu.acquire()
  result = b.notifications.getOrDefault(id)
  b.mu.release()

## clickNotification reports a click on a notification, as the platform
## does. It runs on the main thread, like the backends report it.
proc clickNotification*(b: FakeBackend; id: string) =
  b.h.notificationClicked(id)

## --- FakeWindow methods (Page + Window interfaces) ---

method webViewHandle*(w: FakeWindow): uint = 2
method handle*(w: FakeWindow): uint = 1

method surface*(w: FakeWindow): platform.Surface =
  ## The window's surface, nil unless it was created with
  ## WindowOptions.surface.
  w.surface

## fakeSurface returns the surface with its fake extras.
proc fakeSurface*(w: FakeWindow): FakeSurface = w.surface

## allScripts returns the scripts eval recorded.
proc allScripts*(w: FakeWindow): seq[string] =
  w.mu.acquire()
  result = w.scripts
  w.mu.release()

## clearScripts drops the recorded scripts.
proc clearScripts*(w: FakeWindow) =
  w.mu.acquire()
  w.scripts.setLen(0)
  w.mu.release()

## windowMenu returns the menu setMenu set last.
proc windowMenu*(w: FakeWindow): platform.Menu =
  w.mu.acquire()
  result = w.menu
  w.mu.release()

method setProgressBar*(w: FakeWindow; state: string; value: float64) =
  w.mu.acquire()
  w.progress = state
  w.progressValue = value
  w.mu.release()

method flashFrame*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.flashing = v; w.mu.release()
method setSkipTaskbar*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.skipsTaskbar = v; w.mu.release()
method setVisibleOnAllWorkspaces*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.onAllWorkspaces = v; w.mu.release()
method setAutoHideMenu*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.autoHidesMenu = v; w.mu.release()
method setRepresentedFile*(w: FakeWindow; p: string) =
  w.mu.acquire(); w.representedFile = p; w.mu.release()
method setDocumentEdited*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.documentEdited = v; w.mu.release()

## document returns the represented file and edited state.
proc document*(w: FakeWindow): tuple[path: string, edited: bool] =
  w.mu.acquire()
  result = (w.representedFile, w.documentEdited)
  w.mu.release()

method setIcon*(w: FakeWindow; png: seq[byte]) =
  w.mu.acquire()
  w.icon = png
  w.mu.release()

method printToPDF*(w: FakeWindow; o: platform.PDFOptions;
    cb: proc(data: seq[byte]; err: ref CatchableError)) =
  w.pdf = o
  cb(@[], nil)

method droppedFiles*(w: FakeWindow): seq[string] =
  result = w.dropped
  w.dropped = @[]

proc isClosed*(w: FakeWindow): bool =
  w.mu.acquire()
  result = w.closed
  w.mu.release()

method titleBar*(w: FakeWindow): platform.TitleBar = w.titleBarRoom

method setTitle*(w: FakeWindow; t: string) =
  w.mu.acquire(); w.title = t; w.mu.release()
method title*(w: FakeWindow): string =
  w.mu.acquire(); result = w.title; w.mu.release()
method setBackgroundColor*(w: FakeWindow; c: platform.Color) =
  w.mu.acquire(); w.background = c; w.mu.release()
method setBounds*(w: FakeWindow; r: platform.Rect) =
  w.mu.acquire(); w.bounds = r; w.mu.release()
method bounds*(w: FakeWindow): platform.Rect =
  w.mu.acquire(); result = w.bounds; w.mu.release()
method setContentBounds*(w: FakeWindow; r: platform.Rect) = w.setBounds(r)
method contentBounds*(w: FakeWindow): platform.Rect = w.bounds()
method isResizable*(w: FakeWindow): bool = w.opts.resizable
method isMovable*(w: FakeWindow): bool = w.opts.movable
method isMinimizable*(w: FakeWindow): bool = w.opts.minimizable
method isMaximizable*(w: FakeWindow): bool = w.opts.maximizable
method isClosable*(w: FakeWindow): bool = w.opts.closable
method isAlwaysOnTop*(w: FakeWindow): bool = w.opts.alwaysOnTop

method show*(w: FakeWindow) =
  w.mu.acquire()
  w.visible = true
  w.focused = w.focused or w.opts.flyout == nil or w.opts.flyout.focusable
  w.mu.release()

method showInactive*(w: FakeWindow) =
  w.mu.acquire(); w.visible = true; w.mu.release()
method hide*(w: FakeWindow) =
  w.mu.acquire(); w.visible = false; w.mu.release()
method isVisible*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.visible; w.mu.release()
method focus*(w: FakeWindow) = w.h.focused()
method blur*(w: FakeWindow) = w.h.blurred()
method isFocused*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.focused; w.mu.release()
method minimize*(w: FakeWindow) =
  w.mu.acquire(); w.minimized = true; w.mu.release()
  w.h.minimized()
method isMinimized*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.minimized; w.mu.release()
method maximize*(w: FakeWindow) =
  w.mu.acquire(); w.maximized = true; w.mu.release()
  w.h.maximized()
method unmaximize*(w: FakeWindow) =
  w.mu.acquire(); w.maximized = false; w.mu.release()
  w.h.unmaximized()
method isMaximized*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.maximized; w.mu.release()
method restore*(w: FakeWindow) =
  w.mu.acquire(); w.minimized = false; w.mu.release()
  w.h.restored()
method setFullScreen*(w: FakeWindow; v: bool) =
  w.mu.acquire(); w.full = v; w.mu.release()
method isFullScreen*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.full; w.mu.release()
method setMenu*(w: FakeWindow; m: platform.Menu) =
  w.mu.acquire(); w.menu = m; w.mu.release()

method loadURL*(w: FakeWindow; url: string) =
  w.mu.acquire(); w.url = url; w.mu.release()

proc addHTML(w: FakeWindow; html: string) =
  w.mu.acquire()
  w.html.add html
  w.url = "about:blank"
  w.mu.release()

method loadHTML*(w: FakeWindow; html, baseURL: string) = w.addHTML(html)
method loadFile*(w: FakeWindow; path, readAccessDir: string) =
  w.mu.acquire(); w.url = "file://" & path; w.mu.release()
method url*(w: FakeWindow): string =
  w.mu.acquire(); result = w.url; w.mu.release()
method setZoom*(w: FakeWindow; f: float64) =
  w.mu.acquire(); w.zoom = f; w.mu.release()
method zoom*(w: FakeWindow): float64 =
  w.mu.acquire(); result = w.zoom; w.mu.release()
method userAgent*(w: FakeWindow): string = "fake"
method openDevTools*(w: FakeWindow) =
  w.mu.acquire(); w.devtools = true; w.mu.release()
method closeDevTools*(w: FakeWindow) =
  w.mu.acquire(); w.devtools = false; w.mu.release()
method isDevToolsOpened*(w: FakeWindow): bool =
  w.mu.acquire(); result = w.devtools; w.mu.release()
method capturePage*(w: FakeWindow;
    cb: proc(data: seq[byte]; err: ref CatchableError)) =
  cb(@[byte 'p', byte 'n', byte 'g'], nil)

method setUserScripts*(w: FakeWindow; scripts: seq[platform.UserScript]) =
  w.mu.acquire()
  w.userScripts = scripts
  w.hasUserScripts = true
  w.mu.release()

## userScripts returns the scripts a page loaded now gets: those of the
## options, or the ones setUserScripts set since.
proc getUserScripts*(w: FakeWindow): seq[platform.UserScript] =
  w.mu.acquire()
  if w.hasUserScripts:
    result = w.userScripts
  else:
    result = w.opts.userScripts
  w.mu.release()

method eval*(w: FakeWindow; js: string) =
  if w.onEval != nil:
    w.onEval(js)
    return
  w.mu.acquire()
  w.scripts.add js
  w.mu.release()

method callAsyncFunction*(w: FakeWindow; body: string;
    cb: proc(res: string; err: ref CatchableError)) =
  if w.asyncCallback != nil:
    w.asyncCallback(body, cb)
    return
  if w.asyncFunction == nil:
    cb("", errUnsupported())
    return
  let (res, err) = w.asyncFunction(body)
  if err != nil and err.msg == "fake: no reply":
    return
  cb(res, err)

method close*(w: FakeWindow) =
  w.mu.acquire()
  if w.closed:
    w.mu.release()
    return
  w.closed = true
  w.mu.release()
  closeWebViews(w)
  w.h.closed()

## userClose simulates a click on the close button.
proc userClose*(w: FakeWindow): bool =
  if not w.h.shouldClose(): return false
  w.close()
  true

proc closeWebViews(w: FakeWindow) =
  if w.surface == nil: return
  for v in w.surface.allWebViews():
    v.close()

## --- FakeApp ---

method preferredLanguages*(a: FakeApp): seq[string] =
  a.b.mu.acquire()
  if a.b.languages.len == 0:
    result = @["en-US"]
  else:
    result = a.b.languages
  a.b.mu.release()

method region*(a: FakeApp): platform.Region =
  a.b.mu.acquire()
  if a.b.region == nil:
    result = platform.Region(locale: "en-US", firstWeekday: 0, hourCycle: 12)
  else:
    result = a.b.region[]
  a.b.mu.release()

method savedLocale*(a: FakeApp): tuple[tag: string, kept: bool] =
  a.b.mu.acquire()
  result = (a.b.savedLocale, a.b.keepsLocale)
  a.b.mu.release()

method saveLocale*(a: FakeApp; tag: string): bool =
  a.b.mu.acquire()
  if not a.b.keepsLocale:
    a.b.mu.release()
    return false
  a.b.savedLocale = tag
  a.b.mu.release()
  true

method setLanguages*(a: FakeApp; tags: seq[string]; rtl: bool) =
  a.b.mu.acquire()
  a.b.uiLanguages = tags
  a.b.uiRightToLeft = rtl
  a.b.mu.release()

method registerURLScheme*(a: FakeApp; scheme, id, name: string) =
  a.b.mu.acquire()
  a.b.urlSchemes[scheme] = id & " " & name
  a.b.mu.release()

method unregisterURLScheme*(a: FakeApp; scheme, id, name: string) =
  a.b.mu.acquire()
  a.b.urlSchemes.del(scheme)
  a.b.mu.release()

method setOpenAtLogin*(a: FakeApp; open: bool; id, name, arg: string) =
  a.b.mu.acquire()
  a.b.loginItem = ""
  if open:
    a.b.loginItem = id & " " & name & " " & arg
  a.b.mu.release()

method openAtLogin*(a: FakeApp; id, name, arg: string): bool =
  a.b.mu.acquire()
  result = a.b.loginItem == id & " " & name & " " & arg
  a.b.mu.release()

method setDockMenu*(a: FakeApp; m: platform.Menu) =
  a.b.mu.acquire(); a.b.dockMenu = m; a.b.mu.release()

method clearBrowsingData*(a: FakeApp;
    done: proc(err: ref CatchableError)) =
  a.b.mu.acquire()
  inc a.b.cleared
  a.b.cookies.clear()
  a.b.mu.release()
  done(nil)

method isURLSchemeRegistered*(a: FakeApp; scheme, id, name: string): bool =
  a.b.mu.acquire()
  result = a.b.urlSchemes.getOrDefault(scheme) == id & " " & name
  a.b.mu.release()

method addRecentDocument*(a: FakeApp; path: string) =
  a.b.mu.acquire()
  a.b.recentDocuments.add path
  a.b.mu.release()

method clearRecentDocuments*(a: FakeApp) =
  a.b.mu.acquire()
  a.b.recentDocuments.setLen(0)
  inc a.b.recentCleared
  a.b.mu.release()

method setJumpListTasks*(a: FakeApp; tasks: seq[platform.JumpListTask]) =
  a.b.mu.acquire()
  a.b.jumpListTasks = tasks
  a.b.mu.release()

## --- cookies.go ---

method listCookies*(a: FakeApp;
    done: proc(cs: seq[platform.Cookie]; err: ref CatchableError)) =
  a.b.mu.acquire()
  let now = getTime()
  var res: seq[platform.Cookie]
  for _, c in a.b.cookies:
    if c.expires == default(Time) or c.expires > now:
      res.add c
  a.b.mu.release()
  done(res, nil)

method setCookie*(a: FakeApp; c: platform.Cookie;
    done: proc(err: ref CatchableError)) =
  a.b.mu.acquire()
  a.b.cookies[platform.CookieKey(name: c.name, domain: c.domain,
    path: c.path)] = c
  a.b.mu.release()
  done(nil)

method deleteCookie*(a: FakeApp; key: platform.CookieKey;
    done: proc(err: ref CatchableError)) =
  a.b.mu.acquire()
  a.b.cookies.del(key)
  a.b.mu.release()
  done(nil)

## --- FakeDialogs ---

method showOpenDialog*(d: FakeDialogs; parent: platform.Window;
    o: platform.OpenDialogOptions;
    cb: proc(paths: seq[string]; err: ref CatchableError)) =
  if d.b.onOpenDialog != nil:
    cb(d.b.onOpenDialog(o), nil)
    return
  cb(d.b.openResult, nil)

method showSaveDialog*(d: FakeDialogs; parent: platform.Window;
    o: platform.SaveDialogOptions;
    cb: proc(path: string; err: ref CatchableError)) =
  if d.b.onSaveDialog != nil:
    cb(d.b.onSaveDialog(o), nil)
    return
  cb(d.b.saveResult, nil)

method showMessageBox*(d: FakeDialogs; parent: platform.Window;
    o: platform.MessageBoxOptions;
    cb: proc(r: platform.MessageBoxResult; err: ref CatchableError)) =
  if d.b.onMessageBox != nil:
    cb(d.b.onMessageBox(o), nil)
    return
  cb(d.b.messageResult, nil)

## --- FakeClipboard ---

method readText*(c: FakeClipboard): string =
  let (b, _) = c.b.clipboardData.read(Text)
  bytesToString(b)

method writeText*(c: FakeClipboard; s: string) =
  c.writeData(textData(s), nil)

method readHTML*(c: FakeClipboard): string =
  let (b, _) = c.b.clipboardData.read(HTML)
  bytesToString(b)

method writeHTML*(c: FakeClipboard; markup: string) =
  c.writeData(newData(newItem(bytes(HTML, markup))), nil)

method readImage*(c: FakeClipboard): seq[byte] =
  let (b, _) = c.b.clipboardData.read(PNG)
  b

method writeImage*(c: FakeClipboard; png: seq[byte]) =
  c.writeData(newData(newItem(bytes(PNG, png))), nil)

method clear*(c: FakeClipboard) =
  c.writeData(Data(), nil)

method availableFormats*(c: FakeClipboard): seq[string] =
  for f in c.formats():
    result.add $f

method formats*(c: FakeClipboard): seq[Format] =
  c.b.clipboardData.formats()

method readData*(c: FakeClipboard; formats: seq[Format]):
    tuple[d: Data, err: ref CatchableError] =
  var formats = formats
  if formats.len == 0:
    formats = c.formats()
    if formats.len == 0:
      return (Data(), nil)
  let (d2, err) = c.b.clipboardData.materialize(formats)
  (d2, err)

proc release(c: FakeClipboard)

method writeData*(c: FakeClipboard; d: Data; released: proc()) =
  if c.b.clipboardError != nil:
    raise c.b.clipboardError
  let previous = c.b.clipboardRelease
  c.b.clipboardData = d
  c.b.clipboardRelease = released
  if previous != nil:
    previous()
  if d.formats().len == 0:
    c.release()

proc release(c: FakeClipboard) =
  if c.b.clipboardRelease != nil:
    let fn = c.b.clipboardRelease
    c.b.clipboardRelease = nil
    fn()

method flush*(c: FakeClipboard) =
  if c.formats().len == 0: return
  let (d, err) = c.readData(@[])
  if err != nil:
    raise err
  c.b.clipboardData = d
  c.release()
  if c.b.clipboardDuringFlush != nil:
    c.b.clipboardDuringFlush()

method close*(c: FakeClipboard) =
  if c.b.clipboardRelease != nil:
    c.b.clipboardData = Data()
    c.release()

## --- FakeShell ---

method openExternal*(s: FakeShell; url: string): ref CatchableError = nil
method openPath*(s: FakeShell; path: string) = discard
method showItemInFolder*(s: FakeShell; path: string) = discard
method trashItem*(s: FakeShell; path: string) = discard
method beep*(s: FakeShell) = discard

method openApplication*(s: FakeShell; path: string) =
  openedPaths.add path

method fileIcon*(s: FakeShell; path: string; size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  ## A transparent PNG of the size asked for, or the error of a path
  ## that does not exist.
  if not fileExists(path) and not dirExists(path):
    return (@[], newException(CatchableError, path & ": no such file"))
  let img = newRgba(image.rect(0, 0, size, size))
  (pngEncode(img), nil)

## --- FakePower ---

method watch*(p: FakePower) =
  p.b.mu.acquire(); p.b.watching = true; p.b.mu.release()

method keepAwake*(p: FakePower; display: bool; reason: string):
    platform.ReleaseProc =
  p.b.mu.acquire()
  inc p.b.awake
  p.b.mu.release()
  let b = p.b
  proc() =
    b.mu.acquire()
    dec b.awake
    b.mu.release()

method onBattery*(p: FakePower): bool = false
method idleTime*(p: FakePower): Duration = initDuration(seconds = 42)

## emitPower simulates a power or session event.
proc emitPower*(b: FakeBackend; event: string) = b.h.powerEvent(event)

## --- FakeNetwork ---

method status*(n: FakeNetwork): platform.NetworkStatus =
  n.b.mu.acquire()
  result = platform.NetworkStatus(online: n.b.online,
    constrained: n.b.constrained)
  n.b.mu.release()

method watch*(n: FakeNetwork) =
  n.b.mu.acquire(); n.b.watchingNetwork = true; n.b.mu.release()

## emitNetwork reports a network status to the app, as a backend does
## when it may have changed.
proc emitNetwork*(b: FakeBackend; status: platform.NetworkStatus) =
  b.h.networkChanged(status)

## --- FakeScreen ---

method displays*(s: FakeScreen): seq[platform.Display] =
  @[platform.Display(id: 1, label: "Fake", primary: true,
    scaleFactor: 2,
    bounds: platform.Rect(width: 1440, height: 900),
    workArea: platform.Rect(y: 25, width: 1440, height: 875))]

method cursorPoint*(s: FakeScreen): platform.Point =
  platform.Point(x: 10, y: 20)

## --- FakeTheme ---

method isDark*(t: FakeTheme): bool =
  t.b.mu.acquire()
  result = t.b.themeSource == "dark"
  t.b.mu.release()

method uiFont*(t: FakeTheme): string = ""
method fontRendering*(t: FakeTheme): platform.FontRendering =
  platform.FontRendering()

method setSource*(t: FakeTheme; s: string) =
  t.b.mu.acquire()
  t.b.themeSource = s
  t.b.mu.release()
  t.b.h.themeChanged()

method preferences*(t: FakeTheme): platform.Preferences =
  t.b.mu.acquire()
  inc t.b.prefsReads
  result = t.b.prefs
  t.b.mu.release()

## setPreferences changes the desktop's preferences, as the user does
## in the system's settings.
proc setPreferences*(b: FakeBackend; p: platform.Preferences) =
  b.mu.acquire()
  b.prefs = p
  b.mu.release()
  b.h.themeChanged()

## setSystemLanguages changes the languages the user prefers, and
## reports it; none goes back to en-US.
proc setSystemLanguages*(b: FakeBackend; tags: varargs[string]) =
  b.mu.acquire()
  b.languages = @tags
  b.mu.release()
  b.h.localeChanged()

## setSystemRegion changes the user's regional formats, and reports it.
proc setSystemRegion*(b: FakeBackend; r: platform.Region) =
  b.mu.acquire()
  b.region = new platform.Region
  b.region[] = r
  b.mu.release()
  b.h.localeChanged()

## setSavedLocale sets what the system keeps of the app's language.
proc setSavedLocale*(b: FakeBackend; tag: string) =
  b.mu.acquire()
  b.savedLocale = tag
  b.mu.release()

## preferenceReads returns how many times preferences() read the
## backend, for tests.
proc preferenceReads*(b: FakeBackend): int =
  b.mu.acquire()
  result = b.prefsReads
  b.mu.release()

## --- FakeTray ---

method bounds*(t: FakeTray): platform.Rect =
  ## Puts the icon in the menu bar above the fake display's work area.
  platform.Rect(x: 1300, width: 30, height: 25)

## --- watch.go ---

method newFileWatch*(b: FakeBackend;
    notify: proc(n: platform.FileWatchNotice)):
    tuple[w: platform.FileWatch, err: ref CatchableError] =
  b.mu.acquire()
  if b.fileWatchError != nil:
    let err = b.fileWatchError
    b.mu.release()
    return (nil, err)
  let w = FakeFileWatch(notify: notify, subtree: b.fileWatchSubtree)
  initLock(w.mu)
  b.fileWatches.add w
  b.mu.release()
  (w, nil)

## lastFileWatch returns the FakeFileWatch created last.
proc lastFileWatch*(b: FakeBackend): FakeFileWatch =
  b.mu.acquire()
  result = b.fileWatches[^1]
  b.mu.release()

method add*(w: FakeFileWatch; t: platform.FileWatchTarget) =
  if t.subtree and not w.subtree:
    raise errUnsupported()
  if w.addHook != nil:
    let err = w.addHook(t)
    if err != nil:
      raise err
  w.mu.acquire()
  w.targets[t.id] = t
  w.mu.release()

method remove*(w: FakeFileWatch; id: uint64) =
  w.mu.acquire()
  w.targets.del(id)
  w.mu.release()

method close*(w: FakeFileWatch) =
  w.mu.acquire()
  w.closed = true
  w.targets.clear()
  w.mu.release()

## allTargets returns the enrolled targets.
proc allTargets*(w: FakeFileWatch): seq[platform.FileWatchTarget] =
  w.mu.acquire()
  for _, t in w.targets: result.add t
  w.mu.release()

## notifyNow reports n, as a backend's thread would, unless the watch
## is closed.
proc notifyNow*(w: FakeFileWatch; n: platform.FileWatchNotice) =
  w.mu.acquire()
  let closed = w.closed
  w.mu.release()
  if not closed:
    w.notify(n)

method replaceFile*(b: FakeBackend; target, replacement: string) =
  ## Renames replacement over target, with the target's permissions.
  try:
    let info = getFileInfo(target)
    setFilePermissions(replacement, info.permissions)
  except OSError:
    discard
  moveFile(replacement, target)

## --- FakeSurface ---

method startDataDrag*(s: FakeSurface; r: platform.DragRequest) =
  s.dataDrag = new platform.DragRequest
  s.dataDrag[] = r

proc finishDataDrag*(s: FakeSurface; r: Result)

method cancelDataDrag*(s: FakeSurface) =
  s.finishDataDrag(Result(canceled: true))

method setDropFormats*(s: FakeSurface; f: seq[Format]) =
  s.dropFormats = f

## activeDataDrag returns the active native-source request.
proc activeDataDrag*(s: FakeSurface): ref platform.DragRequest =
  s.dataDrag

## finishDataDrag delivers the native source's result once. Main
## thread only.
proc finishDataDrag*(s: FakeSurface; r: Result) =
  if s.dataDrag != nil:
    let d = s.dataDrag
    s.dataDrag = nil
    d.done(r)

method native*(s: FakeSurface): platform.SurfaceNative =
  platform.SurfaceNative()

method size*(s: FakeSurface): tuple[width, height, scale: float64] =
  s.w.mu.acquire()
  result = (s.w.bounds.width.float64, s.w.bounds.height.float64, s.scale)
  s.w.mu.release()

method refreshRate*(s: FakeSurface): float64 =
  ## The display's refresh rate, 60 unless setRefreshRate set another.
  s.mu.acquire()
  if s.rate == 0: result = 60 else: result = s.rate
  s.mu.release()

## setRefreshRate sets the display's refresh rate.
proc setRefreshRate*(s: FakeSurface; hz: float64) =
  s.mu.acquire()
  s.rate = hz
  s.mu.release()

method requestFrame*(s: FakeSurface) =
  s.mu.acquire()
  inc s.requests
  s.mu.release()

method presentPixels*(s: FakeSurface; pix: openArray[byte];
    stride, width, height: int) =
  s.mu.acquire()
  inc s.frames
  s.pixW = width
  s.pixH = height
  s.pixels = newSeq[byte](4 * width * height)
  for y in 0 ..< height:
    copyMem(addr s.pixels[y * 4 * width], unsafeAddr pix[y * stride],
      4 * width)
  s.mu.release()

method setCursor*(s: FakeSurface; c: platform.Cursor) =
  s.mu.acquire()
  s.cursor = c
  s.mu.release()

method setTextInput*(s: FakeSurface; t: platform.TextInputState) =
  s.mu.acquire()
  s.textInput = t
  s.mu.release()

method updateAccessibility*(s: FakeSurface; tree: platform.AccessTree) =
  s.mu.acquire()
  s.access = new platform.AccessTree
  s.access[] = tree
  inc s.accessN
  s.mu.release()

## send delivers an event to the window's content, on the main thread,
## and returns what the content answered.
proc send*(s: FakeSurface; ev: platform.SurfaceEvent): bool =
  s.w.h.surfaceEvent(ev)

## frame draws a frame when the content asked for one since the last,
## as the display would, and reports whether it did.
proc frame*(s: FakeSurface): bool =
  s.mu.acquire()
  let pending = s.requests > 0
  s.requests = 0
  s.mu.release()
  if pending:
    discard s.send(platform.SurfaceEvent(kind: platform.surfaceFrame))
  pending

## frameCount returns how many frames were presented.
proc frameCount*(s: FakeSurface): int =
  s.mu.acquire()
  result = s.frames
  s.mu.release()

## pixel returns the color of a pixel of the last frame, as BGRA.
proc pixel*(s: FakeSurface; x, y: int): array[4, byte] =
  s.mu.acquire()
  if x < 0 or y < 0 or x >= s.pixW or y >= s.pixH:
    s.mu.release()
    return
  let p = (y * s.pixW + x) * 4
  result = [s.pixels[p], s.pixels[p + 1], s.pixels[p + 2], s.pixels[p + 3]]
  s.mu.release()

## surfaceCursor returns the pointer shape the content set.
proc surfaceCursor*(s: FakeSurface): platform.Cursor =
  s.mu.acquire()
  result = s.cursor
  s.mu.release()

## textInputActive reports whether text input is on, and the caret.
proc textInputActive*(s: FakeSurface): tuple[on: bool, caret: platform.RectF] =
  s.mu.acquire()
  result = (s.textInput.active, s.textInput.caret)
  s.mu.release()

## lastTextInput returns the last state of text input the content set.
proc lastTextInput*(s: FakeSurface): platform.TextInputState =
  s.mu.acquire()
  result = s.textInput
  s.mu.release()

## accessibility returns the last accessibility tree the content gave,
## and how many it gave.
proc accessibility*(s: FakeSurface):
    tuple[tree: ref platform.AccessTree, n: int] =
  s.mu.acquire()
  result = (s.access, s.accessN)
  s.mu.release()

## --- webview.go ---

method newWebView*(s: FakeSurface; o: platform.WindowOptions;
    h: platform.WindowHandler): tuple[w: platform.WebView, err: ref CatchableError] =
  let w = FakeWindow(b: s.w.b, h: h, opts: o, zoom: o.zoom)
  initLock(w.mu)
  if o.backgroundColor != nil:
    w.background = o.backgroundColor[]
  let v = FakeWebView(win: w, host: s.w)
  s.mu.acquire()
  s.webViews.add v
  s.mu.release()
  (v, nil)

method placeWebViews*(s: FakeSurface; views: seq[platform.WebViewPlacement]) =
  s.mu.acquire()
  inc s.placements
  for v in s.webViews:
    v.shown = false
  s.order.setLen(0)
  for p in views:
    if not (p.webView of FakeWebView): continue
    let v = cast[FakeWebView](p.webView)
    if v.host != s.w or v.win.isClosed(): continue
    v.placement = p
    v.shown = true
    s.order.add v
  for v in s.webViews:
    if not v.shown:
      v.focused = false ## a hidden view keeps no keyboard
  s.mu.release()

## allWebViews returns the surface's web views not closed, in the order
## they were made.
proc allWebViews*(s: FakeSurface): seq[FakeWebView] =
  s.mu.acquire()
  for v in s.webViews:
    if not v.win.isClosed():
      result.add v
  s.mu.release()

## placementCount counts the placeWebViews calls.
proc placementCount*(s: FakeSurface): int =
  s.mu.acquire()
  result = s.placements
  s.mu.release()

## webViewAt returns the web view that takes the pointer at x, y: the
## last shown, in the order the content painted them, whose placement
## takes it.
proc webViewAt*(s: FakeSurface; x, y: float64): FakeWebView =
  s.mu.acquire()
  for i in countdown(s.order.len - 1, 0):
    let v = s.order[i]
    if v.shown and v.placement.at(x, y):
      s.mu.release()
      return v
  s.mu.release()
  nil

## press presses the pointer at x, y as the platform would: on the web
## view taking it there, which tells the content (webViewPress) and
## returns it, else on the content, and reports nil.
proc press*(s: FakeSurface; x, y: float64): FakeWebView =
  let v = s.webViewAt(x, y)
  if v != nil:
    discard s.send(platform.SurfaceEvent(kind: platform.webViewPress,
      x: x, y: y))
    v.focus()
    return v
  discard s.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y, clicks: 1))
  discard s.send(platform.SurfaceEvent(kind: platform.pointerUp,
    x: x, y: y, clicks: 1))
  nil

method focus*(v: FakeWebView) =
  v.win.mu.acquire()
  v.focused = true
  v.win.mu.release()

method tabInto*(v: FakeWebView; back: bool) =
  v.win.mu.acquire()
  v.focused = true
  v.tabbedBack = back
  v.win.mu.release()

## tabOut moves the keyboard out of the web view as Tab past its
## page's last element does, or Shift+Tab past its first when back.
proc tabOut*(v: FakeWebView; back: bool) =
  v.win.mu.acquire()
  v.focused = false
  v.win.mu.release()
  var ev = platform.SurfaceEvent(kind: platform.webViewTabOut,
    key: platform.keyTab, webView: v)
  if back:
    ev.mods = platform.modShift
  discard v.host.surface.send(ev)

method close*(v: FakeWebView) =
  v.win.mu.acquire()
  v.win.closed = true
  v.shown = false
  v.focused = false
  v.win.mu.release()

## Forwarding: FakeWebView's page behaves as its inner FakeWindow.
method webViewHandle*(v: FakeWebView): uint = v.win.webViewHandle()
method loadURL*(v: FakeWebView; url: string) = v.win.loadURL(url)
method loadHTML*(v: FakeWebView; html, baseURL: string) =
  v.win.loadHTML(html, baseURL)
method loadFile*(v: FakeWebView; path, readAccessDir: string) =
  v.win.loadFile(path, readAccessDir)
method reload*(v: FakeWebView; ignoreCache: bool) = v.win.reload(ignoreCache)
method stopLoading*(v: FakeWebView) = v.win.stopLoading()
method goBack*(v: FakeWebView) = v.win.goBack()
method goForward*(v: FakeWebView) = v.win.goForward()
method canGoBack*(v: FakeWebView): bool = v.win.canGoBack()
method canGoForward*(v: FakeWebView): bool = v.win.canGoForward()
method url*(v: FakeWebView): string = v.win.url()
method isLoading*(v: FakeWebView): bool = v.win.isLoading()
method eval*(v: FakeWebView; js: string) = v.win.eval(js)
method setUserScripts*(v: FakeWebView; scripts: seq[platform.UserScript]) =
  v.win.setUserScripts(scripts)
proc getUserScripts*(v: FakeWebView): seq[platform.UserScript] =
  v.win.getUserScripts()
method callAsyncFunction*(v: FakeWebView; body: string;
    cb: proc(res: string; err: ref CatchableError)) =
  v.win.callAsyncFunction(body, cb)
method setZoom*(v: FakeWebView; factor: float64) = v.win.setZoom(factor)
method zoom*(v: FakeWebView): float64 = v.win.zoom()
method setUserAgent*(v: FakeWebView; ua: string) = v.win.setUserAgent(ua)
method userAgent*(v: FakeWebView): string = v.win.userAgent()
method openDevTools*(v: FakeWebView) = v.win.openDevTools()
method closeDevTools*(v: FakeWebView) = v.win.closeDevTools()
method isDevToolsOpened*(v: FakeWebView): bool = v.win.isDevToolsOpened()
method capturePage*(v: FakeWebView;
    cb: proc(data: seq[byte]; err: ref CatchableError)) =
  v.win.capturePage(cb)
method printToPDF*(v: FakeWebView; opts: platform.PDFOptions;
    cb: proc(data: seq[byte]; err: ref CatchableError)) =
  v.win.printToPDF(opts, cb)
method droppedFiles*(v: FakeWebView): seq[string] = v.win.droppedFiles()
method print*(v: FakeWebView) = v.win.print()
method setBackgroundColor*(v: FakeWebView; c: platform.Color) =
  v.win.setBackgroundColor(c)

## --- FakeSecrets ---

method setSecret*(s: FakeSecrets; service, account: string;
    secret: seq[byte]) =
  s.b.mu.acquire()
  if s.b.secretError != nil:
    let err = s.b.secretError
    s.b.mu.release()
    raise err
  s.b.secrets[(service, account)] = secret
  s.b.mu.release()

method secret*(s: FakeSecrets; service, account: string):
    tuple[secret: seq[byte], err: ref CatchableError] =
  s.b.mu.acquire()
  if s.b.secretError != nil:
    let err = s.b.secretError
    s.b.mu.release()
    return (@[], err)
  if (service, account) notin s.b.secrets:
    s.b.mu.release()
    return (@[], errSecretNotFound())
  let v = s.b.secrets[(service, account)]
  s.b.mu.release()
  (v, nil)

method deleteSecret*(s: FakeSecrets; service, account: string) =
  s.b.mu.acquire()
  if s.b.secretError != nil:
    let err = s.b.secretError
    s.b.mu.release()
    raise err
  s.b.secrets.del((service, account))
  s.b.mu.release()

## storedSecret returns the secret stored for service and account, as
## the system's store would show it.
proc storedSecret*(b: FakeBackend; service, account: string):
    tuple[v: seq[byte], ok: bool] =
  b.mu.acquire()
  if (service, account) in b.secrets:
    result = (b.secrets[(service, account)], true)
  b.mu.release()

## setSecretError makes every secrets call fail with err, or work
## again when err is nil. It may be called from any thread.
proc setSecretError*(b: FakeBackend; err: ref CatchableError) =
  b.mu.acquire()
  b.secretError = err
  b.mu.release()
