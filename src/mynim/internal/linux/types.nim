## The types of the linux backend, in one declaration block: window,
## surface, tray and the controllers refer to Backend, which refers to
## them.

type
  ## Backend is the Linux implementation of platform.Backend.
  Backend* = ref object of platform.Backend
    h*: AppHandler
    name*: string
    running*: bool

    windows*: Table[int, gtkWindow]
    ## flyouts are the flyouts that show on Wayland, in the order they
    ## showed: each popup's parent is the one before or a toplevel.
    flyouts*: seq[gtkWindow]
    byWebView*: Table[pointer, gtkWindow]
    ## webViews are the web views under surfaces (webview.nim), by id.
    webViews*: Table[int, gtkWindow]
    nextID*: int
    ## frames are the window manager's frames seen last around a
    ## decorated window in its normal state that the user cannot resize
    ## and one they can, which windows that have not shown yet expect
    ## (see window.frameExtents).
    frames*: array[2, extents]

    appMenu*: Menu
    ## languages are those setLanguages told, which the web context
    ## takes as the first web view is made (webLanguages).
    languages*: seq[string]
    webLanguages*: bool
    schemes*: Table[string, bool]
    signaled*: Atomic[bool]
    quitLoops*: seq[pointer]
    popups*: seq[pointer] ## context menus being shown
    modals*: seq[modal]
    trays*: Table[int, gtkTray]
    nextTray*: int
    grabs*: Table[int, grab] ## global shortcuts on X11
    portal*: portalShortcuts ## global shortcuts elsewhere
    themeHooks*: bool
    ## onX11 reports an X11 display, where windows have positions, and
    ## wmName names its window manager.
    onX11*: bool
    wmName*: proc(screen: pointer): pointer
    ## compositorDecorates reports a Wayland compositor that decorates
    ## windows itself, whose title bar shows no buttons of GTK's
    ## (titlebar.nim).
    compositorDecorates*: bool
    ## announceCSD tells a Wayland compositor that a window decorates
    ## itself, so that it draws no title bar
    ## (gdk_wayland_window_announce_csd).
    announceCSD*: proc(window: pointer)

    ## What the launcher entry shows (Window.SetProgressBar, badges).
    launcher*: tuple[badge: string, progress: float64, showing: bool]

  ## modal is a dialog running its own main loop.
  modal* = object
    dialog*: pointer
    native*: bool ## a GtkNativeDialog, else a GtkDialog

  ## extents are the widths of the edges around a rectangle.
  extents* = object
    left*, top*, right*, bottom*: int32

  gtkWindow* = ref object of Window
    b*: Backend
    id*: int
    h*: WindowHandler
    opts*: ref WindowOptions

    win*: pointer ## GtkWindow
    box*: pointer ## GtkBox holding the menu bar and the webview
    web*: pointer ## WebKitWebView
    ucm*: pointer ## WebKitUserContentManager
    menubar*: pointer
    accel*: pointer
    owner*: int
    ownMenu*: bool
    ## autoHideMenu shows the menu bar only while its menus are open;
    ## altAlone is an Alt press no other key or click has joined.
    autoHideMenu*, altAlone*: bool
    ## surface shows the content mynim draws, in place of the web view.
    surface*: gtkSurface
    ## webViews are the web views under the surface (webview.nim), and
    ## host the window whose surface a web view is under; accessParent
    ## is the node of the content its page's accessible is in.
    webViews*: seq[gtkWindow]
    host*: gtkWindow
    accessParent*: pointer
    ## controls are the title buttons over the page of a window with a
    ## hidden title bar (titlebar.nim), in an overlay with the web view.
    controls*: windowControls

    ## flyout is how a flyout (WindowOptions.flyout) was placed last, at
    ## flyoutSize, once placed is set. grabbed tells that a focusable one
    ## grabs the input, dismissing that it asks whether to close; unmaps
    ## counts the unmap events its hiding has yet to bring.
    flyout*: Flyout
    flyoutSize*: Size
    placed*, grabbed*, dismissing*: bool
    unmaps*: int
    ## layer tells that a panel is a layer surface (layer.nim), put at
    ## layerAt, or centered by the compositor without it.
    layer*: bool
    layerAt*: ref platform.Point

    closed*: bool
    programmatic*: bool
    keepAbove*: bool
    ## requested holds bounds set with setBounds until the window
    ## manager answers: GTK resizes and moves asynchronously.
    ## requestFrame is the window manager's frame they were asked for
    ## with, and requestInside tells that the size asked for is the one
    ## inside it (as with setContentBounds). previous is the size GTK
    ## gave the window then, which reports sent before still carry.
    ## placing is set while the window manager places a window that
    ## shows.
    requested*: ref platform.Rect
    requestFrame*: extents
    requestInside*: bool
    previous*: array[2, int32]
    placing*: bool
    ## framed tells that the window manager framed the window that
    ## shows, and frame is its frame as last seen, once seenFrame is
    ## set (see frameExtents).
    framed*, seenFrame*: bool
    frame*: extents
    state*: uint32
    x*, y*, w*, hgt*: int32
    minW*, minH*, maxW*, maxH*: int32

    ## activationResize holds the latest bounds asked for while a
    ## window drawing with GL on Wayland is not focused, and
    ## activationPrevious the size it had before: the configure event
    ## of its activation can bring that size back. resizeIdle is the
    ## idle source that then asks for the bounds again
    ## (cbActivationResize).
    activationResize*: ref platform.Rect
    activationPrevious*: array[2, int32]
    resizeIdle*: uint32

    ## dragged holds the paths of the files dragged over the page,
    ## dropped those of the files dropped on it, for droppedFiles.
    dragged*, dropped*: seq[string]

    ## The last button press on the page, used for window dragging and
    ## context menu positioning.
    press*: tuple[button: int32, rootX, rootY: float64, time: uint32,
                  event: pointer, hasPressed: bool]

    ## dragPending holds whether a window drag was requested with the
    ## last press and waits for the pointer to move; see startDrag.
    dragPending*: bool

    ## cursor is the resize cursor shown over an edge of a frameless
    ## window, and the page's cursor it replaced.
    cursor*: tuple[on: bool, edge: int32, shown, saved: pointer]

    ## asWebView is the platform.WebView facade of a web view (Window
    ## and WebView are siblings under Page).
    asWebView*: gtkWebView

  gtkWebView* = ref object of WebView
    w*: gtkWindow

  gtkSurface* = ref object of Surface
    clientComposition*: InputComposition
    w*: gtkWindow
    area*: pointer ## GtkGLArea, or GtkDrawingArea
    im*: pointer ## GtkIMContext
    cr*: pointer ## the cairo context of the draw signal in progress
    cursor*: Cursor
    ## gl tells that the area is a GtkGLArea, rendering that its render
    ## signal is in progress, rendered that it ran.
    gl*, rendering*, rendered*: bool
    ## present shows the frames the content draws in memory in a
    ## GtkGLArea, as when its GL renderer fails; inMemory tells that it
    ## did, failed that it failed too.
    present*: Presenter
    inMemory*, presentFailed*: bool
    ## tick is the tick callback drawing frames in memory, while one is
    ## asked for (requestFrame); again tells that another was asked for
    ## while it drew one, and ticking that it draws one.
    tick*: uint32
    again*, ticking*: bool
    ## staged is the frame the tick callback drew, which the draw
    ## signal paints in the same frame of the frame clock: the host's
    ## memory, valid until it draws or frees another (see idle).
    staged*: tuple[pix: seq[byte], stride, width, height: int]

    textInput*: bool
    caret*: RectF
    input*: TextInputState
    ## lastKey is a copy of the last key press, which a context menu
    ## the key opens shows for.
    lastKey*: pointer
    ## pressing is the key press being handled, which the Tab moving
    ## the focus to a web view passes on to it (tabInto).
    pressing*: pointer
    lastPointer*: pointer
    dragContext*: pointer
    dragRequest*: ref DragRequest
    dragError*: ref CatchableError
    dragCanceled*: bool
    dataDrop*: gtkDataDrop
    ## layers is the overlay of the area over web, the layout of the
    ## web views under it, and placed where the content shows them
    ## (webview.nim), once the window has some.
    layers*, web*: pointer
    placed*: seq[WebViewPlacement]

  gtkTray* = ref object of Tray
    b*: Backend
    h*: TrayHandler
    id*: int
    ind*: pointer
    menu*: pointer
    owner*: int
    iconDir*: string
    icons*: int

  gtkClipboardSource* = ref object
    id*: pointer
    data*: transfer.Data
    released*: proc()

  gtkTargetEntry* = object
    target*: cstring
    flags*, info*: uint32

  gtkDataDrop* = ref object
    context*: pointer
    event*: DataDragEvent
    x*, y*: float64
    time*: uint32
    pending*: Table[pointer, seq[transfer.Format]]
    reps*: seq[transfer.Representation]
    failed*: bool

  gtkDownload* = ref object
    w*: gtkWindow
    url*, path*: string
    err*: ref CatchableError

  gtkSchemeTask* = ref object of SchemeResponder
    req*: pointer
    cancel*: proc() {.closure.}
    responded*: bool
    done*: bool
    ## fd is the write end of the pipe, -1 before respond and once
    ## closed.
    fd*: int

  grab* = object
    keycode*: uint8
    mods*: uint32

  portalShortcuts* = object
    available*: bool
    shortcuts*: Table[int, accelerator.Accelerator]
    session*: string ## the session the shortcuts are bound in
    busy*: bool ## a session is being created and bound
    stale*: bool ## the shortcuts changed while busy

  gtkAccessTree* = ref object
    s*: gtkSurface
    root*: pointer ## the surface's accessible
    nodes*: Table[uint64, gtkAccessNode]
    top*: seq[gtkAccessNode]
    focus*: uint64
    quiet*: bool ## building the tree assistive technology asked for

  ## gtkAccessNode is a node of the tree, with its ATK object.
  gtkAccessNode* = ref object
    obj*: pointer ## owned
    typ*: uint
    tree*: gtkAccessTree
    parent*: gtkAccessNode
    children*: seq[gtkAccessNode]
    n*: platform.AccessNode
    ## chosen are the rows a list choosing its rows chose, among those
    ## built.
    chosen*: seq[uint64]
    ## page is the accessible of the web view's page the node stands
    ## for, its only child.
    page*: pointer

  windowControls* = ref object
    overlay*: pointer ## GtkOverlay of the web view and the bars
    bars*: array[2, pointer] ## the header bars at the start and the end, or nil
    room*: platform.TitleBar

  inotifyGeneration* = ref object
    ids*: seq[uint64]
    retired*: bool

  ## inotifyWatch watches directories with inotify, which names the
  ## child that changed; files are watched through their directory.
  inotifyWatch* = ref object of watchdriver.Driver
    fd*, epoll*: cint
    pipe*: array[2, cint]
    generations*: Table[cint, seq[inotifyGeneration]]
    targets*: Table[uint64, cint]
    mu*: Lock
    closed*: bool

  inotifyRecord* = object
    wd*: uint64
    kind*: FileWatchKind
    child*: string

  printJob* = ref object
    err*: ref CatchableError ## from "failed", which "finished" follows
    done*: proc(err: ref CatchableError)

  nativeItem* = object
    owner*: int
    item*: pointer
    check*: bool
    windowID*: int ## menu bar or popup's window; 0 for a tray

  appController* = ref object of AppController
    b*: Backend
  dialogsImpl* = ref object of Dialogs
    b*: Backend
  clipboardImpl* = ref object of Clipboard
  shellImpl* = ref object of Shell
  screenImpl* = ref object of Screen
    b*: Backend
  themeImpl* = ref object of Theme
    b*: Backend
  networkImpl* = ref object of Network
    b*: Backend
  powerImpl* = ref object of Power
    b*: Backend
  secretsImpl* = ref object of Secrets

  ## gTypeQueryInfo is GTypeQuery's info.
  gTypeQueryInfo* = object
    typ*: uint
    name*: pointer
    classSize*, instanceSize*: uint32

  ## gInterfaceInfo is GInterfaceInfo.
  gInterfaceInfo* = object
    init*, finalize*, data*: pointer

  ## asyncCalls holds callbacks of asynchronous GIO operations by id.
  asyncCalls* = object
    mu*: Lock
    next*: uint
    m*: Table[uint, proc(source, res: pointer)]

  ## secretAPI is libsecret's functions, loaded once.
  secretAPI* = object
    err*: ref CatchableError
    hashTableNewFull*: proc(hash, equal, keyDestroy, valueDestroy: pointer): pointer {.cdecl.}
    hashTableInsert*: proc(table, key, value: pointer): bool {.cdecl.}
    hashTableUnref*: proc(table: pointer) {.cdecl.}
    strdup*: proc(s: cstring): pointer {.cdecl.}
    free*: proc(p: pointer) {.cdecl.}
    errorFree*: proc(e: pointer) {.cdecl.}
    strHash*, strEqual*, freeFn*: pointer
    schemaNewv*: proc(name: cstring, flags: int32, attributes: pointer): pointer {.cdecl.}
    schemaUnref*: proc(schema: pointer) {.cdecl.}
    valueNew*: proc(secret: pointer, length: int, contentType: cstring): pointer {.cdecl.}
    valueGet*: proc(value: pointer, length: ptr uint): pointer {.cdecl.}
    valueUnref*: proc(value: pointer) {.cdecl.}
    passwordStoreSync*: proc(schema, attributes, collection,
                             label, value, cancellable: pointer,
                             err: ptr pointer): bool {.cdecl.}
    passwordLookupSync*: proc(schema, attributes, cancellable: pointer,
                              err: ptr pointer): pointer {.cdecl.}
    passwordClearSync*: proc(schema, attributes, cancellable: pointer,
                             err: ptr pointer): bool {.cdecl.}
    ## schema is keytar's: org.freedesktop.Secret.Generic with the
    ## string attributes service and account.
    schema*: pointer

  langinfoLib* = object
    loaded*: bool
    newlocale*: proc(mask: int32, locale: cstring, base: uint): uint {.cdecl.}
    freelocale*: proc(loc: uint) {.cdecl.}
    langinfoL*: pointer

var
  theBackend*: Backend
  pending*: asyncCalls
  gtkClipboardSources*: Table[pointer, gtkClipboardSource]
  downloads*: Table[pointer, gtkDownload]
  downloadsHooked*: bool
  menuOwners*: int
  itemsByID*: Table[int, seq[nativeItem]]
  itemRoles*: Table[int, string]
  settingState*: bool
  controlsStyled*: bool
  portalShortcutsOnly*: bool
  langinfo*: langinfoLib
  printJobs*: Table[pointer, printJob]

## pending.add registers a GIO async callback and returns its id.
proc add*(a: var asyncCalls, fn: proc(source, res: pointer)): pointer =
  withLock a.mu:
    a.next += 1
    a.m[a.next] = fn
    return cast[pointer](a.next)

proc take*(a: var asyncCalls, id: pointer): proc(source, res: pointer) =
  withLock a.mu:
    result = a.m[cast[uint](id)]
    a.m.del(cast[uint](id))

## grow returns r with the extents around it.
proc grow*(e: extents, r: platform.Rect): platform.Rect =
  platform.Rect(
    x: r.x - int(e.left), y: r.y - int(e.top),
    width: r.width + int(e.left + e.right),
    height: r.height + int(e.top + e.bottom))

## shrink returns r without the extents around it.
proc shrink*(e: extents, r: platform.Rect): platform.Rect =
  platform.Rect(
    x: r.x + int(e.left), y: r.y + int(e.top),
    width: r.width - int(e.left + e.right),
    height: r.height - int(e.top + e.bottom))

proc surfaceOf*(b: Backend, data: pointer): gtkSurface
proc loadSurface*()
proc initMenuCallbacks*()
proc initClipboardCallbacks*()
proc initDownloadCallbacks*()
proc initSchemeCallbacks*()
proc initSurfaceCallbacks*()
proc initAccessCallbacks*()
proc initWindowCallbacks*()
proc loadDrops*()
proc layoutControls*(w: gtkWindow)
proc initFlyoutCallbacks*()

proc hash*(s: gtkSurface): Hash = hash(cast[pointer](s))
proc hash*(w: gtkWindow): Hash = hash(cast[pointer](w))
