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
      .label("Green").onClick(proc() = inc clicks)
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

doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (scrollTree, _) = native.accessibility()
var greenID = 0'u64
var greenActions: platform.AccessActions
for node in scrollTree.nodes:
  if node.label == "Green":
    greenID = node.id
    greenActions = node.actions
doAssert greenID != 0
doAssert (greenActions and platform.actionScrollIntoView) !=
  platform.AccessActions(0)
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: greenID, action: platform.accessScrollIntoView))
doAssert scrollState.offset().y == 20
doAssert native.frame()
doAssert native.pixel(5, 5) == [0'u8, 255, 0, 255]

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert scrollState.offset().y == 0
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyPageDown))
doAssert scrollState.offset().y == 10
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keySpace, mods: platform.modShift))
doAssert scrollState.offset().y == 0
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert scrollState.offset().y == 20
doAssert native.frame()

let focusState = ui.newScrollState()
let focusContent = ui.newContent(proc(ctx: ui.Context) =
  let viewport = ctx.scroll(focusState).size(30, 20)
  discard viewport.children(proc() =
    for i in 0..<3:
      discard ctx.box().size(30, 20).shrink(0).label("Button " & $i)
        .onClick(proc() = discard)
  )
)
let focusWindow = newWindow(WindowOptions(width: 30, height: 20, hidden: true,
  content: focusContent))
let focusSurface = fake.windows[^1].surface
doAssert focusSurface.frame()
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusSurface.frame()
doAssert focusState.offset().y == 0
doAssert focusSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert focusState.offset().y == 20
doAssert focusSurface.frame()
doAssert focusState.offset().y == 20

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
doAssert nestedSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert innerState.offset().x == 30
doAssert nestedSurface.frame()
doAssert nestedSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert innerState.offset().x == 0
doAssert nestedSurface.frame()
doAssert nestedSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert outerState.offset().y == 30
doAssert nestedSurface.frame()

let barsState = ui.newScrollState()
let barsContent = ui.newContent(proc(ctx: ui.Context) =
  let viewport = ctx.scrollBoth(barsState).size(100, 100)
  discard viewport.children(proc() =
    discard ctx.box().size(300, 300).shrink(0)
  )
)
let barsWindow = newWindow(WindowOptions(width: 100, height: 100, hidden: true,
  content: barsContent))
let barsSurface = fake.windows[^1].surface
doAssert barsSurface.frame()
doAssert barsState.maxOffset() == (x: 200'f32, y: 200'f32)

discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 93, y: 10))
doAssert barsSurface.frame()
doAssert barsSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 93, y: 10, button: 0))
discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 93, y: 68))
doAssert barsState.offset().y == 200
doAssert barsSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 93, y: 68, button: 0))
doAssert barsSurface.frame()

barsState.scrollTo(0, 0)
discard barsSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert barsSurface.frame()
discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 10, y: 94))
doAssert barsSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 10, y: 94, button: 0))
discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 68, y: 94))
doAssert barsState.offset().x == 200
doAssert barsSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 68, y: 94, button: 0))
doAssert barsSurface.frame()

barsState.scrollTo(0, 0)
discard barsSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert barsSurface.frame()
discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 93, y: 45))
doAssert barsSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 93, y: 45, button: 0))
doAssert barsState.offset().y == 90
discard barsSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 93, y: 45, button: 0))
doAssert barsSurface.frame()

win.destroy()
focusWindow.destroy()
nestedWindow.destroy()
barsWindow.destroy()
loop.shutdown()
