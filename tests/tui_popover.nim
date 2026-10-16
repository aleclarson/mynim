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
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui popover test"))
app.initialized = true
app.handleReady()

var modelOpen = true
var insideClicks, outsideClicks: int
let popoverContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().children(proc() =
    let anchor = ctx.button("Anchor").width(100)
    var frameOpen = modelOpen
    discard ctx.popoverBase(anchor, frameOpen, proc(panel: ui.Element) =
      discard panel.size(150, 70).background(ctx.theme.surface)
      let inside = ctx.button("Inside")
      discard inside.onClick(proc() = inc insideClicks)
    )
    if frameOpen != modelOpen:
      modelOpen = frameOpen
    let outside = ctx.button("Outside").absolute().left(210).top(120)
    discard outside.onClick(proc() = inc outsideClicks)
  )
)
let popoverWindow = newWindow(WindowOptions(width: 320, height: 200,
  hidden: true, content: popoverContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
discard accessNode(tree, platform.rolePopup, "")
let anchorNode = accessNode(tree, platform.roleButton, "Anchor")
var insideNode = accessNode(tree, platform.roleButton, "Inside")
let anchorX = anchorNode.bounds.x + anchorNode.bounds.w / 2
let anchorY = anchorNode.bounds.y + anchorNode.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: anchorX, y: anchorY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: anchorX, y: anchorY))
doAssert native.frame()
doAssert modelOpen
tree = native.accessibility()[0]
insideNode = accessNode(tree, platform.roleButton, "Inside")
let insideX = insideNode.bounds.x + insideNode.bounds.w / 2
let insideY = insideNode.bounds.y + insideNode.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: insideX, y: insideY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: insideX, y: insideY))
doAssert native.frame()
doAssert modelOpen and insideClicks == 1

# Escape closes the popup; the caller's frame-local open value is copied out.
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert not modelOpen

# An outside press closes the popup and continues to the target underneath.
modelOpen = true
doAssert native.send(platform.SurfaceEvent(kind: platform.surfaceFrame))
tree = native.accessibility()[0]
let popupNode = accessNode(tree, platform.rolePopup, "")
let outsideNode = accessNode(tree, platform.roleButton, "Outside")
doAssert outsideNode.bounds.x + outsideNode.bounds.w / 2 >
  popupNode.bounds.x + popupNode.bounds.w
let outsideX = outsideNode.bounds.x + outsideNode.bounds.w / 2
let outsideY = outsideNode.bounds.y + outsideNode.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: outsideX, y: outsideY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: outsideX, y: outsideY))
doAssert native.frame()
doAssert not modelOpen and outsideClicks == 1

popoverWindow.destroy()
loop.shutdown()
