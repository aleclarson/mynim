import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui table test"))
app.initialized = true
app.handleReady()

let columns = [
  ui.TableColumn(title: "Name", id: "name", width: 80, sortable: true),
  ui.TableColumn(title: "Size", id: "size", width: 90, align: ui.Align.End,
    sortable: true),
  ui.TableColumn(title: "Kind", id: "kind", width: 70)
]
var savedColumns = ui.TableLayout(order: @["kind", "size"])
let fixedColumns = [
  ui.TableColumn(title: "Name", id: "name", fixed: true, width: 80),
  ui.TableColumn(title: "Size", id: "size", width: 90,
    minWidth: 60, maxWidth: 100),
  ui.TableColumn(title: "Kind", id: "kind", width: 70)
]
doAssert savedColumns.arrange(fixedColumns) == @[0, 2, 1]
savedColumns.setWidth(fixedColumns[1], 130)
doAssert savedColumns.columnWidth(fixedColumns[1]).width == 100

let tableState = ui.newListState(24, selectable = true,
  rowLabel = proc(row: int): string = "Row " & $row,
  rowHeader = proc(row: int): bool = row mod 20 == 0)
tableState.enableMultiSort()
var builtRows: seq[int]
let tableContent = ui.newContent(proc(ctx: ui.Context) =
  builtRows.setLen(0)
  discard ctx.table(tableState, columns, 200, proc(row, column: int) =
    if column == 0:
      builtRows.add(row)
    discard ctx.text(if column == 0: "Row " & $row
      elif column == 1: $(row * 10) else: "Kind")
  ).size(150, 100)
)
let tableWin = newWindow(WindowOptions(width: 150, height: 100, hidden: true,
  content: tableContent))
let tableSurface = fake.windows[^1].surface

doAssert tableSurface.frame()
doAssert builtRows.len < 200, "table should build only visible rows"
doAssert tableState.maxOffset().x > 0, "wide columns should scroll horizontally"

doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (tree, _) = tableSurface.accessibility()
var tableRole, headerRole, columnHeaderRole, rowRole, cellRole = false
var nameHeaderId = 0'u64
var originalHeaderX: float64
for node in tree.nodes:
  if node.role == platform.roleTable:
    tableRole = true
  elif node.role == platform.roleColumnHeader and node.label == "Name":
    columnHeaderRole = true
    nameHeaderId = node.id
    originalHeaderX = node.bounds.x
    doAssert (node.actions and platform.actionPress) != platform.AccessActions(0)
  elif node.role == platform.roleRow:
    headerRole = true
    if node.label == "Row 1":
      rowRole = true
  elif node.role == platform.roleCell:
    cellRole = true
doAssert tableRole and headerRole and columnHeaderRole and rowRole and cellRole
doAssert nameHeaderId > 0

proc clickAt(x, y: float64; mods: platform.Modifiers = 0) =
  doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y, mods: mods))
  doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
    x: x, y: y, mods: mods))
  doAssert tableSurface.frame()

clickAt(10, 10)
doAssert tableState.sortBy.len == 1 and tableState.sortBy[0].column == "name"
doAssert not tableState.sortBy[0].descending
let (ascendingTree, _) = tableSurface.accessibility()
var ascendingHeader = false
for node in ascendingTree.nodes:
  if node.id == nameHeaderId:
    ascendingHeader = (node.states and platform.accessSortAscending) !=
      platform.AccessStates(0)
doAssert ascendingHeader, "sorted header should expose ascending state"

clickAt(10, 10)
doAssert tableState.sortBy.len == 1 and tableState.sortBy[0].descending
clickAt(115, 10, platform.modShift)
doAssert tableState.sortBy.len == 2 and tableState.sortBy[1].column == "size"
doAssert not tableState.sortBy[1].descending
clickAt(115, 10, platform.modShift)
doAssert tableState.sortBy.len == 2 and tableState.sortBy[1].descending
clickAt(115, 10, platform.modShift)
doAssert tableState.sortBy.len == 1 and tableState.sortBy[0].column == "name"

clickAt(10, 75)
doAssert tableState.selected() == 1, "table rows should retain list selection"
let (selectedTree, _) = tableSurface.accessibility()
var rowSelected = false
for node in selectedTree.nodes:
  if node.role == platform.roleRow and node.label == "Row 1":
    rowSelected = (node.states and platform.accessSelected) !=
      platform.AccessStates(0)
doAssert rowSelected, "selected table row should expose selected state"
discard tableSurface.send(platform.SurfaceEvent(kind: platform.pointerScroll,
  x: 20, y: 80, dx: 40, precise: true))
doAssert tableState.offset().x > 0, "body should accept horizontal scrolling"
doAssert tableSurface.frame()
doAssert tableState.offset().x > 0,
  "table layout should preserve the horizontal offset"
let (scrolledTree, _) = tableSurface.accessibility()
var scrolledHeaderX = originalHeaderX
for node in scrolledTree.nodes:
  if node.id == nameHeaderId:
    scrolledHeaderX = node.bounds.x
doAssert scrolledHeaderX < originalHeaderX,
  "header should follow the body's horizontal offset"

tableWin.destroy()
loop.shutdown()
