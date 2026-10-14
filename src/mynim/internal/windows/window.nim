## window.nim (window.go): native windows — creation, styles,
## placement, state, frames, and the window messages of each.

const
  wmMouseActivate* = 0x0021'u32
  maActivateAndEat* = 0x02'u
  timerWebView* = 2'u

var errDestroyed* = newException(CatchableError,
  "mynim: window has been destroyed")

proc errDestroyedErr*(): ref CatchableError = errDestroyed

## Forward declarations for procs of files included later.
proc flyoutStyles*(w: w32Window): tuple[style, ex: uint32]
proc flyoutMessage*(w: w32Window, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc darkMenuMessage*(w: w32Window, m: uint32, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc ownsFocusableFlyout*(w: w32Window): bool
proc roundFlyout*(w: w32Window)
proc placeFlyout*(w: w32Window, f: Flyout, size: Size)
proc newCaptionBar*(w: w32Window): captionBar
proc newSurface*(w: w32Window): w32Surface
proc hasAppMenu*(w: w32Window): bool
proc installMenu*(w: w32Window, m: Menu)
proc menuChar*(w: w32Window, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc barless*(w: w32Window): bool
proc popupMenuBar*(w: w32Window, lp: uint)
proc revealMenu*(w: w32Window, wp, lp: uint): uint
proc attachMenu*(w: w32Window)
proc captionChanged*(w: w32Window)
proc applyTaskbar*(w: w32Window)
proc createWebView*(w: w32Window)
proc focusWebView*(w: w32Window)
proc resizeWebView*(w: w32Window)
proc failPending*(w: w32Window, err: ref CatchableError)
proc closeWebViews*(w: w32Window)
proc closeWebView*(w: w32Window)
proc freeIcons*(w: w32Window)
proc fit*(s: w32Surface)
proc activate*(c: captionBar, active: bool)
proc layout*(c: captionBar)
proc forget*(c: captionBar)
proc updateLayered*(w: w32Window)
proc styles*(w: w32Window): tuple[style, ex: uint32]
proc outerSize*(w: w32Window, width, height: int32,
  dpi: int): tuple[w, h: int32]
proc monitor*(w: w32Window): uint
proc sized*(w: w32Window, kind: uint)
proc captionless*(w: w32Window): bool
proc frameCalcSize*(w: w32Window, wp, lp: uint): uint
proc destroy*(w: w32Window)
proc cleanup*(w: w32Window)
proc rectToDIP*(w: w32Window, r: w32Rect): platform.Rect
proc setStyle*(w: w32Window, bits: uint32, on: bool)
proc setExStyle*(w: w32Window, bits: uint32, on: bool)
proc hasStyle*(w: w32Window, bits: uint32): bool
proc applyWebViewBackground*(w: w32Window)
proc backdropFor*(material: string): int32
proc boolArg*(v: bool): uint
proc placeInitially*(w: w32Window)
proc menuCommand*(b: WinBackend, cmd: uint16, w: w32Window)
proc compositionFor*(b: WinBackend): composition

method newWindow*(b: WinBackend, o: WindowOptions,
    h: WindowHandler): tuple[w: Window, err: ref CatchableError] =
  if not o.surface:
    let err = b.startEnvironment()
    if not err.isNil:
      return (nil, err)
  let w = w32Window(
    b: b, h: h, opts: o,
    movable: o.movable, closable: o.closable, frameless: o.frameless,
    opacity: 1, zoom: 1, shadow: o.hasShadow,
    autoHideMenu: o.autoHideMenu,
    minW: o.minSize.width, minH: o.minSize.height,
    maxW: o.maxSize.width, maxH: o.maxSize.height,
    htmlFor: initTable[string, string](),
    calls: initTable[int, proc(r: string,
      err: ref CatchableError) {.closure.}]())
  w.hiddenTitleBar = not o.frameless and
    (o.titleBarStyle == "hidden" or o.titleBarStyle == "hiddenInset")
  ## A page or native UI with a material behind it needs a window
  ## without a redirection bitmap, whose opaque surface would cover
  ## the system backdrop. GDI draws nothing there: the controls of a
  ## hidden title bar and the frames of native UI show through
  ## DirectComposition (compositor.nim, and the renderer's swap
  ## chain), and the menus open in a popup (barless). Where
  ## DirectComposition is unavailable, the window keeps its bitmap:
  ## what it shows shows, and the material does not. The style is
  ## the window's for life: Windows neither adds it nor removes it
  ## later.
  w.noRedirect = o.vibrancy != "" and systemBackdrops() and
    ((not w.hiddenTitleBar and not o.surface) or
      not b.compositionFor().isNil)
  if not o.flyout.isNil:
    ## What the content leaves transparent shows what is behind.
    w.noRedirect = not b.compositionFor().isNil
  var owner: uint
  let p = if o.parent.isNil: nil else: cast[w32Window](o.parent)
  if not p.isNil and not p.closed:
    w.parent = p
    owner = p.hwnd
  elif o.panel:
    ## A tool window alone may still get a taskbar button, on the
    ## taskbars of other displays: an owned one never does. The
    ## application window is hidden for good.
    owner = b.appHwnd
  var (style, ex) = w.styles()
  var class = windowClass
  if not o.flyout.isNil:
    (style, ex) = w.flyoutStyles()
    if o.hasShadow:
      class = flyoutShadowClass
  w.hwnd = createWindow(ex, class, o.title, style, 0, 0, 0, 0, owner)
  if w.hwnd == 0:
    return (nil, newException(CatchableError,
      "mynim: cannot create a window"))
  b.windows[w.hwnd] = w
  if o.panel:
    ## Windows 11 gives tool windows the small corners of menus.
    w.roundFlyout()
  if not o.flyout.isNil:
    if o.hasShadow:
      w.roundFlyout()
    w.placeFlyout(o.flyout,
      Size(width: o.width, height: o.height))
  else:
    w.placeInitially()

  if not o.closable:
    w.setClosable(false)
  if o.alwaysOnTop:
    w.setAlwaysOnTop(true)
  if o.opacity > 0 and o.opacity < 1:
    w.setOpacity(o.opacity)
  if not o.backgroundColor.isNil:
    w.setBackgroundColor(o.backgroundColor[])
  if w.captionless() and w.shadow and o.flyout.isNil:
    w.setHasShadow(true)
  if w.hiddenTitleBar:
    w.caption = newCaptionBar(w)
  if o.surface:
    w.surface = newSurface(w)
    if w.surface.isNil:
      discard procDestroyWindow(w.hwnd)
      return (nil, newException(CatchableError,
        "mynim: cannot create the window's surface"))
  b.applyWindowTheme(w)
  if o.vibrancy != "":
    w.setVibrancy(o.vibrancy)
  if b.icon != 0:
    w.setIcon(b.icon)
  if not b.appMenu.isNil and w.hasAppMenu():
    w.installMenu(b.appMenu)
  if o.modal and not w.parent.isNil:
    discard procEnableWindow(w.parent.hwnd, 0)
  if o.fullScreen:
    w.setFullScreen(true)
  elif o.maximized:
    w.showMaximized = true
  w.skipTaskbar = o.skipTaskbar ## applied once the taskbar button exists
  if not w.caption.isNil:
    w.caption.layout()
  if not o.surface:
    b.whenEnvironment(proc() {.closure.} = w.createWebView())
  (w, nil)

proc styles*(w: w32Window): tuple[style, ex: uint32] =
  let o = w.opts
  var style = wsOverlappedWindow or wsClipChildren
  if not o.resizable:
    style = style and not (wsThickFrame or wsMaximizeBox)
  if not o.minimizable:
    style = style and not wsMinimizeBox
  if not o.maximizable:
    style = style and not wsMaximizeBox
  var ex = 0'u32
  if not o.focusable:
    ex = ex or wsExNoActivate
  if o.panel:
    ## Out of the taskbar and Alt+Tab, on whichever virtual desktop
    ## is current as it shows, and above other apps' windows. Without
    ## a window menu: DWM draws the close button of a tool window's
    ## menu where a material extends the frame, over the content.
    ex = ex or wsExToolWindow or wsExTopmost
    style = style and not wsSysMenu
  if w.noRedirect:
    ex = ex or wsExNoRedirect
  (style, ex)

## placeInitially sizes and positions a new window, in the DPI of the
## monitor it appears on.
proc placeInitially*(w: w32Window) =
  let o = w.opts
  var mon: uint
  if o.center:
    mon = procMonitorFromPoint(0, monitorDefaultToPrimary)
  else:
    mon = monitorAt(o.x, o.y)
  let dpi = monitorDPI(mon)
  var width = toPx(o.width, dpi)
  var height = toPx(o.height, dpi)
  if o.useContentSize and not w.captionless():
    (width, height) = w.outerSize(width, height, dpi)
  var x = toPx(o.x, dpi)
  var y = toPx(o.y, dpi)
  if o.center:
    let work = monitorWorkArea(mon)
    x = work.left + (work.right - work.left - width) div 2
    y = work.top + (work.bottom - work.top - height) div 2
  discard procSetWindowPos(w.hwnd, 0, uint(uint32(x)),
    uint(uint32(y)), uint(uint32(width)), uint(uint32(height)),
    swpNoZOrder or swpNoActivate)

## outerSize returns the window size for a content size, in pixels.
proc outerSize*(w: w32Window, width, height: int32,
    dpi: int): tuple[w, h: int32] =
  var r = w32Rect(left: 0, top: 0, right: width, bottom: height)
  var menu: uint
  if not w.autoHideMenu and not w.noRedirect and
      (w.hmenu != 0 or
        (not w.b.appMenu.isNil and w.hasAppMenu())):
    menu = 1
  let style = windowLong(w.hwnd, gwlStyle)
  let ex = windowLong(w.hwnd, gwlExStyle)
  if has(procAdjustWindowRectExForDpi):
    discard procAdjustWindowRectExForDpi(cast[uint](addr r), style,
      menu, ex, uint(dpi))
  (r.right - r.left, r.bottom - r.top)

proc monitor*(w: w32Window): uint =
  procMonitorFromWindow(w.hwnd, monitorDefaultToNearest)

## message handles a window message; ok false lets DefWindowProc run.
proc message*(w: w32Window, m: uint32, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  if m == w.b.taskbarButtonCreated and m != 0:
    w.applyTaskbar()
    return (0'u, true)
  if not w.opts.flyout.isNil:
    let (r, ok) = w.flyoutMessage(m, wp, lp)
    if ok:
      return (r, true)
  if m == wmMouseActivate and w.ownsFocusableFlyout():
    return (maActivateAndEat, true)
  let (dr, dok) = w.darkMenuMessage(m, wp, lp)
  if dok:
    return (dr, true)
  case m
  of wmClose:
    if w.h.shouldClose():
      w.destroy()
    return (0'u, true)
  of wmDestroy:
    w.cleanup()
    w.h.closed()
    return (0'u, true)
  of wmTimer:
    if wp != timerWebView:
      return (0'u, false)
    discard procKillTimer(w.hwnd, timerWebView)
    w.createWebView()
    return (0'u, true)
  of wmSize:
    if not w.reframing:
      ## setFullScreen lays the window out once it is done
      w.sized(wp)
    return (0'u, true)
  of wmMove:
    if w.controller != 0:
      discard comCall(w.controller,
        ctlNotifyParentWindowPositionChanged)
    for v in w.webViews:
      if v.controller != 0:
        discard comCall(v.controller,
          ctlNotifyParentWindowPositionChanged)
    w.h.moved()
    return (0'u, true)
  of wmActivate:
    if not w.caption.isNil:
      w.caption.activate(loword(wp) != waInactive)
    if loword(wp) == waInactive:
      w.h.blurred()
    else:
      w.h.focused()
    return (0'u, false)
  of wmSetFocus:
    if not w.surface.isNil:
      discard procSetFocus(w.surface.hwnd)
    else:
      w.focusWebView()
    return (0'u, true)
  of wmGetMinMaxInfo:
    let info = cast[ptr minMaxInfo](cast[pointer](lp))
    let dpi = dpiOf(w.hwnd)
    if w.minW > 0 or w.minH > 0:
      info.minTrackSize = w32Point(x: toPx(w.minW, dpi),
        y: toPx(w.minH, dpi))
    if w.maxW > 0:
      info.maxTrackSize.x = toPx(w.maxW, dpi)
    if w.maxH > 0:
      info.maxTrackSize.y = toPx(w.maxH, dpi)
    return (0'u, true)
  of wmDpiChanged:
    let r = cast[ptr w32Rect](cast[pointer](lp))
    discard procSetWindowPos(w.hwnd, 0, uint(uint32(r.left)),
      uint(uint32(r.top)), uint(uint32(r.right - r.left)),
      uint(uint32(r.bottom - r.top)), swpNoZOrder or swpNoActivate)
    return (0'u, true)
  of wmNCCalcSize:
    if w.captionless() and wp != 0 and not w.fullScreen:
      return (w.frameCalcSize(wp, lp), true)
  of wmEraseBkgnd:
    if w.bgBrush != 0 and w.vibrancy == "":
      var r: w32Rect
      discard procGetClientRect(w.hwnd, cast[uint](addr r))
      discard procFillRect(wp, cast[uint](addr r), w.bgBrush)
    return (1'u, true)
  of wmWindowPosChanging:
    if not w.movable:
      let pos = cast[ptr windowPos](cast[pointer](lp))
      pos.flags = pos.flags or swpNoMove
    return (0'u, false)
  of wmCommand:
    if hiword(wp) == 0 and lp == 0: ## a menu item
      w.b.menuCommand(uint16(loword(wp)), w)
      return (0'u, true)
  of wmEnterMenuLoop:
    w.inMenu = true
  of wmExitMenuLoop:
    w.inMenu = false
  of wmMenuChar:
    let (r, ok) = w.menuChar(wp, lp)
    if ok:
      return (r, true)
  of wmSysCommand:
    ## Alt or F10 alone (lp 0) take the keyboard to the menu bar, and
    ## Alt and a letter (lp the letter) open the menu of the letter;
    ## Alt and Space open the window menu. WebView2 passes no
    ## Alt+letter on: the letters come from native UI only.
    if (wp and 0xFFF0) == scKeyMenu and lp != uint(' ') and
        w.hmenu != 0:
      if w.barless():
        w.popupMenuBar(lp)
        return (0'u, true)
      if lp == 0 and w.autoHideMenu and not w.revealed:
        return (w.revealMenu(wp, lp), true)
  else:
    discard
  (0'u, false)

## sized lays the window out after it changed size or state (a WM_SIZE
## kind), and tells the app.
proc sized*(w: w32Window, kind: uint) =
  w.resizeWebView()
  if not w.surface.isNil:
    w.surface.fit()
  if not w.caption.isNil and kind != sizeMinimized:
    w.caption.layout()
  case kind
  of sizeMinimized:
    if w.state != int(sizeMinimized):
      w.state = int(sizeMinimized)
      w.h.minimized()
  of sizeMaximized:
    if w.state != int(sizeMaximized):
      if w.state == int(sizeMinimized):
        w.h.restored()
      w.state = int(sizeMaximized)
      w.h.maximized()
  of sizeRestored:
    case w.state
    of int(sizeMinimized):
      w.h.restored()
    of int(sizeMaximized):
      w.h.unmaximized()
    else:
      discard
    w.state = int(sizeRestored)
  else:
    discard
  w.h.resized()

## captionless reports a window without a caption: frameless, or with
## a hidden title bar.
proc captionless*(w: w32Window): bool =
  w.frameless or w.hiddenTitleBar

## frameCalcSize removes the title bar of windows without a caption.
## Resizable ones keep their left, right and bottom borders, which
## Windows 10 and later draw invisible outside the window, so they
## still resize. Maximized windows would overflow the screen by their
## borders: fit the work area.
##
## A hidden title bar on Windows 11 keeps a pixel of it, which the
## window's border covers: without any non-client area at the top,
## Windows 11 opens no snap layouts over the maximize button of a
## window that is not maximized. Windows 10 has no snap layouts, and
## over a window that keeps any of its top it draws its whole title
## bar, above the page and the controls.
proc frameCalcSize*(w: w32Window, wp, lp: uint): uint =
  let params = cast[ptr ncCalcSizeParams](cast[pointer](lp))
  if w.isMaximized():
    ## The monitor of the proposed rectangle, not of the window:
    ## while a window is restored from minimized it is still the
    ## minimized one, parked off screen, whose nearest monitor is
    ## not the one it comes back to. Fitting the work area of the
    ## wrong monitor leaves the client area outside the window, and
    ## the content shows nothing. A rectangle on no monitor keeps
    ## the whole window as its client area, as winit and tao do.
    let mon = procMonitorFromRect(cast[uint](addr params.rgrc[0]),
      monitorDefaultToNull)
    if mon != 0:
      params.rgrc[0] = monitorWorkArea(mon)
    return 0
  if (windowLong(w.hwnd, gwlStyle) and wsThickFrame) != 0:
    let top = params.rgrc[0].top
    discard procDefWindowProcW(w.hwnd, wmNCCalcSize, wp, lp)
    params.rgrc[0].top = top
    if w.hiddenTitleBar and windows11():
      params.rgrc[0].top += 1
  0

proc destroy*(w: w32Window) =
  if w.closed or w.destroying:
    return
  w.destroying = true
  ## Re-enable the owner first, or Windows activates another app.
  if w.opts.modal and not w.parent.isNil and not w.parent.closed:
    discard procEnableWindow(w.parent.hwnd, 1)
  discard procDestroyWindow(w.hwnd)

proc cleanup*(w: w32Window) =
  if w.closed:
    return
  w.closeWebViews()
  w.closed = true
  if w.opts.modal and not w.parent.isNil and not w.parent.closed:
    discard procEnableWindow(w.parent.hwnd, 1)
  for id, cb in w.calls:
    w.calls.del(id)
    cb("", errDestroyed)
  w.failPending(errDestroyed)
  if not w.caption.isNil:
    w.caption.forget()
  if w.controller != 0:
    discard comCall(w.controller, ctlClose)
    release(w.settings)
    release(w.webview)
    release(w.controller)
    w.controller = 0
    w.webview = 0
    w.settings = 0
  w.b.menus.drop(w.owner)
  ## Windows destroys the menu bar on the window, not one hidden off
  ## it.
  if w.hmenu != 0 and not w.menuShown():
    discard procDestroyMenu(w.hmenu)
    w.hmenu = 0
  if w.bgBrush != 0:
    discard procDeleteObject(w.bgBrush)
    w.bgBrush = 0
  w.freeIcons()
  w.b.windows.del(w.hwnd)

method handle*(w: w32Window): uint = w.hwnd
method webViewHandle*(w: w32Window): uint = w.webview

method setTitle*(w: w32Window, title: string) =
  discard procSetWindowTextW(w.hwnd, cast[uint](u16(title)))

method title*(w: w32Window): string =
  let n = procGetWindowTextLengthW(w.hwnd)
  var buf = newSeq[uint16](int(n) + 1)
  discard procGetWindowTextW(w.hwnd, cast[uint](addr buf[0]),
    uint(buf.len))
  u16str(buf)

## The core marks the title of an edited document; Windows shows no
## file.
method setRepresentedFile*(w: w32Window, path: string) = discard
method setDocumentEdited*(w: w32Window, edited: bool) = discard

proc rectToDIP*(w: w32Window, r: w32Rect): platform.Rect =
  let dpi = dpiOf(w.hwnd)
  platform.Rect(x: toDIP(r.left, dpi), y: toDIP(r.top, dpi),
    width: toDIP(r.right - r.left, dpi),
    height: toDIP(r.bottom - r.top, dpi))

method setBounds*(w: w32Window, r: platform.Rect) =
  let dpi = dpiOf(w.hwnd)
  discard procSetWindowPos(w.hwnd, 0, uint(uint32(toPx(r.x, dpi))),
    uint(uint32(toPx(r.y, dpi))),
    uint(uint32(toPx(r.width, dpi))),
    uint(uint32(toPx(r.height, dpi))), swpNoZOrder or swpNoActivate)

method bounds*(w: w32Window): platform.Rect =
  var r: w32Rect
  discard procGetWindowRect(w.hwnd, cast[uint](addr r))
  w.rectToDIP(r)

method setContentBounds*(w: w32Window, r: platform.Rect) =
  let dpi = dpiOf(w.hwnd)
  var outer = w32Rect(left: toPx(r.x, dpi), top: toPx(r.y, dpi),
    right: toPx(r.x + r.width, dpi),
    bottom: toPx(r.y + r.height, dpi))
  if not w.captionless() and has(procAdjustWindowRectExForDpi):
    var menu: uint
    if w.menuShown():
      menu = 1
    discard procAdjustWindowRectExForDpi(cast[uint](addr outer),
      windowLong(w.hwnd, gwlStyle), menu,
      windowLong(w.hwnd, gwlExStyle), uint(dpi))
  discard procSetWindowPos(w.hwnd, 0, uint(uint32(outer.left)),
    uint(uint32(outer.top)),
    uint(uint32(outer.right - outer.left)),
    uint(uint32(outer.bottom - outer.top)),
    swpNoZOrder or swpNoActivate)

method contentBounds*(w: w32Window): platform.Rect =
  var r: w32Rect
  discard procGetClientRect(w.hwnd, cast[uint](addr r))
  var origin: w32Point
  discard procClientToScreen(w.hwnd, cast[uint](addr origin))
  w.rectToDIP(w32Rect(left: origin.x, top: origin.y,
    right: origin.x + r.right, bottom: origin.y + r.bottom))

method setMinimumSize*(w: w32Window, s: Size) =
  w.minW = s.width
  w.minH = s.height
method setMaximumSize*(w: w32Window, s: Size) =
  w.maxW = s.width
  w.maxH = s.height

proc setStyle*(w: w32Window, bits: uint32, on: bool) =
  var style = windowLong(w.hwnd, gwlStyle)
  if on:
    style = style or uint(bits)
  else:
    style = style and not uint(bits)
  setWindowLong(w.hwnd, gwlStyle, style)
  discard procSetWindowPos(w.hwnd, 0, 0, 0, 0, 0,
    swpNoMove or swpNoSize or swpNoZOrder or swpNoActivate or
      swpFrameChanged)

proc setExStyle*(w: w32Window, bits: uint32, on: bool) =
  var ex = windowLong(w.hwnd, gwlExStyle)
  if on:
    ex = ex or uint(bits)
  else:
    ex = ex and not uint(bits)
  setWindowLong(w.hwnd, gwlExStyle, ex)

proc hasStyle*(w: w32Window, bits: uint32): bool =
  (windowLong(w.hwnd, gwlStyle) and uint(bits)) != 0

method setResizable*(w: w32Window, v: bool) =
  var bits = wsThickFrame
  if w.opts.maximizable:
    bits = bits or wsMaximizeBox
  w.setStyle(bits, v)
  w.captionChanged()

method isResizable*(w: w32Window): bool = w.hasStyle(wsThickFrame)
method setMovable*(w: w32Window, v: bool) = w.movable = v
method isMovable*(w: w32Window): bool = w.movable

method setMinimizable*(w: w32Window, v: bool) =
  w.setStyle(wsMinimizeBox, v)
  w.captionChanged()

method isMinimizable*(w: w32Window): bool = w.hasStyle(wsMinimizeBox)

method setMaximizable*(w: w32Window, v: bool) =
  w.setStyle(wsMaximizeBox, v)
  w.captionChanged()

method isMaximizable*(w: w32Window): bool = w.hasStyle(wsMaximizeBox)
method isClosable*(w: w32Window): bool = w.closable

method setClosable*(w: w32Window, v: bool) =
  w.closable = v
  let menu = procGetSystemMenu(w.hwnd, 0)
  var flags = uint(mfByCommand)
  if not v:
    flags = flags or uint(mfGrayed)
  discard procEnableMenuItem(menu, scClose, flags)
  if not w.caption.isNil:
    w.caption.paint()

method setAlwaysOnTop*(w: w32Window, v: bool) =
  var after = hwndNoTopmost
  if v:
    after = hwndTopmost
  discard procSetWindowPos(w.hwnd, after, 0, 0, 0, 0,
    swpNoMove or swpNoSize or swpNoActivate)

method isAlwaysOnTop*(w: w32Window): bool =
  (windowLong(w.hwnd, gwlExStyle) and wsExTopmost) != 0

method show*(w: w32Window) =
  let f = w.opts.flyout
  if not f.isNil and not f.focusable:
    discard procShowWindow(w.hwnd, swShowNoActivate)
    return
  if w.showMaximized:
    w.showMaximized = false
    discard procShowWindow(w.hwnd, swShowMaximized)
  else:
    discard procShowWindow(w.hwnd, swShow)
  discard procSetForegroundWindow(w.hwnd)

method showInactive*(w: w32Window) =
  if w.showMaximized:
    ## Maximizing activates the window; there is no inactive variant.
    w.showMaximized = false
    discard procShowWindow(w.hwnd, swShowMaximized)
    return
  discard procShowWindow(w.hwnd, swShowNoActivate)

method hide*(w: w32Window) = discard procShowWindow(w.hwnd, swHide)

method isVisible*(w: w32Window): bool =
  procIsWindowVisible(w.hwnd) != 0

method focus*(w: w32Window) =
  if not w.host.isNil:
    w.focusWebView()
    return
  let f = w.opts.flyout
  if not f.isNil and not f.focusable:
    w.show() ## never activated
    return
  if w.isMinimized():
    discard procShowWindow(w.hwnd, swRestore)
  discard procSetForegroundWindow(w.hwnd)
  w.focusWebView()

method blur*(w: w32Window) =
  const gwHwndNext = 2'u32
  let next = procGetNextWindow(w.hwnd, gwHwndNext)
  if next != 0:
    discard procSetForegroundWindow(next)

method isFocused*(w: w32Window): bool =
  if not w.host.isNil:
    return w.focused
  procGetForegroundWindow() == w.hwnd

method minimize*(w: w32Window) = discard procShowWindow(w.hwnd,
  swMinimize)

method isMinimized*(w: w32Window): bool = procIsIconic(w.hwnd) != 0

method maximize*(w: w32Window) =
  if not w.isVisible():
    w.showMaximized = true ## maximizing would show it
    return
  discard procShowWindow(w.hwnd, swShowMaximized)

method unmaximize*(w: w32Window) =
  if w.showMaximized:
    w.showMaximized = false
    return
  if w.isMaximized():
    discard procShowWindow(w.hwnd, swRestore)

method isMaximized*(w: w32Window): bool =
  if w.showMaximized:
    return true
  procIsZoomed(w.hwnd) != 0

method restore*(w: w32Window) = discard procShowWindow(w.hwnd,
  swRestore)

## setFullScreen takes the window's frame and menu bar away, or gives
## them back. Each step sizes the window again: it is laid out once,
## at the end.
method setFullScreen*(w: w32Window, v: bool) =
  if v == w.fullScreen:
    return
  if w.inMenu:
    ## its menus come from a bar that comes or goes
    discard procEndMenu()
  w.reframing = true
  if v:
    w.savedStyle = windowLong(w.hwnd, gwlStyle)
    w.savedExStyle = windowLong(w.hwnd, gwlExStyle)
    w.savedPlacement.length = uint32(sizeof(w.savedPlacement))
    discard procGetWindowPlacement(w.hwnd,
      cast[uint](addr w.savedPlacement))
    w.fullScreen = true
    let style = w.savedStyle and not uint(wsCaption or wsThickFrame)
    setWindowLong(w.hwnd, gwlStyle, style)
    w.attachMenu() ## no menu bar in full screen
    let m = monitorInfo(w.monitor()).monitor
    discard procSetWindowPos(w.hwnd, 0, uint(uint32(m.left)),
      uint(uint32(m.top)), uint(uint32(m.right - m.left)),
      uint(uint32(m.bottom - m.top)), swpNoZOrder or swpFrameChanged)
  else:
    w.fullScreen = false
    setWindowLong(w.hwnd, gwlStyle, w.savedStyle)
    setWindowLong(w.hwnd, gwlExStyle, w.savedExStyle)
    w.attachMenu()
    discard procSetWindowPlacement(w.hwnd,
      cast[uint](addr w.savedPlacement))
    discard procSetWindowPos(w.hwnd, 0, 0, 0, 0, 0,
      swpNoMove or swpNoSize or swpNoZOrder or swpFrameChanged)
  w.reframing = false
  var kind = uint(sizeRestored)
  if w.isMinimized():
    kind = sizeMinimized
  elif procIsZoomed(w.hwnd) != 0:
    kind = sizeMaximized
  w.sized(kind)
  if v:
    w.h.enteredFullScreen()
  else:
    w.h.leftFullScreen()
  w.captionChanged() ## hidden in full screen

method isFullScreen*(w: w32Window): bool = w.fullScreen

method center*(w: w32Window) =
  var r: w32Rect
  discard procGetWindowRect(w.hwnd, cast[uint](addr r))
  let work = monitorWorkArea(w.monitor())
  let width = r.right - r.left
  let height = r.bottom - r.top
  let x = work.left + (work.right - work.left - width) div 2
  let y = work.top + (work.bottom - work.top - height) div 2
  discard procSetWindowPos(w.hwnd, 0, uint(uint32(x)),
    uint(uint32(y)), 0, 0, swpNoSize or swpNoZOrder or swpNoActivate)

method setBackgroundColor*(w: w32Window, c: platform.Color) =
  w.bg = new platform.Color
  w.bg[] = c
  ## A web view in native UI has no window of its own to paint: only
  ## WebView2 fills it, and a brush would outlive it.
  if w.host.isNil:
    if w.bgBrush != 0:
      discard procDeleteObject(w.bgBrush)
    w.bgBrush = procCreateSolidBrush(uint(c.r) or (uint(c.g) shl 8) or
      (uint(c.b) shl 16))
  w.withWebView(proc() {.closure.} = w.applyWebViewBackground())
  if w.hwnd != 0:
    discard procInvalidateRectW(w.hwnd, 0, 1)

## applyWebViewBackground paints the webview before its page does:
## transparent with a material behind it, else the background color.
## WebView2 only supports fully opaque or fully transparent
## backgrounds. A transparent page shows the window's background
## color behind it, which GDI paints; in a window without a
## redirection bitmap, the webview does.
proc applyWebViewBackground*(w: w32Window) =
  let ctl2 = queryInterface(w.controller,
    addr iidICoreWebView2Controller2)
  if ctl2 == 0:
    return
  defer: release(ctl2)
  var c = 0xFFFFFFFF'u32 ## opaque white: A, R, G, B bytes
  if w.vibrancy != "":
    c = 0
  elif w.opts.transparent and (w.bg.isNil or not w.noRedirect):
    c = 0
  elif not w.bg.isNil and w.bg.a == 0:
    c = 0
  elif not w.bg.isNil:
    c = 0xFF'u32 or (uint32(w.bg.r) shl 8) or
      (uint32(w.bg.g) shl 16) or (uint32(w.bg.b) shl 24)
  discard comCall(ctl2, ctl2PutDefaultBackgroundColor, uint(c))

method setOpacity*(w: w32Window, v: float64) =
  w.opacity = v
  w.updateLayered()

method opacity*(w: w32Window): float64 = w.opacity

## updateLayered makes the window layered while it is translucent or
## lets the mouse through.
proc updateLayered*(w: w32Window) =
  let layered = w.opacity < 1 or w.ignoreMouse
  w.setExStyle(wsExLayered, layered)
  if layered:
    discard procSetLayeredWindowAttributes(w.hwnd, 0,
      uint(byte(w.opacity * 255 + 0.5)), lwaAlpha)

method setHasShadow*(w: w32Window, v: bool) =
  w.shadow = v
  if not w.captionless() or w.vibrancy != "":
    return
  var m: margins
  if v:
    ## a frame the size of a pixel brings the shadow back
    m.top = 1
  discard procDwmExtendFrameIntoClientArea(w.hwnd,
    cast[uint](addr m))

method hasShadow*(w: w32Window): bool = w.shadow

method setIgnoreMouseEvents*(w: w32Window, v: bool) =
  w.ignoreMouse = v
  w.setExStyle(wsExTransparent, v)
  w.updateLayered()

method setContentProtection*(w: w32Window, v: bool) =
  if not has(procSetWindowDisplayAffinity):
    return
  var affinity = uint(wdaNone)
  if v:
    affinity = wdaExcludeFromCapture
  if procSetWindowDisplayAffinity(w.hwnd, affinity) == 0 and v:
    ## WDA_MONITOR before Windows 10 2004
    discard procSetWindowDisplayAffinity(w.hwnd, 1)

## Windows 11 system backdrops (DWM_SYSTEMBACKDROP_TYPE).
const
  backdropNone* = 1'i32
  backdropMica* = 2'i32
  backdropAcrylic* = 3'i32
  backdropMicaAlt* = 4'i32

proc backdropFor*(material: string): int32 =
  case material
  of "":
    backdropNone
  of "mica":
    backdropMica
  of "tabbed":
    backdropMicaAlt
  of "acrylic", "menu", "popover", "hud", "sheet", "tooltip",
      "selection", "fullscreen-ui":
    backdropAcrylic
  else:
    backdropMica

method setVibrancy*(w: w32Window, material: string) =
  w.vibrancy = material
  var backdrop = backdropFor(material)
  var m: margins
  if material != "":
    ## The material shows where the frame extends, behind the page.
    m = margins(left: -1, top: -1, right: -1, bottom: -1)
  discard procDwmExtendFrameIntoClientArea(w.hwnd,
    cast[uint](addr m))
  discard procDwmSetWindowAttribute(w.hwnd, dwmwaSystemBackdropType,
    cast[uint](addr backdrop), 4)
  if material == "" and w.captionless() and w.shadow:
    w.setHasShadow(true)
  w.withWebView(proc() {.closure.} = w.applyWebViewBackground())
  discard procInvalidateRectW(w.hwnd, 0, 1)

## hasAppMenu tells whether the window shows the application menu in
## its menu bar: flyouts and panels show none.
proc hasAppMenu*(w: w32Window): bool =
  w.opts.flyout.isNil and not w.opts.panel

method setMenu*(w: w32Window, m: Menu) =
  w.ownMenu = not m.isNil
  var menu = m
  if menu.isNil and w.hasAppMenu():
    menu = w.b.appMenu
  w.installMenu(menu)

method setAutoHideMenu*(w: w32Window, v: bool) =
  w.autoHideMenu = v
  if w.hmenu != 0 and not w.revealed:
    w.attachMenu()

method startDrag*(w: w32Window) =
  discard procReleaseCapture()
  discard procSendMessageW(w.hwnd, wmNCLButtonDown, htCaption, 0)

method titleBarDoubleClicked*(w: w32Window) =
  if w.isMaximized():
    w.unmaximize()
  elif w.hasStyle(wsMaximizeBox):
    w.maximize()

method close*(w: w32Window) =
  if not w.host.isNil:
    w.closeWebView()
    return
  if not w.closed:
    w.destroy()

proc setIcon*(w: w32Window, icon: uint) =
  const iconSmall = 0'u
  const iconBig = 1'u
  discard procSendMessageW(w.hwnd, wmSetIcon, iconSmall, icon)
  discard procSendMessageW(w.hwnd, wmSetIcon, iconBig, icon)

proc boolArg*(v: bool): uint =
  if v: 1 else: 0
