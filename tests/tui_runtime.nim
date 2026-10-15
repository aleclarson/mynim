import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui runtime test"))
app.initialized = true
app.handleReady()

var builds = 0
var color = ui.rgb(12, 34, 56)
let content = ui.newContent(proc(ctx: ui.Context) =
  inc builds
  discard ctx.box().fill().background(color)
)
let win = newWindow(WindowOptions(width: 512, height: 512, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert builds == 1
doAssert native.frameCount() == 1
doAssert native.pixel(500, 500) == [56'u8, 34, 12, 255]

color = ui.rgb(90, 80, 70)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert builds == 2
doAssert native.frameCount() == 2
doAssert native.pixel(500, 500) == [70'u8, 80, 90, 255]

let (png, captureError) = win.capturePage()
doAssert captureError == nil
doAssert png.len > 8

win.destroy()
loop.shutdown()
