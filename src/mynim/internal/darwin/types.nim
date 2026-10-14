## The types of the darwin backend, in one declaration block: window,
## surface, accessElement and tray refer to Backend, which refers to
## them.

const nsNotFound* = uint(int64.high)

type
  ## Backend is the macOS implementation of platform.Backend.
  Backend* = ref object of platform.Backend
    h*: AppHandler
    app*: id
    delegate*: id
    source*: pointer
    mainLoop*: pointer
    ## Lookup tables for Objective-C callbacks. Main thread only.
    byDelegate*, byWebView*, byNSWindow*: Table[id, macWindow]
    bySurface*: Table[id, macSurface]
    byAccess*: Table[id, accessElement]
    menuTarget*: id
    menuItems*: Table[int, seq[id]]
    appMenu*: seq[int]
    trays*: Table[id, tray]
    hotkeys*: Table[int, uint]
    hkInstalled*: bool
    notifyDelegate*: id
    ## notifyAnswered records that the user has answered whether the app
    ## may show notifications; notifyWaiting holds those shown meanwhile.
    notifyAnswered*: bool
    notifyWaiting*: seq[waitingNotification]
    stepping*: int
    quitAfterModal*: bool
    dockProgress*: dockProgress
    ## openedAtLogin records whether the system started the app as a
    ## login item (WasOpenedAtLogin).
    openedAtLogin*: bool
    ## dockMenu is returned by applicationDockMenu: (retained).
    dockMenu*: id
    dockMenuOwner*: int
  macWindow = ref object of Window
    b*: Backend
    h*: WindowHandler
    opts*: ref WindowOptions
    win*: id
    view*: id ## the content view: holds the web view and a docked inspector
    web*: id
    delegate*: id
    ucc*: id
    effect*: id
    parent*: macWindow
    ## flyout is how a flyout (WindowOptions.flyout) was placed last, at
    ## flyoutSize.
    flyout*: Flyout
    flyoutSize*: Size
    ## popover shows a flyout with the look of AppKit's popovers
    ## (Flyout.popover), in its window, win while it shows;
    ## popoverClosing tells that the backend closes it, not the user.
    popover*, popoverController*: id
    popoverClosing*: bool
    lastMouseDown*: id
    dropped*: seq[string] ## droppedFiles
    downloads*: Table[id, tuple[url, path: string]] ## WKDownload
    attention*: int ## the request of flashFrame
    maximized*: bool
    ## auxiliary tells that setVisibleOnAllWorkspaces made a window that
    ## cannot go full screen an auxiliary of full-screen Spaces, to undo.
    auxiliary*: bool
    programmatic*: bool
    closed*: bool
    sheet*: bool
    trafficLights*: ref platform.Point
    ## surface shows the content mynim draws, in place of the web view.
    surface*: macSurface
    ## webViews are the web views under the surface (webview.nim), and
    ## host the window whose surface a web view is under, in the clip
    ## view clip.
    webViews*: seq[macWindow]
    host*: macWindow
    clip*: id
    ## pointerIn tells that the page of a web view has the pointer,
    ## where nothing the content painted covers it.
    pointerIn*: bool
    ## accessParent is the element of the content showing a web view,
    ## which assistive technology finds its page in.
    accessParent*: id
    ## asWebView is the platform.WebView facade of a web view (Window
    ## and WebView are siblings under Page, so a macWindow cannot be
    ## both).
    asWebView*: macWebView
  macSurface = ref object of Surface
    w*: macWindow
    view*: id
    tracking*: id
    link*: id ## CADisplayLink (macOS 14), nil before
    ## The display link runs while frames follow each other
    ## (linkRunning), and due is whether its next tick draws one.
    ## Without a display link, a timer paces frames at the display's
    ## rate: timing is true while one is due. lastFrame is when the
    ## last frame began, and framePass the pass of the run loop that
    ## drew it (caPass); resized tells that the view changed size or
    ## scale since.
    linkRunning*: bool
    due*: bool
    timing*: bool
    resized*: bool
    lastFrame*: times.Time
    framePass*: uint64
    cursor*: Cursor
    inside*: bool
    ctrlClick*: bool ## the primary button is down for a Control-click
    ## input is the state of the text input with the keyboard; marked
    ## is the input method's composition and markedSel its selection in
    ## it.
    input*: TextInputState
    marked*: string
    markedSel*: nsRange
    keyDown*: bool ## in interpretKeyEvents: text typed with the key
    ## Accessibility: whether the content describes its frames, the
    ## last tree, the elements of its nodes and those at the top (an
    ## NSArray).
    accessOn*: bool
    access*: AccessTree
    elements*: Table[uint64, accessElement]
    topLevel*: id
    updating*: bool
    dataDrag*: macDataSource
    dragOperation*: transfer.Operation
    ## placed are where the content shows the window's web views, under
    ## it (webview.nim).
    placed*: seq[WebViewPlacement]
  macWebView = ref object of WebView
    w*: macWindow
  accessElement = ref object
    obj*: id ## MyGoAccessibilityElement, owned
    s*: macSurface
    node*: AccessNode
    parent*: id
    children*: seq[uint64]
    ## webView is the web view whose page is the first child.
    webView*: macWindow
    ## chosen are the rows of a list or table that are chosen, and
    ## count its rows, built or not.
    chosen*: seq[uint64]
    count*: int
  tray = ref object of Tray
    b*: Backend
    h*: TrayHandler
    item*: id
    button*: id
    owner*: int
  dockProgress* = object
    view*, icon*, track*, fill*: id
  ## waitingNotification is a notification shown before the user has
  ## answered whether the app may show notifications.
  waitingNotification* = object
    n*: ref Notification
    done*: proc(err: ref CatchableError)
  ## appController implements platform.AppController.
  appController = ref object of AppController
    b*: Backend
  dialogsImpl = ref object of Dialogs
    b*: Backend
  macDataSource = ref object
    r*: DragRequest
    s*: macSurface
    obj*, session*: id
    providers*: seq[id]
    err*: ref CatchableError
  macDataProvider = ref object
    src*: macDataSource
    item*: transfer.Item
  schemeTask = ref object of SchemeResponder
    task*: id
    cancel*: proc() {.closure.}
    stopped*: bool
    responded*: bool
    done*: bool
  vnodeWatch = ref object of watchdriver.Driver
    queue*: cint
    pipe*: array[2, cint]
    files*: Table[uint64, cint]
    ids*: Table[cint, uint64]
    mu*: Lock
    closed*: bool
  printJob = ref object
    w*: macWindow
    cb*: proc(pdf: seq[byte], err: ref CatchableError)
    done*: proc(success: bool)
  nativeItem = object
    owner*: int
    item*: id
  ## nsRange is NSRange, for the text input methods.
  nsRange = object
    location*, length*: uint
  ## cgRect is an NSRect returned by a method implemented in Nim.
  cgRect = object
    x*, y*, w*, h*: float64
  macClipboardSource = ref object
    obj*: id
    change*: int
    data*: Data
    items*: Table[id, transfer.Item]
    released*: proc()

var
  theBackend*: Backend
  ## macClipboard is the source that owns the pasteboard while the app
  ## put a Data on it (clipboard.nim).
  macClipboard*: macClipboardSource
  macClipboardProviders*: Table[id, macClipboardSource]
  ## schemeTasks maps live WKURLSchemeTask objects to their state.
  schemeTasks*: Table[id, schemeTask]
  printJobs*: Table[uint, printJob]
  macDragSources*: Table[id, macDataSource]
  macDragProviders*: Table[id, macDataProvider]
  trayTarget*: id

## errInvalidImage is what writeImage/setDockIcon/setIcon fail with on
## undecodable data.
proc errInvalidImage*(): ref PlatformError =
  newException(PlatformError, "mynim: invalid image data")

## primaryScreenHeight is the height of the primary screen, MyGo at
## its top-left: the flip of the Quartz coordinates of NSScreen.
proc primaryScreenHeight*(): float64 =
  let screens = send(`class`("NSScreen"), "screens")
  if sendInt(screens, "count") == 0:
    return 0
  msgRect(send(screens, "objectAtIndex:", argu(0)),
          sel("frame")).size.height

## rectFromMac flips an NSRect into screen coordinates (origin
## top-left of the primary display, in DIPs).
proc rectFromMac*(r: NSRect): platform.Rect =
  let h = primaryScreenHeight()
  platform.Rect(
    x: int(math.round(r.origin.x)),
    y: int(math.round(h - r.origin.y - r.size.height)),
    width: int(math.round(r.size.width)),
    height: int(math.round(r.size.height)))

## rectToMac flips back into the Quartz coordinates of AppKit.
proc rectToMac*(r: platform.Rect): NSRect =
  let h = primaryScreenHeight()
  NSRect(origin: NSPoint(x: float64(r.x),
                         y: h - float64(r.y) - float64(r.height)),
         size: NSSize(width: float64(r.width),
                      height: float64(r.height)))
proc release*(s: macClipboardSource)
proc post*(b: Backend, fn: proc())
proc runOnMain*(b: Backend, fn: proc())
proc startNetworkMonitor*()
