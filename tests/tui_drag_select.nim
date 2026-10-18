import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui drag selection test"))
app.initialized = true
app.handleReady()

let listState = ui.newListState(24, dragSelect = true)
let listContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.list(listState, 20, proc(row: int) =
    discard ctx.box().size(100, 24).shrink(0)
  ).size(100, 80)
)
let listWindow = newWindow(WindowOptions(width: 100, height: 80, hidden: true,
  content: listContent))
let listSurface = fake.windows[^1].surface

doAssert listSurface.frame()
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 12))
doAssert not listState.dragSelecting()
doAssert listState.selectedRows() == @[0],
  "pressing an unselected row should choose it immediately"
discard listSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 12, y: 70))
doAssert listState.dragSelecting()
doAssert listState.selectedRows() == @[0, 1, 2]
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 70))
doAssert not listState.dragSelecting()
doAssert listState.selectedRows() == @[0, 1, 2]
doAssert listSurface.frame()

when defined(macosx):
  const commandModifier = platform.modSuper
else:
  const commandModifier = platform.modCtrl
listState.clearSelection()
listState.select(0)
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 70, mods: commandModifier))
let addedRow = listState.selected()
doAssert listState.selectedRows().len == 2 and 0 in listState.selectedRows(),
  "a modifier press should add an unselected row immediately: " &
  $listState.selectedRows()
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 70, mods: commandModifier))
doAssert listState.selectedRows().len == 2 and
  addedRow in listState.selectedRows(),
  "release should not toggle a row a second time"
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 70))
doAssert listState.selectedRows().len == 2 and
  addedRow in listState.selectedRows(),
  "pressing a chosen row should defer collapsing until release"
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 70))
doAssert listState.selectedRows() == @[addedRow]

listState.clearSelection()
listState.scrollTo(0)
discard listSurface.frame()
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 12, y: 12))
discard listSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 12, y: 78))
let beforeAutoScroll = listState.offset().y
for _ in 0..<3:
  doAssert listSurface.frame()
doAssert listState.offset().y > beforeAutoScroll,
  "holding a drag near the viewport edge should autoscroll"
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 12, y: 78))
doAssert listSurface.frame()

let columns = [
  ui.TableColumn(title: "#", id: "row", width: 40, fixed: true,
    rowHeader: true),
  ui.TableColumn(title: "A", id: "a", width: 100, fixed: true),
  ui.TableColumn(title: "B", id: "b", width: 100, fixed: true)
]
let cellState = ui.newListState(32, cellSelect = true)
let tableContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.table(cellState, columns, 5, proc(row, column: int) =
    discard ctx.text("r" & $row & "c" & $column)
  ).size(260, 220)
)
let tableWindow = newWindow(WindowOptions(width: 260, height: 220,
  hidden: true, content: tableContent))
let tableSurface = fake.windows[^1].surface

doAssert tableSurface.frame()
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 90, y: 75))
discard tableSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 190, y: 147))
doAssert cellState.dragSelecting()
doAssert cellState.selectedRows() == @[1, 2, 3]
doAssert cellState.selectedColumns() == @[
  "a", "b"]
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 190, y: 147))
doAssert not cellState.dragSelecting()
doAssert tableSurface.frame()

listWindow.destroy()
tableWindow.destroy()
loop.shutdown()
