import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/image as sourceImage
import mynim/ui as ui

let pixels = sourceImage.newRgba(sourceImage.rect(0, 0, 2, 2))
pixels.set(0, 0, sourceImage.Rgba(r: 255, g: 0, b: 0, a: 255))
pixels.set(1, 0, sourceImage.Rgba(r: 0, g: 255, b: 0, a: 255))
pixels.set(0, 1, sourceImage.Rgba(r: 0, g: 0, b: 255, a: 255))
pixels.set(1, 1, sourceImage.Rgba(r: 255, g: 255, b: 255, a: 255))
let bitmap = ui.newBitmap(pixels)
let dimensions = bitmap.size()
doAssert dimensions.width == 2 and dimensions.height == 2

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui image test"))
app.initialized = true
app.handleReady()

var fit = ui.Fit.FillBox
var imageWidth, imageHeight = 40'f32
var grayscale = false
let content = ui.newContent(proc(ctx: ui.Context) =
  let image = ctx.image(bitmap).size(imageWidth, imageHeight).fit(fit)
  if grayscale:
    discard image.grayscale()
)
let win = newWindow(WindowOptions(width: 64, height: 64, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 0, 255, 255]
doAssert native.pixel(35, 5) == [0'u8, 255, 0, 255]
doAssert native.pixel(5, 35) == [255'u8, 0, 0, 255]
doAssert native.pixel(35, 35) == [255'u8, 255, 255, 255]

fit = ui.Fit.Contain
imageHeight = 20
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 10) == [0'u8, 0, 0, 0]
doAssert native.pixel(15, 5)[3] == 255

fit = ui.Fit.Cover
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(1, 1)[3] == 255
doAssert native.pixel(39, 19)[3] == 255

fit = ui.Fit.ScaleDown
imageWidth = 40
imageHeight = 40
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 0, 0, 0]
doAssert native.pixel(19, 19)[3] == 255

fit = ui.Fit.NaturalSize
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 0, 0, 0]
doAssert native.pixel(19, 19)[3] == 255

fit = ui.Fit.FillBox
grayscale = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [54'u8, 54, 54, 255]
doAssert native.pixel(35, 5) == [182'u8, 182, 182, 255]

win.destroy()
loop.shutdown()
