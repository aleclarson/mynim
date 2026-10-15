import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui table reorder test"))
app.initialized = true
app.handleReady()

let columns = [
  ui.TableColumn(title: "Name", width: 80, fixed: true),
  ui.TableColumn(title: "Kind", width: 100, sortable: true),
  ui.TableColumn(title: "Size", width: 80)
]
let tableState = ui.newListState(1)
let tableContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.table(tableState, columns, 1, proc(row, column: int) =
    discard ctx.text("file")
  ).size(320, 90)
)
let tableWin = newWindow(WindowOptions(width: 320, height: 90, hidden: true,
  content: tableContent))
let tableSurface = fake.windows[^1].surface
doAssert tableSurface.frame()
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

proc headerBounds(label: string): platform.RectF =
  let (tree, _) = tableSurface.accessibility()
  for node in tree.nodes:
    if node.role == platform.roleColumnHeader and node.label == label:
      return node.bounds
  raise newException(ValueError, "missing table header " & label)

proc pointer(kind: platform.SurfaceEventKind; x, y: float64) =
  discard tableSurface.send(platform.SurfaceEvent(kind: kind, x: x, y: y))

let kindHeader = headerBounds("Kind")
let startX = kindHeader.x + kindHeader.w / 2
let startY = kindHeader.y + kindHeader.h / 2
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: startX, y: startY))
doAssert tableSurface.frame()
for offset in [5.0, 20.0, 50.0, 60.0]:
  pointer(platform.pointerMove, startX + offset, startY)
  doAssert tableSurface.frame()
pointer(platform.pointerUp, startX + 60, startY)
doAssert tableSurface.frame()
doAssert tableState.columns.order == @["Size", "Kind"]
doAssert tableState.sort.column.len == 0,
  "dragging a sortable header must not sort the table"
let sizeHeader = headerBounds("Size")
let movedKindHeader = headerBounds("Kind")
doAssert sizeHeader.x < movedKindHeader.x

let kindAfterReorder = headerBounds("Kind")
let secondStartX = kindAfterReorder.x + kindAfterReorder.w / 2
let secondStartY = kindAfterReorder.y + kindAfterReorder.h / 2
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: secondStartX, y: secondStartY))
doAssert tableSurface.frame()
for offset in [-5.0, -20.0, -50.0, -60.0, -100.0, -200.0]:
  pointer(platform.pointerMove, secondStartX + offset, secondStartY)
  doAssert tableSurface.frame()
pointer(platform.pointerUp, secondStartX - 200, secondStartY)
doAssert tableSurface.frame()
doAssert tableState.columns.order == @["Kind", "Size"],
  "a movable column may reorder beside a fixed one, but not cross it"
doAssert tableState.sort.column.len == 0

let clickKind = headerBounds("Kind")
let clickX = clickKind.x + clickKind.w / 2
let clickY = clickKind.y + clickKind.h / 2
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: clickX, y: clickY))
pointer(platform.pointerUp, clickX, clickY)
doAssert tableSurface.frame()
doAssert tableState.sort.column == "Kind",
  "a click below the drag threshold should still sort the header"

tableWin.destroy()
loop.shutdown()
