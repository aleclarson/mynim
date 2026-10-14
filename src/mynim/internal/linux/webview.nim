## webview.nim: a web view in a window of native UI
## (platform.Surface.newWebView) is a window of this package without a
## GtkWindow of its own: win is its host's, and its WebKitWebView is a
## child of a GtkLayout under the surface's area, in a GtkOverlay that
## the first web view puts where the area was (the area is then an
## overlay of it, which GTK realizes again, with a new GL context). The
## area keeps an alpha channel from then on: its frames are transparent
## where the content shows a web view (holes), so that what the content
## paints after it shows over the page, and an input shape lets the
## pointer through to the page there. Its signals find it by its id in
## Backend.webViews, apart from the windows.

var
  gtkLayoutNew: proc(h, v: pointer): pointer {.cdecl.}
  gtkLayoutPut: proc(l, child: pointer, x, y: int32) {.cdecl.}
  gtkLayoutMove: proc(l, child: pointer, x, y: int32) {.cdecl.}
  gtkWidgetGetParent: proc(w: pointer): pointer {.cdecl.}
  gtkWidgetGetParentWindow: proc(w: pointer): pointer {.cdecl.}
  gdkWindowInputShapeCombineRegion: proc(w, region: pointer, x, y: int32) {.cdecl.}
  cairoRegionCreateRectangle: proc(r: ptr gdkRectangle): pointer {.cdecl.}
  cairoRegionSubtractRectangle: proc(region: pointer,
    r: ptr gdkRectangle): int32 {.cdecl.}
  cairoRegionUnion: proc(region, other: pointer): int32 {.cdecl.}
  cairoRegionDestroy: proc(region: pointer) {.cdecl.}
  gtkWidgetEvent: proc(w, event: pointer): bool {.cdecl.}
  gtkContainerGetFocusChild: proc(c: pointer): pointer {.cdecl.}
  webViewsLoaded: bool

  ## cbWebViewFocus handles a web view's focus signal.
  cbWebViewFocus*: pointer

proc tabOut*(w: gtkWindow, back: bool) ## below
proc makeLayers*(s: gtkSurface) ## below
proc shapeInput*(s: gtkSurface) ## below
proc gdkRect*(r: RectF): ptr gdkRectangle ## below

proc loadWebViews*() =
  if webViewsLoaded: return
  webViewsLoaded = true
  mustBind(libGTK, cast[ptr pointer](addr gtkLayoutNew), "gtk_layout_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkLayoutPut), "gtk_layout_put")
  mustBind(libGTK, cast[ptr pointer](addr gtkLayoutMove),
    "gtk_layout_move")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetParent),
    "gtk_widget_get_parent")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetParentWindow),
    "gtk_widget_get_parent_window")
  mustBind(libGDK,
    cast[ptr pointer](addr gdkWindowInputShapeCombineRegion),
    "gdk_window_input_shape_combine_region")
  mustBind(libCairo, cast[ptr pointer](addr cairoRegionCreateRectangle),
    "cairo_region_create_rectangle")
  mustBind(libCairo,
    cast[ptr pointer](addr cairoRegionSubtractRectangle),
    "cairo_region_subtract_rectangle")
  mustBind(libCairo, cast[ptr pointer](addr cairoRegionUnion),
    "cairo_region_union")
  mustBind(libCairo, cast[ptr pointer](addr cairoRegionDestroy),
    "cairo_region_destroy")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetEvent),
    "gtk_widget_event")
  mustBind(libGTK, cast[ptr pointer](addr gtkContainerGetFocusChild),
    "gtk_container_get_focus_child")
  # GTK moves the keyboard with Tab through focus signals, which
  # WebKit's Tab past the page's ends starts: the content takes the
  # keyboard back, and GTK moving it into a page by itself, as a window
  # shows, leaves it with the content.
  cbWebViewFocus = cast[pointer](
    proc(widget: pointer, direction: int32, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil or w.host.isNil:
        return false
      const tabForward = 0'i32 # GtkDirectionType
      const tabBackward = 1'i32
      if gtkWidgetHasFocus(w.web):
        if direction == tabForward or direction == tabBackward:
          w.tabOut(direction == tabBackward)
          return true
        return false
      if not gtkContainerGetFocusChild(w.web).isNil:
        return false # a dialog of WebKit's in the view has the keyboard
      if w.host.surface != nil:
        gtkWidgetGrabFocus(w.host.surface.area)
      true)

proc newOverlay*(): pointer ## surface_access.nim
proc send*(s: gtkSurface, ev: SurfaceEvent): bool ## surface.nim
method newWebView*(s: gtkSurface, o: ref WindowOptions,
    h: WindowHandler): tuple[w: WebView, err: ref CatchableError] =
  let err = webKit()
  if not err.isNil:
    return (nil, err)
  loadWebViews()
  let host = s.w
  let b = host.b
  if s.layers.isNil:
    s.makeLayers()
  inc b.nextID
  let v = gtkWindow(b: b, id: b.nextID, h: h, opts: o,
    win: host.win, host: host)
  b.webViews[v.id] = v
  v.createWebView()
  discard connect(v.web, "focus", cbWebViewFocus, cast[pointer](v.id))
  gtkWidgetSetNoShowAll(v.web, true) # hidden until placed
  gtkLayoutPut(s.web, v.web, 0, 0)
  b.byWebView[v.web] = v
  host.webViews.add v
  (v.asWebView, nil)

## makeLayers puts the surface's area over a layout holding the web
## views, in an overlay where the area was.
proc makeLayers*(s: gtkSurface) =
  let area = s.area
  let parent = gtkWidgetGetParent(area)
  let focused = gtkWidgetHasFocus(area)
  s.layers = newOverlay()
  s.web = gtkLayoutNew(nil, nil)
  gtkContainerAdd(s.layers, s.web)
  discard gObjectRef(area)
  if not parent.isNil:
    gtkContainerRemove(parent, area)
  if s.gl:
    # Holes show the web views through the frames.
    gtkGLAreaSetHasAlpha(area, true)
  gtkOverlayAddOverlay(s.layers, area)
  gObjectUnref(area)
  if not parent.isNil:
    if parent == s.w.box:
      gtkBoxPackStart(parent, s.layers, true, true, 0)
      if not s.w.menubar.isNil:
        gtkBoxReorderChild(parent, s.layers, 1) # under the menu bar
    else: # the overlay of a hidden title bar's controls
      gtkContainerAdd(parent, s.layers)
  gtkWidgetShowAll(s.layers)
  if focused:
    gtkWidgetGrabFocus(area)

## placeWebViews shows the window's web views where the content shows
## them, in its paint order under the surface, and hides the others;
## the area's input shape lets the pointer through to them.
method placeWebViews*(s: gtkSurface, views: seq[WebViewPlacement]) =
  let host = s.w
  if host.closed or s.layers.isNil:
    return
  s.placed = views
  var shown = newSeqOfCap[gtkWindow](views.len)
  for p in views:
    let v = if p.webView of gtkWebView: gtkWebView(p.webView).w
            else: nil
    if v.isNil or v.host != host or v.closed:
      continue
    let f = p.frame
    let x = int32(round(f.x))
    let y = int32(round(f.y))
    gtkLayoutMove(s.web, v.web, x, y)
    gtkWidgetSetSizeRequest(v.web,
      int32(round(f.x + f.w)) - x, int32(round(f.y + f.h)) - y)
    if not gtkWidgetGetVisible(v.web):
      gtkWidgetShow(v.web)
    shown.add v
  for v in host.webViews:
    if v notin shown and gtkWidgetGetVisible(v.web):
      if gtkWidgetHasFocus(v.web):
        # A hidden view keeps no keyboard: it goes back to the
        # content.
        gtkWidgetGrabFocus(s.area)
      gtkWidgetHide(v.web)
  s.shapeInput()

## shapeInput lets the pointer through the area where the web views
## take it: in their clips but where the content painted over them.
proc shapeInput*(s: gtkSurface) =
  let win = gtkWidgetGetParentWindow(s.area) # the overlay's window of the area
  if win.isNil or win == gtkWidgetGetWindow(s.w.win):
    return
  var all: gdkRectangle
  gtkWidgetGetAllocation(s.area, addr all)
  var whole = gdkRectangle(width: all.width, height: all.height)
  let region = cairoRegionCreateRectangle(addr whole)
  for p in s.placed:
    discard cairoRegionSubtractRectangle(region, gdkRect(p.clip))
    # Unless what the content painted over it takes the pointer: put
    # back by a second region, as cairo has no union of a difference.
    for c in p.covers:
      let r = gdkRect(c)
      let cover = cairoRegionCreateRectangle(r)
      discard cairoRegionUnion(region, cover)
      cairoRegionDestroy(cover)
  gdkWindowInputShapeCombineRegion(win, region, 0, 0)
  cairoRegionDestroy(region)

## gdkRect returns the pixels of r, in DIPs, that it covers wholly.
proc gdkRect*(r: RectF): ptr gdkRectangle =
  let x = int32(ceil(r.x))
  let y = int32(ceil(r.y))
  result = cast[ptr gdkRectangle](alloc0(sizeof(gdkRectangle)))
  result.x = x
  result.y = y
  result.width = max(int32(floor(r.x + r.w)) - x, 0)
  result.height = max(int32(floor(r.y + r.h)) - y, 0)

## webViewAt returns the web view that takes the pointer at x, y in the
## surface.
proc webViewAt*(s: gtkSurface, x, y: float64): gtkWindow =
  for i in countdown(s.placed.len - 1, 0):
    if s.placed[i].at(x, y):
      if s.placed[i].webView of gtkWebView:
        let v = gtkWebView(s.placed[i].webView).w
        if not v.isNil and not v.closed:
          return v

## top returns the window that shows w: its host for a web view.
proc top*(w: gtkWindow): gtkWindow =
  if not w.host.isNil:
    return w.host
  w

## webViewPressed tells the content of the window that a button went
## down on the web view w, at x, y in its window, which takes the
## press.
proc webViewPressed*(w: gtkWindow, x, y: float64, button: uint32,
    mods: platform.Modifiers) =
  let s = w.host.surface
  if s.isNil or w.host.closed:
    return
  var a: gdkRectangle
  gtkWidgetGetAllocation(w.web, addr a)
  var b = -1
  case button
  of 1: b = 0
  of 2: b = 2
  of 3: b = 1
  else: return
  discard s.send(SurfaceEvent(kind: webViewPress,
    x: float64(a.x) + x, y: float64(a.y) + y, button: b, mods: mods))

## focusedWebView returns the web view of w that has the keyboard, if
## one does.
proc focusedWebView*(w: gtkWindow): gtkWindow =
  for v in w.webViews:
    if not v.closed and gtkWidgetHasFocus(v.web):
      return v

## tabInto gives the web view the keyboard. WebKitGTK focuses no element
## of the page as the view takes it: once the page let go of the one it
## had, the Tab moving the focus here, passed on, focuses its first, or
## its last going back.
method tabInto*(w: gtkWindow, back: bool) =
  let s = w.host.surface
  if w.closed or s.isNil:
    return
  w.eval("document.activeElement && document.activeElement.blur()")
  gtkWidgetGrabFocus(w.web)
  let ev = s.pressing
  if not ev.isNil:
    case field[uint32](ev, 28)
    of 0xff09, 0xfe20, 0xff89: # GDK_KEY_Tab, ISO_Left_Tab, KP_Tab
      discard gtkWidgetEvent(w.web, ev)
    else: discard

## tabInto gives the web view the keyboard. WebKitGTK focuses no
## element of the page as the view takes it: once the page let go of the
## one it had, the Tab moving the focus here, passed on, focuses its
## first, or its last going back.
proc tabInto*(w: gtkWindow, back: bool) =
  let s = w.host.surface
  if w.closed or s.isNil:
    return
  w.eval("document.activeElement && document.activeElement.blur()")
  gtkWidgetGrabFocus(w.web)
  let ev = s.pressing
  if not ev.isNil:
    case field[uint32](ev, 28)
    of 0xff09, 0xfe20, 0xff89: # GDK_KEY_Tab, ISO_Left_Tab, KP_Tab
      discard gtkWidgetEvent(w.web, ev)
    else: discard

## tabOut gives the content the keyboard back as Tab leaves the page of
## the web view w past its last element, or Shift+Tab past its first.
proc tabOut*(w: gtkWindow, back: bool) =
  let s = w.host.surface
  if s.isNil or w.host.closed:
    return
  gtkWidgetGrabFocus(s.area)
  var ev = SurfaceEvent(kind: webViewTabOut, key: platform.keyTab,
    webView: w.asWebView)
  if back:
    ev.mods = modShift
  discard s.send(ev)

## closeWebView closes a web view: by close, or as its window closes.
proc closeWebView*(w: gtkWindow) =
  if w.closed: return
  w.closed = true
  let b = w.b
  b.webViews.del(w.id)
  b.byWebView.del(w.web)
  if gtkWidgetHasFocus(w.web) and w.host.surface != nil:
    gtkWidgetGrabFocus(w.host.surface.area)
  webkitUserContentManagerUnregisterHandler(w.ucm, cs("mynim"))
  webkitUserContentManagerRemoveAllScripts(w.ucm)
  gtkWidgetDestroy(w.web)
  gObjectUnref(w.ucm)
  if not w.press.event.isNil:
    gdkEventFree(w.press.event)
    w.press.event = nil
  let h = w.host
  h.webViews.keepItIf(it != w)
  if h.surface != nil:
    let s = h.surface
    s.placed.keepItIf(it.webView != WebView(w.asWebView))
    if not h.closed:
      s.shapeInput()

## closeWebViews closes the web views of a window that closes.
proc closeWebViews*(w: gtkWindow) =
  while w.webViews.len > 0:
    w.webViews[^1].closeWebView()
