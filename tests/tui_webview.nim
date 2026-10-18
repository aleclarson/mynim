import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/internal/scene as scene
import mynim/ui as ui

type TestWebView = ref object of ui.NativeWebView

block rounded_native_webview_hole:
  let c = ui.newContext()
  c.build(proc(ctx: ui.Context) =
    discard ctx.webView(TestWebView()).size(100, 80).padding(10)
      .border(1, ui.rgb(0'u8, 0'u8, 0'u8)).radius(12)
  )
  let frame = c.layout(100, 80).paintScene()
  var holes: seq[scene.Op]
  for op in frame.ops:
    if op.kind == scene.opHole:
      holes.add(op)
  doAssert holes.len == 1
  doAssert holes[0].rect == scene.Rect(x: 11, y: 11, w: 78, h: 58)
  doAssert holes[0].radii[0] == 1'f32 or holes[0].radii[0] == -1'f32
  c.close()

block native_placement_focus_and_accessibility:
  let fake = fakeBackend.newFakeBackend()
  theBackend = platform.Backend(fake)
  backendMade = true
  fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui webview test"))
  app.initialized = true
  app.handleReady()

  var view: ui.NativeWebView
  var showWebView = true
  let content = ui.newContent(proc(ctx: ui.Context) =
    let column = ctx.column().size(200, 140)
      .alignItems(ui.Align.Stretch)
    discard column.children(proc() =
      discard ctx.box().height(20).focusable()
      if showWebView:
        let web = ctx.webView(view).grow()
        discard web.children(proc() =
          discard ctx.box().size(20, 20).absolute().top(10).right(10)
        )
      discard ctx.box().height(20).focusable()
    )
  )
  let win = newWindow(WindowOptions(width: 200, height: 140, hidden: true,
    content: content))
  let native = fake.windows[^1].surface
  let (created, err) = win.newWebView(WebViewOptions())
  doAssert err == nil
  view = created
  let web = fakeBackend.allWebViews(native)[0]

  doAssert native.frame()
  doAssert web.shown
  doAssert web.placement.frame.x == 0 and web.placement.frame.y == 20
  doAssert web.placement.frame.w == 200 and web.placement.frame.h == 100
  doAssert web.placement.covers.len == 1
  doAssert native.webViewAt(100, 60) == web
  doAssert native.webViewAt(175, 35) == nil

  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyTab))
  doAssert native.frame()
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyTab))
  doAssert web.focused
  doAssert not web.tabbedBack

  doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
  var accessibleWebViewId: uint64
  for node in native.accessibility().tree.nodes:
    if node.webView == web:
      accessibleWebViewId = node.id
  doAssert accessibleWebViewId != 0

  web.tabOut(false)
  doAssert native.frame()
  doAssert not web.focused
  doAssert native.press(100, 60) == web
  doAssert web.focused
  doAssert native.frame()
  doAssert native.accessibility().tree.focus == accessibleWebViewId

  web.tabOut(false)
  doAssert native.frame()
  doAssert not web.focused
  doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyTab, mods: platform.modShift))
  doAssert web.focused and web.tabbedBack

  doAssert native.press(100, 60) == web
  doAssert web.focused
  showWebView = false
  doAssert native.frame()
  doAssert not web.shown
  win.destroy()
  loop.shutdown()
