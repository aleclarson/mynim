import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let wrapping = ui.newContext()
var wrappedLabel: ui.Element
wrapping.build(proc(ctx: ui.Context) =
  wrappedLabel = ctx.text("Text rendering wraps across lines")
    .textSize(20).width(70)
)
let wrappedLayout = wrapping.layout(70, 120)
doAssert wrappedLayout.bounds(wrappedLabel).h > 24
wrapping.close()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text test"))
app.initialized = true
app.handleReady()

var clicks = 0

let content = ui.newContent(proc(ctx: ui.Context) =
  let panel = ctx.box().fill().background(ui.rgb(255, 255, 255))
  discard panel.children(proc() =
    discard ctx.text("Mygo").textSize(32).textColor(ui.rgb(0, 0, 0))
    discard ctx.box().size(80, 40).background(ui.rgb(180, 180, 180))
      .onClick(proc() = inc clicks)
  )
)
let win = newWindow(WindowOptions(width: 320, height: 120, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 60))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 10, y: 60))
doAssert clicks == 1
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 60))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 10, y: 60, button: 1))
doAssert clicks == 1
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 60))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 200, y: 110))
doAssert clicks == 1
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 60, button: 1))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 10, y: 60, button: 1))
doAssert clicks == 1
var darkOpaquePixels = 0
for y in 0..<80:
  for x in 0..<320:
    let pixel = native.pixel(x, y)
    if pixel[3] > 0 and pixel[0] < 200 and pixel[1] < 200 and pixel[2] < 200:
      inc darkOpaquePixels
doAssert darkOpaquePixels > 0

win.destroy()
loop.shutdown()
