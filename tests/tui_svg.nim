import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let parsed = ui.parseSvg("""
<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">
  <rect width="2" height="1" fill="currentColor"/>
</svg>
""")
doAssert parsed.error.len == 0
let dimensions = parsed.svg.size()
doAssert dimensions.width == 2 and dimensions.height == 1
let invalid = ui.parseSvg("<svg")
doAssert invalid.svg == nil and invalid.error.len > 0
let twoTone = ui.parseSvg("""
<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">
  <rect width="1" height="1" fill="#ff0000"/>
  <rect x="1" width="1" height="1" fill="#0000ff"/>
</svg>
""")
doAssert twoTone.error.len == 0

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui svg test"))
app.initialized = true
app.handleReady()

var color = ui.rgb(20, 80, 160)
var fit = ui.Fit.Contain
var grayscale = false
var vector = parsed.svg
let content = ui.newContent(proc(ctx: ui.Context) =
  let image = ctx.svg(vector).size(40, 40).fit(fit).svgColor(color)
  if grayscale:
    discard image.grayscale()
)
let win = newWindow(WindowOptions(width: 64, height: 64, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.pixel(20, 5) == [0'u8, 0, 0, 0]
doAssert native.pixel(20, 20) == [160'u8, 80, 20, 255]

color = ui.rgb(220, 30, 40)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(20, 20) == [40'u8, 30, 220, 255]

fit = ui.Fit.FillBox
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(20, 5) == [40'u8, 30, 220, 255]

vector = twoTone.svg
fit = ui.Fit.Cover
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 20) == [0'u8, 0, 255, 255]
doAssert native.pixel(35, 20) == [255'u8, 0, 0, 255]

grayscale = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 20) == [54'u8, 54, 54, 255]
doAssert native.pixel(35, 20) == [18'u8, 18, 18, 255]
grayscale = false

fit = ui.Fit.NaturalSize
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(19, 20) == [0'u8, 0, 255, 255]
doAssert native.pixel(20, 20) == [255'u8, 0, 0, 255]

fit = ui.Fit.ScaleDown
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(19, 20) == [0'u8, 0, 255, 255]
doAssert native.pixel(20, 20) == [255'u8, 0, 0, 255]

win.destroy()
loop.shutdown()
