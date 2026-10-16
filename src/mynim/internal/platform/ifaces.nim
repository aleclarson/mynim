## The interface types of the platform contract: Page, Window, WebView,
## Surface, Backend, the handlers, and the service interfaces.
##
## Error convention: a Go `error` return alone becomes a raised
## exception; a `(T, error)` return becomes a `(T, ref CatchableError)`
## tuple with nil meaning success.
##
## All types sit in one type block so they may reference each other,
## like the Go package's mutually recursive declarations.

type
  AppHandler* = ref object of RootObj
    ## Receives application level events from the backend.

  WindowHandler* = ref object of RootObj
    ## Receives window and webview events from the backend.

  TrayHandler* = ref object of RootObj
    ## Receives tray icon events.

  SchemeResponder* = ref object of RootObj
    ## Delivers a custom protocol response to the webview.

  Stream* = ref object of RootObj
    ## A request body stream, as io.ReadCloser.

  SchemeRequest* = ref object
    ## A request for a custom protocol.
    ## context is cancelled when the webview no longer needs the response.
    context*: CancelCtx
    httpMethod*: string
    url*: string
    header*: HeaderMap
    ## body is nil for requests without a body.
    body*: Stream
    ## responder methods must be called on the main thread, respond first.
    responder*: SchemeResponder

  Surface* = ref object of RootObj
    ## The drawing area of a window created with WindowOptions.surface,
    ## which shows content MyGo draws itself (package ui) instead of a
    ## webview. Its methods run on the main thread.

  SurfaceNative* = object
    ## The native objects of a Surface.
    hwnd*: uint ## the surface's child window (Windows)
    ## composed tells that the window has no redirection bitmap, which
    ## would hide its material (Windows): a GPU renderer presents through
    ## DirectComposition, with the frames' alpha.
    composed*: bool
    view*, layer*: uint ## the surface's NSView and layer (macOS)
    ## widget is the surface's GtkGLArea or GtkDrawingArea, and glArea
    ## the GtkGLArea while its render signal draws a frame (Linux).
    widget*, glArea*: uint
    ## canvas is the number of the canvas's WebGL 2 context (browsers).
    canvas*: uint

  WebViewPlacement* = object
    ## Where the content of a surface shows a web view
    ## (Surface.placeWebViews), in DIPs relative to the surface.
    webView*: WebView
    ## frame is the web view's box; clip the part of it that shows.
    frame*, clip*: RectF
    ## covers are the boxes, within clip, of what the content painted
    ## over the web view that takes the pointer.
    covers*: seq[RectF]

  TextInputClient* = ref object of RootObj
    ## Supplies a focused custom element's text to native input methods.
    ## All calls are synchronous on the main thread. Ranges are absolute
    ## UTF-16 document offsets, including marked text.

  TextInputState* = object
    ## The state of the text input that has the keyboard, for input
    ## methods.
    active*: bool
    ## noInputMethod lets keyboard layouts type directly without composing.
    noInputMethod*: bool
    ## caret is the caret's rectangle, in DIPs relative to the surface.
    caret*: RectF
    ## text is the input's text around the caret, and start and `end` the
    ## selection in it, in runes: both the caret when nothing is selected.
    text*: string
    start*, `end`*: int
    ## client supplies full text and geometry for a custom text element.
    ## The text/start/`end` snapshot remains the plain-widget and
    ## caret fallback.
    client*: TextInputClient

  WindowOptions* = object
    ## Configures a native window and its webview. The public package
    ## fills in all defaults before calling newWindow.
    title*: string
    x*, y*, width*, height*: int
    center*: bool
    useContentSize*: bool
    minSize*, maxSize*: Size
    resizable*, movable*, minimizable*, maximizable*, closable*: bool
    focusable*, fullscreenable*, alwaysOnTop*: bool
    fullScreen*, maximized*, skipTaskbar*, autoHideMenu*: bool
    hasShadow*, frameless*, transparent*: bool
    ## backgroundColor is painted before the page renders; nil keeps the
    ## platform default.
    backgroundColor*: ref Color
    ## titleBarStyle is "default", "hidden" or "hiddenInset". A hidden
    ## title bar gives the page the whole window, under the window
    ## controls.
    titleBarStyle*: string
    ## titleBarHeight is the height of a hidden title bar in DIPs
    ## (Linux, Windows); 0 is the backend's own.
    titleBarHeight*: int
    trafficLightPosition*: ref Point
    vibrancy*: string
    opacity*: float64
    parent*: Window
    modal*: bool
    ## flyout makes the window a flyout of its parent, placed next to an
    ## anchor (Window.placeFlyout): borderless, transparent, out of the
    ## taskbar, with focusable telling whether it takes the keyboard.
    flyout*: Flyout
    ## panel makes the window a panel (mynim.WindowOptions.panel): it
    ## floats above the windows of all apps on the current workspace,
    ## full-screen ones included, out of the taskbar and the app
    ## switcher, and on macOS takes the keyboard without activating the
    ## app.
    panel*: bool
    ## userScripts are injected into every page, in order.
    userScripts*: seq[UserScript]
    ## schemes lists the custom protocols the webview must route to
    ## WindowHandler.schemeRequest.
    schemes*: seq[string]
    devTools*: bool
    userAgent*: string
    zoom*: float64
    ## native carries backend specific state, e.g. the
    ## WKWebViewConfiguration WebKit hands us for window.open().
    native*: uint
    ## surface creates the window with a Surface, which content MyGo
    ## draws itself fills, instead of a webview: Window.surface returns
    ## it, the webview methods do nothing and the webview options are
    ## ignored.
    surface*: bool

  Dialogs* = ref object of RootObj
    ## Shows native dialogs. Callbacks run on the main thread exactly
    ## once. parent may be nil for application modal dialogs.

  Clipboard* = ref object of RootObj
    ## Accesses the system clipboard.

  Shell* = ref object of RootObj
    ## Integrates with the desktop environment.

  Screen* = ref object of RootObj
    ## Queries monitors.

  Theme* = ref object of RootObj
    ## Reads and overrides the system appearance.

  Power* = ref object of RootObj
    ## Reports power and session events and keeps the computer awake.

  Network* = ref object of RootObj
    ## Reports the state of the computer's network connection.

  Secrets* = ref object of RootObj
    ## Keeps small secrets in the system's credential store: the
    ## Keychain on macOS, the Secret Service on Linux (through
    ## libsecret) and the Credential Manager on Windows. Unlike other
    ## platform methods these may be called from any thread, and they
    ## may block while the system asks the user, e.g. to unlock the
    ## keyring: the core never calls them on the main thread of a
    ## running app.

  AppController* = ref object of RootObj
    ## Exposes application level native features.

  Backend* = ref object of RootObj
    ## Implemented by every native backend.

  ReleaseProc* = proc()
    ## What Power.keepAwake returns; call it to release the assertion.

## --- Page ---

method webViewHandle*(p: Page): uint {.base.} =
  ## The native webview object.
  raise errUnsupported()

method loadURL*(p: Page, url: string) {.base.} = discard
method loadHTML*(p: Page, html, baseURL: string) {.base.} = discard
method loadFile*(p: Page, path, readAccessDir: string) {.base.} = discard
method reload*(p: Page, ignoreCache: bool) {.base.} = discard
method stopLoading*(p: Page) {.base.} = discard
method goBack*(p: Page) {.base.} = discard
method goForward*(p: Page) {.base.} = discard
method canGoBack*(p: Page): bool {.base.} = false
method canGoForward*(p: Page): bool {.base.} = false
method url*(p: Page): string {.base.} = ""
method isLoading*(p: Page): bool {.base.} = false
## eval runs JavaScript in the main frame and ignores the result.
method eval*(p: Page, js: string) {.base.} = discard
## setUserScripts replaces the scripts WindowOptions.userScripts gave the
## pages loaded later; the page loaded now keeps those it ran.
method setUserScripts*(p: Page, scripts: seq[UserScript]) {.base.} = discard
## callAsyncFunction runs body as the body of an async function in the
## main frame, awaits it and reports the returned value, which the caller
## arranges to be a string. err is non-nil when the body fails to compile
## or the evaluation fails natively. Page CSP does not apply.
method callAsyncFunction*(p: Page, body: string,
    cb: proc(res: string, err: ref CatchableError)) {.base.} = discard
method setZoom*(p: Page, factor: float64) {.base.} = discard
method zoom*(p: Page): float64 {.base.} = 1
method setUserAgent*(p: Page, ua: string) {.base.} = discard
method userAgent*(p: Page): string {.base.} = ""
method openDevTools*(p: Page) {.base.} = discard
method closeDevTools*(p: Page) {.base.} = discard
method isDevToolsOpened*(p: Page): bool {.base.} = false
## capturePage takes a PNG snapshot of the visible page.
method capturePage*(p: Page,
    cb: proc(png: seq[byte], err: ref CatchableError)) {.base.} = discard
## printToPDF renders the page as a PDF document.
method printToPDF*(p: Page, opts: PDFOptions,
    cb: proc(pdf: seq[byte], err: ref CatchableError)) {.base.} = discard
## droppedFiles returns the paths of the files of the latest drop on the
## page and forgets them. The page reports the drop itself (a "drop"
## message); backends record the paths before the page sees it.
method droppedFiles*(p: Page): seq[string] {.base.} = @[]
method print*(p: Page) {.base.} = discard

## --- Window ---

method handle*(w: Window): uint {.base.} =
  ## The native window (NSWindow*, GtkWindow*, HWND).
  raise errUnsupported()

method surface*(w: Window): Surface {.base.} =
  ## The drawing surface of a window created with WindowOptions.surface,
  ## nil for others.
  nil

method setTitle*(w: Window, title: string) {.base.} = discard
method title*(w: Window): string {.base.} = ""
## setRepresentedFile shows the file a window shows, "" for none: the
## proxy icon of the title bar and its menu of folders (macOS). Other
## platforms do nothing.
method setRepresentedFile*(w: Window, path: string) {.base.} = discard
## setDocumentEdited shows that the window's document has unsaved
## changes: the dot of the close button (macOS). Other platforms do
## nothing; the core marks the title there.
method setDocumentEdited*(w: Window, edited: bool) {.base.} = discard
method setBounds*(w: Window, r: Rect) {.base.} = discard
method bounds*(w: Window): Rect {.base.} = Rect()
method setContentBounds*(w: Window, r: Rect) {.base.} = discard
method contentBounds*(w: Window): Rect {.base.} = Rect()
method setMinimumSize*(w: Window, s: Size) {.base.} = discard
method setMaximumSize*(w: Window, s: Size) {.base.} = discard
method setResizable*(w: Window, v: bool) {.base.} = discard
method isResizable*(w: Window): bool {.base.} = true
method setMovable*(w: Window, v: bool) {.base.} = discard
method isMovable*(w: Window): bool {.base.} = true
method setMinimizable*(w: Window, v: bool) {.base.} = discard
method isMinimizable*(w: Window): bool {.base.} = true
method setMaximizable*(w: Window, v: bool) {.base.} = discard
method isMaximizable*(w: Window): bool {.base.} = true
method setClosable*(w: Window, v: bool) {.base.} = discard
method isClosable*(w: Window): bool {.base.} = true
method setAlwaysOnTop*(w: Window, v: bool) {.base.} = discard
method isAlwaysOnTop*(w: Window): bool {.base.} = false
method show*(w: Window) {.base.} = discard
method showInactive*(w: Window) {.base.} = discard
method hide*(w: Window) {.base.} = discard
method isVisible*(w: Window): bool {.base.} = false
method focus*(w: Window) {.base.} = discard
method blur*(w: Window) {.base.} = discard
method isFocused*(w: Window): bool {.base.} = false
method minimize*(w: Window) {.base.} = discard
method isMinimized*(w: Window): bool {.base.} = false
method maximize*(w: Window) {.base.} = discard
method unmaximize*(w: Window) {.base.} = discard
method isMaximized*(w: Window): bool {.base.} = false
method restore*(w: Window) {.base.} = discard
method setFullScreen*(w: Window, v: bool) {.base.} = discard
method isFullScreen*(w: Window): bool {.base.} = false
method center*(w: Window) {.base.} = discard
method setBackgroundColor*(w: Window, c: Color) {.base.} = discard
method setOpacity*(w: Window, v: float64) {.base.} = discard
method opacity*(w: Window): float64 {.base.} = 1
method setHasShadow*(w: Window, v: bool) {.base.} = discard
method hasShadow*(w: Window): bool {.base.} = true
method setIgnoreMouseEvents*(w: Window, v: bool) {.base.} = discard
method setContentProtection*(w: Window, v: bool) {.base.} = discard
method setVibrancy*(w: Window, material: string) {.base.} = discard
## setProgressBar shows progress on the taskbar button, Dock icon or
## launcher entry: state is "" (none), "normal", "indeterminate",
## "paused" or "error", value between 0 and 1.
method setProgressBar*(w: Window, state: string, value: float64) {.base.} = discard
method flashFrame*(w: Window, flash: bool) {.base.} = discard
method setSkipTaskbar*(w: Window, v: bool) {.base.} = discard
method setVisibleOnAllWorkspaces*(w: Window, v: bool) {.base.} = discard
## setIcon sets the window icon from a PNG image; empty restores the
## application's.
method setIcon*(w: Window, png: seq[byte]) {.base.} = discard
## setMenu sets a per-window menu bar (Linux/Windows). No-op on macOS.
method setMenu*(w: Window, m: Menu) {.base.} = discard
## setAutoHideMenu hides the menu bar until Alt or F10 brings the
## keyboard to it (Linux/Windows). No-op on macOS.
method setAutoHideMenu*(w: Window, v: bool) {.base.} = discard
## titleBar returns the room the window controls of a window with a
## hidden title bar take, which WindowHandler.titleBarChanged reports
## changes of. It is zero for other windows and while the controls are
## hidden, in full screen.
method titleBar*(w: Window): TitleBar {.base.} = TitleBar()
## startDrag moves the window with the mouse (frameless drag regions).
method startDrag*(w: Window) {.base.} = discard
## titleBarDoubleClicked performs the platform action for a double click
## on a custom title bar (zoom/minimize on macOS).
method titleBarDoubleClicked*(w: Window) {.base.} = discard
## placeFlyout places a flyout (WindowOptions.flyout) of the given size
## next to its anchor again, as Flyout.place resolves it in the work
## area of a display, after the anchor, the size or the parent changed.
## It does nothing for other windows.
method placeFlyout*(w: Window, f: Flyout, size: Size) {.base.} = discard
## close destroys the window without asking WindowHandler.shouldClose.
method close*(w: Window) {.base.} = discard

## --- WebView ---

## focus gives the web view the keyboard.
method focus*(w: WebView) {.base.} = discard
## tabInto gives the web view the keyboard as Tab does: at its page's
## first element taking the focus, or its last when back, as Shift+Tab
## does. Tab past the other end comes back as webViewTabOut.
method tabInto*(w: WebView, back: bool) {.base.} = discard
## setBackgroundColor paints the web view before its page does.
method setBackgroundColor*(w: WebView, c: Color) {.base.} = discard
## close destroys the web view; its handler hears no more of it.
## Backends close the web views of a window that closes before telling
## its WindowHandler.closed, and close does nothing then.
method close*(w: WebView) {.base.} = discard

proc at*(p: WebViewPlacement, x, y: float64): bool =
  ## Whether the pointer at x, y is the web view's.
  if not p.clip.contains(x, y): return false
  for c in p.covers:
    if c.contains(x, y): return false
  true

## --- AppHandler ---

method ready*(h: AppHandler) {.base.} = discard
## dispatch drains the queue of functions scheduled for the main thread.
method dispatch*(h: AppHandler) {.base.} = discard
## quitRequested is called when the user or the OS asks the application
## to quit (Cmd+Q, Dock > Quit, logout). Returning true lets the quit
## proceed.
method quitRequested*(h: AppHandler): bool {.base.} = true
## terminating is called right before the process is terminated by the
## OS (logout/shutdown); run will not return.
method terminating*(h: AppHandler) {.base.} = discard
## activated is called when the application is re-activated, e.g. by
## clicking its Dock icon.
method activated*(h: AppHandler, hasVisibleWindows: bool) {.base.} = discard
method didBecomeActive*(h: AppHandler) {.base.} = discard
method didResignActive*(h: AppHandler) {.base.} = discard
method openURLs*(h: AppHandler, urls: seq[string]) {.base.} = discard
method openFiles*(h: AppHandler, paths: seq[string]) {.base.} = discard
method menuItemClicked*(h: AppHandler, id: int) {.base.} = discard
method themeChanged*(h: AppHandler) {.base.} = discard
method displaysChanged*(h: AppHandler) {.base.} = discard
## localeChanged is called when the languages the user prefers, or the
## regional formats, may have changed, on the systems that report it.
method localeChanged*(h: AppHandler) {.base.} = discard
## powerEvent is "suspend", "resume", "lock-screen" or "unlock-screen".
method powerEvent*(h: AppHandler, event: string) {.base.} = discard
## networkChanged reports the network's status, once Network.watch was
## called, when it may have changed.
method networkChanged*(h: AppHandler, status: NetworkStatus) {.base.} = discard
method hotkeyPressed*(h: AppHandler, id: int) {.base.} = discard
method notificationClicked*(h: AppHandler, id: string) {.base.} = discard

## --- WindowHandler ---

## shouldClose is called when the user tries to close the window.
method shouldClose*(h: WindowHandler): bool {.base.} = true
## closed is called after the native window has been destroyed.
method closed*(h: WindowHandler) {.base.} = discard
method focused*(h: WindowHandler) {.base.} = discard
method blurred*(h: WindowHandler) {.base.} = discard
## menuItemClicked reports an item chosen from this window's menu bar or
## context menu, even while the menu has focus instead of the window.
method menuItemClicked*(h: WindowHandler, id: int) {.base.} = discard
method resized*(h: WindowHandler) {.base.} = discard
method moved*(h: WindowHandler) {.base.} = discard
method minimized*(h: WindowHandler) {.base.} = discard
method restored*(h: WindowHandler) {.base.} = discard
method maximized*(h: WindowHandler) {.base.} = discard
method unmaximized*(h: WindowHandler) {.base.} = discard
method enteredFullScreen*(h: WindowHandler) {.base.} = discard
method leftFullScreen*(h: WindowHandler) {.base.} = discard
## titleBarChanged is called when Window.titleBar changes, e.g. when the
## window enters full screen or the desktop's button layout changes.
method titleBarChanged*(h: WindowHandler) {.base.} = discard
## message delivers a message posted by the renderer bridge.
method message*(h: WindowHandler, msg: string) {.base.} = discard
## willNavigate is called before a navigation; returning false cancels it.
method willNavigate*(h: WindowHandler, nav: Navigation): bool {.base.} = true
method navigationStarted*(h: WindowHandler, url: string) {.base.} = discard
method navigationCommitted*(h: WindowHandler, url: string) {.base.} = discard
method loadFinished*(h: WindowHandler) {.base.} = discard
method loadFailed*(h: WindowHandler, url: string, code: int, description: string) {.base.} = discard
method titleChanged*(h: WindowHandler, title: string) {.base.} = discard
## newWindow is called for window.open() and target=_blank links. It
## returns the window that should host the new page or nil to deny it.
method newWindow*(h: WindowHandler, req: NewWindowRequest): Window {.base.} = nil
## closedByPage is called when the page calls window.close().
method closedByPage*(h: WindowHandler) {.base.} = discard
method renderProcessGone*(h: WindowHandler, reason: string) {.base.} = discard
method schemeRequest*(h: WindowHandler, req: SchemeRequest) {.base.} = discard
## downloadStarted returns where to save a download, "" to cancel it;
## downloadFinished reports how it ended.
method downloadStarted*(h: WindowHandler, url, suggestedName: string): string {.base.} = ""
method downloadFinished*(h: WindowHandler, url, path: string,
                         err: ref CatchableError) {.base.} = discard
## schemeDownload downloads a URL of a custom scheme, which the engine
## cannot turn into a download, by serving it again.
method schemeDownload*(h: WindowHandler, url: string) {.base.} = discard
## permissionRequested asks whether the page at origin may use kinds:
## "camera", "microphone", "geolocation" or "notifications".
method permissionRequested*(h: WindowHandler, kinds: seq[string], origin: string): bool {.base.} =
  false
## surfaceEvent delivers input on the window's Surface, and changes of
## it. For fileDragOver and fileDrop it reports whether the content
## takes the files where they are, and for keyPressed whether it took
## the key itself, which the system then leaves alone; it returns false
## for other events.
method surfaceEvent*(h: WindowHandler, ev: SurfaceEvent): bool {.base.} = false

## --- SchemeResponder ---

method respond*(r: SchemeResponder, status: int, header: HeaderMap) {.base.} = discard
method write*(r: SchemeResponder, p: openArray[byte]) {.base.} = discard
method finish*(r: SchemeResponder) {.base.} = discard
method fail*(r: SchemeResponder, err: ref CatchableError) {.base.} = discard
## Go's optional SchemeBodyWriter interface, merged: writeBody writes p
## once respond has run. It is called off the main thread, never at the
## same time as the other methods, and fails once the webview no longer
## reads the response.
method supportsWriteBody*(r: SchemeResponder): bool {.base.} = false
method writeBody*(r: SchemeResponder, p: seq[byte]) {.base.} =
  raise errUnsupported()

## --- Stream ---

## read fills b with the next bytes of the stream, as io.Reader.Read:
## it returns the number of bytes read and whether the stream ended.
method read*(s: Stream, b: var openArray[byte]): tuple[n: int, eof: bool] {.base.} =
  (0, true)
method close*(s: Stream) {.base.} = discard

type
  byteStream = ref object of Stream
    ## A Stream over bytes in memory, as io.NopCloser(bytes.NewReader).
    b: seq[byte]
    off: int

method read(s: byteStream, b: var openArray[byte]): tuple[n: int, eof: bool] =
  let n = min(b.len, s.b.len - s.off)
  if n > 0:
    copyMem(addr b[0], unsafeAddr s.b[s.off], n)
    s.off += n
  (n, s.off >= s.b.len)

proc streamOf*(b: seq[byte]): Stream = byteStream(b: b)

proc readAll*(s: Stream): seq[byte] =
  ## readAll drains a Stream, as io.ReadAll.
  if s == nil:
    return
  var buf = newSeq[byte](64 shl 10)
  while true:
    let (n, eof) = s.read(buf)
    if n > 0:
      result.add buf[0 ..< n]
    if eof or n <= 0:
      break
  s.close()

## --- Surface ---

method native*(s: Surface): SurfaceNative {.base.} =
  ## The native objects a GPU renderer draws into, which it calls before
  ## making one: a surface that shows frames drawn in memory through
  ## those objects (Windows' composed) lets go of them then.
  SurfaceNative()
## size returns the size of the drawing area in DIPs and how many device
## pixels a DIP is.
method size*(s: Surface): tuple[width, height, scale: float64] {.base.} = (0.0, 0.0, 1.0)
## requestFrame asks for a surfaceFrame event at the next opportunity to
## draw: the next display refresh, WM_PAINT or GTK draw. Requests made
## before it comes coalesce.
method requestFrame*(s: Surface) {.base.} = discard
## refreshRate returns how many times a second the display showing the
## surface refreshes, at most, 0 when unknown.
method refreshRate*(s: Surface): float64 {.base.} = 0
## presentPixels shows a frame drawn in memory: premultiplied BGRA rows
## of stride bytes, width×height device pixels. It is called while
## handling a surfaceFrame event.
method presentPixels*(s: Surface, pix: openArray[byte], stride, width, height: int) {.base.} = discard
## setCursor sets the pointer's shape over the surface.
method setCursor*(s: Surface, c: Cursor) {.base.} = discard
## setTextInput turns text input (IME composition) on for an editable
## element, telling input methods where its caret is and the text
## around it, or off.
method setTextInput*(s: Surface, t: TextInputState) {.base.} = discard
## updateAccessibility gives assistive technology the content's
## elements. The content calls it after every frame once the surface
## sent accessibilityOn.
method updateAccessibility*(s: Surface, tree: AccessTree) {.base.} = discard
## startDataDrag starts a native transfer; cancelDataDrag cancels the
## source owned by this surface. Both run on the main thread.
method startDataDrag*(s: Surface, r: DragRequest) {.base.} = discard
method cancelDataDrag*(s: Surface) {.base.} = discard
## setDropFormats registers the formats the content can receive.
method setDropFormats*(s: Surface, formats: seq[Format]) {.base.} = discard
## newWebView creates a web view under the surface, hidden until
## placeWebViews shows it. Of opts, the options of a webview apply
## (userScripts, schemes, devTools, userAgent, zoom, backgroundColor,
## transparent); h hears of its page.
method newWebView*(s: Surface, opts: WindowOptions,
                   h: WindowHandler): tuple[w: WebView, err: ref CatchableError] {.base.} =
  (nil, errUnsupported())
## placeWebViews shows the web views of the surface where the content's
## last frame shows them, in the order it painted them, and hides the
## others, which keep their pages. A press on one, which takes it,
## comes as webViewPress.
method placeWebViews*(s: Surface, views: seq[WebViewPlacement]) {.base.} = discard

## DamageSurface (optional in Go, merged): presentDamage is
## presentPixels for a frame that differs from the last one presented
## only within damage, in device pixels.
method supportsDamage*(s: Surface): bool {.base.} = false
method presentDamage*(s: Surface, pix: openArray[byte], stride, width, height: int,
                      damage: seq[Rectangle]) {.base.} = discard
## OccludableSurface (merged): occluded reports whether nothing of the
## surface shows on screen. Default false means "some of it shows".
method occluded*(s: Surface): bool {.base.} = false
## WideGamutSurface (merged): whether the screen showing most of the
## window shows colors outside the sRGB gamut, as Display P3 screens do.
method wideGamut*(s: Surface): bool {.base.} = false
## MaterialSurface (merged): whether the window shows a material behind
## the content now: what its frames leave transparent shows it, rather
## than nothing.
method showsMaterial*(s: Surface): bool {.base.} = false
## IdleSurface (merged): idle tells that no frame came for a while: the
## surface may give back memory that drawing frames took and freed.
method idle*(s: Surface) {.base.} = discard

## --- TextInputClient ---

## Nil ranges (nil refs) mean the marked range, if present, otherwise
## the selection.
method textForRange*(c: TextInputClient, r: TextRange):
    tuple[s: string, actual: TextRange] {.base.} =
  ("", TextRange())
method selection*(c: TextInputClient): TextSelection {.base.} = TextSelection()
method markedRange*(c: TextInputClient): tuple[r: TextRange, ok: bool] {.base.} =
  (TextRange(), false)
method replaceText*(c: TextInputClient, r: ref TextRange, text: string) {.base.} = discard
method setMarkedText*(c: TextInputClient, r: ref TextRange, text: string,
                      sel: TextRange) {.base.} = discard
method unmarkText*(c: TextInputClient) {.base.} = discard
method boundsForRange*(c: TextInputClient, r: TextRange):
    tuple[bounds: RectF, actual: TextRange, ok: bool] {.base.} =
  (RectF(), TextRange(), false)
method indexForPoint*(c: TextInputClient, x, y: float64):
    tuple[i: int, ok: bool] {.base.} =
  (0, false)

## --- Dialogs ---

method showOpenDialog*(d: Dialogs, parent: Window, opts: OpenDialogOptions,
    cb: proc(paths: seq[string], err: ref CatchableError)) {.base.} = discard
method showSaveDialog*(d: Dialogs, parent: Window, opts: SaveDialogOptions,
    cb: proc(path: string, err: ref CatchableError)) {.base.} = discard
method showMessageBox*(d: Dialogs, parent: Window, opts: MessageBoxOptions,
    cb: proc(res: MessageBoxResult, err: ref CatchableError)) {.base.} = discard

## --- Clipboard ---

## readData reads copy accepted representations, so returned data
## outlives native ownership. Nil/empty formats reads all; a missing
## explicit match is transfer's errFormat. writeData takes an
## application-owned snapshot; released runs once when native providers
## are no longer needed, never after a failed write. Neither operation
## depends on a source window.
method readData*(c: Clipboard, formats: seq[Format]): tuple[d: Data, err: ref CatchableError] {.base.} =
  (Data(), errUnsupported())
method writeData*(c: Clipboard, data: Data, released: proc()) {.base.} = discard
method formats*(c: Clipboard): seq[Format] {.base.} = @[]
## flush materializes owned providers and asks the system to persist the
## data. close drops any remaining owned providers at app shutdown.
method flush*(c: Clipboard) {.base.} = discard
method close*(c: Clipboard) {.base.} = discard
method readText*(c: Clipboard): string {.base.} = ""
method writeText*(c: Clipboard, text: string) {.base.} = discard
method readHTML*(c: Clipboard): string {.base.} = ""
method writeHTML*(c: Clipboard, markup: string) {.base.} = discard
method readImage*(c: Clipboard): seq[byte] {.base.} = @[]
method writeImage*(c: Clipboard, png: seq[byte]) {.base.} = discard
method clear*(c: Clipboard) {.base.} = discard
method availableFormats*(c: Clipboard): seq[string] {.base.} = @[]

## --- Shell ---

method openExternal*(s: Shell, url: string): ref CatchableError {.base.} =
  raise errUnsupported()
method openPath*(s: Shell, path: string) {.base.} =
  raise errUnsupported()
method showItemInFolder*(s: Shell, path: string) {.base.} = discard
method trashItem*(s: Shell, path: string) {.base.} =
  raise errUnsupported()
method beep*(s: Shell) {.base.} = discard
## fileIcon returns the icon the file manager shows for a file, a
## folder or an application, as a PNG image of size by size pixels.
method fileIcon*(s: Shell, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] {.base.} =
  (@[], errUnsupported())
## openApplication starts the application at Application.path, or
## brings it to the front.
method openApplication*(s: Shell, path: string) {.base.} =
  raise errUnsupported()

## --- Screen ---

method displays*(s: Screen): seq[Display] {.base.} = @[]
method cursorPoint*(s: Screen): Point {.base.} = Point()

## --- Theme ---

method isDark*(t: Theme): bool {.base.} = false
## setSource is "system", "light" or "dark".
method setSource*(t: Theme, source: string) {.base.} = discard
## uiFont returns the family of the desktop's interface font where the
## system's text stack does not know it, as on Linux, else "".
method uiFont*(t: Theme): string {.base.} = ""
## fontRendering returns how the desktop's settings say to rasterize
## text where the system's text stack does not know them, as on Linux.
method fontRendering*(t: Theme): FontRendering {.base.} = FontRendering()
## preferences returns the settings of the desktop that the system's
## controls follow. A change of any of them calls AppHandler.themeChanged.
method preferences*(t: Theme): Preferences {.base.} = Preferences()

## --- Power ---

## watch starts reporting AppHandler.powerEvent.
method watch*(p: Power) {.base.} = discard
## keepAwake keeps the system, and with display the display, from
## sleeping while idle until release is called.
method keepAwake*(p: Power, display: bool, reason: string): ReleaseProc {.base.} = nil
method onBattery*(p: Power): bool {.base.} = false
method idleTime*(p: Power): Duration {.base.} = initDuration()

## --- Network ---

## watch starts reporting AppHandler.networkChanged, which may also be
## called when the status stayed the same.
method watch*(n: Network) {.base.} = discard
method status*(n: Network): NetworkStatus {.base.} = NetworkStatus()

## --- Secrets ---

method setSecret*(s: Secrets, service, account: string, secret: seq[byte]) {.base.} =
  raise errUnsupported()
## secret's err satisfies isErrSecretNotFound when there is none.
method secret*(s: Secrets, service, account: string):
    tuple[secret: seq[byte], err: ref CatchableError] {.base.} =
  (@[], errUnsupported())
## deleteSecret succeeds when there is no secret to delete.
method deleteSecret*(s: Secrets, service, account: string) {.base.} =
  raise errUnsupported()

## --- TrayHandler ---

method clicked*(h: TrayHandler) {.base.} = discard
method rightClicked*(h: TrayHandler) {.base.} = discard

## --- Tray ---

method setImage*(t: Tray, png: seq[byte], `template`: bool) {.base.} = discard
method setTitle*(t: Tray, title: string) {.base.} = discard
method setToolTip*(t: Tray, tip: string) {.base.} = discard
method setMenu*(t: Tray, m: Menu) {.base.} = discard
method popUpMenu*(t: Tray, m: Menu) {.base.} = discard
method bounds*(t: Tray): Rect {.base.} = Rect()
method destroy*(t: Tray) {.base.} = discard

## --- AppController ---

method setActivationPolicy*(a: AppController, policy: string) {.base.} = discard
method activate*(a: AppController) {.base.} = discard
method hide*(a: AppController) {.base.} = discard
method unhide*(a: AppController) {.base.} = discard
method isHidden*(a: AppController): bool {.base.} = false
method setBadge*(a: AppController, label: string) {.base.} = discard
method badge*(a: AppController): string {.base.} = ""
## bounce requests user attention and returns an id for cancelBounce.
method bounce*(a: AppController, critical: bool): int {.base.} = 0
method cancelBounce*(a: AppController, id: int) {.base.} = discard
method setDockIcon*(a: AppController, png: seq[byte]) {.base.} =
  raise errUnsupported()
## setDockMenu sets the menu of the Dock icon (macOS); nil removes it.
method setDockMenu*(a: AppController, m: Menu) {.base.} = discard
## clearBrowsingData deletes the data pages stored; done runs on the
## main thread.
method clearBrowsingData*(a: AppController, done: proc(err: ref CatchableError)) {.base.} = discard
## Cookie operations address the default page store. Calls and
## exactly-once completions run on main; listCookies returns
## independent values.
method listCookies*(a: AppController,
    done: proc(c: seq[Cookie], err: ref CatchableError)) {.base.} = discard
method setCookie*(a: AppController, cookie: Cookie,
    done: proc(err: ref CatchableError)) {.base.} = discard
method deleteCookie*(a: AppController, key: CookieKey,
    done: proc(err: ref CatchableError)) {.base.} = discard
method showAboutPanel*(a: AppController, opts: AboutPanelOptions) {.base.} = discard
## preferredLanguages returns the languages the user reads, most
## preferred first, as the system's settings list them, in the forms
## the system writes them (the core normalizes them): never what the
## app chose for itself (saveLocale). Safe before init.
method preferredLanguages*(a: AppController): seq[string] {.base.} = @[]
## region returns the user's regional formats. Safe before init.
method region*(a: AppController): Region {.base.} = Region()
## savedLocale returns the language the app chose for itself, as the
## system keeps it, and whether the system keeps one at all (macOS:
## AppleLanguages in the app's own defaults; browsers: localStorage).
## Where it keeps none, the core keeps it in a file. Safe before init.
method savedLocale*(a: AppController): tuple[tag: string, kept: bool] {.base.} = ("", false)
## saveLocale keeps tag where savedLocale reads it, "" to forget it,
## and reports whether the system keeps one at all.
method saveLocale*(a: AppController, tag: string): bool {.base.} = false
## setLanguages tells the backend the languages the app shows, its own
## language first, and whether it is laid out right to left, for what
## shows text the core does not draw: the web views it creates later
## and, where it can change, those it created, and the system's own
## texts and widgets.
method setLanguages*(a: AppController, tags: seq[string], rtl: bool) {.base.} = discard
## registerURLScheme makes the app, identified by id (its identifier)
## and named name, the handler of the URLs of scheme for the user.
method registerURLScheme*(a: AppController, scheme, id, name: string) {.base.} =
  raise errUnsupported()
method unregisterURLScheme*(a: AppController, scheme, id, name: string) {.base.} =
  raise errUnsupported()
method isURLSchemeRegistered*(a: AppController, scheme, id, name: string): bool {.base.} = false
## setOpenAtLogin makes the app start at login, passing arg where the
## start command takes arguments; openAtLogin reports whether it does
## so without one (macOS login items).
method setOpenAtLogin*(a: AppController, open: bool, id, name, arg: string) {.base.} =
  raise errUnsupported()
method openAtLogin*(a: AppController, id, name, arg: string): bool {.base.} = false
## openedAtLogin reports whether the system started it so.
method openedAtLogin*(a: AppController): bool {.base.} = false
## package describes the application bundle the process runs from; ok
## is false for a plain executable (e.g. `nimble run`). Safe to call
## from any thread, before init too.
method `package`*(a: AppController): tuple[info: PackageInfo, ok: bool] {.base.} =
  (PackageInfo(), false)
## addRecentDocument records the absolute path of a document the user
## opened in the system's recent documents; clearRecentDocuments
## removes the ones the app recorded.
method addRecentDocument*(a: AppController, path: string) {.base.} = discard
method clearRecentDocuments*(a: AppController) {.base.} = discard
## setJumpListTasks sets the Tasks category of the app's jump list
## (Windows); elsewhere it does nothing.
method setJumpListTasks*(a: AppController, tasks: seq[JumpListTask]) {.base.} = discard

## --- Backend ---

## name identifies the backend, for example "darwin/wkwebview".
method name*(b: Backend): string {.base.} = "unsupported"

## init prepares the native application. It is called once, on the
## main thread, before run.
method init*(b: Backend, h: AppHandler, opts: AppOptions) {.base.} =
  raise errUnsupported()
## run runs the native event loop until quit is called. h.ready is
## invoked once the application has finished launching.
method run*(b: Backend) {.base.} =
  raise errUnsupported()
## quit makes run return.
method quit*(b: Backend) {.base.} = discard

## isMainThread reports whether the caller runs on the UI thread. Safe
## to call from any thread.
method isMainThread*(b: Backend): bool {.base.} = false
## signal asks the backend to invoke AppHandler.dispatch on the main
## thread as soon as possible. Safe to call from any thread.
method signal*(b: Backend) {.base.} = discard
## step blocks until at least one native event has been processed or
## wake has been called. Main thread only; used for nested waits.
method step*(b: Backend) {.base.} = discard
## wake unblocks a pending step. Safe to call from any thread.
method wake*(b: Backend) {.base.} = discard

method newWindow*(b: Backend, opts: WindowOptions,
                  h: WindowHandler): tuple[w: Window, err: ref CatchableError] {.base.} =
  (nil, errUnsupported())

method setApplicationMenu*(b: Backend, m: Menu) {.base.} = discard
## popupMenu shows a context menu. pos is relative to the window's
## content area; nil means the current mouse location. It blocks until
## the menu is dismissed.
method popupMenu*(b: Backend, m: Menu, w: Window, pos: ref Point) {.base.} = discard
## updateMenuItem refreshes label/state of every native item created
## for item.id.
method updateMenuItem*(b: Backend, item: MenuItem) {.base.} = discard

method app*(b: Backend): AppController {.base.} = nil
method dialogs*(b: Backend): Dialogs {.base.} = nil
method clipboard*(b: Backend): Clipboard {.base.} = nil
method shell*(b: Backend): Shell {.base.} = nil
method screen*(b: Backend): Screen {.base.} = nil
method theme*(b: Backend): Theme {.base.} = nil
method power*(b: Backend): Power {.base.} = nil
method network*(b: Backend): Network {.base.} = nil
## secrets may be called before init, from any thread.
method secrets*(b: Backend): Secrets {.base.} = nil
## applications lists the applications installed on the computer.
## Unlike other methods it may be called from any thread once init
## returned: it reads the disk, which the core does off the main thread.
method applications*(b: Backend): tuple[apps: seq[Application], err: ref CatchableError] {.base.} =
  (@[], errUnsupported())

## newFileWatch starts watching files, with no target yet. notify is
## called on a thread of the backend, one notice at a time. May be
## called before init, from any thread.
method newFileWatch*(b: Backend, notify: proc(n: FileWatchNotice)):
    tuple[w: FileWatch, err: ref CatchableError] {.base.} =
  (nil, errUnsupported())
## replaceFile replaces the file at target with the file at
## replacement, in the same directory, keeping what the system keeps of
## the target's metadata (permissions, owner, extended attributes,
## creation date); replacement is gone afterwards. It may be called
## before init, from any thread.
method replaceFile*(b: Backend, target, replacement: string) {.base.} =
  raise errUnsupported()

method newTray*(b: Backend, h: TrayHandler): tuple[t: Tray, err: ref CatchableError] {.base.} =
  (nil, errUnsupported())
method registerHotkey*(b: Backend, id: int, accelerator: string) {.base.} =
  raise errUnsupported()
method unregisterHotkey*(b: Backend, id: int) {.base.} = discard

method notificationsSupported*(b: Backend): bool {.base.} = false
## showNotification shows n; done runs on the main thread once the
## system has it, or with why it could not.
method showNotification*(b: Backend, n: Notification, done: proc(err: ref CatchableError)) {.base.} = discard
method removeNotification*(b: Backend, id: string) {.base.} = discard
## removeAllNotifications removes the app's notifications, on macOS
## those of earlier runs too.
method removeAllNotifications*(b: Backend) {.base.} = discard

## webViewSupported reports whether the system webview is there, and so
## whether windows showing web pages can work: WKWebView on macOS,
## WebKitGTK on Linux, the WebView2 Runtime on Windows. A window
## showing native UI needs none, so an app whose windows all do runs
## without one.
method webViewSupported*(b: Backend): bool {.base.} = false
