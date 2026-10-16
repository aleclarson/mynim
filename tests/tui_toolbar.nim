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

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui toolbar test"))
app.initialized = true
app.handleReady()

var bold = false
let toolbarContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().gap(8).children(proc() =
    discard ctx.button("Before")
    discard ctx.toolbar(proc() =
      discard ctx.button("Cut")
      discard ctx.toggle(bold, "Bold")
      discard ctx.menuButton("More", proc(menu: ui.Menu) =
        discard menu.item("Duplicate"))
    ).label("Format")
    discard ctx.button("After")
  )
)
let win = newWindow(WindowOptions(width: 420, height: 120, hidden: true,
  content: toolbarContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let toolbarId = accessId(tree, platform.roleToolbar, "Format")
let beforeId = accessId(tree, platform.roleButton, "Before")
let cutId = accessId(tree, platform.roleButton, "Cut")
let boldId = accessId(tree, platform.roleToggleButton, "Bold")
let moreId = accessId(tree, platform.roleMenuButton, "More")
let afterId = accessId(tree, platform.roleButton, "After")
doAssert toolbarId > 0 and beforeId > 0 and cutId > 0 and boldId > 0 and
  moreId > 0 and afterId > 0

# The toolbar is one Tab stop, with horizontal navigation and Home/End.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == beforeId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == cutId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == boldId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == moreId
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == cutId, "toolbar arrows should wrap"
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == afterId

win.destroy()
loop.shutdown()
