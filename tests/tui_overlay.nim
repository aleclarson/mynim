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
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui overlay test"))
app.initialized = true
app.handleReady()

var chosen = false
let overlayContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().children(proc() =
    var anchor: ui.Element
    let clipped = ctx.column().size(180, 40).clip()
    discard clipped.children(proc() =
      anchor = ctx.button("Anchor")
    )
    discard ctx.overlay(anchor, proc(panel: ui.Element) =
      discard panel.size(120, 100).padding(0).background(ctx.theme.surface)
      discard panel.children(proc() =
        discard ctx.box().height(50)
        let pick = ctx.button("Choose").height(24)
        discard pick.onClick(proc() = chosen = true)
      )
    ).label("Popup")
    discard ctx.button("Later").absolute().left(0).top(80)
      .width(180).height(24)
  )
)
let overlayWindow = newWindow(WindowOptions(width: 240, height: 160,
  hidden: true, content: overlayContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
let popupNode = accessNode(tree, platform.roleGroup, "Popup")
let optionNode = accessNode(tree, platform.roleButton, "Choose")
doAssert optionNode.bounds.y + optionNode.bounds.h / 2 > 40
doAssert popupNode.bounds.y >= 0 and
  popupNode.bounds.y + popupNode.bounds.h <= 160

# The option is outside its clipped host but remains a valid pointer target.
let x = optionNode.bounds.x + optionNode.bounds.w / 2
let y = optionNode.bounds.y + optionNode.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y))
doAssert native.frame()
doAssert chosen

let aboveContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().children(proc() =
    discard ctx.box().height(110)
    let anchor = ctx.button("Bottom anchor")
    discard ctx.overlay(anchor, proc(panel: ui.Element) =
      discard panel.size(120, 50).background(ctx.theme.surface)
    ).label("Above popup")
  )
)
let aboveWindow = newWindow(WindowOptions(width: 240, height: 160,
  hidden: true, content: aboveContent))
let aboveSurface = fake.windows[^1].surface
doAssert aboveSurface.frame()
doAssert aboveSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let aboveTree = aboveSurface.accessibility()[0]
let abovePopup = accessNode(aboveTree, platform.roleGroup, "Above popup")
let bottomAnchor = accessNode(aboveTree, platform.roleButton, "Bottom anchor")
doAssert abovePopup.bounds.y + abovePopup.bounds.h <= bottomAnchor.bounds.y
doAssert abovePopup.bounds.y >= 0

aboveWindow.destroy()
overlayWindow.destroy()
loop.shutdown()
