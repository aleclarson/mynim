import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "row double-click test"))
app.initialized = true
app.handleReady()

let rows = ui.newListState(24, selectable = true)
let columns = [
  ui.TableColumn(title: "A", width: 100),
  ui.TableColumn(title: "B", width: 100)]
var doubleClicked: seq[(int, int)]
let viewContent = ui.newContent(proc(ctx: ui.Context) =
  doubleClicked.setLen(0)
  discard ctx.table(rows, columns, 4, proc(row, column: int) =
    let cell = ctx.box().fillWidth()
    discard cell.children(proc() =
      discard ctx.text("r" & $row & "c" & $column)
    )
    if cell.rowDoubleClicked():
      doubleClicked.add((row, column))
  ).size(200, 140)
)
let win = newWindow(WindowOptions(width: 200, height: 140, hidden: true,
  content: viewContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
doAssert native.frame()
var point: tuple[x, y: float64]
var found = false
for node in native.accessibility().tree.nodes:
  if node.label == "r1c1":
    point = (node.bounds.x + node.bounds.w / 2,
             node.bounds.y + node.bounds.h / 2)
    found = true
    break
doAssert found, "table cell should appear in the accessibility tree"
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: point.x, y: point.y, clicks: 1))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: point.x, y: point.y, clicks: 1))
doAssert native.frame()
doAssert doubleClicked.len == 0, "single click should not report a row double click"
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: point.x, y: point.y, clicks: 2))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: point.x, y: point.y, clicks: 2))
doAssert native.frame()
doAssert doubleClicked == @[(1, 1)]
doAssert rows.selected() == 1, "double click should retain row selection"

win.destroy()
loop.shutdown()
