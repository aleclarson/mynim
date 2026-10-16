import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui menu button test"))
app.initialized = true
app.handleReady()

var selected = "Name"
var includeItems = true
var disabled = false
var builds = 0
let menuContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.menuButton("Sort by", proc(menu: ui.Menu) =
    inc builds
    if includeItems:
      for option in ["Name", "Date", "Size"]:
        let item = menu.item(option).checked(selected == option)
        if item.chosen:
          selected = option
  ).disabled(disabled)
)
let win = newWindow(WindowOptions(width: 300, height: 100, hidden: true,
  content: menuContent))
let windowSurface = fake.windows[^1].surface
doAssert windowSurface.frame()
doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

let (tree, _) = windowSurface.accessibility()
var buttonId = 0'u64
var buttonBounds: platform.RectF
for node in tree.nodes:
  if node.role == platform.roleMenuButton and node.label == "Sort by":
    buttonId = node.id
    buttonBounds = node.bounds
doAssert buttonId > 0, "menu button should have an accessible menu-button role"

let x = buttonBounds.x + buttonBounds.w / 2
let y = buttonBounds.y + buttonBounds.h / 2
doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y, button: 0)), "pointer down should open the menu"
fake.step()
doAssert fake.allPopups().len == 1
let firstMenu = fake.allPopups()[0].menu
doAssert firstMenu.items.len == 3
doAssert firstMenu.items[0].label == "Name"
doAssert firstMenu.items[1].label == "Date"
doAssert firstMenu.items[0].checked
doAssert fake.allPopups()[0].pos.x == int(buttonBounds.x)
doAssert fake.allPopups()[0].pos.y == int(buttonBounds.y + buttonBounds.h)
discard windowSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y, button: 0))

fake.windows[^1].clickMenuItem(firstMenu.items[1].id)
doAssert selected == "Date", "the chosen menu item should reach its builder"
doAssert builds == 2, "the builder should run when opened and chosen"
doAssert windowSurface.frame()

doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown)), "Down should open the focused menu button"
fake.step()
doAssert fake.allPopups().len == 2
let secondMenu = fake.allPopups()[1].menu
doAssert secondMenu.items[1].checked
fake.windows[^1].clickMenuItem(secondMenu.items[0].id)
doAssert selected == "Name"
doAssert windowSurface.frame()

for key in [platform.keyEnter, platform.keySpace]:
  doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
    key: key)), "Enter and Space should open the focused menu button"
  fake.step()
  let keyboardMenu = fake.allPopups()[^1].menu
  fake.windows[^1].clickMenuItem(keyboardMenu.items[2].id)
  doAssert selected == "Size"
  doAssert windowSurface.frame()

let beforeAccessPress = fake.allPopups().len
doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: buttonId, action: platform.accessPress)),
  "accessibility press should open the menu"
fake.step()
doAssert fake.allPopups().len == beforeAccessPress + 1

includeItems = false
doAssert windowSurface.frame()
doAssert windowSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter)), "Enter should be handled by the menu button"
fake.step()
doAssert fake.allPopups().len == beforeAccessPress + 1,
  "an empty menu should not be shown"

includeItems = true
disabled = true
doAssert windowSurface.frame()
discard windowSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyDown))
fake.step()
doAssert fake.allPopups().len == beforeAccessPress + 1,
  "a disabled menu button should not open its menu"

win.destroy()
loop.shutdown()
