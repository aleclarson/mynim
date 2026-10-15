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
var showGradient = false
var showShadow = false
var showInsetShadow = false
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  inc builds
  if showGradient:
    discard ctx.box().fill().gradient(ui.rgb(0, 0, 0), ui.rgb(255, 255, 255), 90)
  elif showShadow:
    discard ctx.box().size(40, 40).background(ui.rgb(255, 255, 255))
      .shadow(8, 8, 0, 0, ui.rgb(0, 0, 0))
  elif showInsetShadow:
    discard ctx.box().size(40, 40).background(ui.rgb(255, 255, 255))
      .insetShadow(8, 0, 0, 0, ui.rgb(0, 0, 0))
  else:
    discard ctx.box().fill().background(color)
)
let win = newWindow(WindowOptions(width: 512, height: 512, hidden: true,
  content: uiContent))
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

showGradient = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert builds == 3
doAssert native.pixel(0, 256) == [0'u8, 0, 0, 255]
doAssert native.pixel(256, 256) == [128'u8, 128, 128, 255]
doAssert native.pixel(511, 256) == [255'u8, 255, 255, 255]

showGradient = false
showShadow = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert builds == 4
doAssert native.pixel(20, 20) == [255'u8, 255, 255, 255]
doAssert native.pixel(45, 20) == [0'u8, 0, 0, 255]

showShadow = false
showInsetShadow = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert builds == 5
doAssert native.pixel(2, 20) == [0'u8, 0, 0, 255]
doAssert native.pixel(20, 20) == [255'u8, 255, 255, 255]

let (png, captureError) = win.capturePage()
doAssert captureError == nil
doAssert png.len > 8

win.destroy()
loop.shutdown()
