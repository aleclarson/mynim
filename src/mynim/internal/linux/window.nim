## window.nim: the window — a GtkWindow holding a menu bar and a
## WebKitWebView or a native surface, and its callbacks. data of a signal
## carries the window id.

# GDK window state flags.
const
  stateIconified = 1'u32 shl 1
  stateMaximized = 1'u32 shl 2
  stateFullscreen0 = 1'u32 shl 4
  stateAbove = 1'u32 shl 5
  stateFocused = 1'u32 shl 7
  stateTiled = 1'u32 shl 8
  # The edges the window manager lets resize (GDK 3.22.23 and later).
  stateTopResizable = 1'u32 shl 10
  stateRightResizable = 1'u32 shl 12
  stateBottomResizable = 1'u32 shl 14
  stateLeftResizable = 1'u32 shl 16

proc window*(b: Backend, data: pointer): gtkWindow =
  var w = b.windows.getOrDefault(cast[int](data))
  if w.isNil:
    w = b.webViews.getOrDefault(cast[int](data))
  if w.isNil or w.closed:
    return nil
  w

proc surfaceOf*(b: Backend, data: pointer): gtkSurface =
  let w = b.window(data)
  if w.isNil: nil
  elif w.host != nil: w.host.surface
  else: w.surface

proc createSurface*(w: gtkWindow) ## surface.nim
proc createWebView*(w: gtkWindow) ## below
proc applyGeometry*(w: gtkWindow) ## below
proc addUserScripts*(w: gtkWindow) ## below
proc undecorated*(w: gtkWindow): bool ## below
proc hiddenTitleBar*(w: gtkWindow): bool ## below
proc contentInsets*(w: gtkWindow): extents ## below
proc frameExtents*(w: gtkWindow): extents ## below
proc setBounds*(w: gtkWindow, r0: platform.Rect, inside: bool) ## below
proc selectionPaths*(sel: pointer): seq[string] ## surface_drop.nim
proc gdkMods*(state: uint32): platform.Modifiers ## surface.nim
proc decideResponse*(w: gtkWindow, decision: pointer): bool ## below
proc surfaceToPNG*(surface: pointer):
    tuple[png: seq[byte], err: ref CatchableError] ## below
proc destroy*(s: gtkSurface) ## surface.nim
proc windowManager*(b: Backend, win: pointer): bool ## app.nim
proc drawsGL*(s: gtkSurface): bool ## surface.nim
proc releaseCursor*(w: gtkWindow) ## below
proc closeWebViews*(w: gtkWindow) ## webview.nim
proc closeWebView*(w: gtkWindow) ## webview.nim

proc webViewPressed*(w: gtkWindow, x, y: float64, button: uint32,
  mods: platform.Modifiers) ## webview.nim
proc top*(w: gtkWindow): gtkWindow ## webview.nim
proc tabInto*(w: gtkWindow, back: bool) ## webview.nim

var
  cbDeleteEvent*, cbDestroy*, cbFocusIn*, cbFocusOut*, cbConfigure*,
    cbWindowState*: pointer
  cbScriptMessage*, cbLoadChanged*, cbLoadFailed*, cbTitle*,
    cbDecidePolicy*: pointer
  cbCreate*, cbClose*, cbCrashed*, cbButtonPress*, cbPNGWrite*: pointer
  cbDragData*, cbDragDrop*, cbPrintFinished*, cbPrintFailed*,
    cbPermission*: pointer
  cbMotion*, cbActivationResize*: pointer

method newWindow*(b: Backend, opts: WindowOptions, h: WindowHandler):
    tuple[w: Window, err: ref CatchableError] =
  let o = opts
  if not o.surface:
    let err = webKit()
    if not err.isNil:
      return (nil, err)
  inc b.nextID
  let opts = new(WindowOptions)
  opts[] = o
  let w = gtkWindow(b: b, id: b.nextID, h: h, opts: opts,
    autoHideMenu: o.autoHideMenu)
  let data = cast[pointer](w.id)

  var typ = 0'i32 # GTK_WINDOW_TOPLEVEL
  if o.flyout != nil and o.flyout.tray == nil:
    typ = 1 # GTK_WINDOW_POPUP
  w.win = gtkWindowNew(typ)
  gtkWindowSetTitle(w.win, cs(o.title))
  if o.panel:
    discard w.initLayer() # before anything realizes the window
  if o.center:
    gtkWindowSetPosition(w.win, 1) # GTK_WIN_POS_CENTER
  else:
    gtkWindowMove(w.win, int32(o.x), int32(o.y))
  gtkWindowSetResizable(w.win, o.resizable)
  gtkWindowSetDeletable(w.win, o.closable)
  if w.undecorated():
    gtkWindowSetDecorated(w.win, false)
  if o.alwaysOnTop:
    w.setAlwaysOnTop(true)
  if o.skipTaskbar:
    gtkWindowSetSkipTaskbarHint(w.win, true)
  if o.opacity > 0 and o.opacity < 1:
    gtkWidgetSetOpacity(w.win, o.opacity)
  w.minW = int32(o.minSize.width)
  w.minH = int32(o.minSize.height)
  w.maxW = int32(o.maxSize.width)
  w.maxH = int32(o.maxSize.height)
  w.applyGeometry()
  if o.transparent:
    let visual = gdkScreenGetRGBAVisual(gtkWidgetGetScreen(w.win))
    if not visual.isNil:
      gtkWidgetSetVisual(w.win, visual)
    gtkWidgetSetAppPaintable(w.win, true)
  let p = gtkWindow(o.parent)
  if p != nil:
    gtkWindowSetTransientFor(w.win, p.win)
    if o.modal:
      gtkWindowSetModal(w.win, true)

  w.box = gtkBoxNew(1, 0) # vertical
  # GTK makes a window whose child has no natural size, as the web
  # view, 200x200 by nature, and one the user cannot resize never
  # smaller than its natural size.
  gtkWidgetSetSizeRequest(w.box, 1, 1)
  gtkContainerAdd(w.win, w.box)
  if w.hiddenTitleBar():
    w.newControls()
  if o.surface:
    w.createSurface()
  else:
    w.createWebView()
  if w.controls != nil:
    gtkContainerAdd(w.controls.overlay, w.contentWidget())
  else:
    gtkBoxPackStart(w.box, w.contentWidget(), true, true, 0)
  w.accel = gtkAccelGroupNew()
  gtkWindowAddAccelGroup(w.win, w.accel)
  if b.appMenu != nil and w.hasAppMenu():
    w.installMenu(b.appMenu)
  # GTK sizes the window inside the window manager's frame, with the
  # menu bar.
  var width = int32(o.width)
  var height = int32(o.height)
  if o.useContentSize:
    let `in` = w.contentInsets()
    width += `in`.left + `in`.right
    height += `in`.top + `in`.bottom
  else:
    let f = w.frameExtents()
    width -= f.left + f.right
    height -= f.top + f.bottom
  gtkWindowSetDefaultSize(w.win, max(width, 1'i32), max(height, 1'i32))
  if w.layer:
    w.sizeLayer(max(width, 1'i32), max(height, 1'i32))

  discard connect(w.win, "delete-event", cbDeleteEvent, data)
  discard connect(w.win, "destroy", cbDestroy, data)
  discard connect(w.win, "focus-in-event", cbFocusIn, data)
  discard connect(w.win, "focus-out-event", cbFocusOut, data)
  discard connect(w.win, "configure-event", cbConfigure, data)
  discard connect(w.win, "window-state-event", cbWindowState, data)
  discard connect(w.win, "key-press-event", cbMenuKey, data)
  discard connect(w.win, "key-release-event", cbMenuKey, data)

  b.windows[w.id] = w
  if not w.web.isNil:
    b.byWebView[w.web] = w
  if o.frameless and o.flyout == nil and not w.layer and
      b.announceCSD != nil:
    # GTK asks a Wayland compositor that speaks
    # org_kde_kwin_server_decoration (KWin, COSMIC, Sway…) to decorate
    # every window it does not decorate itself, an undecorated one too:
    # say the window decorates itself, before it is mapped, so that the
    # compositor draws no title bar.
    gtkWidgetRealize(w.win)
    b.announceCSD(gtkWidgetGetWindow(w.win))
  gtkWidgetShowAll(w.box)
  if o.flyout != nil:
    w.initFlyout()
  if o.panel:
    w.initPanel()
  if o.fullScreen:
    gtkWindowFullscreen(w.win)
  elif o.maximized:
    gtkWindowMaximize(w.win)
  (w, nil)

proc createWebView*(w: gtkWindow) =
  let o = w.opts
  let data = cast[pointer](w.id)
  if w.asWebView.isNil:
    w.asWebView = gtkWebView(w: w)
  w.ucm = webkitUserContentManagerNew()
  if not w.b.webLanguages:
    # The first web view: WebKit just loaded.
    w.b.webLanguages = true
    w.b.applyWebLanguages()
  for s in o.schemes:
    w.b.registerScheme(s)
  w.web = webkitWebViewNewWithUserContentManager(w.ucm)
  discard webkitUserContentManagerRegisterHandler(w.ucm, cs("mynim"))
  discard connect(w.ucm, "script-message-received::mynim",
    cbScriptMessage, data)
  w.addUserScripts()

  let settings = webkitWebViewGetSettings(w.web)
  webkitSettingsSetEnableDeveloperExtras(settings, o.devTools)
  webkitSettingsSetAllowFileAccessFromFileURLs(settings, true)
  webkitSettingsSetJavascriptCanAccessClipboard(settings, true)
  if o.userAgent != "":
    webkitSettingsSetUserAgent(settings, cs(o.userAgent))
  if o.zoom > 0 and o.zoom != 1:
    webkitWebViewSetZoomLevel(w.web, o.zoom)
  if o.transparent:
    var empty: gdkRGBA
    webkitWebViewSetBackgroundColor(w.web, addr empty)
  elif o.backgroundColor != nil:
    w.setBackgroundColor(o.backgroundColor[])

  discard connect(w.web, "load-changed", cbLoadChanged, data)
  discard connect(w.web, "load-failed", cbLoadFailed, data)
  discard connect(w.web, "notify::title", cbTitle, data)
  discard connect(w.web, "decide-policy", cbDecidePolicy, data)
  discard connect(w.web, "create", cbCreate, data)
  discard connect(w.web, "close", cbClose, data)
  discard connect(w.web, "web-process-terminated", cbCrashed, data)
  discard connect(w.web, "button-press-event", cbButtonPress, data)
  if w.undecorated():
    discard connect(w.web, "motion-notify-event", cbMotion, data)
  discard connect(w.web, "drag-data-received", cbDragData, data)
  discard connect(w.web, "drag-drop", cbDragDrop, data)
  discard connect(w.web, "permission-request", cbPermission, data)
  hookDownloads()

proc applyGeometry*(w: gtkWindow) =
  var g = gdkGeometry(minWidth: w.minW, minHeight: w.minH,
    maxWidth: w.maxW, maxHeight: w.maxH)
  var mask = 0'i32
  if w.minW > 0 or w.minH > 0:
    mask = mask or 1'i32 shl 1 # GDK_HINT_MIN_SIZE
  if w.maxW > 0 or w.maxH > 0:
    if g.maxWidth == 0:
      g.maxWidth = 1'i32 shl 20
    if g.maxHeight == 0:
      g.maxHeight = 1'i32 shl 20
    mask = mask or 1'i32 shl 2 # GDK_HINT_MAX_SIZE
  gtkWindowSetGeometryHints(w.win, nil, addr g, mask)

proc cleanup*(w: gtkWindow) =
  if w.closed: return
  w.closeWebViews()
  w.closed = true
  w.b.windows.del(w.id)
  w.b.flyouts.keepItIf(it != w)
  w.b.byWebView.del(w.web)
  dropOwner(w.owner)
  if w.surface != nil:
    w.surface.destroy()
  if not w.ucm.isNil:
    webkitUserContentManagerUnregisterHandler(w.ucm, cs("mynim"))
    webkitUserContentManagerRemoveAllScripts(w.ucm)
    gObjectUnref(w.ucm)
  if not w.press.event.isNil:
    gdkEventFree(w.press.event)
    w.press.event = nil
  w.releaseCursor()

method handle*(w: gtkWindow): uint = cast[uint](w.win)
method webViewHandle*(w: gtkWindow): uint = cast[uint](w.web)

method setTitle*(w: gtkWindow, title: string) =
  gtkWindowSetTitle(w.win, cs(title))
method title*(w: gtkWindow): string =
  goStr(gtkWindowGetTitle(w.win))

# The core marks the title of an edited document; GTK shows no file.
method setRepresentedFile*(w: gtkWindow, path: string) = discard
method setDocumentEdited*(w: gtkWindow, edited: bool) = discard

## frameExtents returns the extents of the frame a reparenting window
## manager puts around the window on X11, title bar and borders: GTK
## sizes the window inside it and positions the frame (NORTH_WEST
## gravity). They are known once the window manager framed the window
## that shows, which its first own (synthetic) configure report tells.
## Until then the window expects the frame it had last, or the one seen
## last around a decorated window in its normal state that the user can
## resize or not as this one, or none. Wayland tells no positions, and
## its compositors' decorations have no say in GTK's sizes.
proc frameExtents*(w: gtkWindow): extents =
  if not w.b.onX11:
    return extents()
  var resizable = 0
  if gtkWindowGetResizable(w.win):
    resizable = 1
  if not w.framed or not gtkWidgetGetMapped(w.win):
    if w.seenFrame:
      return w.frame
    if w.undecorated():
      return extents()
    return w.b.frames[resizable]
  let gdkWin = gtkWidgetGetWindow(w.win)
  var frame: gdkRectangle
  gdkWindowGetFrameExtents(gdkWin, addr frame)
  var x, y, width, height: int32
  discard gdkWindowGetOrigin(gdkWin, addr x, addr y)
  gdkWindowGetGeometry(gdkWin, nil, nil, addr width, addr height) # from the server, as the frame
  let f = extents(left: x - frame.x, top: y - frame.y,
    right: frame.x + frame.width - x - width,
    bottom: frame.y + frame.height - y - height)
  w.frame = f
  w.seenFrame = true
  const special = stateMaximized or stateFullscreen0 or stateTiled or
    stateIconified
  if not w.undecorated() and (w.state and special) == 0:
    w.b.frames[resizable] = f
  f

## contentInsets returns where the content is inside the window GTK
## sizes: below the menu bar, which GTK gives its natural height. That
## holds before GTK lays out a menu bar that just showed or went,
## unlike where it has the content.
proc contentInsets*(w: gtkWindow): extents =
  if w.menubar.isNil or not gtkWidgetGetVisible(w.menubar):
    return extents()
  var minimum, natural: int32
  gtkWidgetGetPreferredHeight(w.menubar, addr minimum, addr natural)
  extents(top: natural)

method setBounds*(w: gtkWindow, r: platform.Rect) =
  ## asks for the bounds of the window manager's frame: GTK moves the
  ## frame and sizes the window inside it.
  if w.layer:
    w.setLayerBounds(r)
    return
  w.setBounds(r, false)

method setContentBounds*(w: gtkWindow, r: platform.Rect) =
  w.setBounds(w.frameExtents().grow(w.contentInsets().grow(r)), true)

## setBounds asks for the bounds of the frame, for the size inside it
## when inside is set: a frame other than expected keeps that size (see
## cbConfigure).
proc setBounds*(w: gtkWindow, r0: platform.Rect, inside: bool) =
  var r = r0
  let f = w.frameExtents()
  let (width, height) = w.constrain(
    int32(r.width) - f.left - f.right,
    int32(r.height) - f.top - f.bottom)
  r.width = int(width + f.left + f.right)
  r.height = int(height + f.top + f.bottom)
  if w.requested == nil:
    gtkWindowGetSize(w.win, addr w.previous[0], addr w.previous[1])
  w.requested = (ref platform.Rect)(x: r.x, y: r.y,
    width: r.width, height: r.height)
  w.requestFrame = f
  w.requestInside = inside
  if w.resizeIdle != 0:
    w.activationResize = w.requested # the idle callback asks for it
    return
  if not w.b.onX11 and w.surface != nil and w.surface.rendered and
      w.surface.drawsGL() and (w.state and stateFocused) == 0:
    if w.activationResize == nil:
      gtkWindowGetSize(w.win, addr w.activationPrevious[0],
        addr w.activationPrevious[1])
    w.activationResize = w.requested
  # GTK keeps a window the user cannot resize at least as large as its
  # default size.
  gtkWindowSetDefaultSize(w.win, width, height)
  gtkWindowMove(w.win, int32(r.x), int32(r.y))
  gtkWindowResize(w.win, width, height)

## constrain returns the size GTK gives the window when asked for one:
## within its minimum and maximum sizes, and no smaller than its
## content, or than the content's natural size when the user cannot
## resize the window.
proc constrain*(w: gtkWindow, width0, height0: int32):
    tuple[width, height: int32] =
  var width = width0
  var height = height0
  var minW, natW, minH, natH: int32
  gtkWidgetGetPreferredWidth(w.box, addr minW, addr natW)
  gtkWidgetGetPreferredHeight(w.box, addr minH, addr natH)
  if not gtkWindowGetResizable(w.win):
    minW = natW
    minH = natH
  if w.maxW > 0:
    width = min(width, w.maxW)
  if w.maxH > 0:
    height = min(height, w.maxH)
  (max(width, max(w.minW, minW)), max(height, max(w.minH, minH)))

method bounds*(w: gtkWindow): platform.Rect =
  ## the bounds of the window manager's frame, which are the window's
  ## own without one.
  if w.layer:
    return w.layerBounds()
  if w.requested != nil:
    return w.requested[]
  if w.framed and gtkWidgetGetMapped(w.win):
    var r: gdkRectangle
    gdkWindowGetFrameExtents(gtkWidgetGetWindow(w.win), addr r)
    return platform.Rect(x: int(r.x), y: int(r.y),
      width: int(r.width), height: int(r.height))
  var x, y, width, height: int32
  gtkWindowGetPosition(w.win, addr x, addr y) # the frame's
  gtkWindowGetSize(w.win, addr width, addr height)
  let f = w.frameExtents()
  platform.Rect(x: int(x), y: int(y),
    width: int(width + f.left + f.right),
    height: int(height + f.top + f.bottom))

## size returns the size GTK gives the window, or was asked to give it.
proc size*(w: gtkWindow): tuple[width, height: int32] =
  if w.requested != nil:
    let r = w.requested
    let f = w.requestFrame
    return (int32(r.width) - f.left - f.right,
      int32(r.height) - f.top - f.bottom)
  var width, height: int32
  gtkWindowGetSize(w.win, addr width, addr height)
  (width, height)

method contentBounds*(w: gtkWindow): platform.Rect =
  ## where the content is: on X11, where X has the window inside the
  ## window manager's frame, below the menu bar.
  var r: platform.Rect
  if w.requested == nil and w.b.onX11 and gtkWidgetGetMapped(w.win):
    var x, y: int32
    discard gdkWindowGetOrigin(gtkWidgetGetWindow(w.win), addr x, addr y)
    let (width, height) = w.size()
    r = platform.Rect(x: int(x), y: int(y), width: int(width),
      height: int(height))
  else:
    var f = w.requestFrame
    if w.requested == nil:
      f = w.frameExtents()
    r = f.shrink(w.bounds())
  w.contentInsets().shrink(r)

method setMinimumSize*(w: gtkWindow, s: Size) =
  w.minW = int32(s.width)
  w.minH = int32(s.height)
  w.applyGeometry()

method setMaximumSize*(w: gtkWindow, s: Size) =
  w.maxW = int32(s.width)
  w.maxH = int32(s.height)
  w.applyGeometry()

method setResizable*(w: gtkWindow, v: bool) =
  if not v:
    # Keep the size it has or was given (see setBounds).
    let (width, height) = w.size()
    gtkWindowSetDefaultSize(w.win, width, height)
  gtkWindowSetResizable(w.win, v)
  if w.controls != nil:
    w.layoutControls() # with a maximize button or without

method isResizable*(w: gtkWindow): bool = gtkWindowGetResizable(w.win)
method setMovable*(w: gtkWindow, v: bool) = discard
method isMovable*(w: gtkWindow): bool = true
method setMinimizable*(w: gtkWindow, v: bool) = discard
method isMinimizable*(w: gtkWindow): bool = not w.opts.panel
method setMaximizable*(w: gtkWindow, v: bool) = discard
method isMaximizable*(w: gtkWindow): bool =
  gtkWindowGetResizable(w.win) and not w.opts.panel
method setClosable*(w: gtkWindow, v: bool) =
  gtkWindowSetDeletable(w.win, v)
  if w.controls != nil:
    w.layoutControls() # with a close button or without

method isClosable*(w: gtkWindow): bool = gtkWindowGetDeletable(w.win)
method setAlwaysOnTop*(w: gtkWindow, v: bool) =
  w.keepAbove = v
  gtkWindowSetKeepAbove(w.win, v)

## isAlwaysOnTop reports the requested state: only some window managers
## reflect it in the window state.
method isAlwaysOnTop*(w: gtkWindow): bool =
  w.keepAbove or (w.state and stateAbove) != 0

method show*(w: gtkWindow) =
  if w.opts.flyout != nil:
    w.showFlyout(w.flyout.focusable)
    return
  if w.layer:
    w.layerKeyboard(true)
  w.willShow()
  gtkWidgetShow(w.win)
  gtkWindowPresent(w.win)

method showInactive*(w: gtkWindow) =
  if w.opts.flyout != nil:
    w.showFlyout(false)
    return
  if w.layer:
    w.layerKeyboard(false)
  w.willShow()
  gtkWidgetShow(w.win)

## willShow makes bounds report where GTK asks for a window about to
## show until the window manager put it there. Until then, X has the
## window where GTK created it or where it was, and a reparenting
## window manager has its frame where it created that.
proc willShow*(w: gtkWindow) =
  if gtkWidgetGetVisible(w.win):
    return
  w.framed = false # until the window manager frames it again
  if w.requested == nil:
    let b = w.bounds() # what GTK asks for, while the window does not show
    # The size it was made with, or had, unless it was made with
    # that of its frame.
    let inside = w.opts.useContentSize or w.seenFrame
    w.requested = (ref platform.Rect)(x: b.x, y: b.y,
      width: b.width, height: b.height)
    w.requestFrame = w.frameExtents()
    w.requestInside = inside
    let (w0, h0) = w.size()
    w.previous = [w0, h0]
  w.placing = w.b.windowManager(w.win)

method hide*(w: gtkWindow) =
  if w.opts.flyout != nil:
    w.hideFlyout()
    return
  gtkWidgetHide(w.win)

method isVisible*(w: gtkWindow): bool = gtkWidgetGetVisible(w.win)

method focus*(w: gtkWindow) =
  if w.host != nil:
    if not w.closed:
      gtkWidgetGrabFocus(w.web)
    return
  if w.opts.flyout != nil:
    # A popup takes the keyboard only by its grab, as it shows.
    w.showFlyout(w.flyout.focusable)
    return
  w.b.dismissFlyouts(w)
  if w.layer:
    w.layerKeyboard(true)
  w.willShow() # presenting shows a hidden window
  gtkWindowPresent(w.win)

method blur*(w: gtkWindow) = discard
method isFocused*(w: gtkWindow): bool = gtkWindowIsActive(w.win)
method minimize*(w: gtkWindow) = gtkWindowIconify(w.win)
method isMinimized*(w: gtkWindow): bool =
  (w.state and stateIconified) != 0
method maximize*(w: gtkWindow) = gtkWindowMaximize(w.win)
method unmaximize*(w: gtkWindow) = gtkWindowUnmaximize(w.win)
method isMaximized*(w: gtkWindow): bool = gtkWindowIsMaximized(w.win)
method restore*(w: gtkWindow) = gtkWindowDeiconify(w.win)

method setFullScreen*(w: gtkWindow, v: bool) =
  if v:
    gtkWindowFullscreen(w.win)
  else:
    gtkWindowUnfullscreen(w.win)

method isFullScreen*(w: gtkWindow): bool =
  (w.state and stateFullscreen0) != 0

method setProgressBar*(w: gtkWindow, state: string, value: float64) =
  w.b.launcher.showing = state != ""
  w.b.launcher.progress = value
  if state == "indeterminate":
    w.b.launcher.progress = 1
  w.b.updateLauncherEntry()

method flashFrame*(w: gtkWindow, flash: bool) =
  gtkWindowSetUrgencyHint(w.win, flash)
method setSkipTaskbar*(w: gtkWindow, v: bool) =
  gtkWindowSetSkipTaskbarHint(w.win, v)

method setVisibleOnAllWorkspaces*(w: gtkWindow, v: bool) =
  if v:
    gtkWindowStick(w.win)
  else:
    gtkWindowUnstick(w.win)

method setIcon*(w: gtkWindow, png: seq[byte]) =
  if png.len == 0:
    gtkWindowSetIcon(w.win, nil) # back to the default icon
    return
  let (pix, err) = pixbufFromPNG(png)
  if not err.isNil:
    raise err
  defer: gObjectUnref(pix)
  gtkWindowSetIcon(w.win, pix)

method droppedFiles*(w: gtkWindow): seq[string] =
  result = w.dropped
  w.dropped = @[]

method center*(w: gtkWindow) =
  if w.layer:
    w.centerLayer()
    return
  let b = w.bounds()
  for d in screenImpl().displays():
    if d.primary:
      let area = d.workArea
      let x = area.x + (area.width - b.width) div 2
      let y = area.y + (area.height - b.height) div 2
      if w.requested != nil:
        # Bounds that GTK has not confirmed yet move with it.
        w.requested.x = x
        w.requested.y = y
      gtkWindowMove(w.win, int32(x), int32(y))
      return

method setBackgroundColor*(w: gtkWindow, c: platform.Color) =
  if not w.web.isNil:
    var rgba = gdkRGBA(r: float64(c.r) / 255,
      g: float64(c.g) / 255, b: float64(c.b) / 255,
      a: float64(c.a) / 255)
    webkitWebViewSetBackgroundColor(w.web, addr rgba)

method setOpacity*(w: gtkWindow, v: float64) =
  gtkWidgetSetOpacity(w.win, v)
method opacity*(w: gtkWindow): float64 = gtkWidgetGetOpacity(w.win)
method setHasShadow*(w: gtkWindow, v: bool) = discard
method hasShadow*(w: gtkWindow): bool = true
method setIgnoreMouseEvents*(w: gtkWindow, v: bool) = discard
method setContentProtection*(w: gtkWindow, v: bool) = discard
method setVibrancy*(w: gtkWindow, v: string) = discard

## startDrag begins moving the window with the last button press. On an
## undecorated window the compositor takes the pointer once the move
## starts, so the move waits until the pointer moves, keeping a second
## press free to reach the page as a double click. Decorated windows
## observe no motion on the page, so they move at once.
method startDrag*(w: gtkWindow) =
  if not w.press.hasPressed:
    return
  if not w.undecorated():
    gtkWindowBeginMoveDrag(w.win, w.press.button,
      int32(w.press.rootX), int32(w.press.rootY), w.press.time)
    return
  w.dragPending = true

## checkDragStart starts a pending window drag once the pointer moves
## past the drag threshold with the button still down.
proc checkDragStart*(w: gtkWindow, event: pointer) =
  if not w.dragPending:
    return
  # GdkEventMotion: state 48, x_root 64, y_root 72.
  if (field[uint32](event, 48) and (1'u32 shl 8)) == 0:
    # The button went up without the pointer moving.
    w.dragPending = false
    return
  const dragThreshold = 8 # pixels, as GTK's
  let dx = field[float64](event, 64) - w.press.rootX
  let dy = field[float64](event, 72) - w.press.rootY
  if dx * dx + dy * dy < dragThreshold * dragThreshold:
    return
  w.dragPending = false
  gtkWindowBeginMoveDrag(w.win, w.press.button, int32(w.press.rootX),
    int32(w.press.rootY), w.press.time)

# GTK gives windows without decorations no resize edges, so the outer
# pixels of the page resize frameless windows, as in Electron.
const
  resizeInset = 5 # pixels of the page along the edges
  resizeCorner = 16 # pixels along the edges from a corner that resize it

## resizeEdges are the GdkWindowEdge values, with their cursors and the
## states in which the window manager lets them resize the window.
const resizeEdges: array[8, tuple[cursor: string, states: uint32]] = [
  ("nw-resize", stateTopResizable or stateLeftResizable),
  ("n-resize", stateTopResizable),
  ("ne-resize", stateTopResizable or stateRightResizable),
  ("w-resize", stateLeftResizable),
  ("e-resize", stateRightResizable),
  ("sw-resize", stateBottomResizable or stateLeftResizable),
  ("s-resize", stateBottomResizable),
  ("se-resize", stateBottomResizable or stateRightResizable),
]

## resizeEdge returns the GdkWindowEdge a pointer event on the page (a
## GdkEventMotion or GdkEventButton) would resize, or -1.
proc resizeEdge*(w: gtkWindow, event: pointer): int32 =
  # GdkEventMotion and GdkEventButton: window 8, x 24, y 32.
  if not w.undecorated() or
      (w.state and (stateMaximized or stateFullscreen0)) != 0 or
      field[pointer](event, 8) != w.contentWindow() or
      not gtkWindowGetResizable(w.win):
    return -1
  let x = field[float64](event, 24)
  let y = field[float64](event, 32)
  var page: gdkRectangle
  gtkWidgetGetAllocation(w.contentWidget(), addr page)
  let width = float64(page.width)
  let height = float64(page.height)
  let atTop = page.y == 0 # no menu bar above the page
  var top = atTop and y < resizeInset
  var bottom = y >= height - resizeInset
  var left = x < resizeInset
  var right = x >= width - resizeInset
  if not top and not bottom and not left and not right:
    return -1
  # Near a corner, the edges resize the corner.
  top = top or ((left or right) and atTop and y < resizeCorner)
  bottom = bottom or ((left or right) and y >= height - resizeCorner)
  left = left or ((top or bottom) and x < resizeCorner)
  right = right or ((top or bottom) and x >= width - resizeCorner)
  var edge: int32
  if top and left: edge = 0
  elif top and right: edge = 2
  elif bottom and left: edge = 5
  elif bottom and right: edge = 7
  elif top: edge = 1
  elif bottom: edge = 6
  elif left: edge = 3
  else: edge = 4
  # Tiled windows resize at the edges the window manager allows, as
  # with GTK's own decorations.
  const resizable = stateTopResizable or stateRightResizable or
    stateBottomResizable or stateLeftResizable
  let need = resizeEdges[edge].states
  if ((w.state and resizable) != 0 and (w.state and need) != need) or
      ((w.state and resizable) == 0 and (w.state and stateTiled) != 0):
    return -1
  edge

## showResizeCursor shows the cursor of a resize edge over the page, or
## the page's own cursor again for -1.
proc showResizeCursor*(w: gtkWindow, edge: int32) =
  if edge < 0 and not w.cursor.on:
    return
  let page = w.contentWindow()
  let current = gdkWindowGetCursor(page)
  if edge < 0:
    if w.cursor.on and current == w.cursor.shown:
      gdkWindowSetCursor(page, w.cursor.saved)
    w.releaseCursor()
    return
  if not w.cursor.on or current != w.cursor.shown:
    # The pointer comes onto an edge, or WebKit changed the cursor.
    w.releaseCursor()
    if not current.isNil:
      discard gObjectRef(current)
    w.cursor.on = true
    w.cursor.edge = -1
    w.cursor.saved = current
  if w.cursor.edge != edge:
    let cursor = gdkCursorNewFromName(gdkWindowGetDisplay(page),
      cs(resizeEdges[edge].cursor))
    gdkWindowSetCursor(page, cursor)
    if not cursor.isNil:
      gObjectUnref(cursor) # the GdkWindow holds it
    w.cursor.edge = edge
    w.cursor.shown = cursor

## releaseCursor forgets the page's cursor kept to restore.
proc releaseCursor*(w: gtkWindow) =
  if not w.cursor.saved.isNil:
    gObjectUnref(w.cursor.saved)
  w.cursor.on = false
  w.cursor.edge = -1
  w.cursor.shown = nil
  w.cursor.saved = nil

## hiddenTitleBar reports a TitleBarStyle that hides the title bar (not
## a frameless window's, which has no buttons either).
proc hiddenTitleBar*(w: gtkWindow): bool =
  let o = w.opts
  not o.frameless and
    (o.titleBarStyle == "hidden" or o.titleBarStyle == "hiddenInset")

## undecorated reports a window without the window manager's
## decorations, whose page's outer pixels resize it.
proc undecorated*(w: gtkWindow): bool =
  w.opts.frameless or w.hiddenTitleBar()

method titleBarDoubleClicked*(w: gtkWindow) =
  if w.isMaximized():
    w.unmaximize()
  else:
    w.maximize()

method close*(w: gtkWindow) =
  if w.host != nil:
    w.closeWebView()
    return
  if not w.closed:
    if w.opts.flyout != nil:
      w.ungrab()
    gtkWidgetDestroy(w.win)

method loadURL*(w: gtkWindow, url: string) =
  w.programmatic = true
  webkitWebViewLoadURI(w.web, cs(url))

method loadHTML*(w: gtkWindow, html, baseURL: string) =
  w.programmatic = true
  webkitWebViewLoadHTML(w.web, cs(html), optCS(baseURL))

method loadFile*(w: gtkWindow, path, readAccessDir: string) =
  let f = gFileNewForPath(cs(path))
  let uri = takeStr(gFileGetURI(f))
  gObjectUnref(f)
  w.loadURL(uri)

method reload*(w: gtkWindow, ignoreCache: bool) =
  if ignoreCache:
    webkitWebViewReloadBypassCache(w.web)
  else:
    webkitWebViewReload(w.web)

method stopLoading*(w: gtkWindow) = webkitWebViewStopLoading(w.web)
method goBack*(w: gtkWindow) = webkitWebViewGoBack(w.web)
method goForward*(w: gtkWindow) = webkitWebViewGoForward(w.web)
method canGoBack*(w: gtkWindow): bool = webkitWebViewCanGoBack(w.web)
method canGoForward*(w: gtkWindow): bool =
  webkitWebViewCanGoForward(w.web)
method url*(w: gtkWindow): string = goStr(webkitWebViewGetURI(w.web))
method isLoading*(w: gtkWindow): bool = webkitWebViewIsLoading(w.web)

## addUserScripts gives the content manager the scripts of the options,
## and the script that tells the bridge the room of the window
## controls.
proc addUserScripts*(w: gtkWindow) =
  for s in w.opts.userScripts:
    var frames = 1'i32 # top frame
    var `when` = 0'i32 # document start
    if s.allFrames:
      frames = 0
    if s.atDocumentEnd:
      `when` = 1
    let script = webkitUserScriptNew(cs(s.source), frames, `when`,
      nil, nil)
    webkitUserContentManagerAddScript(w.ucm, script)
    webkitUserScriptUnref(script)
  if w.controls != nil:
    # After the bridge, which it tells; top frame, document start.
    let script = webkitUserScriptNew(cs(w.titleBarScript()), 1, 0,
      nil, nil)
    webkitUserContentManagerAddScript(w.ucm, script)
    webkitUserScriptUnref(script)

method setUserScripts*(w: gtkWindow, scripts: seq[UserScript]) =
  if w.closed or w.ucm.isNil:
    return
  w.opts.userScripts = scripts
  webkitUserContentManagerRemoveAllScripts(w.ucm)
  w.addUserScripts()

method eval*(w: gtkWindow, js: string) =
  if webkitWebViewEvaluateJavascript != nil:
    # With its length, the script needs no NUL terminated copy.
    webkitWebViewEvaluateJavascript(w.web, cs(js), int32(js.len),
      nil, nil, nil, nil, nil)
  elif webkitWebViewRunJavascript != nil:
    webkitWebViewRunJavascript(w.web, cs(js), nil, nil, nil)

method callAsyncFunction*(w: gtkWindow, body: string,
    cb: proc(r: string, err: ref CatchableError)) =
  if webkitWebViewCallAsyncJavascriptFunction.isNil:
    cb("", newException(CatchableError,
      "mynim: Eval requires WebKitGTK 2.40 or later"))
    return
  let id = pending.add(proc(source, res: pointer) =
    var gerr: pointer
    let v = webkitWebViewCallAsyncJavascriptFunctionFinish(
      source, res, addr gerr)
    if not gerr.isNil:
      cb("", gErr(gerr))
      return
    let s = takeStr(jscValueToString(v))
    gObjectUnref(v)
    cb(s, nil))
  webkitWebViewCallAsyncJavascriptFunction(w.web, cs(body),
    int32(body.len), nil, nil, nil, nil, cbAsyncReady, id)

method setZoom*(w: gtkWindow, f: float64) =
  webkitWebViewSetZoomLevel(w.web, f)
method zoom*(w: gtkWindow): float64 = webkitWebViewGetZoomLevel(w.web)

method setUserAgent*(w: gtkWindow, ua: string) =
  webkitSettingsSetUserAgent(webkitWebViewGetSettings(w.web), optCS(ua))

method userAgent*(w: gtkWindow): string =
  goStr(webkitSettingsGetUserAgent(webkitWebViewGetSettings(w.web)))

method openDevTools*(w: gtkWindow) =
  if w.opts.devTools:
    webkitWebInspectorShow(webkitWebViewGetInspector(w.web))

method closeDevTools*(w: gtkWindow) =
  webkitWebInspectorClose(webkitWebViewGetInspector(w.web))

method isDevToolsOpened*(w: gtkWindow): bool =
  not webkitWebInspectorGetWebView(
    webkitWebViewGetInspector(w.web)).isNil

method capturePage*(w: gtkWindow,
    cb: proc(png: seq[byte], err: ref CatchableError)) =
  let id = pending.add(proc(source, res: pointer) =
    var gerr: pointer
    let surface = webkitWebViewGetSnapshotFinish(source, res, addr gerr)
    if not gerr.isNil:
      cb(@[], gErr(gerr))
      return
    let (png, err) = surfaceToPNG(surface)
    cairoSurfaceDestroy(surface)
    cb(png, err))
  webkitWebViewGetSnapshot(w.web, 0, 0, nil, cbAsyncReady, id)

## decideResponse makes attachments, and what WebKit cannot show,
## downloads. WebKit cannot download what a custom scheme serves, so the
## app serves it again into a download.
proc decideResponse*(w: gtkWindow, decision: pointer): bool =
  let resp = webkitResponsePolicyDecisionGetResponse(decision)
  let uri = goStr(webkitURIResponseGetURI(resp))
  var disposition = ""
  let h = webkitURIResponseGetHTTPHeaders(resp)
  if not h.isNil:
    disposition = goStr(soupMessageHeadersGetOne(h,
      cs("Content-Disposition")))
  let attachment = disposition.toLower.strip.startsWith("attachment")
  if not attachment and
      webkitResponsePolicyDecisionIsMIMETypeSupported(decision):
    return false
  let scheme = uri.split(':', 1)[0]
  if w.b.schemes.getOrDefault(scheme.toLower):
    webkitPolicyDecisionIgnore(decision)
    w.h.schemeDownload(uri)
    return true
  webkitPolicyDecisionDownload(decision)
  true

## printToPDF prints to the "Print to File" printer of GTK, which
## writes the PDF to a temporary file.
method printToPDF*(w: gtkWindow, o: PDFOptions,
    cb: proc(pdf: seq[byte], err: ref CatchableError)) =
  # WebKitGTK crashes printing a web view that never loaded anything,
  # whose URI is still NULL.
  if webkitWebViewGetURI(w.web).isNil:
    cb(@[], newException(CatchableError,
      "mynim: printing to PDF: the page has loaded nothing"))
    return
  let path = getTempDir() / "mynim-" & $getCurrentProcessId() & "-" &
    $cast[int](w) & ".pdf"
  let settings = gtkPrintSettingsNew()
  gtkPrintSettingsSet(settings, cs("printer"), cs("Print to File"))
  gtkPrintSettingsSet(settings, cs("output-file-format"), cs("pdf"))
  gtkPrintSettingsSet(settings, cs("output-uri"),
    cs("file://" & path))
  let setup = gtkPageSetupNew()
  const unitInch = 2'i32 # GTK_UNIT_INCH
  let paper = gtkPaperSizeNewCustom(cs("mynim"), cs("MyNim"),
    o.pageWidth, o.pageHeight, unitInch)
  gtkPageSetupSetPaperSize(setup, paper)
  gtkPaperSizeFree(paper)
  if o.landscape:
    gtkPageSetupSetOrientation(setup, 1) # GTK_PAGE_ORIENTATION_LANDSCAPE
  gtkPageSetupSetTopMargin(setup, o.marginTop, unitInch)
  gtkPageSetupSetRightMargin(setup, o.marginRight, unitInch)
  gtkPageSetupSetBottomMargin(setup, o.marginBottom, unitInch)
  gtkPageSetupSetLeftMargin(setup, o.marginLeft, unitInch)

  let web = webkitWebViewGetSettings(w.web)
  let backgrounds = webkitSettingsGetPrintBackgrounds(web)
  webkitSettingsSetPrintBackgrounds(web, o.background)
  let op = webkitPrintOperationNew(w.web)
  webkitPrintOperationSetPrintSettings(op, settings)
  webkitPrintOperationSetPageSetup(op, setup)
  gObjectUnref(settings)
  gObjectUnref(setup)
  printJobs[op] = printJob(done: proc(err: ref CatchableError) =
    printJobs.del(op)
    webkitSettingsSetPrintBackgrounds(web, backgrounds)
    gObjectUnref(op)
    var data: seq[byte]
    var rerr: ref CatchableError
    try:
      data = cast[seq[byte]](readFile(path))
    except IOError as e:
      rerr = e
    try: removeFile(path)
    except OSError: discard
    var e = err
    if e.isNil and (not rerr.isNil or data.len == 0):
      e = newException(CatchableError,
        "mynim: printing to PDF produced no file")
    if not e.isNil:
      data = @[]
    cb(data, e))
  discard connect(op, "finished", cbPrintFinished, nil)
  discard connect(op, "failed", cbPrintFailed, nil)
  webkitPrintOperationPrint(op)

method print*(w: gtkWindow) =
  let op = webkitPrintOperationNew(w.web)
  discard webkitPrintOperationRunDialog(op, w.win)
  gObjectUnref(op)

## surfaceToPNG encodes a cairo surface as PNG through a write callback.
var pngBuffers*: Table[pointer, ref seq[byte]]

proc surfaceToPNG*(surface: pointer):
    tuple[png: seq[byte], err: ref CatchableError] =
  var key = cast[pointer](pngBuffers.len + 1)
  while pngBuffers.hasKey(key):
    key = cast[pointer](cast[int](key) + 1)
  var buf = new(seq[byte])
  pngBuffers[key] = buf
  defer: pngBuffers.del(key)
  if cairoSurfaceWriteToPNGStream(surface, cbPNGWrite, key) != 0:
    return (@[], newException(CatchableError,
      "mynim: cannot encode snapshot"))
  (buf[], nil)

## initWindowCallbacks makes the GTK callbacks of windows. Each is
## created once and routed by user data.
proc initWindowCallbacks*() =
  cbDeleteEvent = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        return not w.h.shouldClose()
      false)
  cbDestroy = cast[pointer](
    proc(widget, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.cleanup()
        w.h.closed())
  cbFocusIn = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.h.focused()
      false)
  cbFocusOut = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.altAlone = false
        w.h.blurred()
        if w.trayFlyout() and w.flyout.focusable and
            not w.grabbingChild():
          w.dismissFlyout(false)
      false)
  # A window drawing with GL on Wayland got focus: the configure event
  # of the activation can carry the size of the last buffer it drew,
  # from before a resize GTK already took, and GTK went back to it. Ask
  # for the latest bounds again then, unless the window manager sized
  # the window.
  cbActivationResize = cast[pointer](
    proc(data: pointer): int32 {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return 0
      let r = w.activationResize
      w.activationResize = nil
      w.resizeIdle = 0
      var width, height: int32
      gtkWindowGetSize(w.win, addr width, addr height)
      if (w.state and (stateMaximized or stateFullscreen0 or
          stateTiled)) == 0 and (w.requested != nil or
          [width, height] == w.activationPrevious):
        # GTK skips a request for the size it asked for last: the first
        # check takes the configure, the second asks for the size the
        # window has, so that the bounds are asked for again. Handlers
        # of the new size may close the window.
        gtkWindowResize(w.win, width, height)
        gtkContainerCheckResize(w.win)
        if not w.closed:
          gtkContainerCheckResize(w.win)
        if not w.closed:
          w.setBounds(r[])
      else:
        w.requested = nil
      0)
  cbConfigure = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      # GdkEventConfigure: x, y, width, height at offsets 20..32.
      let x = field[int32](event, 20)
      let y = field[int32](event, 24)
      let width = field[int32](event, 28)
      let height = field[int32](event, 32)
      let moved = x != w.x or y != w.y
      let resized = width != w.w or height != w.hgt
      w.x = x; w.y = y; w.w = width; w.hgt = height
      # The window manager's own report (send_event at 16) comes once it
      # framed and moved the window.
      let synthetic = field[int8](event, 16) != 0
      if synthetic and w.b.onX11:
        w.framed = true
      if w.requested != nil and w.resizeIdle == 0:
        let r = w.requested
        # Without the decorations GTK draws, as requested.
        var cw, ch: int32
        gtkWindowGetSize(w.win, addr cw, addr ch)
        let f = w.frameExtents()
        let old = w.requestFrame
        if f != old:
          # The window manager framed the window otherwise than
          # expected as it placed it. GTK positions the frame, so the
          # bounds grow with the frame around the size asked for inside
          # it, or GTK is asked for the size inside the frame again,
          # which is done once GTK has it there.
          if w.requestInside:
            r.width += int(f.left + f.right - old.left - old.right)
            r.height += int(f.top + f.bottom - old.top - old.bottom)
            w.requestFrame = f
          else:
            let (rw, rh) = w.constrain(int32(r.width) - f.left - f.right,
              int32(r.height) - f.top - f.bottom)
            r.width = int(rw + f.left + f.right)
            r.height = int(rh + f.top + f.bottom)
            w.requestFrame = f
            w.previous = [cw, ch]
            w.placing = false
            gtkWindowSetDefaultSize(w.win, rw, rh)
            gtkWindowResize(w.win, rw, rh)
        let (rw, rh) = w.size()
        var done = false
        if cw != rw or ch != rh:
          if cw == w.previous[0] and ch == w.previous[1]:
            # A report from before the window manager took the
            # request, as openbox sends when the size hints change.
            # GTK would ask for this size again from it (and keeps a
            # window the user cannot resize as large), unless asked
            # for the new one again.
            gtkWindowResize(w.win, rw, rh)
          else:
            done = true # the window manager, or the user, chose it
        elif synthetic or not w.b.onX11:
          done = true
        elif not w.placing:
          # X11 reports where the window is, in the frame of the
          # window manager: it is done once that is where it was
          # asked to be.
          var cx, cy: int32
          gtkWindowGetPosition(w.win, addr cx, addr cy)
          done = cx == int32(r.x) and cy == int32(r.y)
        if done:
          w.requested = nil
          w.placing = false
      if resized:
        w.h.resized()
      if moved:
        w.h.moved()
      false)
  cbWindowState = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      # GdkEventWindowState: changed_mask at 20, new_window_state at 24.
      let changed = field[uint32](event, 20)
      let state = field[uint32](event, 24)
      w.state = state
      if (changed and stateFocused) != 0 and
          (state and stateFocused) != 0 and
          w.activationResize != nil and w.resizeIdle == 0:
        # G_PRIORITY_DEFAULT_IDLE: after GTK took the configure event
        # of the activation.
        w.resizeIdle = gIdleAddFull(200, cbActivationResize,
          cast[pointer](w.id), nil)
      if (changed and stateIconified) != 0:
        if (state and stateIconified) != 0:
          w.h.minimized()
        else:
          w.h.restored()
      if (changed and stateMaximized) != 0:
        if (state and stateMaximized) != 0:
          w.h.maximized()
        else:
          w.h.unmaximized()
      if (changed and stateFullscreen0) != 0:
        if (state and stateFullscreen0) != 0:
          w.h.enteredFullScreen()
        else:
          w.h.leftFullScreen()
        if not w.menubar.isNil:
          gtkWidgetSetVisible(w.menubar, not w.menuHides())
        if w.controls != nil:
          w.fullScreenChanged()
      false)
  cbDecorationLayout = cast[pointer](
    proc(settings, pspec, data: pointer) {.cdecl.} =
      for w in theBackend.windows.values:
        if w.controls != nil and not w.closed:
          w.layoutControls())
  cbButtonPress = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      var w = theBackend.window(data)
      if w.isNil:
        return false
      if w.host != nil:
        # GdkEventButton: type 0, x 24, y 32, state 48, button 52.
        if field[int32](event, 0) == 4:
          w.webViewPressed(field[float64](event, 24),
            field[float64](event, 32), field[uint32](event, 52),
            gdkMods(field[uint32](event, 48)))
        # A web view's page drags the window it is in (startDrag).
        w = w.top()
      w.altAlone = false
      # GdkEventButton: time 20, button 52, x_root 64, y_root 72.
      w.press.time = field[uint32](event, 20)
      w.press.button = int32(field[uint32](event, 52))
      w.press.rootX = field[float64](event, 64)
      w.press.rootY = field[float64](event, 72)
      w.press.hasPressed = true
      if not w.press.event.isNil:
        gdkEventFree(w.press.event)
      w.press.event = gdkEventCopy(event)
      let edge = w.resizeEdge(event)
      if edge >= 0:
        # GdkEventButton: type 0; GDK_BUTTON_PRESS, not a double click.
        if field[int32](event, 0) == 4 and w.press.button == 1:
          gtkWindowBeginResizeDrag(w.win, edge, w.press.button,
            int32(w.press.rootX), int32(w.press.rootY), w.press.time)
        return true # the edges are not the page's
      false)
  cbMotion = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      let edge = w.resizeEdge(event)
      w.showResizeCursor(edge)
      w.checkDragStart(event)
      edge >= 0)
  # WebKit asks for the data of a drag while it moves over the page,
  # before the drop; the uri-list of files gives their paths.
  cbDragData = cast[pointer](
    proc(widget, context: pointer, x, y: int32, sel: pointer,
        info, time: uint32, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.dragged = selectionPaths(sel))
  # Runs before WebKit's own handler, which gets the drop to the page.
  cbDragDrop = cast[pointer](
    proc(widget, context: pointer, x, y: int32, time: uint32,
        data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.dropped = w.dragged
        w.dragged = @[]
      false)
  cbScriptMessage = cast[pointer](
    proc(ucm, res, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.h.message(takeStr(jscValueToString(
          webkitJavascriptResultGetJSValue(res)))))
  cbLoadChanged = cast[pointer](
    proc(web: pointer, event: int32, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return
      case event
      of 0: w.h.navigationStarted(w.url()) # WEBKIT_LOAD_STARTED
      of 2: w.h.navigationCommitted(w.url()) # WEBKIT_LOAD_COMMITTED
      of 3: w.h.loadFinished() # WEBKIT_LOAD_FINISHED
      else: discard)
  cbLoadFailed = cast[pointer](
    proc(web: pointer, event: int32, uri, gerr,
        data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil or gerr.isNil:
        return false
      let code = field[int32](gerr, 4)
      # Cancelled loads (302) and navigations stopped by policy (102)
      # are not failures.
      if code == 302 or code == 102:
        return false
      w.h.loadFailed(goStr(uri), int(code),
        goStr(field[pointer](gerr, 8)))
      false)
  cbTitle = cast[pointer](
    proc(web, pspec, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.h.titleChanged(goStr(webkitWebViewGetTitle(w.web))))
  cbDecidePolicy = cast[pointer](
    proc(web, decision: pointer, kind: int32,
        data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      if kind == 2: # WEBKIT_POLICY_DECISION_TYPE_RESPONSE
        return w.decideResponse(decision)
      if kind != 0: # WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
        return false
      let action = webkitNavigationPolicyDecisionGetNavigationAction(
        decision)
      let navType = webkitNavigationActionGetNavigationType(action)
      var mainFrame = true
      if webkitNavigationPolicyDecisionGetFrameName != nil:
        mainFrame =
          webkitNavigationPolicyDecisionGetFrameName(decision).isNil
      # WebKitNavigationType: link, form, back/forward, reload, …
      var nav = platform.Navigation(
        url: goStr(webkitURIRequestGetURI(
          webkitNavigationActionGetRequest(action))),
        isMainFrame: mainFrame,
        userInitiated: webkitNavigationActionIsUserGesture(action) or
          navType == 0 or navType == 1,
        unasked: navType == 2 or navType == 3,
        reload: navType == 3)
      if nav.isMainFrame and w.programmatic:
        w.programmatic = false
        nav.unasked = true
      if w.h.willNavigate(nav):
        webkitPolicyDecisionUse(decision)
      else:
        webkitPolicyDecisionIgnore(decision)
      true)
  cbCreate = cast[pointer](
    proc(web, action, data: pointer): pointer {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return nil
      # WebKitGTK makes a related view share the opener's user content
      # manager, which would route the new window's IPC to the opener.
      # Open an independent window instead; its page has no opener.
      let url = goStr(webkitURIRequestGetURI(
        webkitNavigationActionGetRequest(action)))
      let child = w.h.newWindow(NewWindowRequest(url: url))
      if child of gtkWindow and gtkWindow(child) != nil:
        gtkWindow(child).loadURL(url)
      nil)
  cbClose = cast[pointer](
    proc(web, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        w.h.closedByPage())
  cbCrashed = cast[pointer](
    proc(web: pointer, reason: int32, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil:
        let map = {0'i32: "crashed", 1'i32: "exceeded memory limit",
          2'i32: "terminated by API"}.toTable
        w.h.renderProcessGone(map.getOrDefault(reason)))
  # Camera, microphone, location and notifications; other requests get
  # WebKit's default answer.
  cbPermission = cast[pointer](
    proc(web, req, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      var kinds: seq[string]
      if gTypeCheckInstanceIsA(req,
          webkitUserMediaPermissionRequestGetType()):
        if webkitUserMediaPermissionIsForVideoDevice(req):
          kinds.add "camera"
        if webkitUserMediaPermissionIsForAudioDevice(req):
          kinds.add "microphone"
      elif gTypeCheckInstanceIsA(req,
          webkitGeolocationPermissionRequestGetType()):
        kinds = @["geolocation"]
      elif gTypeCheckInstanceIsA(req,
          webkitNotificationPermissionRequestGetType()):
        kinds = @["notifications"]
      else:
        return false
      var origin = goStr(webkitWebViewGetURI(web))
      try:
        let u = parseUri(origin)
        origin = $u.scheme & "://" & $u.hostname
        if u.port != "":
          origin &= ":" & u.port
      except CatchableError:
        discard
      if w.h.permissionRequested(kinds, origin):
        webkitPermissionRequestAllow(req)
      else:
        webkitPermissionRequestDeny(req)
      true)
  cbPrintFinished = cast[pointer](
    proc(op, data: pointer) {.cdecl.} =
      if printJobs.hasKey(op):
        printJobs[op].done(printJobs[op].err))
  cbPrintFailed = cast[pointer](
    proc(op, gerr, data: pointer) {.cdecl.} =
      if printJobs.hasKey(op):
        # GError: domain, code, then the message.
        printJobs[op].err = newException(CatchableError,
          "mynim: printing to PDF: " & goStr(field[pointer](gerr, 8))))
  cbPNGWrite = cast[pointer](
    proc(closure, data: pointer, length: uint32): int32 {.cdecl.} =
      if pngBuffers.hasKey(closure) and length > 0:
        let p = cast[ptr UncheckedArray[byte]](data)
        for i in 0 ..< int(length):
          pngBuffers[closure][].add p[i]
      0) # CAIRO_STATUS_SUCCESS

# Web view facade methods. A web view under a surface is a gtkWindow
# without a GtkWindow of its own; gtkWebView (platform.WebView) wraps
# it, delegating to it.
method webViewHandle*(v: gtkWebView): uint = cast[uint](v.w.web)
method loadURL*(v: gtkWebView, url: string) = v.w.loadURL(url)
method loadHTML*(v: gtkWebView, html, baseURL: string) =
  v.w.loadHTML(html, baseURL)
method loadFile*(v: gtkWebView, path, readAccessDir: string) =
  v.w.loadFile(path, readAccessDir)
method reload*(v: gtkWebView, ignoreCache: bool) =
  v.w.reload(ignoreCache)
method stopLoading*(v: gtkWebView) = v.w.stopLoading()
method goBack*(v: gtkWebView) = v.w.goBack()
method goForward*(v: gtkWebView) = v.w.goForward()
method canGoBack*(v: gtkWebView): bool = v.w.canGoBack()
method canGoForward*(v: gtkWebView): bool = v.w.canGoForward()
method url*(v: gtkWebView): string = v.w.url()
method isLoading*(v: gtkWebView): bool = v.w.isLoading()
method eval*(v: gtkWebView, js: string) = v.w.eval(js)
method setUserScripts*(v: gtkWebView, scripts: seq[UserScript]) =
  v.w.setUserScripts(scripts)
method callAsyncFunction*(v: gtkWebView, body: string,
    cb: proc(r: string, err: ref CatchableError)) =
  v.w.callAsyncFunction(body, cb)
method setZoom*(v: gtkWebView, factor: float64) = v.w.setZoom(factor)
method zoom*(v: gtkWebView): float64 = v.w.zoom()
method setUserAgent*(v: gtkWebView, ua: string) = v.w.setUserAgent(ua)
method userAgent*(v: gtkWebView): string = v.w.userAgent()
method openDevTools*(v: gtkWebView) = v.w.openDevTools()
method closeDevTools*(v: gtkWebView) = v.w.closeDevTools()
method isDevToolsOpened*(v: gtkWebView): bool = v.w.isDevToolsOpened()
method capturePage*(v: gtkWebView,
    cb: proc(png: seq[byte], err: ref CatchableError)) =
  v.w.capturePage(cb)
method printToPDF*(v: gtkWebView, o: PDFOptions,
    cb: proc(pdf: seq[byte], err: ref CatchableError)) =
  v.w.printToPDF(o, cb)
method droppedFiles*(v: gtkWebView): seq[string] = v.w.droppedFiles()
method print*(v: gtkWebView) = v.w.print()
method focus*(v: gtkWebView) = v.w.focus()
method tabInto*(v: gtkWebView, back: bool) = v.w.tabInto(back)
method setBackgroundColor*(v: gtkWebView, c: platform.Color) =
  v.w.setBackgroundColor(c)
method close*(v: gtkWebView) = v.w.closeWebView()

## contentWidget returns the window's content: the web view or the
## surface's area.
proc contentWidget*(w: gtkWindow): pointer =
  if w.surface != nil:
    return w.surface.area
  w.web

## contentWindow returns the GdkWindow the page's events name.
proc contentWindow*(w: gtkWindow): pointer =
  if w.surface != nil:
    return gtkWidgetGetWindow(w.surface.area)
  if not w.web.isNil:
    return gtkWidgetGetWindow(w.web)
  nil

## popupTrigger returns the event of the last button press on the page,
## which GTK menus show for.
proc popupTrigger*(w: gtkWindow): pointer = w.press.event
