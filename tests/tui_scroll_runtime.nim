import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let ease = ui.cubicBezier(0.25, 0.1, 0.25, 1)
doAssert ease(0) == 0
doAssert ease(1) == 1
doAssert ease(0.5) > 0.5

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

let animatedState = ui.newScrollState()
let animatedContent = ui.newContent(proc(ctx: ui.Context) =
  let viewport = ctx.scroll(animatedState).size(20, 20)
  discard viewport.children(proc() =
    for i in 0..<3:
      discard ctx.box().size(20, 20).shrink(0)
  )
)
let animatedWindow = newWindow(WindowOptions(width: 20, height: 20,
  hidden: true, content: animatedContent))
let animatedSurface = fake.windows[^1].surface
doAssert animatedSurface.frame()
doAssert animatedState.maxOffset().y == 40

animatedState.scrollTo(0, 40, ui.Smooth)
discard animatedSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert animatedSurface.frame()
doAssert animatedState.scrolling
os.sleep(25)
doAssert animatedSurface.frame()
let springOffset = animatedState.offset().y
doAssert springOffset > 0 and springOffset < 40

discard animatedSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 3))
doAssert not animatedState.scrolling
doAssert animatedState.offset().y > springOffset
doAssert animatedSurface.frame()

animatedState.scrollTo(0, 40, ui.Animation(
  duration: initDuration(milliseconds = 80), ease: ui.linear))
discard animatedSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert animatedSurface.frame()
doAssert animatedState.scrolling
os.sleep(100)
doAssert animatedSurface.frame()
doAssert animatedState.offset().y == 40
doAssert not animatedState.scrolling

animatedState.scrollTo(0, 0, ui.Smooth)
discard animatedSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert animatedSurface.frame()
os.sleep(25)
doAssert animatedSurface.frame()
doAssert animatedState.scrolling
fake.setPreferences(platform.Preferences(reduceMotion: true))
doAssert animatedSurface.frame()
doAssert animatedState.offset().y == 0
doAssert not animatedState.scrolling
animatedState.scrollTo(0, 40, ui.Smooth)
discard animatedSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert animatedSurface.frame()
doAssert animatedState.offset().y == 40
doAssert not animatedState.scrolling
fake.setPreferences(platform.Preferences())

let followState = ui.newScrollState()
let followContent = ui.newContent(proc(ctx: ui.Context) =
  let root = ctx.column()
  discard root.children(proc() =
    let header = ctx.row().size(100, 20).clip()
    discard header.children(proc() =
      discard ctx.box().size(50, 20).shrink(0)
        .background(ui.rgb(255, 0, 0))
      discard ctx.box().size(50, 20).shrink(0)
        .background(ui.rgb(0, 255, 0))
      discard ctx.box().size(50, 20).shrink(0)
        .background(ui.rgb(255, 255, 0))
    )
    let list = ctx.row().size(100, 20).scrollX(followState)
    discard list.children(proc() =
      for _ in 0..<3:
        discard ctx.box().size(50, 20).shrink(0)
    )
    discard header.scrollWith(list)
  )
)
let followWindow = newWindow(WindowOptions(width: 120, height: 40,
  hidden: true, content: followContent))
let followSurface = fake.windows[^1].surface
doAssert followSurface.frame()
doAssert followState.maxOffset().x == 50
doAssert followSurface.pixel(10, 5) == [0'u8, 0, 255, 255]
doAssert followSurface.pixel(60, 5) == [0'u8, 255, 0, 255]
doAssert followSurface.pixel(110, 5) == [0'u8, 0, 0, 0]

discard followSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 25, dx: 25))
doAssert followSurface.frame()
doAssert followState.offset().x == 25
doAssert followSurface.pixel(10, 5) == [0'u8, 0, 255, 255]
doAssert followSurface.pixel(30, 5) == [0'u8, 255, 0, 255]
doAssert followSurface.pixel(80, 5) == [0'u8, 255, 255, 255]
doAssert followSurface.pixel(110, 5) == [0'u8, 0, 0, 0]

let axisClipContent = ui.newContent(proc(ctx: ui.Context) =
  let root = ctx.column()
  discard root.children(proc() =
    let top = ctx.row().size(60, 20).shrink(0)
    discard top.children(proc() =
      let xClip = ctx.box().size(20, 20).shrink(0).clipX()
      discard xClip.children(proc() =
        discard ctx.box().size(40, 40).shrink(0)
          .background(ui.rgb(255, 0, 0))
      )
    )
    let bottom = ctx.row().size(60, 20).shrink(0)
    discard bottom.children(proc() =
      discard ctx.box().size(20, 20).shrink(0)
      let yClip = ctx.box().size(20, 20).shrink(0).clipY()
      discard yClip.children(proc() =
        discard ctx.box().size(40, 40).shrink(0)
          .background(ui.rgb(0, 255, 0))
      )
    )
  )
)
let axisClipWindow = newWindow(WindowOptions(width: 60, height: 60,
  hidden: true, content: axisClipContent))
let axisClipSurface = fake.windows[^1].surface
doAssert axisClipSurface.frame()
doAssert axisClipSurface.pixel(25, 5) == [0'u8, 0, 0, 0]
doAssert axisClipSurface.pixel(5, 25) == [0'u8, 0, 255, 255]
doAssert axisClipSurface.pixel(45, 25) == [0'u8, 255, 0, 255]
doAssert axisClipSurface.pixel(45, 45) == [0'u8, 0, 0, 0]

win.destroy()
focusWindow.destroy()
nestedWindow.destroy()
barsWindow.destroy()
animatedWindow.destroy()
followWindow.destroy()
axisClipWindow.destroy()
loop.shutdown()
