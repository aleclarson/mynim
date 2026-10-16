import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessId(tree: ref platform.AccessTree; role: platform.AccessRole;
              label: string): uint64 =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node.id

proc accessNode(tree: ref platform.AccessTree; id: uint64):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == id:
        return node

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui toolbar overflow test"))
app.initialized = true
app.handleReady()

var clicks = 0
var enabled = false
var nestedChosen = false
let toolbarContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().children(proc() =
    discard ctx.toolbar(proc() =
      let first = ctx.button("First action")
      if first.clicked():
        inc clicks
      let second = ctx.button("Second action")
      if second.clicked():
        inc clicks
      discard ctx.toggle(enabled, "Enabled")
      let fourth = ctx.button("Fourth action").disabled()
      if fourth.clicked():
        inc clicks
      discard ctx.menuButton("Nested menu", proc(menu: ui.Menu) =
        let item = menu.item("Nested action")
        if item.chosen:
          nestedChosen = true
      )
    ).label("Actions")
  )
)
let win = newWindow(WindowOptions(width: 260, height: 140, hidden: true,
  content: toolbarContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let toolbarId = accessId(tree, platform.roleToolbar, "Actions")
let firstId = accessId(tree, platform.roleButton, "First action")
let secondId = accessId(tree, platform.roleButton, "Second action")
let enabledId = accessId(tree, platform.roleToggleButton, "Enabled")
let moreId = accessId(tree, platform.roleMenuButton, "More")
doAssert toolbarId > 0 and firstId > 0 and moreId > 0
doAssert secondId == 0 and enabledId == 0,
  "overflowed controls should leave the accessibility tree"

# Only visible toolbar controls participate in focus navigation.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == firstId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == moreId

let more = accessNode(tree, moreId)
let x = more.bounds.x + more.bounds.w / 2
let y = more.bounds.y + more.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y, button: 0))
fake.step()
var popups = fake.allPopups()
doAssert popups.len == 1
var openedMenu = popups[^1].menu
var labels: seq[string]
for item in openedMenu.items:
  labels.add(item.label)
doAssert labels == @["Second action", "Enabled", "Fourth action", "Nested menu"]
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y, button: 0))

fake.windows[^1].clickMenuItem(openedMenu.items[0].id)
doAssert native.frame()
doAssert clicks == 1, "choosing an overflow item should click its control"

# A hidden toggle remains live through its checked menu item.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y, button: 0))
fake.step()
popups = fake.allPopups()
openedMenu = popups[^1].menu
doAssert openedMenu.items[1].label == "Enabled" and not openedMenu.items[1].checked
doAssert openedMenu.items[2].label == "Fourth action" and
  not openedMenu.items[2].enabled
fake.windows[^1].clickMenuItem(openedMenu.items[1].id)
doAssert native.frame()
doAssert enabled

# Choosing a hidden menu button opens its child menu at the More button.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y, button: 0))
fake.step()
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y, button: 0))
popups = fake.allPopups()
openedMenu = popups[^1].menu
doAssert openedMenu.items[1].checked
fake.windows[^1].clickMenuItem(openedMenu.items[^1].id)
fake.step()
popups = fake.allPopups()
doAssert popups.len == 4
doAssert popups[^1].menu.items.len == 1 and
  popups[^1].menu.items[0].label == "Nested action"
doAssert not nestedChosen
fake.windows[^1].clickMenuItem(popups[^1].menu.items[0].id)
doAssert nestedChosen, "the nested menu choice should reach its builder"

# When the window grows, every control returns to the toolbar and More hides.
var windowBounds = fake.windows[^1].bounds()
windowBounds.width = 900
fake.windows[^1].setBounds(windowBounds)
doAssert native.frame()
tree = native.accessibility()[0]
doAssert accessId(tree, platform.roleMenuButton, "More") == 0
doAssert accessId(tree, platform.roleButton, "Second action") > 0
doAssert accessId(tree, platform.roleToggleButton, "Enabled") > 0

win.destroy()
loop.shutdown()
