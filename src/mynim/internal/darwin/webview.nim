## webview.go: a web view in a window of native UI (Surface.newWebView)
## is a window of this package without an NSWindow of its own: win is
## its host's, which its sheets and panels use, and its MyNimWebView
## sits in a clip view, a subview of the host's content view under the
## surface. The surface's frames are transparent where the content shows
## the web view (holes), so what the content paints after it shows over
## the page, and its hitTest: lets the pointer through to the page
## there; the web view takes no mouse moves where the content painted
## over it. Its delegate is the web view's alone, never the NSWindow's,
## so it hears only of its page.

## nsViewMinYMargin is NSViewMinYMargin: the margin below a view grows,
## which keeps its distance to the top of an unflipped superview.
const nsViewMinYMargin = 8

## nsWindowBelow is NSWindowBelow, for addSubview:positioned:relativeTo:.
const nsWindowBelow = -1

proc stackWebViews(s: macSurface, shown: seq[macWindow])

method newWebView*(s: macSurface, o: WindowOptions,
                   h: WindowHandler):
    tuple[w: WebView, err: ref CatchableError] =
  let host = s.w
  let b = host.b
  let v = macWindow(b: b, h: h, win: host.win, host: host)
  v.opts = new(WindowOptions)
  v.opts[] = o
  v.asWebView = macWebView(w: v)
  withPool(proc() =
    v.delegate = alloc("MyNimWindowDelegate")
    v.createWebView(NSRect())
    discard send(v.web, "setAutoresizingMask:", argu(0))
    v.clip = msgInitRect(send(`class`("MyNimClipView"), "alloc"),
      sel("initWithFrame:"), NSRect())
    discard send(v.clip, "setWantsLayer:", argu(1))
    discard send(send(v.clip, "layer"), "setMasksToBounds:", argu(1))
    discard send(v.clip, "setAutoresizingMask:",
      argu(nsViewMinYMargin))
    discard send(v.clip, "setHidden:", argu(1))
    if o.backgroundColor != nil and not o.transparent:
      v.clipBackground(o.backgroundColor[])
    discard send(v.clip, "addSubview:", argu(v.web))
    discard send(host.view, "addSubview:positioned:relativeTo:",
      argu(v.clip), argu(nsWindowBelow), argu(s.view)))
  b.byDelegate[v.delegate] = v
  b.byWebView[v.web] = v
  host.webViews.add(v)
  (WebView(v.asWebView), nil)

## clipBackground fills the clip view with c until the page paints.
proc clipBackground*(w: macWindow, c: platform.Color) =
  discard send(send(w.clip, "layer"), "setBackgroundColor:",
    argu(send(nsColor(c), "CGColor")))

method placeWebViews*(s: macSurface, views: seq[WebViewPlacement]) =
  let host = s.w
  if host.closed:
    return
  s.placed = views
  let height = msgRect(host.view, sel("bounds")).size.height
  var shown: seq[macWindow]
  withPool(proc() =
    for p in views:
      if not (p.webView of macWebView):
        continue
      let v = macWebView(p.webView).w
      if v.host != host or v.closed:
        continue
      let c = p.clip
      let f = p.frame
      msgSetRect(v.clip, sel("setFrame:"), NSRect(
        origin: NSPoint(x: c.x, y: height - c.y - c.h),
        size: NSSize(width: c.w, height: c.h)))
      # The clip view is flipped.
      msgSetRect(v.web, sel("setFrame:"), NSRect(
        origin: NSPoint(x: f.x - c.x, y: f.y - c.y),
        size: NSSize(width: f.w, height: f.h)))
      if sendBool(v.clip, "isHidden"):
        discard send(v.clip, "setHidden:", argu(0))
      shown.add(v)
    for v in host.webViews:
      if v notin shown and not sendBool(v.clip, "isHidden"):
        if v.hasKeyboard():
          # A hidden view keeps no keyboard: it goes back to the
          # content.
          discard send(host.win, "makeFirstResponder:", argu(s.view))
        discard send(v.clip, "setHidden:", argu(1))
    s.stackWebViews(shown))

## stackWebViews puts the clip views of the web views shown in the order
## the content painted them, under the surface, unless they are.
proc stackWebViews(s: macSurface, shown: seq[macWindow]) =
  if shown.len < 2:
    return
  let subviews = send(s.w.view, "subviews")
  let n = sendInt(subviews, "count")
  var at = 0
  for i in 0 ..< n:
    if at < shown.len and
        send(subviews, "objectAtIndex:", argu(i)) == shown[at].clip:
      inc at
  if at == shown.len:
    return
  # Moving a view out of its superview takes the keyboard from it: the
  # first responder goes back to it.
  let first = send(s.w.win, "firstResponder")
  for v in shown:
    discard retain(v.clip)
    discard send(v.clip, "removeFromSuperview")
    discard send(s.w.view, "addSubview:positioned:relativeTo:",
      argu(v.clip), argu(nsWindowBelow), argu(s.view))
    release(v.clip)
  if first != nil and first != send(s.w.win, "firstResponder"):
    discard send(s.w.win, "makeFirstResponder:", argu(first))

## webViewAt returns the web view that takes the pointer at x, y in the
## surface: the last placed, as the content painted it over the others,
## whose placement takes it.
proc webViewAt*(s: macSurface, x, y: float64): macWindow =
  for i in countdown(s.placed.len - 1, 0):
    let p = s.placed[i]
    if p.at(x, y) and p.webView of macWebView:
      let v = macWebView(p.webView).w
      if not v.closed:
        return v
  nil

## covered reports whether the content painted over the web view w where
## the mouse event ev happened, or does not show it there.
proc covered*(w: macWindow, ev: id): bool =
  let s = w.host.surface
  if s == nil:
    return false
  let (x, y) = s.location(ev)
  s.webViewAt(x, y) != w

## top returns the window that shows w: its host for a web view.
proc top*(w: macWindow): macWindow =
  if w.host != nil:
    return w.host
  w

## hasKeyboard reports whether the web view, or a view in it, is the
## first responder of its window.
proc hasKeyboard*(w: macWindow): bool =
  let r = send(w.win, "firstResponder")
  r != nil and sendBool(r, "isKindOfClass:", argu(`class`("NSView"))) and
    sendBool(r, "isDescendantOf:", argu(w.web))

## pressed tells the content of the window that a button went down on
## the web view w, which takes the press.
proc pressed*(w: macWindow, ev: id, button: int) =
  let s = w.host.surface
  if s != nil and not w.host.closed:
    let (x, y) = s.location(ev)
    discard s.send(platform.SurfaceEvent(kind: webViewPress, x: x,
      y: y, button: button, mods: eventMods(ev)))

method tabInto*(w: macWebView, back: bool) =
  ## tabInto gives the web view the keyboard as the window's key view
  ## loop does, which tells WebKit to focus the page's first element, or
  ## its last going back: the web view follows the surface in the loop,
  ## or precedes it.
  let s = w.w.host.surface
  if w.w.closed or s == nil:
    return
  withPool(proc() =
    if back:
      discard send(w.w.web, "setNextKeyView:", argu(s.view))
      discard send(w.w.win, "selectKeyViewPrecedingView:",
        argu(s.view))
    else:
      discard send(s.view, "setNextKeyView:", argu(w.w.web))
      discard send(w.w.win, "selectKeyViewFollowingView:",
        argu(s.view)))

method focus*(w: macWebView) = w.tabInto(false)

method setBackgroundColor*(w: macWebView, c: Color) =
  w.w.clipBackground(c)

method close*(w: macWebView) = w.w.closeWebView()

## tabOut gives the content the keyboard back as Tab leaves the page of
## the web view w past its last element, or Shift+Tab past its first.
proc tabOut*(w: macWindow, back: bool) =
  let s = w.host.surface
  if s == nil or w.host.closed:
    return
  discard send(w.win, "makeFirstResponder:", argu(s.view))
  var ev = platform.SurfaceEvent(kind: webViewTabOut, key: keyTab,
    webView: w.asWebView)
  if back:
    ev.mods = platform.modShift
  discard s.send(ev)

## webViewOf returns the web view that is view or holds it.
proc webViewOf*(view: id): macWindow =
  var v = view
  while v != nil:
    let w = theBackend.byWebView.getOrDefault(v)
    if w != nil:
      return w
    v = send(v, "superview")
  nil

## closeWebView closes a web view: by close, or as its window closes.
proc closeWebView*(w: macWindow) =
  if w.closed:
    return
  w.closed = true
  let b = w.b
  withPool(proc() =
    if w.hasKeyboard() and w.host.surface != nil:
      discard send(w.win, "makeFirstResponder:",
        argu(w.host.surface.view))
    discard send(w.web, "removeObserver:forKeyPath:",
      argu(w.delegate), argu(nsString("title")))
    discard send(w.ucc, "removeScriptMessageHandlerForName:",
      argu(nsString("mynim")))
    discard send(w.ucc, "removeAllUserScripts")
    discard send(w.web, "stopLoading")
    discard send(w.web, "setNavigationDelegate:", argu(nil))
    discard send(w.web, "setUIDelegate:", argu(nil))
    discard send(w.clip, "removeFromSuperview")
    b.byDelegate.del(w.delegate)
    b.byWebView.del(w.web)
    release(w.lastMouseDown)
    w.lastMouseDown = nil
    release(w.ucc)
    release(w.web)
    release(w.clip)
    # WebKit may still hold the delegate as the page goes.
    discard autorelease(w.delegate))
  let h = w.host
  h.webViews.keepItIf(it != w)
  if h.surface != nil:
    h.surface.placed.keepItIf(
      it.webView != WebView(w.asWebView))

## closeWebViews closes the web views of a window that closes.
proc closeWebViews*(w: macWindow) =
  while w.webViews.len > 0:
    w.webViews[^1].closeWebView()

## webViewMethods are the overrides of MyNimWebView for web views in a
## window of native UI: a press tells the content, which closes its
## popovers, and the mouse moving where the content painted over the
## page is the content's alone, which sets the cursor there; the page
## hears that it left.
proc webViewMethods*(): seq[MethodDef] =
  template pressOf(button: int): pointer =
    cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
      let w = theBackend.byWebView.getOrDefault(self)
      if w != nil and w.host != nil:
        w.pressed(ev, button)
      discard sendSuper(self, "MyNimWebView", cmd, argu(ev)))
  proc webMoved(self: id, cmd: SEL, ev: id) {.cdecl.} =
    let w = theBackend.byWebView.getOrDefault(self)
    if w != nil and w.host != nil:
      if w.covered(ev):
        if w.pointerIn:
          w.pointerIn = false
          w.leave(ev)
        return
      w.pointerIn = true
    discard sendSuper(self, "MyNimWebView", cmd, argu(ev))
  proc webExited(self: id, cmd: SEL, ev: id) {.cdecl.} =
    let w = theBackend.byWebView.getOrDefault(self)
    if w != nil:
      w.pointerIn = false
    discard sendSuper(self, "MyNimWebView", cmd, argu(ev))
  @[
    methodDef("rightMouseDown:", pressOf(1), "v@:@"),
    methodDef("otherMouseDown:", pressOf(2), "v@:@"),
    methodDef("mouseMoved:", cast[pointer](webMoved), "v@:@"),
    methodDef("mouseEntered:", cast[pointer](webMoved), "v@:@"),
    methodDef("mouseExited:", cast[pointer](webExited), "v@:@"),
    methodDef("cursorUpdate:", cast[pointer](webMoved), "v@:@"),
    # The content resizes a web view as its window resizes, frame by
    # frame: told of the window's live resize, WebKit would show the
    # page's scrollers throughout it, at the page's last width.
    methodDef("viewWillStartLiveResize",
      cast[pointer](proc(self: id, cmd: SEL) {.cdecl.} =
        let w = theBackend.byWebView.getOrDefault(self)
        if w == nil or w.host == nil:
          discard sendSuper(self, "MyNimWebView", cmd)), "v@:"),
    methodDef("viewDidEndLiveResize",
      cast[pointer](proc(self: id, cmd: SEL) {.cdecl.} =
        let w = theBackend.byWebView.getOrDefault(self)
        if w == nil or w.host == nil:
          discard sendSuper(self, "MyNimWebView", cmd)), "v@:"),
    methodDef("accessibilityParent",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
        let w = theBackend.byWebView.getOrDefault(self)
        if w != nil and w.accessParent != nil:
          return w.accessParent
        sendSuper(self, "MyNimWebView", cmd)), "@@:"),
  ]

proc registerClipViewClass*() =
  discard classDef("MyNimClipView", "NSView", @[], @[
    methodDef("isFlipped",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    # Assistive technology finds the page in the element of the
    # content showing it, not beside the content.
    methodDef("accessibilityChildren",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} = nsArray()),
      "@@:"),
  ])
