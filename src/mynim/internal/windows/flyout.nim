## flyout.nim (flyout.go): a flyout (WindowOptions.flyout) is a
## WS_POPUP window owned by its parent, which keeps it above, out of
## the taskbar (WS_EX_TOOLWINDOW), and transparent where its content
## is: without a redirection bitmap, the content shows through
## DirectComposition with its alpha. One that is not focusable is
## never activated (WS_EX_NOACTIVATE, MA_NOACTIVATE), and one that is
## closes when another window is activated. Owned windows do not
## follow their owner: the core places flyouts again as their parent
## moves.

const
  maNoActivate* = 3'u
  ## wmAppDismiss asks a flyout whether it closes, after the
  ## activation that dismissed it.
  wmAppDismiss* = wmApp + 6

## Forward declarations of procs of files included later.
proc rect*(t: w32Tray): tuple[r: w32Rect, shows: bool]
proc dismissFlyout*(w: w32Window)

## roundFlyout rounds the corners of a flyout with a shadow, as
## Windows 11 rounds its menus and WinUI's flyouts: DWM clips the
## window, outlines it and casts the shadow around all of it.
## Windows 10 rounds nothing, and casts the shadow of its menus,
## square, along the right and bottom edges.
proc roundFlyout*(w: w32Window) =
  var pref = int32(dwmwcpRound)
  discard procDwmSetWindowAttribute(w.hwnd,
    dwmwaWindowCornerPreference, cast[uint](addr pref), 4)

## flyoutStyles returns the styles of a flyout's window.
proc flyoutStyles*(w: w32Window): tuple[style, ex: uint32] =
  var style = wsPopup or wsClipChildren
  var ex = wsExToolWindow
  if not w.opts.flyout.tray.isNil:
    ## over other apps' windows, without an owner
    ex = ex or wsExTopmost
  if not w.opts.flyout.focusable:
    ex = ex or wsExNoActivate
  if w.noRedirect:
    ex = ex or wsExNoRedirect
  (style, ex)

## rectOf returns r as a platform rectangle.
proc rectOf*(r: w32Rect): platform.Rect =
  platform.Rect(x: int(r.left), y: int(r.top),
    width: int(r.right - r.left), height: int(r.bottom - r.top))

## placeFlyout places a flyout next to its anchor, in the parent's
## client area or a tray's icon, as Flyout.place resolves it in the
## work area of the monitor that has most of the anchor, in physical
## pixels at the DPI of the parent, or of the icon's monitor.
method placeFlyout*(w: w32Window, f: Flyout, size: Size) =
  if w.opts.flyout.isNil or w.closed:
    return
  w.flyout = f
  w.flyoutSize = size
  var a: w32Rect ## the anchor
  var dpi = 0
  if f.tray of w32Tray:
    let t = w32Tray(f.tray)
    var shows = false
    (a, shows) = t.rect()
    if not shows:
      ## In the middle of the primary monitor's work area.
      let mon = procMonitorFromPoint(0, monitorDefaultToPrimary)
      dpi = monitorDPI(mon)
      let r = centered(
        Size(width: int(toPx(size.width, dpi)),
             height: int(toPx(size.height, dpi))),
        rectOf(monitorWorkArea(mon)))
      discard procSetWindowPos(w.hwnd, 0, uint(uint32(r.x)),
        uint(uint32(r.y)), uint(uint32(r.width)),
        uint(uint32(r.height)), swpNoZOrder or swpNoActivate)
      return
    let mon = procMonitorFromRect(cast[uint](addr a),
      monitorDefaultToNearest)
    dpi = monitorDPI(mon)
  else:
    let p = w.parent
    if p.isNil or p.closed:
      return
    dpi = dpiOf(p.hwnd)
    var origin: w32Point
    discard procClientToScreen(p.hwnd, cast[uint](addr origin))
    a.left = origin.x + toPx(f.anchor.x, dpi)
    a.top = origin.y + toPx(f.anchor.y, dpi)
    a.right = a.left + toPx(f.anchor.width, dpi)
    a.bottom = a.top + toPx(f.anchor.height, dpi)
  var px = f
  px.gap = int(toPx(f.gap, dpi))
  var search = w32Rect(left: a.left, top: a.top,
    right: max(a.right, a.left + 1),
    bottom: max(a.bottom, a.top + 1))
  let mon = procMonitorFromRect(cast[uint](addr search),
    monitorDefaultToNearest)
  let (r, fx, fy) = px.place(rectOf(a),
    Size(width: int(toPx(size.width, dpi)),
         height: int(toPx(size.height, dpi))),
    rectOf(monitorWorkArea(mon)))
  discard fx
  discard fy
  discard procSetWindowPos(w.hwnd, 0, uint(uint32(r.x)),
    uint(uint32(r.y)), uint(uint32(r.width)),
    uint(uint32(r.height)), swpNoZOrder or swpNoActivate)

## flyoutMessage handles the messages of a flyout's window that
## differ from other windows'.
proc flyoutMessage*(w: w32Window, m: uint32, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  case m
  of wmMouseActivate:
    if not w.flyout.focusable:
      return (maNoActivate, true)
  of wmActivate:
    if loword(wp) == waInactive and w.flyout.focusable:
      ## Unless the window activated is a flyout of its own.
      var x = w.b.windows.getOrDefault(lp)
      while not x.isNil:
        if x == w:
          return (0'u, false)
        x = x.parent
      ## A press on its own tray icon, which activates the taskbar:
      ## the icon's click toggles it.
      if w.flyout.tray of w32Tray:
        let t = w32Tray(w.flyout.tray)
        var pt: w32Point
        discard procGetCursorPos(cast[uint](addr pt))
        let (r, shows) = t.rect()
        if shows and pt.x >= r.left and pt.x < r.right and
            pt.y >= r.top and pt.y < r.bottom:
          return (0'u, false)
      postMessage(w.hwnd, wmAppDismiss, 0, 0)
  of wmAppDismiss:
    w.dismissFlyout()
    return (0'u, true)
  of wmNCCalcSize:
    if wp != 0:
      ## all of the window is client area
      return (0'u, true)
  else:
    discard
  (0'u, false)

## ownsFocusableFlyout reports whether a focusable flyout of w, or of
## its flyouts, shows: a click activating w only closes it, as it
## closes menus and WinUI's flyouts, which would otherwise come back
## as the click on what opened them toggles them.
proc ownsFocusableFlyout*(w: w32Window): bool =
  for x in w.b.windows.values:
    let f = x.opts.flyout
    if f.isNil or not f.focusable or x.closed or not x.isVisible():
      continue
    var p = x.parent
    while not p.isNil:
      if p == w:
        return true
      p = p.parent
  false

## dismissFlyout closes a focusable flyout another window was
## activated over, as the user closing it.
proc dismissFlyout*(w: w32Window) =
  if not w.closed and w.isVisible() and w.h.shouldClose():
    w.close()
