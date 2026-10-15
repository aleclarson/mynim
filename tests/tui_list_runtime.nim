import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui list test"))
app.initialized = true
app.handleReady()

let listState = ui.newListState(20, selectable = true)
var builtRows: seq[int]
let listContent = ui.newContent(proc(ctx: ui.Context) =
  builtRows.setLen(0)
  discard ctx.list(listState, 100, proc(row: int) =
    builtRows.add(row)
    let color = if row mod 2 == 0: ui.rgb(255, 0, 0) else: ui.rgb(0, 255, 0)
    discard ctx.box().size(20, 20).shrink(0).background(color)
  ).size(20, 40)
)
let listWindow = newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: listContent))
let listSurface = fake.windows[^1].surface

doAssert listSurface.frame()
doAssert builtRows.len < 100
doAssert listState.maxOffset().y == 1960

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert listSurface.frame()
doAssert listState.selected() == 0,
  "click should select row 0, got " & $listState.selected()

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert listSurface.frame()
doAssert listState.selected() == 1

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert listSurface.frame()
doAssert listState.selected() == 0

discard listSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 100))
doAssert listState.offset().y == 100
doAssert listSurface.frame()
doAssert 5 in builtRows
doAssert listSurface.pixel(5, 5) == [0'u8, 255, 0, 255]

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert listSurface.frame()
doAssert listState.selected() == 5

doAssert listSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert listSurface.frame()
doAssert listState.selected() == 99

var followCount = 100
let followState = ui.newListState(20, followEnd = true)
let followContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(followState, followCount, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: followContent))
let followSurface = fake.windows[^1].surface

doAssert followSurface.frame()
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y

discard followSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: -100))
let scrolledAway = followState.offset().y
doAssert scrolledAway < followState.maxOffset().y
doAssert followSurface.frame()

followCount = 110
discard followSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert followSurface.frame()
doAssert followState.offset().y == scrolledAway
doAssert followState.offset().y < followState.maxOffset().y

discard followSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 5, y: 5, dy: 10_000))
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y

followCount = 120
discard followSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert followSurface.frame()
doAssert followState.offset().y == followState.maxOffset().y
