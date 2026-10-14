## window.go: windows — NSWindow/NSPanel creation, the window delegate
## (also WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler and
## WKDownloadDelegate), navigation, downloads, flyouts, the title bar's
## traffic lights, and printing.

const
  styleTitled              = 1 shl 0
  styleClosable            = 1 shl 1
  styleMiniaturizable      = 1 shl 2
  styleResizable           = 1 shl 3
  styleFullScreen          = 1 shl 14
  styleFullSizeContentView = 1 shl 15
  styleNonactivatingPanel  = 1 shl 7

  nsBackingStoreBuffered   = 2
  nsFloatingWindowLevel    = 3
  nsPopUpMenuWindowLevel   = 101
  nsNormalWindowLevel      = 0


  collectionCanJoinAllSpaces    = 1 shl 0
  collectionTransient           = 1 shl 3
  collectionIgnoresCycle        = 1 shl 6
  collectionFullScreenPrimary   = 1 shl 7
  collectionFullScreenAuxiliary = 1 shl 8
  collectionFullScreenNone      = 1 shl 9

  ## NSApplicationPresentationOptions
  presentationAutoHideMenuBar = 1 shl 2
  presentationFullScreen      = 1 shl 10
  presentationAutoHideToolbar = 1 shl 11

proc errClosed*(): ref PlatformError =
  newException(PlatformError, "mynim: window has been closed")

proc createFlyout(w: macWindow)
proc fillWindow(w: macWindow, content: NSRect)
proc layoutTrafficLights*(w: macWindow)
proc createWebView*(w: macWindow, content: NSRect)
proc create(w: macWindow)
proc errDestroyed*(): ref CatchableError
proc loadFailed(w: macWindow, err: id)
proc pngFromImage(img: id): seq[byte]
proc addUserScripts*(w: macWindow)
proc showFlyout(w: macWindow, key: bool)
proc hideFlyout(w: macWindow)
proc watchOutsideClicks*(b: Backend)
proc watchAnchorPresses*(b: Backend)
proc webViewMethods*(): seq[MethodDef]
proc registerClipViewClass*()
proc webViewOf*(view: id): macWindow
proc tabOut*(w: macWindow, back: bool)
proc pressed*(w: macWindow, ev: id, button: int)
proc closeWebView*(w: macWindow)
proc closeWebViews*(w: macWindow)
proc clipBackground*(w: macWindow, c: platform.Color)
proc top*(w: macWindow): macWindow
proc hasKeyboard*(w: macWindow): bool
proc `==`*(a, b: macWindow): bool = cast[pointer](a) == cast[pointer](b)

method newWindow*(b: Backend, o: WindowOptions, h: WindowHandler):
    tuple[w: Window, err: ref CatchableError] =
  let opts = new(WindowOptions)
  opts[] = o
  let w = macWindow(b: b, h: h, opts: opts,
                    trafficLights: o.trafficLightPosition,
                    downloads: initTable[id, tuple[url, path: string]]())
  if o.parent of macWindow and macWindow(o.parent) != nil:
    w.parent = macWindow(o.parent)
  withPool(proc() = w.create())
  (Window(w), nil)

proc create(w: macWindow) =
  let o = w.opts

  if o.flyout != nil:
    w.createFlyout()
    return
  var style = styleTitled.uint
  if o.closable:
    style = style or styleClosable
  if o.minimizable:
    style = style or styleMiniaturizable
  if o.resizable:
    style = style or styleResizable
  let hiddenTitleBar = o.frameless or
    o.titleBarStyle == "hidden" or o.titleBarStyle == "hiddenInset"
  if hiddenTitleBar:
    style = style or styleFullSizeContentView

  let size = NSRect(size: NSSize(width: float64(o.width),
                                 height: float64(o.height)))
  var content = size
  if not o.useContentSize:
    content = msgRectForRect(`class`("NSWindow"),
      sel("contentRectForFrameRect:styleMask:"), size, style)
    content.origin = NSPoint()
  var cls = "MyNimWindow"
  if o.panel:
    ## The nonactivating style must be there from the start: the window
    ## server only learns that the window never activates its app from
    ## the style it is created with.
    cls = "MyNimPanel"
    style = style or styleNonactivatingPanel
  w.win = msgInitWindow(send(`class`(cls), "alloc"),
    sel("initWithContentRect:styleMask:backing:defer:"),
    content, style, nsBackingStoreBuffered, false)
  discard send(w.win, "setReleasedWhenClosed:", argu(0))
  w.delegate = alloc("MyNimWindowDelegate")
  discard send(w.win, "setDelegate:", argu(w.delegate))
  discard send(w.win, "setTitle:", argu(nsString(o.title)))
  ## NSWindowTabbingModeDisallowed
  discard send(w.win, "setTabbingMode:", argu(2))

  if hiddenTitleBar:
    discard send(w.win, "setTitlebarAppearsTransparent:", argu(1))
    ## NSWindowTitleHidden
    discard send(w.win, "setTitleVisibility:", argu(1))
  if o.frameless:
    for i in 0 ..< 3:
      discard send(send(w.win, "standardWindowButton:", argu(i)),
                   "setHidden:", argu(1))
  if o.titleBarStyle == "hiddenInset" and not o.frameless:
    let tb = send(send(`class`("NSToolbar"), "alloc"),
      "initWithIdentifier:", argu(nsString("mynim.titlebar")))
    discard send(tb, "setShowsBaselineSeparator:", argu(0))
    discard send(w.win, "setToolbar:", argu(tb))
    release(tb)
  if o.minSize.width > 0 or o.minSize.height > 0:
    w.setMinimumSize(o.minSize)
  if o.maxSize.width > 0 or o.maxSize.height > 0:
    w.setMaximumSize(o.maxSize)
  discard send(w.win, "setMovable:", argu(o.movable))
  if not o.maximizable:
    w.setMaximizable(false)
  var behavior = collectionFullScreenPrimary.uint
  if not o.fullscreenable:
    behavior = collectionFullScreenNone
  if o.panel:
    ## On the Space the user is on, full-screen ones included, as they
    ## switch, and out of Mission Control and the window cycle.
    behavior = (collectionCanJoinAllSpaces or collectionFullScreenAuxiliary or
                collectionIgnoresCycle or collectionTransient).uint
    ## A panel stays as the app is deactivated: the app hides it.
    discard send(w.win, "setHidesOnDeactivate:", argu(0))
  discard send(w.win, "setCollectionBehavior:", argu(behavior))
  if o.alwaysOnTop:
    discard send(w.win, "setLevel:", argu(nsFloatingWindowLevel))
  w.fillWindow(content)

  if o.center:
    discard send(w.win, "center")
  else:
    let frame = msgRect(w.win, sel("frame"))
    var r = rectFromMac(frame)
    r.x = o.x
    r.y = o.y
    msgSetRectBool(w.win, sel("setFrame:display:"), rectToMac(r), false)
  if w.trafficLights != nil:
    w.layoutTrafficLights()
    ## The window's appearance changes with the application's, or when
    ## it is given its own; either lays the title bar out again.
    discard send(w.win, "addObserver:forKeyPath:options:context:",
      argu(w.delegate), argu(nsString("effectiveAppearance")), argu(0),
      argu(0))
  w.register()

  if o.fullScreen:
    discard send(w.win, "toggleFullScreen:", argu(0))
  elif o.maximized:
    discard send(w.win, "zoom:", argu(0))

## createFlyout creates the panel of a flyout (WindowOptions.flyout):
## borderless and nonactivating, so that it never activates the app,
## and the key window only when it is focusable, while its parent
## stays the main window. It is a child window of its parent while it
## shows.
proc createFlyout(w: macWindow) =
  let o = w.opts
  let content = NSRect(size: NSSize(width: float64(o.width),
                                    height: float64(o.height)))
  w.flyout = o.flyout
  w.flyoutSize = Size(width: o.width, height: o.height)
  if w.flyout.popover:
    w.createPopover(content)
    return
  w.win = msgInitWindow(send(`class`("MyNimFlyout"), "alloc"),
    sel("initWithContentRect:styleMask:backing:defer:"),
    content, styleNonactivatingPanel, nsBackingStoreBuffered, false)
  discard send(w.win, "setReleasedWhenClosed:", argu(0))
  w.delegate = alloc("MyNimWindowDelegate")
  discard send(w.win, "setDelegate:", argu(w.delegate))
  discard send(w.win, "setTitle:", argu(nsString(o.title)))
  ## NSPanel hides when the app is deactivated: a flyout stays with its
  ## parent instead, and one that takes the keyboard closes.
  discard send(w.win, "setHidesOnDeactivate:", argu(0))
  discard send(w.win, "setCollectionBehavior:",
    argu(collectionTransient or collectionIgnoresCycle or
         collectionFullScreenAuxiliary))
  if w.flyout.tray != nil:
    ## Over the windows of other apps, as the menus of the menu bar.
    discard send(w.win, "setLevel:", argu(nsPopUpMenuWindowLevel))
  w.fillWindow(content)
  w.register()
  w.placeFlyout(w.flyout, w.flyoutSize)

## fillWindow gives a new window its look and its web view or surface.
proc fillWindow(w: macWindow, content: NSRect) =
  let o = w.opts
  discard send(w.win, "setHasShadow:", argu(o.hasShadow))
  if o.opacity < 1:
    msgSetFloat(w.win, sel("setAlphaValue:"), o.opacity)
  if o.transparent:
    discard send(w.win, "setOpaque:", argu(0))
    discard send(w.win, "setBackgroundColor:",
      argu(send(`class`("NSColor"), "clearColor")))
  elif o.backgroundColor != nil:
    discard send(w.win, "setBackgroundColor:",
                 argu(nsColor(o.backgroundColor[])))

  w.createContent(content)
  if w.surface != nil:
    discard send(w.win, "makeFirstResponder:", argu(w.surface.view))
  discard send(w.win, "setContentView:", argu(w.view))
  if o.vibrancy != "":
    w.setVibrancy(o.vibrancy)

## createContent creates the web view or the surface, in w.view.
proc createContent*(w: macWindow, content: NSRect) =
  if w.opts.surface:
    w.createSurface(content)
  else:
    w.createWebView(content)
  ## WebKit docks the inspector next to the web view, in its superview.
  ## That must not be the window's frame view: AppKit would draw a
  ## broken legacy title bar from then on.
  w.view = msgInitRect(send(`class`("NSView"), "alloc"),
    sel("initWithFrame:"), NSRect(size: content.size))
  if w.surface != nil:
    discard send(w.view, "addSubview:", argu(w.surface.view))
  else:
    discard send(w.view, "addSubview:", argu(w.web))

## register lets the delegate, the web view and the window find w.
proc register(w: macWindow) =
  let b = w.b
  b.byDelegate[w.delegate] = w
  b.byWebView[w.web] = w
  if not w.win.isNil:
    b.byNSWindow[w.win] = w

## placeFlyout places a flyout next to its anchor, in the parent's
## content area, as Flyout.place resolves it in the visible frame of a
## screen.
method placeFlyout*(w: macWindow, f: Flyout, size: Size) =
  if w.opts.flyout == nil or w.closed:
    return
  w.flyout = f
  w.flyoutSize = size
  if not w.popover.isNil:
    w.placePopover()
    return
  let displays = screenImpl().displays()
  var anchor = f.anchor
  if f.tray of tray:
    anchor = tray(f.tray).bounds()
    if anchor.width == 0 or anchor.height == 0:
      let r = centered(size, primaryWorkArea(displays))
      msgSetRectBool(w.win, sel("setFrame:display:"), rectToMac(r), true)
      return
  elif w.parent != nil and not w.parent.closed:
    let c = w.parent.contentBounds()
    anchor.x += c.x
    anchor.y += c.y
  let (r, _, _) = f.place(anchor, size, workAreaFor(anchor, displays))
  msgSetRectBool(w.win, sel("setFrame:display:"), rectToMac(r), true)

proc createWebView*(w: macWindow, content: NSRect) =
  let o = w.opts
  var cfg: id
  if o.native != 0:
    ## window.open(): WebKit hands us the configuration to use.
    cfg = retain(cast[id](o.native))
  else:
    cfg = alloc("WKWebViewConfiguration")
    for s in o.schemes:
      discard send(cfg, "setURLSchemeHandler:forURLScheme:",
                   argu(schemeHandler()), argu(nsString(s)))
  let prefs = send(cfg, "preferences")
  discard send(prefs, "setValue:forKey:", argu(nsBool(o.devTools)),
               argu(nsString("developerExtrasEnabled")))
  discard send(prefs, "setValue:forKey:", argu(nsBool(true)),
               argu(nsString("allowFileAccessFromFileURLs")))
  if respondsTo(prefs, "setElementFullscreenEnabled:"):
    discard send(prefs, "setElementFullscreenEnabled:", argu(1))

  ## Every window gets its own content controller so messages, scripts
  ## and the bridge configuration never leak between windows.
  w.ucc = alloc("WKUserContentController")
  discard send(w.ucc, "addScriptMessageHandler:name:",
               argu(w.delegate), argu(nsString("mynim")))
  w.addUserScripts()
  discard send(cfg, "setUserContentController:", argu(w.ucc))

  w.web = msgInitRectID(send(`class`("MyNimWebView"), "alloc"),
    sel("initWithFrame:configuration:"), NSRect(size: content.size),
    cfg)
  release(cfg)
  discard send(w.web, "setNavigationDelegate:", argu(w.delegate))
  discard send(w.web, "setUIDelegate:", argu(w.delegate))
  discard send(w.web, "setAutoresizingMask:",
               argu(nsViewWidthHeightSizable))
  if o.transparent or o.backgroundColor != nil or o.vibrancy != "":
    ## Let the window color show until the page paints.
    discard send(w.web, "setValue:forKey:", argu(nsBool(false)),
                 argu(nsString("drawsBackground")))
    if o.backgroundColor != nil and
        respondsTo(w.web, "setUnderPageBackgroundColor:"):
      discard send(w.web, "setUnderPageBackgroundColor:",
                   argu(nsColor(o.backgroundColor[])))
  if respondsTo(w.web, "setInspectable:"):
    discard send(w.web, "setInspectable:", argu(o.devTools))
  if o.userAgent != "":
    discard send(w.web, "setCustomUserAgent:", argu(nsString(o.userAgent)))
  if o.zoom > 0 and o.zoom != 1:
    msgSetFloat(w.web, sel("setPageZoom:"), o.zoom)
  discard send(w.web, "addObserver:forKeyPath:options:context:",
    argu(w.delegate), argu(nsString("title")), argu(1), argu(0))

## cleanup releases native resources; called from windowWillClose:.
proc cleanup*(w: macWindow) =
  if w.closed:
    return
  w.closeWebViews()
  w.closed = true
  let b = w.b
  discard send(w.web, "removeObserver:forKeyPath:", argu(w.delegate),
               argu(nsString("title")))
  if w.trafficLights != nil:
    discard send(w.win, "removeObserver:forKeyPath:", argu(w.delegate),
                 argu(nsString("effectiveAppearance")))
  discard send(w.ucc, "removeScriptMessageHandlerForName:",
               argu(nsString("mynim")))
  discard send(w.ucc, "removeAllUserScripts")
  discard send(w.web, "stopLoading")
  discard send(w.web, "setNavigationDelegate:", argu(0))
  discard send(w.web, "setUIDelegate:", argu(0))
  if not w.popover.isNil:
    w.cleanupPopover()
  else:
    discard send(w.win, "setDelegate:", argu(0))
    if w.parent != nil and not w.parent.closed:
      discard send(w.parent.win, "removeChildWindow:", argu(w.win))
  b.byDelegate.del(w.delegate)
  b.byWebView.del(w.web)
  b.byNSWindow.del(w.win)
  release(w.lastMouseDown)
  w.lastMouseDown = nil
  release(w.ucc)
  for j in printJobs.values:
    if j.w == w and j.cb != nil:
      let cb = j.cb
      j.cb = nil
      cb(@[], errDestroyed())
  if w.surface != nil:
    w.surface.destroySurface()
  release(w.effect)
  release(w.web)
  release(w.view)
  ## AppKit is still closing the window; let the pool release it.
  discard autorelease(w.delegate)
  if w.popover.isNil:
    discard autorelease(w.win)

method handle*(w: macWindow): uint = cast[uint](w.win)
method webViewHandle*(w: macWindow): uint = cast[uint](w.web)

method setTitle*(w: macWindow, title: string) =
  withPool(proc() =
    discard send(w.win, "setTitle:", argu(nsString(title))))
  w.layoutTrafficLights()

## setRepresentedFile shows the file's proxy icon in the title bar,
## which the user drags, and whose Cmd-click menu lists its folders.
method setRepresentedFile*(w: macWindow, path: string) =
  withPool(proc() =
    var url: id
    if path != "":
      url = fileURL(path)
    discard send(w.win, "setRepresentedURL:", argu(url)))
  ## AppKit lays the title bar's buttons out again.
  w.layoutTrafficLights()

## setDocumentEdited shows the dot in the close button, and dims the
## proxy icon.
method setDocumentEdited*(w: macWindow, edited: bool) =
  discard send(w.win, "setDocumentEdited:", argu(edited))
  w.layoutTrafficLights()

method title*(w: macWindow): string =
  withPool(proc() =
    result = goString(send(w.win, "title")))

method setBounds*(w: macWindow, r: platform.Rect) =
  msgSetRectBool(w.win, sel("setFrame:display:"), rectToMac(r), true)

method bounds*(w: macWindow): platform.Rect =
  rectFromMac(msgRect(w.win, sel("frame")))

method setContentBounds*(w: macWindow, r: platform.Rect) =
  let frame = msgRectToRect(w.win, sel("frameRectForContentRect:"),
                            rectToMac(r))
  msgSetRectBool(w.win, sel("setFrame:display:"), frame, true)

method contentBounds*(w: macWindow): platform.Rect =
  let frame = msgRect(w.win, sel("frame"))
  rectFromMac(msgRectToRect(w.win, sel("contentRectForFrameRect:"),
                            frame))

method setMinimumSize*(w: macWindow, s: Size) =
  msgSetSize(w.win, sel("setMinSize:"),
             NSSize(width: float64(s.width), height: float64(s.height)))

method setMaximumSize*(w: macWindow, s: Size) =
  var max = NSSize(width: float64(high(float32)),
                   height: float64(high(float32)))
  if s.width > 0:
    max.width = float64(s.width)
  if s.height > 0:
    max.height = float64(s.height)
  msgSetSize(w.win, sel("setMaxSize:"), max)

proc setStyle(w: macWindow, bit: uint, on: bool) =
  var mask = cast[uint](send(w.win, "styleMask"))
  if on:
    mask = mask or bit
  else:
    mask = mask and not bit
  discard send(w.win, "setStyleMask:", argu(mask))

proc hasStyle(w: macWindow, bit: uint): bool =
  (cast[uint](send(w.win, "styleMask")) and bit) != 0

method setResizable*(w: macWindow, v: bool) =
  w.setStyle(styleResizable, v)
method isResizable*(w: macWindow): bool = w.hasStyle(styleResizable)
method setMovable*(w: macWindow, v: bool) =
  discard send(w.win, "setMovable:", argu(v))
method isMovable*(w: macWindow): bool = sendBool(w.win, "isMovable")
method setMinimizable*(w: macWindow, v: bool) =
  w.setStyle(styleMiniaturizable, v)
method isMinimizable*(w: macWindow): bool =
  w.hasStyle(styleMiniaturizable)
method setClosable*(w: macWindow, v: bool) = w.setStyle(styleClosable, v)
method isClosable*(w: macWindow): bool = w.hasStyle(styleClosable)

method setMaximizable*(w: macWindow, v: bool) =
  discard send(send(w.win, "standardWindowButton:", argu(2)),
               "setEnabled:", argu(v))

method isMaximizable*(w: macWindow): bool =
  sendBool(send(w.win, "standardWindowButton:", argu(2)), "isEnabled")

method setAlwaysOnTop*(w: macWindow, v: bool) =
  var level = nsNormalWindowLevel.uint
  if v:
    level = nsFloatingWindowLevel
  discard send(w.win, "setLevel:", argu(level))

method isAlwaysOnTop*(w: macWindow): bool =
  sendInt(w.win, "level") != nsNormalWindowLevel

method show*(w: macWindow) =
  if not w.popover.isNil:
    w.showPopover()
    return
  if w.opts.flyout != nil:
    w.showFlyout(w.flyout.focusable)
    return
  if w.parent != nil and w.opts.modal and not w.sheet:
    w.sheet = true
    discard send(w.parent.win, "beginSheet:completionHandler:",
                 argu(w.win), argu(0))
    return
  discard send(w.win, "makeKeyAndOrderFront:", argu(0))
  if w.parent != nil and not w.parent.closed:
    discard send(w.parent.win, "addChildWindow:ordered:", argu(w.win),
                 argu(1))
  if not w.opts.panel:
    discard send(w.b.app, "activateIgnoringOtherApps:", argu(1))

## showFlyout shows a flyout above its parent, as its child window,
## and gives it the keyboard when it takes it. Showing it does not
## activate the app: it shows over a parent the user is using.
proc showFlyout(w: macWindow, key: bool) =
  if key:
    w.b.watchOutsideClicks()
    discard send(w.win, "makeKeyAndOrderFront:", argu(0))
  else:
    discard send(w.win, "orderFront:", argu(0))
  if w.parent != nil and not w.parent.closed and
      send(w.win, "parentWindow").isNil:
    ## NSWindowAbove
    discard send(w.parent.win, "addChildWindow:ordered:", argu(w.win),
                 argu(1))

## hideFlyout hides a flyout. It stops being a child window, which
## AppKit would order in again with its parent, and gives the keyboard
## it had back to the parent.
proc hideFlyout(w: macWindow) =
  let key = sendBool(w.win, "isKeyWindow")
  if w.parent != nil and not w.parent.closed:
    discard send(w.parent.win, "removeChildWindow:", argu(w.win))
    if key and sendBool(w.parent.win, "isVisible"):
      discard send(w.parent.win, "makeKeyWindow")
  discard send(w.win, "orderOut:", argu(0))

## outsideClicks is the monitor of clicks outside the app, in other
## apps or the menu bar, which close focusable flyouts as AppKit's
## transient popovers close: their panels may take the keyboard without
## the app being activated, and a click in the menu bar activates no
## other app, so they would not resign the key window. It is made
## once, as the first focusable flyout shows.
var outsideClicks: id

proc watchOutsideClicks*(b: Backend) =
  if not outsideClicks.isNil:
    return
  ## left, right and other mouse down
  const mask = (1 shl 1) or (1 shl 3) or (1 shl 25)
  let blk = mkBlockId(proc(ev: id) =
    var open: seq[macWindow]
    for w in b.byNSWindow.values:
      if w.opts.flyout != nil and w.popover.isNil and
          w.flyout.focusable and not w.closed and
          sendBool(w.win, "isVisible"):
        open.add w
    for w in open:
      if not w.closed and w.h.shouldClose():
        w.close())
  outsideClicks = retain(send(`class`("NSEvent"),
    "addGlobalMonitorForEventsMatchingMask:handler:", argu(mask),
    argu(blk)))
  b.watchAnchorPresses()

## anchorPresses is the monitor of presses in the app that eats a press
## on the anchor of a focusable flyout, which only closes the flyout,
## as AppKit's transient popovers eat a press on their positioning
## rect: the press would make the parent key, which closes the flyout
## before the release clicks what opened it, which would open it
## again. The press's drags and release are eaten too. Presses
## elsewhere go on to what is under the pointer. It is made once, with
## outsideClicks.
var anchorPresses: id

## eatingPress is the type of the release that ends a press
## anchorPresses ate, or 0. Main thread only.
var eatingPress: int

proc flyoutAnchoredAt*(b: Backend, ev: id): macWindow =
  ## flyoutAnchoredAt returns the focusable flyout that shows in a
  ## panel whose anchor is under the press ev in its parent, or nil.
  let p = b.byNSWindow.getOrDefault(send(ev, "window"))
  if p == nil or p.closed:
    return nil
  let frame = msgRect(p.win, sel("frame"))
  let c = msgRectToRect(p.win, sel("contentRectForFrameRect:"), frame)
  let loc = msgPoint(ev, sel("locationInWindow"))
  let x = loc.x - (c.origin.x - frame.origin.x)
  let y = c.origin.y - frame.origin.y + c.size.height - loc.y
  for w in b.byNSWindow.values:
    if w.parent != p or w.opts.flyout == nil or not w.popover.isNil or
        not w.flyout.focusable or w.closed or
        not sendBool(w.win, "isVisible"):
      continue
    let a = w.flyout.anchor
    if x >= float64(a.x) and y >= float64(a.y) and
        x < float64(a.x + a.width) and y < float64(a.y + a.height):
      return w

proc watchAnchorPresses*(b: Backend) =
  ## left, right and other mouse down, up and dragged
  const mask = (1 shl 1) or (1 shl 3) or (1 shl 25) or (1 shl 2) or
    (1 shl 4) or (1 shl 26) or (1 shl 6) or (1 shl 7) or (1 shl 27)
  let blk = mkBlockIdRetId(proc(ev: id): id =
    let typ = sendInt(ev, "type")
    case typ
    of 2, 4, 26: ## NSEventTypeLeftMouseUp, RightMouseUp, OtherMouseUp
      if typ == eatingPress:
        eatingPress = 0
        return nil
    of 6, 7, 27: ## LeftMouseDragged, RightMouseDragged, OtherMouseDragged
      if eatingPress != 0:
        return nil
    else:
      ## a press, which ends any other
      eatingPress = 0
      let w = b.flyoutAnchoredAt(ev)
      if w != nil:
        eatingPress = typ + 1
        if w.h.shouldClose():
          w.close()
        return nil
    return ev)
  anchorPresses = retain(send(`class`("NSEvent"),
    "addLocalMonitorForEventsMatchingMask:handler:", argu(mask),
    argu(blk)))

## dismissFlyout closes a focusable flyout that lost the keyboard, as
## the user closing it, unless it went to a flyout of its own.
proc dismissFlyout(w: macWindow) =
  if w.closed or not w.flyout.focusable or not sendBool(w.win, "isVisible"):
    return
  var k = w.b.byNSWindow.getOrDefault(send(w.b.app, "keyWindow"))
  while k != nil:
    if k == w:
      return
    k = k.parent
  if w.h.shouldClose():
    w.close()

method showInactive*(w: macWindow) =
  if not w.popover.isNil:
    w.showPopover()
    return
  if w.opts.flyout != nil:
    w.showFlyout(false)
    return
  discard send(w.win, "orderFrontRegardless")
  if w.parent != nil and not w.parent.closed:
    discard send(w.parent.win, "addChildWindow:ordered:", argu(w.win),
                 argu(1))

method hide*(w: macWindow) =
  if not w.popover.isNil:
    w.hidePopover()
    return
  if w.opts.flyout != nil:
    w.hideFlyout()
    return
  if w.sheet:
    w.sheet = false
    discard send(w.parent.win, "endSheet:", argu(w.win))
    return
  discard send(w.win, "orderOut:", argu(0))

method isVisible*(w: macWindow): bool =
  if not w.popover.isNil:
    return sendBool(w.popover, "isShown")
  sendBool(w.win, "isVisible")

method focus*(w: macWindow) =
  if w.host != nil:
    if not w.closed:
      discard send(w.win, "makeFirstResponder:", argu(w.web))
    return
  if w.opts.flyout != nil:
    w.show() ## the key window only when it takes the keyboard
    return
  discard send(w.win, "makeKeyAndOrderFront:", argu(0))
  if not w.opts.panel:
    discard send(w.b.app, "activateIgnoringOtherApps:", argu(1))

method blur*(w: macWindow) = discard send(w.win, "orderBack:", argu(0))
method isFocused*(w: macWindow): bool = sendBool(w.win, "isKeyWindow")
method minimize*(w: macWindow) =
  discard send(w.win, "miniaturize:", argu(0))
method isMinimized*(w: macWindow): bool =
  sendBool(w.win, "isMiniaturized")

method maximize*(w: macWindow) =
  if not w.isMaximized():
    discard send(w.win, "zoom:", argu(0))

method unmaximize*(w: macWindow) =
  if w.isMaximized():
    discard send(w.win, "zoom:", argu(0))

method isMaximized*(w: macWindow): bool =
  sendBool(w.win, "isZoomed") and not w.isFullScreen()

method restore*(w: macWindow) =
  if w.isMinimized():
    discard send(w.win, "deminiaturize:", argu(0))

method setFullScreen*(w: macWindow, v: bool) =
  if v != w.isFullScreen():
    discard send(w.win, "toggleFullScreen:", argu(0))

method isFullScreen*(w: macWindow): bool = w.hasStyle(styleFullScreen)
method center*(w: macWindow) = discard send(w.win, "center")

method setBackgroundColor*(w: macWindow, c: platform.Color) =
  withPool(proc() =
    if w.host != nil:
      ## A web view's window is its host's.
      w.clipBackground(c)
    else:
      discard send(w.win, "setBackgroundColor:", argu(nsColor(c)))
    discard send(w.web, "setValue:forKey:", argu(nsBool(false)),
                 argu(nsString("drawsBackground")))
    if respondsTo(w.web, "setUnderPageBackgroundColor:"):
      discard send(w.web, "setUnderPageBackgroundColor:",
                   argu(nsColor(c))))

method setOpacity*(w: macWindow, v: float64) =
  msgSetFloat(w.win, sel("setAlphaValue:"), v)

method setProgressBar*(w: macWindow, state: string, value: float64) =
  w.b.setDockProgress(state, value)

method flashFrame*(w: macWindow, flash: bool) =
  if w.attention != 0:
    discard send(w.b.app, "cancelUserAttentionRequest:",
                 argu(w.attention))
    w.attention = 0
  if flash:
    ## NSInformationalRequest
    w.attention = sendInt(w.b.app, "requestUserAttention:", argu(10))

## setSkipTaskbar does nothing: the Dock shows applications, not
## windows.
method setSkipTaskbar*(w: macWindow, v: bool) = discard

method setVisibleOnAllWorkspaces*(w: macWindow, v: bool) =
  const canJoinAllSpaces = 1 shl 0
  var behavior = sendInt(w.win, "collectionBehavior").uint
  if v:
    behavior = behavior or canJoinAllSpaces
    ## FullScreenNone (DisableFullScreen) also keeps a window out of
    ## other apps' full-screen Spaces. As an auxiliary, the window
    ## shows there too (an accessory app's: macOS shows no regular
    ## app's windows there), and still cannot go full screen itself.
    if (behavior and collectionFullScreenNone) != 0:
      behavior = (behavior and not collectionFullScreenNone.uint) or
                 collectionFullScreenAuxiliary
      w.auxiliary = true
  else:
    behavior = behavior and not canJoinAllSpaces.uint
    if w.auxiliary:
      behavior = (behavior and not collectionFullScreenAuxiliary.uint) or
                 collectionFullScreenNone
      w.auxiliary = false
  discard send(w.win, "setCollectionBehavior:", argu(behavior))

## setIcon does nothing: macOS windows show no icon of their own.
method setIcon*(w: macWindow, png: seq[byte]) = discard
method opacity*(w: macWindow): float64 = msgFloat(w.win, sel("alphaValue"))
method setHasShadow*(w: macWindow, v: bool) =
  discard send(w.win, "setHasShadow:", argu(v))
method hasShadow*(w: macWindow): bool = sendBool(w.win, "hasShadow")
method setIgnoreMouseEvents*(w: macWindow, v: bool) =
  discard send(w.win, "setIgnoresMouseEvents:", argu(v))

method setContentProtection*(w: macWindow, v: bool) =
  var sharing = 1 ## NSWindowSharingReadOnly
  if v:
    sharing = 0 ## NSWindowSharingNone
  discard send(w.win, "setSharingType:", argu(sharing))

## vibrancyMaterials maps mynim.Vibrancy values to
## NSVisualEffectMaterial.
var vibrancyMaterials = {
  "titlebar": 3, "selection": 4, "menu": 5, "popover": 6, "sidebar": 7,
  "header": 10, "sheet": 11, "window": 12, "hud": 13,
  "fullscreen-ui": 15, "tooltip": 17, "content": 18,
  "under-window": 21, "under-page": 22,
  # Windows 11 backdrops.
  "mica": 21, "tabbed": 21, "acrylic": 13,
}.toTable

method setVibrancy*(w: macWindow, material: string) =
  withPool(proc() =
    if not vibrancyMaterials.hasKey(material):
      if material != "":
        stderr.writeLine("mynim: unknown vibrancy " & material.escape())
      if not w.effect.isNil:
        discard send(w.effect, "removeFromSuperview")
        release(w.effect)
        w.effect = nil
      return
    let m = vibrancyMaterials[material]
    if w.effect.isNil:
      w.effect = msgInitRect(send(`class`("NSVisualEffectView"),
        "alloc"), sel("initWithFrame:"),
        msgRect(w.view, sel("bounds")))
      ## NSVisualEffectBlendingModeBehindWindow
      discard send(w.effect, "setBlendingMode:", argu(0))
      ## NSVisualEffectStateActive
      discard send(w.effect, "setState:", argu(1))
      discard send(w.effect, "setAutoresizingMask:",
                   argu(nsViewWidthHeightSizable))
      ## Behind the page and a docked inspector. NSWindowBelow
      discard send(w.view, "addSubview:positioned:relativeTo:",
                   argu(w.effect), argu(high(uint)), argu(0))
      discard send(w.web, "setValue:forKey:", argu(nsBool(false)),
                   argu(nsString("drawsBackground")))
    discard send(w.effect, "setMaterial:", argu(m)))

method setMenu*(w: macWindow, m: Menu) = discard

## setAutoHideMenu does nothing: the menu bar belongs to the
## application.
method setAutoHideMenu*(w: macWindow, v: bool) = discard

method startDrag*(w: macWindow) =
  if not w.lastMouseDown.isNil:
    discard send(w.win, "performWindowDragWithEvent:",
                 argu(w.lastMouseDown))

## hiddenTitleBar reports a titleBarStyle that hides the title bar but
## keeps the traffic lights.
proc hiddenTitleBar*(w: macWindow): bool =
  let o = w.opts
  not o.frameless and
    (o.titleBarStyle == "hidden" or o.titleBarStyle == "hiddenInset")

## titleBar returns the room the traffic lights take, from the left
## edge to the right edge of the zoom button, in the title bar, which
## is as tall as the window's own or, with trafficLightPosition,
## leaves as much room below them as above. They hide in full screen.
method titleBar*(w: macWindow): platform.TitleBar =
  if not w.hiddenTitleBar() or w.closed or w.isFullScreen():
    return platform.TitleBar()
  let closeBtn = send(w.win, "standardWindowButton:", argu(0))
  let zoom = send(w.win, "standardWindowButton:", argu(2))
  if closeBtn.isNil or zoom.isNil:
    return platform.TitleBar()
  let c = msgRect(closeBtn, sel("frame"))
  let z = msgRect(zoom, sel("frame"))
  if w.trafficLights != nil:
    let p = w.trafficLights
    ## Where layoutTrafficLights puts them, which may not have run yet.
    let right = float64(p.x) + z.origin.x - c.origin.x + z.size.width
    return platform.TitleBar(height: int(round(c.size.height + 2 * float64(p.y))),
                    left: int(ceil(right)))
  let frame = msgRect(w.win, sel("frame"))
  let content = msgRect(w.win, sel("contentLayoutRect"))
  let height = frame.size.height - content.origin.y - content.size.height
  platform.TitleBar(height: int(round(height)),
           left: int(ceil(z.origin.x + z.size.width)))

method titleBarDoubleClicked*(w: macWindow) =
  var action = ""
  withPool(proc() =
    let defaults = send(`class`("NSUserDefaults"),
                        "standardUserDefaults")
    action = goString(send(defaults, "stringForKey:",
                           argu(nsString("AppleActionOnDoubleClick")))))
  case action
  of "None": discard
  of "Minimize":
    discard send(w.win, "performMiniaturize:", argu(0))
  else:
    discard send(w.win, "performZoom:", argu(0))

method close*(w: macWindow) =
  if w.host != nil:
    w.closeWebView()
    return
  if w.closed:
    return
  if not w.popover.isNil:
    w.closePopover()
    return
  if w.sheet:
    w.sheet = false
    discard send(w.parent.win, "endSheet:", argu(w.win))
  if w.opts.flyout != nil:
    w.hideFlyout()
  discard send(w.win, "close")

## layoutTrafficLights puts the top-left corner of the close button at
## the requested position, and the other buttons after it, in a title
## bar that leaves as much room below them as above. AppKit lays the
## title bar out again when the window resizes, its title changes or
## the appearance changes, so this runs after each of them.
proc layoutTrafficLights*(w: macWindow) =
  let p = w.trafficLights
  if p == nil or w.closed or w.isFullScreen():
    return
  let closeBtn = send(w.win, "standardWindowButton:", argu(0))
  if closeBtn.isNil:
    return
  let container = send(send(closeBtn, "superview"), "superview")
  if container.isNil:
    return
  let btnFrame = msgRect(closeBtn, sel("frame"))
  let height = btnFrame.size.height + 2 * float64(p.y)
  let winFrame = msgRect(w.win, sel("frame"))
  var cf = msgRect(container, sel("frame"))
  cf.size.height = height
  cf.origin.y = winFrame.size.height - height
  msgSetRect(container, sel("setFrame:"), cf)

  let mini = send(w.win, "standardWindowButton:", argu(1))
  let gap = msgRect(mini, sel("frame")).origin.x - btnFrame.origin.x
  for i in 0 ..< 3:
    let btn = send(w.win, "standardWindowButton:", argu(i))
    msgSetPoint(btn, sel("setFrameOrigin:"),
      NSPoint(x: float64(p.x) + float64(i) * gap, y: float64(p.y)))

## Navigation.

method loadURL*(w: macWindow, url: string) =
  w.programmatic = true
  withPool(proc() =
    let req = send(`class`("NSURLRequest"), "requestWithURL:",
                   argu(nsURL(url)))
    discard send(w.web, "loadRequest:", argu(req)))

method loadHTML*(w: macWindow, html, baseURL: string) =
  w.programmatic = true
  withPool(proc() =
    var base: id
    if baseURL != "":
      base = nsURL(baseURL)
    discard send(w.web, "loadHTMLString:baseURL:",
                 argu(nsString(html)), argu(base)))

method loadFile*(w: macWindow, path, readAccessDir: string) =
  w.programmatic = true
  withPool(proc() =
    discard send(w.web, "loadFileURL:allowingReadAccessToURL:",
                 argu(fileURL(path)), argu(fileURL(readAccessDir))))

method reload*(w: macWindow, ignoreCache: bool) =
  if ignoreCache:
    discard send(w.web, "reloadFromOrigin")
  else:
    discard send(w.web, "reload")

method stopLoading*(w: macWindow) = discard send(w.web, "stopLoading")
method goBack*(w: macWindow) = discard send(w.web, "goBack")
method goForward*(w: macWindow) = discard send(w.web, "goForward")
method canGoBack*(w: macWindow): bool = sendBool(w.web, "canGoBack")
method canGoForward*(w: macWindow): bool =
  sendBool(w.web, "canGoForward")
method isLoading*(w: macWindow): bool = sendBool(w.web, "isLoading")

method url*(w: macWindow): string =
  withPool(proc() =
    result = goString(send(send(w.web, "URL"), "absoluteString")))

## addUserScripts gives the content controller the scripts of the
## options, and the script that tells the bridge the room of the
## traffic lights.
proc addUserScripts*(w: macWindow) =
  for s in w.opts.userScripts:
    var injection = 0u ## WKUserScriptInjectionTimeAtDocumentStart
    if s.atDocumentEnd:
      injection = 1
    let script = send(send(`class`("WKUserScript"), "alloc"),
      "initWithSource:injectionTime:forMainFrameOnly:",
      argu(nsString(s.source)), argu(injection), argu(not s.allFrames))
    discard send(w.ucc, "addUserScript:", argu(script))
    release(script)
  if w.hiddenTitleBar():
    ## After the bridge, which it tells: the room of the traffic lights.
    let script = send(send(`class`("WKUserScript"), "alloc"),
      "initWithSource:injectionTime:forMainFrameOnly:",
      argu(nsString(bridge.titleBarScript(w.titleBar(), w.opts.zoom))),
      argu(0), argu(1))
    discard send(w.ucc, "addUserScript:", argu(script))
    release(script)

method setUserScripts*(w: macWindow, scripts: seq[UserScript]) =
  if w.closed or w.ucc.isNil:
    return
  w.opts.userScripts = scripts
  withPool(proc() =
    discard send(w.ucc, "removeAllUserScripts")
    w.addUserScripts())

method eval*(w: macWindow, js: string) =
  withPool(proc() =
    discard send(w.web, "evaluateJavaScript:completionHandler:",
                 argu(nsString(js)), argu(0)))

method callAsyncFunction*(w: macWindow, body: string,
    cb: proc(r: string, err: ref CatchableError)) =
  if not respondsTo(w.web,
      "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:"):
    cb("", newException(ValueError,
                        "mynim: Eval requires macOS 11 or later"))
    return
  withPool(proc() =
    let blk = mkBlockIdId(proc(result, err: id) =
      if not err.isNil:
        cb("", nsError(err))
        return
      cb(goString(result), nil))
    defer: blockRelease(blk)
    discard send(w.web,
      "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:",
      argu(nsString(body)), argu(0), argu(0),
      argu(send(`class`("WKContentWorld"), "pageWorld")), argu(blk)))

method setZoom*(w: macWindow, factor: float64) =
  msgSetFloat(w.web, sel("setPageZoom:"), factor)
method zoom*(w: macWindow): float64 = msgFloat(w.web, sel("pageZoom"))

method setUserAgent*(w: macWindow, ua: string) =
  withPool(proc() =
    var s: id
    if ua != "":
      s = nsString(ua)
    discard send(w.web, "setCustomUserAgent:", argu(s)))

method userAgent*(w: macWindow): string =
  withPool(proc() =
    result = goString(send(w.web, "customUserAgent"))
    if result == "" and respondsTo(w.web, "_userAgent"):
      result = goString(send(w.web, "_userAgent")))

proc inspector(w: macWindow): id =
  if not w.opts.devTools or not respondsTo(w.web, "_inspector"):
    return nil
  send(w.web, "_inspector")

method openDevTools*(w: macWindow) =
  let i = w.inspector()
  if not i.isNil:
    discard send(i, "show")

method closeDevTools*(w: macWindow) =
  let i = w.inspector()
  if not i.isNil:
    discard send(i, "close")

method isDevToolsOpened*(w: macWindow): bool =
  let i = w.inspector()
  not i.isNil and respondsTo(i, "isVisible") and sendBool(i, "isVisible")

method capturePage*(w: macWindow,
                    cb: proc(png: seq[byte], err: ref CatchableError)) =
  withPool(proc() =
    let blk = mkBlockIdId(proc(img, err: id) =
      if not err.isNil or img.isNil:
        cb(@[], nsError(err))
        return
      withPool(proc() = cb(pngFromImage(img), nil)))
    defer: blockRelease(blk)
    discard send(w.web,
      "takeSnapshotWithConfiguration:completionHandler:", argu(0),
      argu(blk)))

## pngFromImage encodes an NSImage as PNG.
proc pngFromImage(img: id): seq[byte] =
  let tiff = send(img, "TIFFRepresentation")
  let rep = send(`class`("NSBitmapImageRep"), "imageRepWithData:",
                 argu(tiff))
  if rep.isNil:
    return
  ## NSBitmapImageFileTypePNG
  let data = send(rep, "representationUsingType:properties:", argu(4),
    argu(send(`class`("NSDictionary"), "dictionary")))
  goBytes(data)

## securityOrigin renders a WKSecurityOrigin like a URL origin.
proc securityOrigin(o: id): string =
  result = goString(send(o, "protocol")) & "://" &
           goString(send(o, "host"))
  let port = sendInt(o, "port")
  if port != 0:
    result &= ":" & $port

proc errDestroyed*(): ref CatchableError =
  newException(ValueError, "mynim: window has been destroyed")

## printToPDF saves the page as a PDF (macOS 11); a job whose window
## closes may never end: WebKit leaves it waiting for the page, so the
## window's cleanup gives cb errDestroyed, and done releases what the
## job holds if it ends after all.
method printToPDF*(w: macWindow, o: PDFOptions,
                   cb: proc(pdf: seq[byte], err: ref CatchableError)) =
  if not respondsTo(w.web, "printOperationWithPrintInfo:"):
    cb(@[], newException(ValueError,
      "mynim: printing to PDF needs macOS 11 or later"))
    return
  var f: File
  var path: string
  try:
    (f, path) = createTempFile("mynim-", ".pdf", "")
    f.close()
  except OSError as e:
    cb(@[], e)
    return
  withPool(proc() =
    let info = autorelease(send(
      send(`class`("NSPrintInfo"), "sharedPrintInfo"), "copy"))
    discard send(info, "setJobDisposition:",
                 argu(appKitString("NSPrintSaveJob")))
    let url = send(`class`("NSURL"), "fileURLWithPath:",
                   argu(nsString(path)))
    discard send(send(info, "dictionary"), "setObject:forKey:",
                 argu(url), argu(appKitString("NSPrintJobSavingURL")))
    const points = 72.0
    var width = o.pageWidth
    var height = o.pageHeight
    var orientation = 0 ## NSPaperOrientationPortrait
    if o.landscape:
      swap(width, height)
      orientation = 1
    msgSetSize(info, sel("setPaperSize:"),
               NSSize(width: width * points, height: height * points))
    discard send(info, "setOrientation:", argu(orientation))
    msgSetFloat(info, sel("setTopMargin:"), o.marginTop * points)
    msgSetFloat(info, sel("setRightMargin:"), o.marginRight * points)
    msgSetFloat(info, sel("setBottomMargin:"), o.marginBottom * points)
    msgSetFloat(info, sel("setLeftMargin:"), o.marginLeft * points)
    ## fit the width, like browsers; as many pages as it takes
    discard send(info, "setHorizontalPagination:", argu(1))
    discard send(info, "setVerticalPagination:", argu(0))
    discard send(info, "setHorizontallyCentered:", argu(0))
    discard send(info, "setVerticallyCentered:", argu(0))
    ## The preferences are shared with the configuration's copy. They
    ## are kept for the job, which may end after the window closed.
    let prefs = retain(send(send(w.web, "configuration"),
                            "preferences"))
    ## macOS 13.3
    let backgrounds = respondsTo(prefs, "setShouldPrintBackgrounds:")
    var printedBackgrounds = false
    if backgrounds:
      printedBackgrounds = sendBool(prefs, "shouldPrintBackgrounds")
      discard send(prefs, "setShouldPrintBackgrounds:",
                   argu(o.background))
    ## Kept until it ran: nothing else holds on to it.
    let op = retain(send(w.web, "printOperationWithPrintInfo:",
                         argu(info)))
    discard send(op, "setShowsPrintPanel:", argu(0))
    discard send(op, "setShowsProgressPanel:", argu(0))
    msgSetRect(send(op, "view"), sel("setFrame:"),
               msgRect(w.web, sel("bounds")))
    var job = cast[uint](printJobs.len + 1)
    while printJobs.hasKey(job):
      inc job
    let j = printJob(w: w, cb: cb)
    j.done = proc(success: bool) =
      release(op)
      if backgrounds:
        discard send(prefs, "setShouldPrintBackgrounds:",
                     argu(printedBackgrounds))
      release(prefs)
      var data: seq[byte]
      var err: ref CatchableError
      try:
        data = cast[seq[byte]](readFile(path))
      except OSError as e:
        err = e
      removeFile(path)
      if j.cb == nil:
        return
      if err == nil and (not success or data.len == 0):
        err = newException(ValueError,
                           "mynim: printing to PDF failed")
      j.cb(data, err)
    printJobs[job] = j
    ## The app's delegate hears of the end, as the window's may be
    ## gone.
    discard send(op,
      "runOperationModalForWindow:delegate:didRunSelector:contextInfo:",
      argu(w.win), argu(w.b.delegate),
      argu(sel("mynimPrintOperationDidRun:success:contextInfo:")),
      argu(job)))

method print*(w: macWindow) =
  if not respondsTo(w.web, "printOperationWithPrintInfo:"):
    return
  withPool(proc() =
    let info = send(`class`("NSPrintInfo"), "sharedPrintInfo")
    ## Kept until it ran: nothing else holds on to it.
    let op = retain(send(w.web, "printOperationWithPrintInfo:",
                         argu(info)))
    let view = send(op, "view")
    msgSetRect(view, sel("setFrame:"), msgRect(w.web, sel("bounds")))
    discard send(op,
      "runOperationModalForWindow:delegate:didRunSelector:contextInfo:",
      argu(w.win), argu(0), argu(0), argu(0)))

## draggedFiles returns the paths of the files on the pasteboard of a
## drag.
proc draggedFiles(info: id): seq[string] =
  withPool(proc() =
    let opts = send(`class`("NSDictionary"),
      "dictionaryWithObject:forKey:", argu(nsBool(true)),
      argu(nsString("NSPasteboardURLReadingFileURLsOnlyKey")))
    let urls = send(send(info, "draggingPasteboard"),
      "readObjectsForClasses:options:",
      argu(nsArray(`class`("NSURL"))), argu(opts))
    for u in arrayItems(urls):
      let p = goString(send(send(u, "filePathURL"), "path"))
      if p != "":
        result.add p)

method droppedFiles*(w: macWindow): seq[string] =
  result = w.dropped
  w.dropped = @[]

proc windowFor*(b: Backend, delegate: id): macWindow =
  let w = b.byDelegate.getOrDefault(delegate)
  if w == nil or w.closed:
    return nil
  w

## msgExitEvent builds an enterExitEventWithType: NSEvent (leave).
proc msgExitEvent(cls: id, s: SEL, typ: uint, loc: NSPoint, flags: uint,
                  ts: float64, wn: int, ctx: id, en, tn: int,
                  data: uint): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

## leave tells the page of the web view w that the pointer left it, as
## it went onto what the content painted over the page: an exit
## outside the view, which WebKit takes as a move there, unhovering
## what was under the pointer.
proc leave*(w: macWindow, ev: id) =
  ## NSEventTypeMouseExited
  const typeMouseExited = 9
  let exit = msgExitEvent(`class`("NSEvent"),
    sel("enterExitEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:trackingNumber:userData:"),
    typeMouseExited, NSPoint(x: -1e5, y: -1e5), 0,
    msgFloat(ev, sel("timestamp")),
    sendInt(w.win, "windowNumber"), nil, 0, 0, 0)
  discard sendSuper(w.web, "MyNimWebView", sel("mouseExited:"),
                    argu(exit))

proc registerWindowClasses*() =
  # WebKit moves the keyboard out of a page past its ends through the
  # window's key view loop: a web view in native UI gives it back to
  # the content.
  proc selectKeyView(cls: string, back: bool): pointer =
    cast[pointer](proc(self: id, cmd: SEL, view: id) {.cdecl.} =
      let w = webViewOf(view)
      if w != nil and w.host != nil:
        w.tabOut(back)
        return
      discard sendSuper(self, cls, cmd, argu(view)))

  discard classDef("MyNimWindow", "NSWindow", @[], @[
    methodDef("canBecomeKeyWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    methodDef("canBecomeMainWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    methodDef("selectKeyViewFollowingView:",
      selectKeyView("MyNimWindow", false), "v@:@"),
    methodDef("selectKeyViewPrecedingView:",
      selectKeyView("MyNimWindow", true), "v@:@"),
  ])

  # A panel (WindowOptions.panel) takes the keyboard, without
  # activating the app, and is never the main window.
  discard classDef("MyNimPanel", "NSPanel", @[], @[
    methodDef("canBecomeKeyWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    methodDef("canBecomeMainWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = false),
      "B@:"),
    # NSPanel closes on an Escape its content leaves
    # (cancelOperation:), past windowShouldClose: mynim closes it
    # then, as the user closing it, which OnClose listeners may
    # prevent.
    methodDef("cancelOperation:",
      cast[pointer](proc(self: id, cmd: SEL, sender: id) {.cdecl.} =
        discard),
      "v@:@"),
    methodDef("selectKeyViewFollowingView:",
      selectKeyView("MyNimPanel", false), "v@:@"),
    methodDef("selectKeyViewPrecedingView:",
      selectKeyView("MyNimPanel", true), "v@:@"),
  ])

  # A flyout's panel becomes the key window only when it takes the
  # keyboard, and never the main window: its parent stays it.
  discard classDef("MyNimFlyout", "NSPanel", @[], @[
    methodDef("canBecomeKeyWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let w = theBackend.byNSWindow.getOrDefault(self)
        w != nil and w.flyout.focusable),
      "B@:"),
    methodDef("canBecomeMainWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = false),
      "B@:"),
    methodDef("selectKeyViewFollowingView:",
      selectKeyView("MyNimFlyout", false), "v@:@"),
    methodDef("selectKeyViewPrecedingView:",
      selectKeyView("MyNimFlyout", true), "v@:@"),
  ])

  registerClipViewClass()
  var webMethods = webViewMethods()
  webMethods.add @[
    methodDef("mouseDown:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        var w = theBackend.byWebView.getOrDefault(self)
        if w != nil:
          if w.host != nil:
            w.pressed(ev, 0)
          # A web view's page drags the window it is in (startDrag).
          w = w.top()
          release(w.lastMouseDown)
          w.lastMouseDown = retain(ev)
        discard sendSuper(self, "MyNimWebView", cmd, argu(ev))),
      "v@:@"),
    # Files dropped on the page: the page gets File objects, the app
    # their paths.
    methodDef("performDragOperation:",
      cast[pointer](proc(self: id, cmd: SEL, info: id): bool {.cdecl.} =
        let w = theBackend.byWebView.getOrDefault(self)
        if w != nil:
          w.dropped = draggedFiles(info)
        (cast[uint](sendSuper(self, "MyNimWebView", cmd,
          argu(info))) and 0xff) != 0),
      "B@:@"),
  ]
  discard classDef("MyNimWebView", "WKWebView", @[], webMethods)

  discard classDef("MyNimWindowDelegate", "NSObject",
    @["NSWindowDelegate", "WKNavigationDelegate", "WKUIDelegate",
      "WKScriptMessageHandler", "WKDownloadDelegate",
      "NSPopoverDelegate"],
    popoverDelegateMethods() & @[
    # NSWindowDelegate
    methodDef("windowShouldClose:",
      cast[pointer](proc(self: id, cmd: SEL, sender: id): bool {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          return w.h.shouldClose()
        true),
      "B@:@"),
    # WKUIDelegate (macOS 12): camera and microphone requests.
    methodDef("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, origin, frame: id,
                         typ: int, handler: pointer) {.cdecl.} =
        # WKPermissionDecision
        const grant = 1
        const deny = 2
        var decision = deny
        let w = theBackend.windowFor(self)
        if w != nil:
          let kinds = case typ
            of 0: @["camera"]
            of 1: @["microphone"]
            else: @["camera", "microphone"]
          if w.h.permissionRequested(kinds, securityOrigin(origin)):
            decision = grant
        callBlock(handler, @[decision.uint])),
      "v@:@@@q?"),
    methodDef("windowWillClose:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.cleanup()
          w.h.closed()),
      "v@:@"),
    methodDef("windowDidBecomeKey:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.focused()
          w.surfaceKeyChanged(true)),
      "v@:@"),
    methodDef("windowDidResignKey:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.blurred()
          w.surfaceKeyChanged(false)
          if w.opts.flyout != nil and w.popover.isNil:
            # Once AppKit made another window key, or none, unless
            # the press on its tray icon toggles it.
            if not (w.flyout.tray of tray) or
                not tray(w.flyout.tray).pressed():
              let ww = w
              theBackend.post(proc() = ww.dismissFlyout())),
      "v@:@"),
    methodDef("windowDidResize:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w == nil:
          return
        w.layoutTrafficLights()
        let z = w.isMaximized()
        if z != w.maximized:
          w.maximized = z
          if z:
            w.h.maximized()
          else:
            w.h.unmaximized()
        w.h.resized()),
      "v@:@"),
    methodDef("windowDidMove:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.moved()),
      "v@:@"),
    methodDef("windowDidChangeOcclusionState:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil and w.surface != nil and w.surface.visibleSurface():
          discard w.surface.send(SurfaceEvent(kind: surfaceShown))),
      "v@:@"),
    methodDef("windowDidMiniaturize:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.minimized()),
      "v@:@"),
    methodDef("windowDidDeminiaturize:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.restored()),
      "v@:@"),
    # The toolbar that insets the traffic lights holds no items: in
    # full screen it hides with the menu bar instead of covering the
    # top of the page.
    methodDef("window:willUseFullScreenPresentationOptions:",
      cast[pointer](proc(self: id, cmd: SEL, win: id,
                         proposed: uint): uint {.cdecl.} =
        const autoHide = presentationFullScreen or
          presentationAutoHideMenuBar
        if not send(win, "toolbar").isNil and
            (proposed and autoHide.uint) == autoHide.uint:
          return proposed or presentationAutoHideToolbar.uint
        proposed),
      "Q@:@Q"),
    methodDef("windowDidEnterFullScreen:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.enteredFullScreen()
          if w.hiddenTitleBar():
            # the traffic lights hid
            w.h.titleBarChanged()),
      "v@:@"),
    methodDef("windowDidExitFullScreen:",
      cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.layoutTrafficLights()
          w.h.leftFullScreen()
          if w.hiddenTitleBar():
            w.h.titleBarChanged()),
      "v@:@"),

    # WKScriptMessageHandler
    methodDef("userContentController:didReceiveScriptMessage:",
      cast[pointer](proc(self: id, cmd: SEL, ucc, msg: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w == nil:
          return
        # The handler is reachable from every frame; only the page's
        # own bridge may talk to Nim.
        let frame = send(msg, "frameInfo")
        if frame.isNil or not sendBool(frame, "isMainFrame"):
          return
        let body = send(msg, "body")
        if body.isNil or not sendBool(body, "isKindOfClass:",
                                      argu(`class`("NSString"))):
          return
        w.h.message(goString(body))),
      "v@:@@"),

    # Key-value observing of the page title and the window's
    # appearance.
    methodDef("observeValueForKeyPath:ofObject:change:context:",
      cast[pointer](proc(self: id, cmd: SEL, keyPath, obj, change: id,
                         ctx: pointer) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w == nil:
          return
        case goString(keyPath)
        of "title":
          w.h.titleChanged(goString(send(w.web, "title")))
        of "effectiveAppearance":
          # AppKit lays the title bar out again after telling us.
          let ww = w
          theBackend.post(proc() = ww.layoutTrafficLights())
        else: discard),
      "v@:@@@^v"),

    # WKNavigationDelegate
    methodDef("webView:decidePolicyForNavigationAction:decisionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, action: id,
                         handler: pointer) {.cdecl.} =
        # A link with the download attribute (macOS 11.3).
        if respondsTo(action, "shouldPerformDownload") and
            sendBool(action, "shouldPerformDownload"):
          # WKNavigationActionPolicyDownload
          callBlock(handler, @[2u])
          return
        var allow = true
        let w = theBackend.windowFor(self)
        if w != nil:
          let frame = send(action, "targetFrame")
          let navType = sendInt(action, "navigationType")
          # WKNavigationType: link, form, back/forward, reload, ...
          var nav = platform.Navigation(
            url: goString(send(send(send(action, "request"), "URL"),
                               "absoluteString")),
            isMainFrame: not frame.isNil and
              sendBool(frame, "isMainFrame"),
            userInitiated: navType == 0 or navType == 1,
            unasked: navType == 2 or navType == 3,
            reload: navType == 3)
          if nav.isMainFrame and w.programmatic:
            w.programmatic = false
            nav.unasked = true
          allow = w.h.willNavigate(nav)
        callBlock(handler, @[argu(allow)])),
      "v@:@@@?"),
    # Responses the page cannot show, or sent as attachments, are
    # downloads (macOS 11.3).
    methodDef("webView:decidePolicyForNavigationResponse:decisionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav: id,
                         handler: pointer) {.cdecl.} =
        # WKNavigationResponsePolicy
        const cancel = 0
        const allow = 1
        const download = 2
        let resp = send(nav, "response")
        let url = goString(send(send(resp, "URL"), "absoluteString"))
        var disposition = ""
        var custom = false
        if schemeDispositions.hasKey(url):
          disposition = schemeDispositions[url]
          custom = true
        elif respondsTo(resp, "allHeaderFields"):
          disposition = goString(send(send(resp, "allHeaderFields"),
            "objectForKey:", argu(nsString("Content-Disposition"))))
        let attachment = toLowerAscii(disposition.strip()).startsWith(
          "attachment")
        if not attachment and sendBool(nav, "canShowMIMEType"):
          callBlock(handler, @[allow.uint])
        elif custom:
          # WebKit cannot turn what a scheme handler serves into a
          # download: serve it again into one.
          callBlock(handler, @[cancel.uint])
          let w = theBackend.windowFor(self)
          if w != nil:
            w.h.schemeDownload(url)
        elif hasClass("WKDownload"):
          callBlock(handler, @[download.uint])
        else:
          callBlock(handler, @[cancel.uint])),
      "v@:@@@?"),
    methodDef("webView:navigationAction:didBecomeDownload:",
      cast[pointer](proc(self: id, cmd: SEL, web, action,
                         download: id) {.cdecl.} =
        discard send(download, "setDelegate:", argu(self))),
      "v@:@@@"),
    methodDef("webView:navigationResponse:didBecomeDownload:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav,
                         download: id) {.cdecl.} =
        discard send(download, "setDelegate:", argu(self))),
      "v@:@@@"),
    # WKDownloadDelegate.
    methodDef("download:decideDestinationUsingResponse:suggestedFilename:completionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, download, resp,
                         suggested: id, handler: pointer) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w == nil:
          callBlock(handler, @[0u])
          return
        let url = goString(send(
          send(send(download, "originalRequest"), "URL"),
          "absoluteString"))
        let path = w.h.downloadStarted(url, goString(suggested))
        if path == "":
          # cancels the download
          callBlock(handler, @[0u])
          return
        # WebKit refuses to replace a file
        try: removeFile(path)
        except OSError: discard
        w.downloads[download] = (url, path)
        withPool(proc() =
          callBlock(handler, @[argu(send(`class`("NSURL"),
            "fileURLWithPath:", argu(nsString(path))))]))),
      "v@:@@@?"),
    methodDef("downloadDidFinish:",
      cast[pointer](proc(self: id, cmd: SEL, download: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil and w.downloads.hasKey(download):
          let d = w.downloads[download]
          w.downloads.del(download)
          w.h.downloadFinished(d.url, d.path, nil)),
      "v@:@"),
    methodDef("download:didFailWithError:resumeData:",
      cast[pointer](proc(self: id, cmd: SEL, download, nserr,
                         resume: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil and w.downloads.hasKey(download):
          let d = w.downloads[download]
          w.downloads.del(download)
          w.h.downloadFinished(d.url, d.path,
            newException(ValueError,
              goString(send(nserr, "localizedDescription"))))),
      "v@:@@@"),
    methodDef("webView:didStartProvisionalNavigation:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.navigationStarted(w.url())),
      "v@:@@"),
    methodDef("webView:didCommitNavigation:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.navigationCommitted(w.url())),
      "v@:@@"),
    methodDef("webView:didFinishNavigation:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.loadFinished()),
      "v@:@@"),
    methodDef("webView:didFailProvisionalNavigation:withError:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav,
                         err: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.loadFailed(err)),
      "v@:@@@"),
    methodDef("webView:didFailNavigation:withError:",
      cast[pointer](proc(self: id, cmd: SEL, web, nav,
                         err: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.loadFailed(err)),
      "v@:@@@"),
    methodDef("webViewWebContentProcessDidTerminate:",
      cast[pointer](proc(self: id, cmd: SEL, web: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.renderProcessGone("terminated")),
      "v@:@"),

    # WKUIDelegate
    methodDef("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
      cast[pointer](proc(self: id, cmd: SEL, web, cfg, action,
                         features: id): id {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w == nil:
          return nil
        let num = proc(key: string): int =
          let n = send(features, key)
          if not n.isNil:
            return sendInt(n, "integerValue")
          0
        let req = platform.NewWindowRequest(
          url: goString(send(send(send(action, "request"), "URL"),
                             "absoluteString")),
          x: num("x"), y: num("y"),
          width: num("width"), height: num("height"),
          native: cast[uint](cfg))
        let child = w.h.newWindow(req)
        if not (child of macWindow) or macWindow(child) == nil:
          return nil
        macWindow(child).web),
      "@@:@@@@"),
    methodDef("webViewDidClose:",
      cast[pointer](proc(self: id, cmd: SEL, web: id) {.cdecl.} =
        let w = theBackend.windowFor(self)
        if w != nil:
          w.h.closedByPage()),
      "v@:@"),
    methodDef("webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, message, frame: id,
                         handler: pointer) {.cdecl.} =
        jsAlert(theBackend.windowFor(self), goString(message),
                handler)),
      "v@:@@@?"),
    methodDef("webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, message, frame: id,
                         handler: pointer) {.cdecl.} =
        jsConfirm(theBackend.windowFor(self), goString(message),
                  handler)),
      "v@:@@@?"),
    methodDef("webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, prompt,
                         defaultText, frame: id,
                         handler: pointer) {.cdecl.} =
        jsPrompt(theBackend.windowFor(self), goString(prompt),
                 goString(defaultText), handler)),
      "v@:@@@@?"),
    methodDef("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
      cast[pointer](proc(self: id, cmd: SEL, web, params, frame: id,
                         handler: pointer) {.cdecl.} =
        jsFileInput(theBackend.windowFor(self), params, handler)),
      "v@:@@@?"),
  ])

proc loadFailed(w: macWindow, err: id) =
  let code = sendInt(err, "code")
  # Cancelled (-999) and "frame load interrupted" (102) happen when a
  # navigation is replaced or denied; they are not failures.
  if code == -999 or code == 102:
    return
  var url, desc: string
  withPool(proc() =
    let info = send(err, "userInfo")
    url = goString(send(info, "objectForKey:",
      argu(nsString("NSErrorFailingURLStringKey"))))
    desc = goString(send(err, "localizedDescription")))
  w.h.loadFailed(url, code, desc)
