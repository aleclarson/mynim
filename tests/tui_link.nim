import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessLink(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleLink and node.label == label:
        return node
  raise newException(AssertionDefect, "missing link " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui link test"))
app.initialized = true
app.handleReady()

var linkClicked = false
let linkContent = ui.newContent(proc(ctx: ui.Context) =
  let link = ctx.link("Mygo documentation", "")
  linkClicked = link.clicked()
)
let win = newWindow(WindowOptions(width: 240, height: 60,
  hidden: true, content: linkContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let link = accessLink(tree, "Mygo documentation")
doAssert (link.states and platform.accessFocusable) != platform.AccessStates(0)

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: link.id, action: platform.accessFocus))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnter))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.keyReleased,
  key: platform.keyEnter))
doAssert native.frame()
doAssert linkClicked

tree = native.accessibility()[0]
let focusedLink = accessLink(tree, "Mygo documentation")
doAssert tree.focus == focusedLink.id
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: focusedLink.bounds.x + 1, y: focusedLink.bounds.y + 1))
doAssert native.frame()
doAssert native.cursor == platform.cursorPointer

win.destroy()
loop.shutdown()
