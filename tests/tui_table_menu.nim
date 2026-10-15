import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui table menu test"))
app.initialized = true
app.handleReady()

let columns = [
  ui.TableColumn(title: "Name", id: "name", width: 60),
  ui.TableColumn(title: "Kind", id: "kind", width: 60),
  ui.TableColumn(title: "Size", id: "size", width: 60)
]
let tableState = ui.newListState(20)
tableState.columns.order = @["size", "name", "kind"]
var builtColumn = -2
var chosenColumn = -2
var includeItem = true
var itemLabel = "Hide Column"
let menuContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.table(tableState, columns, 1, proc(row, column: int) =
    discard ctx.text("cell")
  ).size(320, 100)
)
let menuWin = newWindow(WindowOptions(width: 320, height: 100, hidden: true,
  content: menuContent))
let menuSurface = fake.windows[^1].surface
doAssert menuSurface.frame()
doAssert menuSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

proc header(label: string): platform.RectF =
  let (tree, _) = menuSurface.accessibility()
  for node in tree.nodes:
    if node.role == platform.roleColumnHeader and node.label == label:
      return node.bounds
  raise newException(ValueError, "missing header " & label)

let kind = header("Kind")
let kindX = kind.x + kind.w / 2
let kindY = kind.y + kind.h / 2
doAssert not menuSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: kindX, y: kindY, button: 1)),
  "right-click without a menu should not be consumed"
doAssert fake.allPopups().len == 0

tableState.headerMenu = proc(menu: ui.Menu; column: int) =
  builtColumn = column
  if includeItem and menu.item(itemLabel).chosen:
    chosenColumn = column
doAssert menuSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: kindX, y: kindY, button: 1))
doAssert builtColumn == 1,
  "the reordered Kind header should report its original column index"
fake.step()
let popups = fake.allPopups()
doAssert popups.len == 1
doAssert popups[0].menu.items.len == 1
doAssert popups[0].menu.items[0].label == "Hide Column"
doAssert popups[0].menu.items[0].enabled
fake.windows[^1].clickMenuItem(popups[0].menu.items[0].id)
doAssert chosenColumn == 1,
  "choosing a menu item should rebuild the menu with the original index"

let blankX = 300.0
let blankY = kindY
doAssert menuSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: blankX, y: blankY, button: 1))
doAssert builtColumn == -1,
  "the table header area past its columns should report -1"
fake.step()
doAssert fake.allPopups().len == 2
itemLabel = "Reset Columns"
fake.windows[^1].clickMenuItem(fake.allPopups()[1].menu.items[0].id)
doAssert chosenColumn == 1,
  "a menu item changed after opening should not receive the stale choice"
itemLabel = "Hide Column"

when defined(macosx):
  let nameHeader = header("Name")
  doAssert menuSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: nameHeader.x + nameHeader.w / 2, y: nameHeader.y + nameHeader.h / 2,
    button: 0, mods: platform.modCtrl)),
    "Control-click on macOS should open a context menu"
  doAssert builtColumn == 0
  fake.step()
  doAssert fake.allPopups().len == 3

includeItem = false
doAssert menuSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: blankX, y: blankY, button: 1))
doAssert builtColumn == -1
fake.step()
doAssert fake.allPopups().len == (when defined(macosx): 3 else: 2),
  "an empty menu builder should not show a native menu"

menuWin.destroy()
loop.shutdown()
