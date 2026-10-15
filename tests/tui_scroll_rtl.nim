import std/[assertions, os]

putEnv("MYNIM_DIRECTION", "rtl")
include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui RTL scroll test"))
app.initialized = true
app.handleReady()

let scrollState = ui.newScrollState()
var revealRed = false
var rtlTheme = ui.lightTheme()
rtlTheme.scrollbar = ui.rgb(255, 0, 255)
let rtlContent = ui.newContent(proc(ctx: ui.Context) =
  ctx.setTheme(rtlTheme)
  let viewport = ctx.scrollBoth(scrollState).size(100, 100)
    .background(ui.rgb(0, 0, 255)).onClick(proc() = discard)
  discard viewport.children(proc() =
    let canvas = ctx.box().size(300, 300).shrink(0)
      .background(ui.rgb(0, 0, 255))
    discard canvas.children(proc() =
      let red = ctx.box().size(100, 100).absolute().left(0).top(0)
        .background(ui.rgb(255, 0, 0))
      if revealRed:
        discard red.scrollIntoView()
    )
  )
)
let rtlWindow = newWindow(WindowOptions(width: 100, height: 100,
  hidden: true, content: rtlContent))
let rtlSurface = fake.windows[^1].surface
doAssert rtlSurface.frame()
doAssert scrollState.maxOffset() == (x: 200'f32, y: 200'f32)

# At the RTL start, the viewport shows the content's right side.
doAssert rtlSurface.pixel(5, 5) == [255'u8, 0, 0, 255]

# The vertical thumb is on the left and uses the theme color.
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 3, y: 20, button: 0))
doAssert rtlSurface.frame()
doAssert rtlSurface.pixel(3, 20) == [255'u8, 0, 255, 255]
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 3, y: 20, button: 0))
discard rtlSurface.frame()

# The horizontal thumb starts at the right; dragging it left reaches the end.
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 80, y: 94, button: 0))
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 20, y: 94))
doAssert scrollState.offset().x == 200
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 20, y: 94, button: 0))
doAssert rtlSurface.frame()
doAssert rtlSurface.pixel(5, 5) == [0'u8, 0, 255, 255]

# Positive horizontal wheel movement goes back toward the RTL start.
scrollState.scrollTo(0, 0)
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert rtlSurface.frame()
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 50, y: 50, dx: 10))
doAssert scrollState.offset().x == 0
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 50, y: 50, dx: -10))
doAssert scrollState.offset().x == 10

# Paging from the left of the horizontal thumb advances toward the end.
scrollState.scrollTo(0, 0)
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert rtlSurface.frame()
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 94, button: 0))
doAssert scrollState.offset().x == 90
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 20, y: 94, button: 0))

# Horizontal arrow keys move in physical directions under RTL.
scrollState.scrollTo(100, 0)
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert rtlSurface.frame()
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 50, y: 50, button: 0))
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 50, y: 50, button: 0))
discard rtlSurface.frame()
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert scrollState.offset().x == 60
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft))
doAssert scrollState.offset().x == 100

# Revealing a child at the physical left moves the logical offset to the end.
scrollState.scrollTo(0, 0)
revealRed = true
discard rtlSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert rtlSurface.frame()
doAssert scrollState.offset().x == scrollState.maxOffset().x
doAssert rtlSurface.pixel(5, 5) == [0'u8, 0, 255, 255]
