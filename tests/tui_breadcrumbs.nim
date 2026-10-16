import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node
  raise newException(AssertionDefect,
    "missing access node " & $role & " labeled " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui breadcrumbs test"))
app.initialized = true
app.handleReady()

let locations = ["Macintosh HD", "Users", "ada", "Documents"]
var chosen = -1
var changes = 0
var changedThisFrame = false
let pathContent = ui.newContent(proc(ctx: ui.Context) =
  let path = ctx.breadcrumbs(locations, chosen).label("Path")
    .width(300).onChange(proc() = inc changes)
  changedThisFrame = path.changed()
)
let pathWindow = newWindow(WindowOptions(width: 320, height: 80,
  hidden: true, content: pathContent))
let pathNative = fake.windows[^1].surface
doAssert pathNative.frame()
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = pathNative.accessibility()[0]
doAssert tree != nil
discard accessNode(tree, platform.roleGroup, "Path")
let users = accessNode(tree, platform.roleLink, "Users")
let ada = accessNode(tree, platform.roleLink, "ada")
discard accessNode(tree, platform.roleLink, "Macintosh HD")
discard accessNode(tree, platform.roleText, "Documents")
for node in tree.nodes:
  doAssert not (node.role == platform.roleLink and node.label == "Documents")

# Pointer activation chooses a location and reports a change on the path.
let x = users.bounds.x + users.bounds.w / 2
let y = users.bounds.y + users.bounds.h / 2
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y))
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y))
doAssert pathNative.frame()
doAssert chosen == 1 and changedThisFrame and changes == 1

# Links also take sequential focus and activate with Enter.
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert pathNative.frame()
tree = pathNative.accessibility()[0]
doAssert tree.focus == ada.id
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert pathNative.frame()
tree = pathNative.accessibility()[0]
doAssert tree.focus == users.id
doAssert pathNative.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
discard pathNative.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert pathNative.frame()
doAssert chosen == 1 and changedThisFrame and changes == 2

pathWindow.destroy()
loop.shutdown()
