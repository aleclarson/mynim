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

proc focusedNode(tree: ref platform.AccessTree): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.id == tree.focus:
        return node
  raise newException(AssertionDefect, "missing focused access node")

proc hasLabel(tree: ref platform.AccessTree; label: string): bool =
  if tree != nil:
    for node in tree.nodes:
      if node.label == label:
        return true

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui dialog test"))
app.initialized = true
app.handleReady()

var modalOpen = false
var modalDismissed = false
var outsideClicks, backgroundShortcuts: int
let modalContent = ui.newContent(proc(ctx: ui.Context) =
  ctx.onShortcut(platform.modSuper, platform.keyS,
    proc() = inc backgroundShortcuts)
  discard ctx.column().fill().children(proc() =
    let opener = ctx.button("Open dialog")
    var frameOpen = modalOpen or opener.clicked()
    let dialog = ctx.dialogBase(frameOpen,
      proc(backdrop, panel: ui.Element) =
        discard backdrop.background(ui.rgba(0, 0, 0, 0.4'f32))
        discard panel.size(250, 160).background(ctx.theme.surface)
        discard panel.children(proc() =
          discard ctx.text("Edit item")
          discard ctx.button("Cancel")
          discard ctx.button("Apply").autoFocus()
        )
    )
    modalOpen = frameOpen
    modalDismissed = modalDismissed or dialog.dismissed()
    let outside = ctx.button("Outside").absolute().left(410).top(260)
    discard outside.onClick(proc() = inc outsideClicks)
  )
)
let modalWindow = newWindow(WindowOptions(width: 500, height: 300,
  hidden: true, content: modalContent))
let modalSurface = fake.windows[^1].surface
doAssert modalSurface.frame()
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = modalSurface.accessibility()[0]
let opener = accessNode(tree, platform.roleButton, "Open dialog")
let outside = accessNode(tree, platform.roleButton, "Outside")
let openerX = opener.bounds.x + opener.bounds.w / 2
let openerY = opener.bounds.y + opener.bounds.h / 2
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: openerX, y: openerY))
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: openerX, y: openerY))
doAssert modalSurface.frame()
doAssert modalOpen

tree = modalSurface.accessibility()[0]
doAssert tree.nodes.len == 6
doAssert not tree.hasLabel("Outside")
discard accessNode(tree, platform.roleDialog, "")
doAssert focusedNode(tree).label == "Apply"

# Tab stays in the dialog and wraps at both ends.
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert modalSurface.frame()
tree = modalSurface.accessibility()[0]
doAssert focusedNode(tree).label == "Cancel"
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab, mods: platform.modShift))
doAssert modalSurface.frame()
tree = modalSurface.accessibility()[0]
doAssert focusedNode(tree).label == "Apply"

# Shortcuts registered behind the dialog wait while it is open.
discard modalSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyS, mods: platform.modSuper))
doAssert backgroundShortcuts == 0

# A press on an outside control hits the full-window backdrop instead.
let outsideX = outside.bounds.x + outside.bounds.w / 2
let outsideY = outside.bounds.y + outside.bounds.h / 2
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: outsideX, y: outsideY))
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: outsideX, y: outsideY))
doAssert modalSurface.frame()
doAssert not modalOpen and modalDismissed
doAssert outsideClicks == 0
doAssert modalSurface.frame()
tree = modalSurface.accessibility()[0]
doAssert accessNode(tree, platform.roleButton, "Open dialog").id == tree.focus

# Escape reports dismissal in the same frame it closes and restores focus.
modalOpen = true
modalDismissed = false
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.surfaceFrame))
tree = modalSurface.accessibility()[0]
doAssert focusedNode(tree).label == "Apply"
doAssert modalSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert modalSurface.frame()
doAssert not modalOpen and modalDismissed
tree = modalSurface.accessibility()[0]
doAssert accessNode(tree, platform.roleButton, "Open dialog").id == tree.focus

modalWindow.destroy()

var alertOpen = true
var alertChoice = -1
let alertContent = ui.newContent(proc(ctx: ui.Context) =
  var frameOpen = alertOpen
  alertChoice = ctx.alertDialog(frameOpen, "Remove item?",
    "This cannot be undone.", "Cancel", "Remove")
  alertOpen = frameOpen
)
let alertWindow = newWindow(WindowOptions(width: 500, height: 300,
  hidden: true, content: alertContent))
let alertSurface = fake.windows[^1].surface
doAssert alertSurface.frame()
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
tree = alertSurface.accessibility()[0]
let alertNode = accessNode(tree, platform.roleAlertDialog, "Remove item?")
doAssert alertNode.description == "This cannot be undone."
doAssert focusedNode(tree).label == "Remove"

# Alerts ignore backdrop presses, while their default button has focus.
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 5, y: 5))
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 5, y: 5))
doAssert alertSurface.frame()
doAssert alertOpen and alertChoice == -1

doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert alertSurface.frame()
doAssert not alertOpen and alertChoice == ui.AlertDismissed

alertOpen = true
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.surfaceFrame))
tree = alertSurface.accessibility()[0]
let remove = accessNode(tree, platform.roleButton, "Remove")
let removeX = remove.bounds.x + remove.bounds.w / 2
let removeY = remove.bounds.y + remove.bounds.h / 2
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: removeX, y: removeY))
doAssert alertSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: removeX, y: removeY))
doAssert alertSurface.frame()
doAssert not alertOpen and alertChoice == 1

alertWindow.destroy()
loop.shutdown()
