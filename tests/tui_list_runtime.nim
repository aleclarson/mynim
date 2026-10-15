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

let multiState = ui.newListState(20, multiSelectable = true)
when defined(macosx):
  const selectionCommand = platform.modSuper
else:
  const selectionCommand = platform.modCtrl
let multiContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(multiState, 100, proc(row: int) =
    discard ctx.box().size(20, 20).shrink(0)
  ).size(20, 40)
)
discard newWindow(WindowOptions(width: 20, height: 40, hidden: true,
  content: multiContent))
let multiSurface = fake.windows[^1].surface

doAssert multiSurface.frame()
doAssert multiSurface.frame()
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert multiSurface.frame()
doAssert multiState.selectedRows() == @[0]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 25, mods: selectionCommand))
doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 25))
doAssert multiSurface.frame()
doAssert multiState.selected() == 1
doAssert multiState.selectedRows() == @[0, 1]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown, mods: platform.modShift))
doAssert multiSurface.frame()
when defined(macosx):
  doAssert multiState.selectedRows() == @[0, 1, 2]
else:
  doAssert multiState.selectedRows() == @[1, 2]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown, mods: selectionCommand or platform.modShift))
doAssert multiSurface.frame()
when defined(macosx):
  doAssert multiState.selectedRows() == @[0, 1, 2, 3]
else:
  doAssert multiState.selectedRows() == @[1, 2, 3]
  doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keyUp, mods: platform.modCtrl))
  doAssert multiSurface.frame()
  doAssert multiState.selected() == 2
  doAssert multiState.selectedRows() == @[1, 2, 3]

  doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: platform.keySpace, mods: platform.modCtrl))
  doAssert multiSurface.frame()
  doAssert multiState.selectedRows() == @[1, 3]

doAssert multiSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: selectionCommand))
doAssert multiSurface.frame()
doAssert multiState.selectedRows().len == 100
doAssert multiState.isSelected(99)
