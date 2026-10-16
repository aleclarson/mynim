## Forward declarations and shared type fields of the root package, in
## one type block so the parts may reference each other's types, like
## Go's package scope. Types whose fields are not needed by others stay
## in their own parts.

type
  WindowStateStore* = ref object of RootObj
    ## Keeps the states of the windows with a WindowOptions.stateKey,
    ## by key, for app.setWindowStateStore. MyNim calls it on the main
    ## thread, so it should return quickly.

  Content* = surface.Content
    ## What a window shows in place of a web page (package ui).

  TitleBarStyle* = distinct string
    ## Selects how the title bar of a framed window looks.

  DevTools* = enum
    ## Selects whether the web inspector is available.
    devToolsAuto
      ## enables the inspector unless the app was built for production
      ## with `mynim build`.
    devToolsEnabled
    devToolsDisabled

  Point* = object
    ## A position in screen coordinates.
    x*, y*: int

  Size* = object
    ## A width and height in DIPs.
    width*, height*: int

  Rectangle* = object
    ## A position and size in screen coordinates (DIPs, origin at the
    ## top-left corner of the primary display).
    x*, y*, width*, height*: int

  Vibrancy* = distinct string
    ## A translucent material behind a transparent window (macOS and
    ## Windows 11 22H2).

  ProgressState* = distinct string
    ## The state a window's progress bar shows.

  ProgressBar* = object
    ## Progress shown on the window's taskbar or Dock icon.
    state*: ProgressState
    ## value is the progress between 0 and 1; -1 is indeterminate.
    value*: float64

  Permission* = distinct string
    ## Something a page asks the user for.

  PermissionRequest* = object
    ## Passed to the permission handler of a window.
    ## permissions asked for together, such as the camera and the
    ## microphone of a video call.
    permissions*: seq[Permission]
    ## origin of the page asking, e.g. "https://example.com".
    origin*: string

  LoadError* = ref object of CatchableError
    ## Describes a failed page load.
    url*: string
    code*: int
    description*: string

  EvalError* = ref object of CatchableError
    ## An error the page's JavaScript threw.
    message*: string

  WindowOpenRequest* = object
    ## Describes a window.open() call or a click on a target="_blank"
    ## link.
    url*: string
    frameName*: string
    ## width and height requested through window.open() features; 0
    ## when not specified.
    width*, height*: int

  PageOptions* = object
    ## Configures the web page a window shows.
    ## devTools selects whether the web inspector is available.
    devTools*: DevTools
    ## preloadScript runs before the page's scripts on every load.
    preloadScript*: string
    ## trustedOrigins lists the origins whose pages may call bound
    ## methods, like "https://app.example.com" — the app's own
    ## mygo://app origin is always trusted. Empty trusts the same.
    trustedOrigins*: seq[string]
    ## acceptDroppedFiles lets the page receive file drops.
    acceptDroppedFiles*: bool
    ## zoomFactor is the page's zoom (default 1).
    zoomFactor*: float64
    ## userAgent overrides the user agent string.
    userAgent*: string

  WindowOptions* = object
    ## Configures newWindow. The zero value is a visible, resizable
    ## 800x600 window centered on screen.
    ## title of the window. Defaults to the application name. The title
    ## follows the page's <title> unless an onPageTitleUpdated listener
    ## prevents it.
    title*: string
    ## url is loaded right after the window is created. "/" and other
    ## URLs without a scheme are pages of the app's frontend.
    url*: string
    ## width and height of the window in DIPs (default 800x600).
    width*, height*: int
    ## useContentSize makes width and height describe the page area
    ## instead of the whole window.
    useContentSize*: bool
    ## x and y of the top-left corner. The window is centered when both
    ## are zero.
    x*, y*: int
    minWidth*, minHeight*: int
    maxWidth*, maxHeight*: int
    ## hidden creates the window without showing it. Call show,
    ## typically from onReadyToShow, to avoid a blank window while the
    ## page loads.
    hidden*: bool
    ## frameless removes the title bar and window chrome. Mark
    ## draggable areas with the CSS `--app-region: drag`.
    frameless*: bool
    ## titleBarStyle hides the title bar but keeps the window controls,
    ## so the page fills the window and draws its own title bar under
    ## them: the traffic lights on macOS, and minimize, maximize and
    ## close at the top corner on Linux and Windows.
    titleBarStyle*: TitleBarStyle
    ## trafficLightPosition moves the window controls of a window with
    ## a hidden title bar (macOS): the top-left corner of the close
    ## button goes this far from the top-left corner of the window.
    trafficLightPosition*: ptr Point
    ## titleBarHeight is the height of the title bar that the page of a
    ## window with a hidden title bar draws (Linux, Windows). Zero is
    ## 32 on Windows and the height of the desktop's header bars on
    ## Linux.
    titleBarHeight*: int
    disableResize*: bool
    disableMove*: bool
    disableMinimize*: bool
    disableMaximize*: bool
    disableClose*: bool
    disableFullScreen*: bool
    disableShadow*: bool
    alwaysOnTop*: bool
    fullScreen*: bool
    ## maximized creates the window maximized.
    maximized*: bool
    ## skipTaskbar hides the window from the taskbar (Linux, Windows).
    skipTaskbar*: bool
    ## autoHideMenuBar keeps the window's menu bar out of sight until
    ## the user presses Alt or F10 (Linux, Windows). Its keyboard
    ## shortcuts work all along.
    autoHideMenuBar*: bool
    ## transparent makes the window background transparent, so a page
    ## with a transparent background shows the desktop through.
    transparent*: bool
    ## backgroundColor fills the window until the page paints, which
    ## avoids a flash of another color while it loads. CSS syntax:
    ## "#1e1e1e", "#rgba", "rgb(30 30 30)", or
    ## "light-dark(#f5f5f7, #1e1e1e)" for a page that follows the light
    ## or dark appearance.
    backgroundColor*: string
    ## vibrancy puts a translucent, blurred material behind a
    ## transparent page, or behind native UI where it draws no
    ## background (macOS and Windows 11 22H2), e.g. vibrancySidebar.
    vibrancy*: Vibrancy
    ## opacity of the window between 0 and 1 (default 1).
    opacity*: float64
    ## parent makes this window a child window that stays on top of it.
    parent*: Window
    ## modal makes a child window modal to its parent.
    modal*: bool
    ## panel makes the window a panel, as the windows of launchers and
    ## quick entry (Spotlight, Raycast) are: it floats above the
    ## windows of all apps, on whichever Space or virtual desktop the
    ## user is on, over full-screen apps too, and stays out of the
    ## taskbar, the Dock and the app switcher. It cannot be minimized,
    ## maximized or go full screen. On macOS, showing or focusing it
    ## gives it the keyboard without activating the app, so the app the
    ## user was in stays active and gets the keyboard back when the
    ## panel hides.
    panel*: bool
    ## page configures the window's web page.
    page*: PageOptions
    ## stateKey remembers the window's position, size, and maximized
    ## and full screen state under this key, in window-state.json in
    ## pathUserData or the store of app.setWindowStateStore, saved when
    ## the window closes and when the app quits. A window created with
    ## the same key, for example at the next launch, gets them back as
    ## long as it would show on a connected display.
    stateKey*: string
    ## content makes the window show a user interface MyNim draws
    ## itself, on the GPU where it can, instead of a web page: create
    ## it with package ui. The window then has no page (Window.page is
    ## nil): url and page are ignored.
    content*: Content

  WindowState* = object
    ## What WindowOptions.stateKey remembers of a window: its bounds in
    ## the normal state, which it gets back when it leaves the
    ## maximized or full screen state, and that state.
    x*: int
    y*: int
    width*: int
    height*: int
    maximized*: bool
    fullScreen*: bool

  HtmlDocument* = ref object of RootObj
    ## A document loadHTML loaded.
    html*, baseURL*: string
    ## shown is set once the page committed it.
    shown*: bool

  PathName* = enum
    ## Names a well known directory for Application.path.
    pathHome ## ~
    pathAppData
      ## The per-user application data directory: ~/Library/Application
      ## Support, $XDG_CONFIG_HOME or %AppData%.
    pathUserData
      ## pathAppData joined with the application name. Created on first
      ## use.
    pathCache
      ## The per-user cache directory of this application. Created on
      ## first use.
    pathLogs
      ## Where the application should write logs. Created on first use.
    pathResources
      ## The directory of the files the app ships with: the contents of
      ## the project's resources directory, with those of its
      ## directories for the app's platform merged in, and the
      ## resources listed in mynim.config.ts, which `mynim dev` and
      ## `mynim build` copy there.
    pathTemp
    pathExe
    pathDesktop
    pathDocuments
    pathDownloads
    pathMusic
    pathPictures
    pathVideos

  MenuItemType* = enum
    ## The kind of a menu item, inferred when menuItemNormal and a
    ## submenu is set.
    menuItemNormal
    menuItemSeparator
    menuItemSubmenu
    menuItemCheckbox
    menuItemRadio

  MenuRole* = enum
    ## Gives a menu item a predefined behavior, label and accelerator.
    roleNone, roleUndo, roleRedo, roleCut, roleCopy, rolePaste,
    rolePasteAndMatchStyle, roleDelete, roleSelectAll, roleReload,
    roleForceReload, roleToggleDevTools, roleResetZoom, roleZoomIn,
    roleZoomOut, roleToggleFullScreen, roleMinimize, roleZoom, roleClose,
    roleNew, roleOpen, roleOpenRecent, roleSave, roleSaveAs,
    roleDuplicate, roleRename, roleMoveTo, roleRevert, roleQuit,
    roleAbout, roleHide, roleHideOthers, roleUnhide, roleFront,
    roleServices, roleStartSpeaking, roleStopSpeaking, roleWindow,
    roleHelp, roleAppMenu, roleFileMenu, roleEditMenu, roleViewMenu,
    roleWindowMenu, roleFormatMenu, roleBold, roleItalic, roleUnderline,
    roleStrikethrough, roleAlignLeft, roleAlignCenter, roleAlignRight

  MenuItem* = ref object of RootObj
    ## An entry of a Menu. Fill in the fields to build a menu template;
    ## after the item has been added to a menu, change its state with
    ## the set methods so native menus update.
    id*: string ## identifies the item for menu.itemByID
    label*: string
    `type`*: MenuItemType
    ## role gives the item a predefined behavior; label and accelerator
    ## default to the role's.
    role*: MenuRole
    ## accelerator is a keyboard shortcut such as "CmdOrCtrl+Shift+N".
    accelerator*: string
    disabled*: bool
    hidden*: bool
    ## checked is the state of checkbox and radio items. It is toggled
    ## before click is called.
    checked*: bool
    toolTip*: string
    submenu*: seq[MenuItem]
    ## click is called on the main thread when the item is chosen. On
    ## Linux and Windows, win is the window whose menu bar or context
    ## menu was chosen. Other menus use the focused window, which may
    ## be nil.
    click*: proc(item: MenuItem; win: Window) {.closure.}

    uid: int
    parent: Menu
    sub: Menu
    ## roleLabel is the label the item took from its role, which says
    ## it in the language the app shows for as long as the app gives
    ## the item no label of its own (relabelMenus).
    roleLabel: string

  Menu* = ref object of RootObj
    ## A list of menu items used as application menu, window menu,
    ## context menu or tray menu.
    items: seq[MenuItem]

  Page* = ref object of RootObj
    ## The web page a window shows: what it loads, the scripts it runs,
    ## its developer tools and its events. A window showing native UI
    ## (WindowOptions.content) has none.
    w: Window

  WebView* = ref object of surface.SurfaceWebView
    ## A web view a window showing native UI embeds.
    w: Window
    pw: platform.WebView

  ## A message of the bridge protocol (JSON object text), in parts that
  ## are joined when it is sent, so that an encoded value, which can be
  ## large, is not copied into it.
  Message* = object
    head*, value*, tail*: string

  ## Placement is where a flyout goes from its anchor: the side, and
  ## how it lines up with the anchor along that side, as in
  ## "bottom-start", below the anchor with their left edges lined up.
  Placement* = distinct string

  ## FlyoutOptions configures newFlyout.
  FlyoutOptions* = object
    ## parent owns the flyout, which stays above it, follows it as it
    ## moves and closes with it. A flyout has a parent or a tray.
    parent*: Window
    ## tray anchors the flyout to a tray icon instead, as the panel of
    ## a menu bar app: it goes next to the icon, on the side placement
    ## names, and floats above the windows of other apps. anchor does
    ## not apply.
    tray*: Tray
    ## anchor is the rectangle the flyout is placed against, in DIPs
    ## relative to the parent's content area: the box of the element
    ## that opens it, as ui.Element.bounds gives it, or a point, such
    ## as the pointer's.
    anchor*: Rectangle
    ## placement is where the flyout goes from anchor (default
    ## placementBottomStart).
    placement*: Placement
    ## gap is the distance between anchor and the flyout, in DIPs.
    gap*: int
    ## width and height of the flyout in DIPs (default 200x200).
    width*, height*: int
    ## focusable makes the flyout take the keyboard as it shows, and
    ## close as a menu does when the user presses outside it.
    focusable*: bool
    ## hidden creates the flyout without showing it.
    hidden*: bool
    ## shadow gives the flyout the system's window shadow (macOS,
    ## Windows).
    shadow*: bool
    ## popover gives the flyout the look of the system's popovers on
    ## macOS.
    popover*: bool
    ## url is loaded right after the flyout is created, as
    ## WindowOptions.url.
    url*: string
    ## page configures the flyout's web page.
    page*: PageOptions
    ## content makes the flyout show native UI instead of a web page,
    ## as WindowOptions.content.
    content*: Content

  ## flyoutOptions carries what newWindow needs of a flyout: its
  ## tray's native icon is read on the main thread.
  FlyoutOpts = object
    flyout: platform.Flyout
    tray: Tray

  ## WebViewOptions configure window.newWebView.
  WebViewOptions* = object
    ## url is loaded right away. "/" and other URLs without a scheme
    ## are pages of the app's frontend (see page.loadURL).
    url*: string
    ## page configures the web view's page.
    page*: PageOptions
    ## backgroundColor fills the web view until its page paints, as
    ## WindowOptions.backgroundColor does; by default the page's, or
    ## white.
    backgroundColor*: string
    ## transparent shows what the window's view paints under the web
    ## view through the transparent parts of its page.
    transparent*: bool

  ## FindOptions configures page.findInPage.
  FindOptions* = object
    ## matchCase finds only text with the same capitalization.
    matchCase*: bool
    ## backward goes to the previous match rather than the next one.
    backward*: bool
    ## findNext moves on from the current match of the same text.
    findNext*: bool

  ## FindResult reports the matches of page.findInPage.
  FindResult* = object
    matches*, active*: int

  ## A timer for window-state capture (Go's time.AfterFunc): reset
  ## re-arms it, stop cancels it.
  StateTimer = ref object of RootObj
    generation: Atomic[int64]
    stopped: Atomic[bool]
    d: Duration
    fn: proc() {.closure.}

  ChannelObj* = object
    ## A channel carrying values between a page and a bound method.
    w: Window
    id: int64 ## the page's
    token: string
    ctx: CancelCtx ## the call's
    ## cancel ends the call's context when the page closes the channel.
    cancel: proc() {.closure.}
    ## head and ackHead start its values' messages, the latter asking
    ## for an acknowledgment.
    head, ackHead: string
    mu: Lock
    cond: Cond
    closed: bool
    ## stop stops closing it with ctx. It is set once the page can
    ## close the channel, so a close may find it nil and leave it to
    ## newChannel.
    stop: proc(): bool {.closure.}
    ## Flow control, in bytes: sent, taken by the page as far as it
    ## said, and sent when an acknowledgment was last asked for, by seq.
    `seq`, sent, taken, asked: int64
    asks: seq[ChannelAsk]

  Channel*[T] = ref object of RootObj
    ## A stream of values from a bound method to the page that called
    ## it, arriving in order and before the call's result: the lines a
    ## command prints, the tokens of a model's answer, the progress of
    ## a download. See send and close.
    c: ref ChannelObj

  Event*[T] = ref object of RootObj
    ## A typed event the app sends to pages (ipc.nim, newEvent).
    name*: string

  ChannelAsk* = object
    `seq`, sent: int64

  Window* = ref object of RootObj
    ## A native window hosting a web page, or the content of package
    ## ui. Create windows with newWindow once the application is ready.
    id: int
    parent: Window
    ## flyout places a window newFlyout created, at flyoutSize, the
    ## size it asked for. Main thread only.
    flyout: platform.Flyout
    flyoutSize: platform.Size
    ## panel is WindowOptions.panel.
    panel: bool
    ## host is the window a web view is in, for the page of a web view
    ## (webView); webViews are the pages of a window's web views,
    ## guarded by the lock of windows.
    host: Window
    webView: WebView
    webViews: seq[Window]
    ## pg is the window's page, which page returns unless the window
    ## shows native UI.
    pg: Page
    ## content is WindowOptions.content; conn connects it to the native
    ## surface (main thread only). devTools tells that
    ## PageOptions.devTools turned the developer tools on: the web
    ## inspector, or the inspector of the Content.
    content: Content
    conn: surface.Conn
    devTools: bool
    invalidating: Atomic[bool]
    ## secret starts every message of the bridge in this window's
    ## pages. Only the bridge knows it, so messages posted from
    ## elsewhere (an iframe of another origin) are ignored.
    secret: string
    ## preload is PageOptions.preloadScript, which the scripts of the
    ## pages loaded later keep (pageScripts).
    preload: string
    ## native is only accessed on the main thread; nil once destroyed.
    native: platform.Window
    destroyed: Atomic[bool]
    shown: bool
    readyShow: bool
    ## background is the backgroundColor, if any. Main thread only.
    background: ref Background
    ## hiddenTitleBar is a titleBarStyle that hides the title bar: the
    ## pages hear the room the window controls take. Main thread only.
    hiddenTitleBar: bool
    ## hasVibrancy reports whether native UI can draw over the material.
    hasVibrancy: bool
    menu: Menu
    ## title is the title the app or the page set; representedFile and
    ## documentEdited are the document the window shows. Main thread
    ## only.
    title: string
    representedFile: string
    documentEdited: bool
    ## stateKey is WindowOptions.stateKey; stateTimer captures the
    ## state once it settled. Main thread only.
    stateKey: string
    stateTimer: StateTimer
    ## trusted reports whether the current page may call bound methods.
    ## Main thread only.
    trusted: bool
    trustedOrigins: seq[string]
    ## html is the document loadHTML loaded, while it is the page's or
    ## about to be. Main thread only.
    html: HtmlDocument

    mu: Lock
    openHandler: proc(req: WindowOpenRequest): ref WindowOptions {.closure.}
    permissionHandler: proc(req: PermissionRequest): bool {.closure.}
    pageCtx: CancelCtx
    pageCancel: proc() {.closure.}
    ## channels are those of the current page, by the page's id for
    ## them.
    channels: Table[int64, ref ChannelObj]
    ## closedEarly holds the channels the current page closed before
    ## their calls made them, with the page's token.
    closedEarly: Table[int64, string]

    outMu: Lock
    outbox: seq[Message]
    flushing: bool
    ## held keeps events until the page's DOM is ready, so events sent
    ## right after creating a window or during a navigation are not
    ## lost.
    held: seq[Message]
    domReady: bool

    onClose: Listeners[proc(e: var CloseEvent) {.closure.}]
    onClosed: Listeners[proc() {.closure.}]
    onFocus: Listeners[proc() {.closure.}]
    onBlur: Listeners[proc() {.closure.}]
    onShow: Listeners[proc() {.closure.}]
    onHide: Listeners[proc() {.closure.}]
    onReadyToShow: Listeners[proc() {.closure.}]
    onResize: Listeners[proc() {.closure.}]
    onFileDrop: Listeners[proc(e: var FileDropEvent) {.closure.}]
    onWillDownload: Listeners[proc(e: var DownloadEvent) {.closure.}]
    onDownloadDone: Listeners[proc(d: Download) {.closure.}]
    onMove: Listeners[proc() {.closure.}]
    onMaximize: Listeners[proc() {.closure.}]
    onUnmaximize: Listeners[proc() {.closure.}]
    onMinimize: Listeners[proc() {.closure.}]
    onRestore: Listeners[proc() {.closure.}]
    onEnterFullScreen: Listeners[proc() {.closure.}]
    onLeaveFullScreen: Listeners[proc() {.closure.}]
    onPageTitleUpdated: Listeners[proc(e: var TitleEvent) {.closure.}]
    onWillNavigate: Listeners[proc(e: var NavigateEvent) {.closure.}]
    onDidNavigate: Listeners[proc(url: string) {.closure.}]
    onDOMReady: Listeners[proc() {.closure.}]
    onDidFinishLoad: Listeners[proc() {.closure.}]
    onDidFailLoad: Listeners[proc(e: LoadError) {.closure.}]
    onRenderGone: Listeners[proc(reason: string) {.closure.}]

  Tray* = ref object of RootObj
    ## An icon in the menu bar (macOS) or notification area.
    native: platform.Tray
    menu: Menu
    onClick: Listeners[proc() {.closure.}]
    onRight: Listeners[proc() {.closure.}]

  Notification* = ref object of RootObj
    ## A desktop notification.
    id: string
    opts: NotificationOptions
    onClick: Listeners[proc() {.closure.}]

  NotificationOptions* = object
    ## Configures a notification.
    ## id identifies the notification: app.onNotificationClick receives
    ## it, also after the app has quit and been launched again, and
    ## showing a notification with the ID of one still shown replaces
    ## that one. Empty gives it an ID of its own.
    id*: string
    title*: string
    subtitle*: string
    body*: string
    ## silent suppresses the notification sound.
    silent*: bool
    ## group gathers the notifications that share it in one stack of
    ## Notification Center (macOS), such as the messages of a
    ## conversation. Empty leaves them in the app's.
    group*: string

  Dock* = ref object of RootObj
    ## Controls the application's Dock icon (macOS). Its methods do
    ## nothing on other platforms.
    mu: Lock
    menu: Menu

  Download* = ref object of RootObj
    ## A download in progress.
    url*: string
    path*: string
    ## err is why the download failed, or nil.
    err*: ref CatchableError

  DownloadEvent* = object
    ## Passed to Page.onWillDownload listeners.
    preventable*: Preventable
    url*, suggestedName*: string
    ## path is where the download will be saved; set it to change it,
    ## "" to cancel.
    path*: string

  ActivationPolicy* = enum
    ## Controls how a macOS application appears in the Dock and app
    ## switcher.
    policyRegular ## an ordinary app with a Dock icon and menu bar
    policyAccessory
      ## hides the Dock icon; windows can still be shown. Typical for
      ## menu bar (tray) apps.
    policyProhibited ## hides the app entirely

  Application* = ref object of RootObj
    ## Controls the event loop and the lifecycle of the process.
    ## Use the app singleton.
    mu: Lock
    name: string
    version: string
    policy: ActivationPolicy
    policySet: bool
    running: bool
    ready: bool
    readyCh: system.Channel[bool]
    whenReady: seq[proc() {.closure.}]
    menu: Menu
    menuSet: bool
    paths: Table[PathName, string]
    ## stateStore is the WindowStateStore, or nil for the file.
    stateStore: WindowStateStore
    finishedOnce: Atomic[bool]

    # quitting is only touched on the main thread.
    quitting: bool
    relaunch: bool ## relaunch: start again once quit (main thread)
    initialized: bool ## run initialized the backend (main thread)

    dock*: Dock ## controls the Dock icon on macOS

    onReady: Listeners[proc() {.closure.}]
    onWindowAllClosed: Listeners[proc() {.closure.}]
    onBeforeQuit: Listeners[proc(e: var QuitEvent) {.closure.}]
    onWillQuit: Listeners[proc(e: var QuitEvent) {.closure.}]
    onQuit: Listeners[proc() {.closure.}]
    onActivate: Listeners[proc(v: bool) {.closure.}]
    onDidBecomeActive: Listeners[proc() {.closure.}]
    onDidResignActive: Listeners[proc() {.closure.}]
    onOpenURL: Listeners[proc(u: string) {.closure.}]
    onOpenFile: Listeners[proc(p: string) {.closure.}]
    onWindowCreated: Listeners[proc(w: Window) {.closure.}]
    onNotificationClick: Listeners[proc(id: string) {.closure.}]

  AboutPanelOptions* = object
    ## Customizes the standard about panel.
    applicationName*: string
    applicationVersion*: string
    ## version is the build version shown next to applicationVersion.
    version*: string
    copyright*: string
    credits*: string


  ShellModule* = object
    ## Integrates with the desktop environment.

  ProtocolModule* = ref object of RootObj
    ## Serves custom URL schemes such as app:// from Nim
    ## (protocol.nim).
    mu: Lock
    handlers: Table[string, HttpHandler]

  ClipboardModule* = object
    ## Reads and writes the system clipboard.

  SecretsModule* = object
    ## Keeps small secrets, such as access tokens and API keys, in the
    ## system's credential store.

  InstalledApp* = object
    ## An application installed on the computer, which
    ## shell.installedApps lists.
    name*: string
    id*: string
    path*: string

  Display* = object
    ## Describes a monitor.
    id*: int64
    label*: string
    ## bounds is the area of the display in screen coordinates.
    bounds*: Rectangle
    ## workArea excludes the menu bar, Dock and taskbars.
    workArea*: Rectangle
    scaleFactor*: float64
    rotation*: int
    internal*: bool
    primary*: bool

  ScreenModule* = ref object of RootObj
    ## Queries displays.
    onChanged: Listeners[proc() {.closure.}]

  ThemeSource* = distinct string
    ## Selects the appearance of the app.

  ThemePreferences* = object
    ## The accent color and the accessibility settings of the desktop.
    accent*: Color
    reduceMotion*: bool
    highContrast*: bool
    textScale*: float64

  ThemeModule* = ref object of RootObj
    ## Reads and overrides the light/dark appearance.
    mu: Lock
    source: ThemeSource
    onUpdated: Listeners[proc() {.closure.}]
    # The preferences read last, until the next change. Main thread only.
    prefs: ThemePreferences
    prefsOK: bool

  GlobalShortcutModule* = ref object of RootObj
    ## Registers system wide keyboard shortcuts.
    mu: Lock
    next: int
    byKey: Table[string, int]
    byID: Table[int, proc() {.closure.}]
    keyByID: Table[int, string]

  NetworkStatus* = object
    ## The state of the computer's network connection.
    online*: bool
    constrained*: bool

  NetworkModule* = ref object of RootObj
    ## Reports whether the computer is online.
    mu: Lock
    watching: bool
    last: NetworkStatus
    onChanged: Listeners[proc(s: NetworkStatus) {.closure.}]

  PowerModule* = object
    ## Reports power and session changes and keeps the computer awake.
    mu: Lock
    watching: bool
    onSuspend, onResume, onLockScreen, onUnlockScreen:
      Listeners[proc() {.closure.}]

  ClipboardOptions* = object
    ## Configures the lifetime of a clipboard write.
    ## onRelease runs once on the main thread after native providers
    ## are no longer needed: replacement, clear, flush, or application
    ## shutdown.
    onRelease*: proc() {.closure.}

  TrayOptions* = object
    ## Configures newTray.
    icon*: seq[byte]
    iconIsTemplate*: bool
    title*: string
    toolTip*: string
    menu*: Menu

  ## Region is the user's regional formats (app.region).
  Region* = i18n.Region

  ## ShownLocale is the language and the formats the app shows.
  ShownLocale = ref object of RootObj
    locale*: string
    preferred*: seq[string]
    region*: Region

  ## LocaleState is what the app knows of its languages. Guarded by mu
  ## but shown, which the main thread sets and every thread reads.
  LocaleState = object
    mu*: Lock
    ## languages are those setLanguages set, or empty for the
    ## catalogs'.
    languages*: seq[string]
    ## override is the language the app chose (setLocale, the one
    ## saved, or MYNIM_LOCALE), "" to follow the user's; fromEnv tells
    ## that MYNIM_LOCALE set it, which makes setLocale save nothing.
    override*: string
    fromEnv*: bool
    ## loaded tells that the saved language and MYNIM_LOCALE were
    ## read.
    loaded*: bool
    ## chosen tells that setLocale chose the language, which reading
    ## the saved one again does not undo.
    chosen*: bool
    ## generation counts the setLocale calls; the work they queue runs
    ## for the last one only.
    generation*: uint64
    ## shown is what the app shows, as the windows and listeners last
    ## heard of it, nil before anything asked.
    shown*: Atomic[ShownLocale]
    onLocaleChanged*: Listeners[proc(l: string) {.closure.}]
    onRegionChanged*: Listeners[proc(r: Region) {.closure.}]


const
  titleBarDefault* = TitleBarStyle"default"
  ## titleBarHidden gives the page the whole window while keeping the
  ## window controls, which sit over it.
  titleBarHidden* = TitleBarStyle"hidden"
  ## titleBarHiddenInset is titleBarHidden with the window controls
  ## inset further from the edges (macOS; titleBarHidden elsewhere).
  titleBarHiddenInset* = TitleBarStyle"hiddenInset"

const
  permissionCamera* = Permission"camera"
  permissionMicrophone* = Permission"microphone"
  permissionGeolocation* = Permission"geolocation"
  permissionNotifications* = Permission"notifications"

const
  ## progressError shows a failed progress in the taskbar or Dock icon.
  progressError* = ProgressState"error"
  progressIndeterminate* = ProgressState"indeterminate"
  progressNormal* = ProgressState"normal"
  progressNone* = ProgressState""
  progressPaused* = ProgressState"paused"

proc `$`*(p: ActivationPolicy): string =
  case p
  of policyRegular: "regular"
  of policyAccessory: "accessory"
  of policyProhibited: "prohibited"

proc msg*(e: LoadError): string =
  "mynim: failed to load " & e.url & ": " & e.description &
    " (" & $e.code & ")"

proc msg*(e: EvalError): string =
  "mynim: javascript error: " & e.message

proc equalsIgnoreCase*(a, b: string): bool =
  ## ASCII case-insensitive comparison, as strings.EqualFold.
  a.cmpIgnoreCase(b) == 0

proc `==`*(a, b: TitleBarStyle): bool = a.string == b.string
proc `==`*(a, b: ProgressState): bool = a.string == b.string
proc `==`*(a, b: Placement): bool = a.string == b.string
proc hash*(p: Placement): Hash = hash(p.string)

method loadWindowStates*(s: WindowStateStore):
    tuple[states: Table[string, WindowState], err: ref CatchableError] {.base.} =
  ## Loads the states saved before; an empty map when none are.
  raise errUnsupported()
method saveWindowStates*(s: WindowStateStore;
    states: Table[string, WindowState]): ref CatchableError {.base.} =
  ## Saves the states of all windows with a stateKey.
  raise errUnsupported()
