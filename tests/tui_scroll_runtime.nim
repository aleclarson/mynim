import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui scroll test"))
app.initialized = true
app.handleReady()

let scrollState = ui.newScrollState()
var clicks = 0
let scrollContent = ui.newContent(proc(ctx: ui.Context) =
  let viewport = ctx.scroll(scrollState).size(20, 20).background(ui.rgb(0, 0, 255))
  discard viewport.children(proc() =
    discard ctx.box().size(20, 20).shrink(0).background(ui.rgb(255, 0, 0))
    discard ctx.box().size(20, 20).shrink(0).background(ui.rgb(0, 255, 0))
      .onClick(proc() = inc clicks)
  )
)
let win = newWindow(WindowOptions(width: 40, height: 40, hidden: true,
  content: scrollContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 0, 255, 255]
doAssert native.pixel(5, 25) == [0'u8, 0, 0, 0]
doAssert scrollState.maxOffset().y == 20

discard native.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 15))
doAssert native.frame()
doAssert scrollState.offset().y == 15
doAssert native.pixel(5, 10) == [0'u8, 255, 0, 255]
doAssert native.pixel(5, 25) == [0'u8, 0, 0, 0]

discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 22, button: 0))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 22, button: 0))
doAssert clicks == 0

discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 10, button: 0))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 10, button: 0))
doAssert clicks == 1

let outerState = ui.newScrollState()
let innerState = ui.newScrollState()
let nestedContent = ui.newContent(proc(ctx: ui.Context) =
  let outer = ctx.scroll(outerState).size(30, 30)
  discard outer.children(proc() =
    let inner = ctx.scrollBoth(innerState).size(30, 20).shrink(0)
    discard inner.children(proc() =
      discard ctx.box().size(60, 40).shrink(0)
    )
    discard ctx.box().size(30, 40).shrink(0)
  )
)
let nestedWindow = newWindow(WindowOptions(width: 30, height: 30, hidden: true,
  content: nestedContent))
let nestedSurface = fake.windows[^1].surface
doAssert nestedSurface.frame()
doAssert innerState.maxOffset() == (x: 30'f32, y: 20'f32)
doAssert outerState.maxOffset() == (x: 0'f32, y: 30'f32)

discard nestedSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 100))
doAssert nestedSurface.frame()
doAssert innerState.offset().y == 20
doAssert outerState.offset().y == 0

discard nestedSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 10, mods: platform.modShift))
doAssert nestedSurface.frame()
doAssert innerState.offset().x == 10
doAssert innerState.offset().y == 20

discard nestedSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 10))
doAssert nestedSurface.frame()
doAssert innerState.offset().y == 20
doAssert outerState.offset().y == 10

win.destroy()
nestedWindow.destroy()
loop.shutdown()
