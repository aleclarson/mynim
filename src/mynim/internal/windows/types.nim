## types.nim: the shared types of the Windows backend. All types sit
## in one type block so they may reference each other; the small leaf
## controllers are here with it.

type
  ## formatEtc is FORMATETC.
  formatEtc* = object
    format*: uint16
    device*: uint
    aspect*: uint32
    index*: int32
    tymed*: uint32

  ## stgMedium is STGMEDIUM.
  stgMedium* = object
    tymed*: uint32
    handle*: uint
    unkForRelease*: uint

const
  cfHDrop* = 15'u16
  dvaspectContent* = 1'u32
  tymedHGlobal* = 1'u32
  dropEffectNone* = 0'u32
  dropEffectCopy* = 1'u32
  dropEffectMove* = 2'u32
  dropEffectLink* = 4'u32
  dataGetData* = 3 ## IDataObject::GetData
  dataQueryGetData* = 5 ## IDataObject::QueryGetData
  wmMouseMove* = 0x0200'u32

proc initDropTarget*()

## dropOnceDo runs initDropTarget once (Go's dropOnce sync.Once); all
## callers are on the main thread.
var dropInit: bool
proc dropOnceDo*() =
  if not dropInit:
    dropInit = true
    initDropTarget()

type
  dataProvider* = proc(): tuple[b: seq[byte], err: ref CatchableError]

  # The COM objects' visible memory and their GC-visible state
  # (surface_drag.nim, surface_drop.nim).
  dragDataCom = object
    vtbl: ptr array[12, uint]
    refs: int32
  dragDataEntry* = ref object
    com: ptr dragDataCom
    providers*: Table[uint16, dataProvider]
    formats*: seq[uint16]
    extra*: Table[uint16, stgMedium]
    err*: ref CatchableError
    clipboard*: bool
    onRelease*: proc()

  oleDragSourceCom = object
    vtbl: ptr array[5, uint]
    refs: int32
  oleDragSourceEntry = ref object
    com: ptr oleDragSourceCom
    canceled*: bool

  formatEnumCom = object
    vtbl: ptr array[7, uint]
    refs: int32
  formatEnumEntry = ref object
    com: ptr formatEnumCom
    formats: seq[formatEtc]
    n: int

  ## Backend is the Windows (Win32 + WebView2) implementation of
  ## platform.Backend.
  WinBackend* = ref object of Backend
    h*: AppHandler
    name*: string
    appHwnd*: uint # hidden window receiving app level messages
    running*: bool
    signaled*: Atomic[bool]

    windows*: Table[uint, w32Window] # by HWND
    # languages are those setLanguages told: the first is the language
    # of the WebView2 environment, once made.
    languages*: seq[string]
    appMenu*: Menu

    # The WebView2 environment is created asynchronously, when the
    # first window that shows a web page needs it; windows wait.
    env*: uint
    envErr*: ref CatchableError
    envStarted*: bool
    envWaiters*: seq[proc()]

    menus*: menuTable

    trays*: Table[uint32, w32Tray]
    nextTray*: uint32
    taskbarCreated*: uint32

    # ITaskbarList3 (taskbar.nim) and the message telling a window its
    # taskbar button exists.
    taskbarList*: uint
    taskbarFailed*: bool
    taskbarButtonCreated*: uint32

    watchingPower*: bool
    notifications*: Table[string, w32Notification]

    themeSource*: string
    badge*: string
    hidden*: seq[w32Window]
    icon*: uint # default window icon (setDockIcon)

    # captions are the windows of the controls of windows with a
    # hidden title bar (titlebar.nim), captionFonts their glyphs by
    # DPI.
    captions*: Table[uint, captionBar]
    captionFonts*: Table[int, captionFont]
    # comp shows the controls of windows with a material behind them
    # (compositor.nim). compRetry is when to try making it again after
    # compFails failures in a row, and composeAt when timerCompose
    # draws again the controls that could not draw, zero when it is
    # not set.
    comp*: composition
    compRetry*, composeAt*: MonoTime
    compFails*: int

    # surfaces are the windows of the content mynim draws
    # (surface.nim).
    surfaces*: Table[uint, w32Surface]

  appController* = ref object of AppController
    b*: WinBackend

  dialogs* = ref object of Dialogs
    b*: WinBackend

  w32Clipboard* = ref object of Clipboard
    b*: WinBackend

  w32Shell* = ref object of Shell

  w32Screen* = ref object of Screen

  w32Theme* = ref object of Theme
    b*: WinBackend

  w32Power* = ref object of Power
    b*: WinBackend

  w32Network* = ref object of Network
    b*: WinBackend

  w32Secrets* = ref object of Secrets

  ## menuEntry is a native menu item: WM_COMMAND reports 16-bit
  ## command ids, which map back to the items they were built from.
  menuEntry* = ref object
    uid*: int
    role*: string
    owner*: int
    menu*: uint # the HMENU holding the item
    radio*: bool
    accel*: string

  ## menuTable maps command IDs to the items they were built from.
  menuTable* = ref object
    entries*: Table[uint16, menuEntry]
    next*: uint16
    nextOwner*: int

  w32Tray* = ref object of Tray
    b*: WinBackend
    id*: uint32
    hwnd*: uint
    hicon*: uint
    tip*: string
    menu*: Menu

  w32Notification* = ref object
    id*: string
    toast*: uint

  ## captionBar is the window controls of a window with a hidden
  ## title bar (titlebar.nim): the buttons' window, the top edge's,
  ## and the buttons shown, left to right.
  captionBar* = ref object
    w*: w32Window
    buttons*: uint # the buttons' window
    edge*: uint # the top edge's window, 0 when it could not be created
    shown*: seq[captionButton]
    # hot is the index of the button under the pointer and pressed
    # that of the button pressed, or -1.
    hot*, pressed*: int
    tracking*: bool # TrackMouseEvent asked for WM_NCMOUSELEAVE
    active*: bool # the window is the active window
    # comp shows the buttons in a window without a redirection
    # bitmap, where UpdateLayeredWindow cannot (compositor.nim);
    # nil otherwise.
    comp*: compositor

  captionFont* = object
    regular*, marquee*: uint

  captionButton* = enum
    captionClose
    captionMinimize
    captionMaximize
    captionRestore

  ## composition is the backend's Direct3D 11 device and
  ## DirectComposition device, shared by the windows that show
  ## through it (compositor.nim). removed is the event that tells
  ## the GPU device was removed, which a thread waits for (watch),
  ## and cookie its registration; removed is 0 without ID3D11Device4
  ## (Windows 10 before 1607).
  composition* = ref object
    d3d*, ctx*, dcomp*: uint
    software*: bool
    removed*: uint
    cookie*: uint32

  ## pendingCall runs once the WebView2 controller exists.
  pendingCall* = object
    fn*: proc(w: w32Window) {.closure.}
    err*: proc(err: ref CatchableError) {.closure.}

  ## accelKey is the virtual key and modifiers of a menu accelerator.
  accelKey* = object
    vk*: uint32
    mods*: accelerator.Modifiers

  ## menuKey is the letter of Alt and a letter that opened
  ## popupMenuBar, and its popup.
  menuKey* = object
    popup*, key*: uint

  w32Window* = ref object of Window
    b*: WinBackend
    h*: WindowHandler
    opts*: WindowOptions
    hwnd*: uint
    parent*: w32Window
    # flyout is how a flyout (WindowOptions.flyout) was placed last,
    # at flyoutSize.
    flyout*: Flyout
    flyoutSize*: Size

    # The WebView2 controller is created asynchronously; calls that
    # need it wait in pending until it exists, or fail with
    # webViewErr, why it could not be created.
    controller*: uint # ICoreWebView2Controller
    webview*: uint # ICoreWebView2
    settings*: uint # ICoreWebView2Settings
    ready*: bool
    pending*: seq[pendingCall]
    webViewErr*: ref CatchableError
    webViewFails*: int
    # scriptIDs are the IDs of the scripts
    # AddScriptToExecuteOnDocumentCreated added, and scriptGen counts
    # the times setUserScripts replaced them: an ID that arrives for
    # scripts replaced since is removed at once.
    scriptIDs*: seq[string]
    scriptGen*: int
    closed*: bool
    destroying*: bool

    minW*, minH*, maxW*, maxH*: int # DIPs
    movable*, closable*: bool
    frameless*: bool
    hiddenTitleBar*: bool # a titleBarStyle that hides the caption
    caption*: captionBar # the controls in its place, nil if failed
    noRedirect*: bool # no redirection bitmap, material behind the page
    fullScreen*: bool
    reframing*: bool # setFullScreen is changing the frame
    showMaximized*: bool # on the first show (WindowOptions.maximized)
    dropped*: seq[string] # droppedFiles
    skipTaskbar*: bool
    progressState*: string
    progressValue*: float64
    icons*: array[2, uint] # small and big, from setIcon
    # surface shows the content mynim draws, in place of the webview.
    surface*: w32Surface
    # webViews are the web views under the surface
    # (webview_embed.nim), and host the window whose surface a web
    # view is under, which shows it through its composition
    # controller comp (comp3 its drag and drop, on runtimes having
    # it; uia the provider of its page for UI Automation), in the
    # visual webVis inside clipVis, at frame clipped to clip while
    # shown. focused tells that it has the keyboard, and cursor is
    # the cursor its page wants.
    webViews*: seq[w32Window]
    host*: w32Window
    comp*, comp3*, uia*: uint
    clipVis*, webVis*: uint
    frame*, clip*: RectF
    shown*, focused*: bool
    cursor*: uint
    savedStyle*, savedExStyle*: uint
    savedPlacement*: windowPlacement
    state*: int # last sizeRestored, sizeMinimized or sizeMaximized
    opacity*: float64
    bgBrush*: uint
    bg*: ref platform.Color
    vibrancy*: string
    shadow*: bool
    ignoreMouse*: bool

    menu*: Menu # menu bar
    hmenu*: uint
    owner*: int
    ownMenu*: bool
    accels*: Table[accelKey, uint16]
    # autoHideMenu keeps hmenu off the window except while revealed,
    # when the keyboard is in the menu bar.
    autoHideMenu*, revealed*: bool
    inMenu*: bool # in a menu loop, of the bar or a popup
    menuKey*: menuKey # the letter that opened popupMenuBar

    programmatic*: bool
    loading*: bool
    zoom*: float64
    devTools*: bool
    htmlFor*: Table[string, string] # loadHTML documents by load URL
    htmlNext*: bool # loadHTML started the next navigation
    calls*: Table[int, proc(r: string, err: ref CatchableError) {.closure.}]
    nextCall*: int

  ## uiaIface is an interface pointer of an element: COM calls its
  ## methods with its address.
  uiaIface* = object
    vtbl*: ptr uint
    e*: uiaElement

  ## uiaElement is a node of the tree as UI Automation sees it, or
  ## the root.
  uiaElement* = ref object
    ifaces*: array[13, uiaIface]
    refs*: int32
    tree*: uiaTree
    root*: bool
    dead*: bool
    n*: AccessNode
    # textRunes are the runes of n.value, runesOf the value they
    # are of.
    textRunes*: seq[Rune]
    runesOf*: string
    parent*: uiaElement
    children*: seq[uiaElement]

  ## uiaTree is what UI Automation sees of a surface
  ## (surface_access.nim).
  uiaTree* = ref object
    s*: w32Surface
    hwnd*: uint
    root*: uiaElement
    nodes*: Table[uint64, uiaElement]
    order*: seq[uiaElement] # in the order of the content's tree
    focus*: uint64
    quiet*: bool # building the tree a client asked for
    # announced is the text of the live region of announcements.
    announced*: string

  ## webLayer composes the web views under a surface's frames
  ## (webview_embed.nim).
  webLayer* = ref object
    hwnd*: uint
    dcomp*: uint
    target*: uint
    visual*: uint

  ## compositor shows a bitmap in one window through
  ## DirectComposition (compositor.nim).
  compositor* = ref object
    b*: WinBackend
    hwnd*: uint
    # dev made target, visual and surface, nil until it draws.
    dev*: composition
    target*, visual*, surface*: uint
    w*, h*: int32
    px*: seq[uint32] # the pixels to show, kept from paint to paint
    # retry is when to draw again after drawing failed fails times
    # in a row, with a device that stayed valid.
    retry*: MonoTime
    fails*: int

  w32Surface* = ref object of Surface
    b*: WinBackend
    w*: w32Window
    hwnd*: uint

    clientComposition*: InputComposition

    paintDC*: uint
    tracking*: bool
    buttons*: int
    cursor*: Cursor
    high*: uint16 # a high surrogate of WM_CHAR waiting for its pair
    ime*: bool
    caret*: RectF
    input*: TextInputState

    # keyTaken tells that the content took the key down, whose
    # WM_SYSCHAR then opens no menu.
    keyTaken*: bool

    reconvert*: ref tuple[a, b: int] # the runes a reconversion replaces
    dropTarget*: uint
    access*: uiaTree
    dragSource*: oleDragSourceEntry

    # comp shows the frames drawn in memory in a window without a
    # redirection bitmap, where GDI cannot (compositor.nim); nil
    # while none shows.
    comp*: compositor

    # layer holds the web views under the frames, once there are
    # some (webview_embed.nim): placed are where the content shows
    # them, and stacked those shown, in the order of their visuals.
    # webHover is the web view under the pointer, and webCapture the
    # one a press went to, which gets the mouse until the buttons
    # are let go.
    layer*: webLayer
    placed*: seq[WebViewPlacement]
    stacked*: seq[w32Window]
    webHover*, webCapture*: w32Window

var theBackend*: WinBackend
## set at module init, on the main thread
var mainThreadID* {.used.}: uint32 = currentThreadID()

## Forward declarations across files.
proc send*(w: w32Window, ev: SurfaceEvent): bool
proc send*(s: w32Surface, ev: SurfaceEvent): bool
proc dpi*(s: w32Surface): int
proc toDIP*(s: w32Surface, v: int32): float64
proc webViewAt*(s: w32Surface, x, y: float64): w32Window
proc pagePoint*(w: w32Window, pt: uint): uint
proc paint*(c: captionBar)
proc menuShown*(w: w32Window): bool
proc withWebView*(w: w32Window, fn: proc())
proc devtools*(w: w32Window, method0, params: string,
  done: proc(r: string, err: ref CatchableError))
proc applyMenuTheme*(b: WinBackend)
proc appMessage*(b: WinBackend, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc message*(w: w32Window, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc message*(c: captionBar, hwnd: uint, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc message*(s: w32Surface, hwnd: uint, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc trayMessage*(b: WinBackend, id, m: uint32)
proc add*(t: w32Tray)
proc drop*(t: menuTable, owner: int)
proc recompose*(b: WinBackend)
proc deviceRemoved*(b: WinBackend, wp: uint)
proc messageBox*(b: WinBackend, owner: uint,
  o: MessageBoxOptions): MessageBoxResult
proc iconFromPNG*(png: seq[byte], size: int): tuple[icon: uint,
  err: ref CatchableError]
proc setIcon*(w: w32Window, icon: uint)
