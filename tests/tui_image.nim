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

let measureContext = ui.newContext()
var measuredImage: ui.Element
measureContext.build(proc(ctx: ui.Context) =
  measuredImage = ctx.imageRegion(bitmap,
    ui.Rect(x: 0, y: 1, w: 2, h: 1)).alignSelf(ui.Align.Start)
)
let measuredLayout = measureContext.layout(64, 64)
let measuredBounds = measuredLayout.bounds(measuredImage)
doAssert measuredBounds.w == 2 and measuredBounds.h == 1

var clippedImage: ui.Element
measureContext.build(proc(ctx: ui.Context) =
  clippedImage = ctx.imageRegion(bitmap,
    ui.Rect(x: 1, y: 1, w: 8, h: 8)).alignSelf(ui.Align.Start)
)
let clippedLayout = measureContext.layout(64, 64)
let clippedBounds = clippedLayout.bounds(clippedImage)
doAssert clippedBounds.w == 1 and clippedBounds.h == 1
measureContext.close()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui image test"))
app.initialized = true
app.handleReady()

var fit = ui.Fit.FillBox
var imageWidth, imageHeight = 40'f32
var grayscale = false
var tint = ui.transparent
var sourceRegion = ui.Rect()
var flipX, flipY = false
let content = ui.newContent(proc(ctx: ui.Context) =
  let image = ctx.imageRegion(bitmap, sourceRegion, flipX, flipY)
    .size(imageWidth, imageHeight).fit(fit).tint(tint)
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

grayscale = false
tint = ui.rgb(255, 0, 0)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(35, 35) == [0'u8, 0, 255, 255]
doAssert native.pixel(35, 5) == [0'u8, 0, 0, 255]

tint = ui.rgba(255, 0, 0, 0.5)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(35, 35) == [0'u8, 0, 128, 128]

tint = ui.transparent
sourceRegion = ui.Rect(x: 0, y: 1, w: 2, h: 1)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [255'u8, 0, 0, 255]
doAssert native.pixel(35, 5) == [255'u8, 255, 255, 255]

sourceRegion = ui.Rect(x: 1, y: 1, w: 8, h: 8)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [255'u8, 255, 255, 255]
doAssert native.pixel(35, 35) == [255'u8, 255, 255, 255]

sourceRegion = ui.Rect()
flipX = true
flipY = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [255'u8, 255, 255, 255]
doAssert native.pixel(35, 5) == [255'u8, 0, 0, 255]
doAssert native.pixel(5, 35) == [0'u8, 255, 0, 255]
doAssert native.pixel(35, 35) == [0'u8, 0, 255, 255]

flipX = false
flipY = false
let updatedPixels = sourceImage.newRgba(sourceImage.rect(0, 0, 2, 2))
for y in 0..<2:
  for x in 0..<2:
    updatedPixels.set(x, y, sourceImage.Rgba(r: 255, g: 255, b: 0, a: 255))
bitmap.update(updatedPixels)
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 255, 255, 255]
doAssert native.pixel(35, 35) == [0'u8, 255, 255, 255]

let resizedPixels = sourceImage.newRgba(sourceImage.rect(0, 0, 1, 1))
resizedPixels.set(0, 0, sourceImage.Rgba(r: 0, g: 0, b: 255, a: 255))
bitmap.update(resizedPixels)
let updatedDimensions = bitmap.size()
doAssert updatedDimensions.width == 1 and updatedDimensions.height == 1
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.pixel(20, 20) == [255'u8, 0, 0, 255]

win.destroy()
loop.shutdown()
