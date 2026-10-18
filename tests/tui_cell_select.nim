import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui cell selection test"))
app.initialized = true
app.handleReady()

let columns = [
  ui.TableColumn(title: "#", id: "row", width: 40, fixed: true,
    rowHeader: true, sortable: true),
  ui.TableColumn(title: "A", id: "a", width: 100, fixed: true),
  ui.TableColumn(title: "B", id: "b", width: 100, fixed: true)
]
let cellState = ui.newListState(32, cellSelect = true)
let cellContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.table(cellState, columns, 5, proc(row, column: int) =
    discard ctx.text("r" & $row & "c" & $column)
  ).size(260, 220)
)
let win = newWindow(WindowOptions(width: 260, height: 220, hidden: true,
  content: cellContent))
let native = fake.windows[^1].surface

doAssert not cellState.cellSelected(0, 1),
  "cell queries are false before the first table frame"
doAssert native.frame()
doAssert not cellState.cellSelected(0, 1)
doAssert cellState.selectedColumns() == @["a"]

proc clickAt(x, y: float64; mods: platform.Modifiers = 0) =
  doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y, mods: mods))
  doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
    x: x, y: y, mods: mods))
  doAssert native.frame()

clickAt(90, 75)
doAssert cellState.selectedRows() == @[1]
doAssert cellState.selectedColumns() == @["a"]
doAssert cellState.cellSelected(1, 1)
doAssert not cellState.cellSelected(1, 2)
doAssert not cellState.cellSelected(1, 0), "partial blocks omit row headers"

clickAt(190, 147, platform.modShift)
doAssert cellState.selectedRows() == @[1, 2, 3]
doAssert cellState.selectedColumns() == @["a", "b"]
doAssert cellState.cellSelected(1, 1) and cellState.cellSelected(3, 2)
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (selectedTree, _) = native.accessibility()
var selectedAccessibleCell = false
for node in selectedTree.nodes:
  if node.role == platform.roleCell and
      (node.states and platform.accessSelected) != platform.AccessStates(0):
    selectedAccessibleCell = true
doAssert selectedAccessibleCell

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert cellState.selectedColumns() == @["b"]
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyLeft, mods: platform.modShift))
doAssert native.frame()
doAssert cellState.selectedColumns() == @["a", "b"]

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
doAssert native.frame()
doAssert cellState.selectedRows() == @[4]
doAssert cellState.selectedColumns() == @["a"],
  "moving rows without Shift collapses the column range"

clickAt(20, 99, platform.modShift)
let rowHeaderRange = cellState.selectedRows()
doAssert rowHeaderRange.len == 3 and 2 in rowHeaderRange and
  3 in rowHeaderRange and 4 in rowHeaderRange
doAssert cellState.cells.all
doAssert cellState.cellSelected(2, 0), "whole-row choice includes row headers"
doAssert cellState.selectedColumns() == @["a", "b"]

clickAt(20, 10)
doAssert cellState.selectedRows().len == 5
doAssert cellState.isSelected(0) and cellState.isSelected(4)
doAssert cellState.cells.all
doAssert cellState.cellSelected(4, 0)
doAssert cellState.sort.column.len == 0, "row-header columns do not sort"

cellState.selectColumns("a", "b")
doAssert cellState.selectedRows().len == 5
doAssert cellState.selectedColumns() == @["a", "b"]
doAssert cellState.cellSelected(4, 1) and cellState.cellSelected(4, 2)

win.destroy()
loop.shutdown()
