import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui context selection test"))
app.initialized = true
app.handleReady()

let listState = ui.newListState(24, multiSelectable = true,
  rowLabel = proc(row: int): string = "row" & $row,
  menuKeepsSelection = true)
var rowsAtMenu: seq[seq[int]]
let listContent = ui.newContent(proc(ctx: ui.Context) =
  let list = ctx.list(listState, 5, proc(row: int) =
    discard ctx.text("row" & $row)
  ).size(160, 160)
  discard list.contextMenu(proc(menu: ui.Menu) =
    rowsAtMenu.add(listState.selectedRows())
    discard menu.item("List action")
  )
)
let listWindow = newWindow(WindowOptions(width: 160, height: 160, hidden: true,
  content: listContent))
let listSurface = fake.windows[^1].surface

doAssert listSurface.frame()
doAssert listSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

proc listRowCenter(label: string): tuple[x, y: float64] =
  let (tree, _) = listSurface.accessibility()
  for node in tree.nodes:
    if node.role == platform.roleListItem and node.label == label:
      return (node.bounds.x + node.bounds.w / 2,
        node.bounds.y + node.bounds.h / 2)
  raise newException(ValueError, "missing list row " & label)

proc rightClickListRow(label: string) =
  let (x, y) = listRowCenter(label)
  doAssert listSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y, button: 1))
  fake.step()

listState.select(0)
listState.toggleSelection(2)
rightClickListRow("row1")
doAssert listState.selectedRows() == @[0, 2]
doAssert rowsAtMenu[^1] == @[0, 2],
  "the constructor option should preserve the current choice"

discard listState.setMenuKeepsSelection(false)
rightClickListRow("row1")
doAssert listState.selectedRows() == @[1]
doAssert rowsAtMenu[^1] == @[1],
  "the menu builder should observe the clicked row already selected"

listState.select(0)
listState.toggleSelection(2)
rightClickListRow("row0")
doAssert listState.selectedRows() == @[0, 2]
doAssert rowsAtMenu[^1] == @[0, 2],
  "right-clicking an already selected row should preserve the choice"
discard listState.setMenuKeepsSelection(true)
rightClickListRow("row1")
doAssert listState.selectedRows() == @[0, 2]
doAssert rowsAtMenu[^1] == @[0, 2],
  "MenuKeepsSelection should preserve a multi-row choice"

discard listState.setMenuKeepsSelection(false)
rightClickListRow("row1")
doAssert listState.selectedRows() == @[1]

let columns = [
  ui.TableColumn(title: "A", id: "a", width: 100, fixed: true),
  ui.TableColumn(title: "B", id: "b", width: 100, fixed: true)
]
let cellState = ui.newListState(32, cellSelect = true)
cellState.columns.order = @["b", "a"]
var rowsAtCellMenu: seq[seq[int]]
var columnsAtCellMenu: seq[seq[string]]
let tableContent = ui.newContent(proc(ctx: ui.Context) =
  let table = ctx.table(cellState, columns, 5, proc(row, column: int) =
    discard ctx.text("r" & $row & "c" & $column)
  ).size(220, 220)
  discard table.contextMenu(proc(menu: ui.Menu) =
    rowsAtCellMenu.add(cellState.selectedRows())
    columnsAtCellMenu.add(cellState.selectedColumns())
    discard menu.item("Cell action")
  )
)
let tableWindow = newWindow(WindowOptions(width: 220, height: 220,
  hidden: true, content: tableContent))
let tableSurface = fake.windows[^1].surface

doAssert tableSurface.frame()
doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

proc columnCenter(label: string): float64 =
  let (tree, _) = tableSurface.accessibility()
  for node in tree.nodes:
    if node.role == platform.roleColumnHeader and node.label == label:
      return node.bounds.x + node.bounds.w / 2
  raise newException(ValueError, "missing table column " & label)

let aX = columnCenter("A")
let bX = columnCenter("B")
proc clickTableCell(x, y: float64; button = 0;
                    mods: platform.Modifiers = 0) =
  doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y, button: button, mods: mods))
  if button == 0:
    doAssert tableSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
      x: x, y: y, mods: mods))
    doAssert tableSurface.frame()
  else:
    fake.step()

clickTableCell(bX, 75)
clickTableCell(bX, 147, mods = platform.modShift)
doAssert cellState.selectedRows() == @[1, 2, 3]
doAssert cellState.selectedColumns() == @["b"]
clickTableCell(bX, 111, button = 1)
doAssert cellState.selectedRows() == @[1, 2, 3],
  "right-clicking a selected cell should preserve its row range"
doAssert cellState.selectedColumns() == @["b"]
doAssert rowsAtCellMenu[^1] == @[1, 2, 3]
doAssert columnsAtCellMenu[^1] == @["b"]

discard cellState.setMenuKeepsSelection(true)
clickTableCell(aX, 111, button = 1)
doAssert cellState.selectedRows() == @[1, 2, 3]
doAssert cellState.selectedColumns() == @["b"]
doAssert rowsAtCellMenu[^1] == @[1, 2, 3]
doAssert columnsAtCellMenu[^1] == @["b"]

discard cellState.setMenuKeepsSelection(false)
clickTableCell(aX, 111, button = 1)
doAssert cellState.selectedRows() == @[2],
  "right-clicking an unselected cell should choose its row"
doAssert cellState.selectedColumns() == @["a"]
doAssert rowsAtCellMenu[^1] == @[2]
doAssert columnsAtCellMenu[^1] == @["a"]

listWindow.destroy()
tableWindow.destroy()
loop.shutdown()
