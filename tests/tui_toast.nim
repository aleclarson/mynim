import std/[assertions, os, times]

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc node(tree: ref platform.AccessTree; role: platform.AccessRole;
          label: string): platform.AccessNode =
  if tree != nil:
    for item in tree.nodes:
      if item.role == role and item.label == label:
        return item
  raise newException(AssertionDefect,
    "missing access node " & $role & " labeled " & label)

proc statusCount(tree: ref platform.AccessTree): int =
  if tree != nil:
    for item in tree.nodes:
      if item.role == platform.roleStatus:
        inc result

proc statusNode(tree: ref platform.AccessTree): platform.AccessNode =
  if tree != nil:
    for item in tree.nodes:
      if item.role == platform.roleStatus:
        return item
  raise newException(AssertionDefect, "missing toast status node")

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui toast test"))
app.initialized = true
app.handleReady()

var context: ui.Context
var shown: seq[string]
var left: seq[Duration]
var toastClosed: seq[string]
var undone = 0
var customViewport = true
let toastContent = ui.newContent(proc(c: ui.Context) =
  context = c
  shown.setLen(0)
  left.setLen(0)
  if customViewport:
    discard c.toastViewportBase(proc(viewport: ui.Element;
                                     toasts: seq[ui.Toast]) =
      discard viewport.padding(16).alignItems(ui.Align.End).gap(8)
      for value in toasts:
        let toast = value
        shown.add(toast.title)
        let parts = c.toastBase(toast)
        left.add(parts.left)
        discard parts.root.padding(10).background(c.theme.surface)
          .children(proc() =
            discard c.text(toast.title)
            if toast.action.len > 0:
              discard parts.actionButton().label(toast.action).children(proc() =
                discard c.text(toast.action)
              )
            discard parts.closeButton().label("Close")
              .children(proc() = discard c.text("×"))
            )
    )
)
let toastWindow = newWindow(WindowOptions(width: 400, height: 300, hidden: true,
  content: toastContent))
let toastSurface = fake.windows[^1].surface
doAssert toastSurface.frame()
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

var ids: seq[string]
for title in ["A", "B", "C", "D"]:
  ids.add(context.addToast(ui.Toast(title: title)))
doAssert toastSurface.frame()
doAssert shown == @["B", "C", "D"]
doAssert left.len == 3
for remaining in left:
  doAssert remaining > initDuration() and
    remaining <= initDuration(seconds = 4)
let tree = toastSurface.accessibility()[0]
doAssert tree.statusCount() == 3
doAssert tree.announcements == @["A", "B", "C", "D"]

discard context.addToast(ui.Toast(id: ids[2], title: "C2"))
doAssert toastSurface.frame()
doAssert shown == @["B", "C2", "D"]
doAssert left[1] > initDuration() and
  left[1] <= initDuration(seconds = 4)

context.closeToast(ids[3])
doAssert toastSurface.frame()
doAssert shown == @["A", "B", "C2"]

context.closeToast("")
doAssert toastSurface.frame()
doAssert shown.len == 0

var uploadToast = ui.Toast(id: "upload", title: "Upload failed",
  description: "Try again later", action: "Undo")
uploadToast.onAction = proc() = inc undone
uploadToast.onClose = proc() = toastClosed.add("upload")
let actionId = context.addToast(uploadToast)
doAssert actionId == "upload"
doAssert toastSurface.frame()
var actionTree = toastSurface.accessibility()[0]
doAssert actionTree.statusCount() == 1
doAssert actionTree.node(platform.roleButton, "Undo").bounds.w > 0
doAssert actionTree.announcements == @["Upload failed", "Try again later"]

# Tab reaches the toast action. Escape closes it and runs OnClose once.
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert toastSurface.frame()
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert toastSurface.frame()
doAssert shown.len == 0
doAssert undone == 0
doAssert toastClosed == @["upload"]

# The action button runs its callback and then closes the toast.
var undoToast = ui.Toast(id: "undo", title: "Deleted", action: "Undo")
undoToast.onAction = proc() = inc undone
undoToast.onClose = proc() = toastClosed.add("undo")
discard context.addToast(undoToast)
doAssert toastSurface.frame()
actionTree = toastSurface.accessibility()[0]
let undo = actionTree.node(platform.roleButton, "Undo")
let x = undo.bounds.x + undo.bounds.w / 2
let y = undo.bounds.y + undo.bounds.h / 2
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: x, y: y))
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: x, y: y))
doAssert toastSurface.frame()
doAssert undone == 1
doAssert toastClosed == @["upload", "undo"]
doAssert toastSurface.frame()
doAssert shown.len == 0

# A positive timeout expires and invokes OnClose.
var shortToast = ui.Toast(id: "short", title: "Short lived",
  timeout: initDuration(milliseconds = 50))
shortToast.onClose = proc() = toastClosed.add("short")
discard context.addToast(shortToast)
doAssert toastSurface.frame()
os.sleep(80)
doAssert toastSurface.frame()
doAssert shown.len == 0
doAssert toastClosed == @["upload", "undo", "short"]

# The themed viewport appears automatically and the message helper reuses IDs.
customViewport = false
context.toast("Saved")
doAssert toastSurface.frame()
var defaultTree = toastSurface.accessibility()[0]
doAssert defaultTree.statusCount() == 1
doAssert defaultTree.node(platform.roleText, "Saved").label == "Saved"
context.toast("Saved")
doAssert toastSurface.frame()
defaultTree = toastSurface.accessibility()[0]
doAssert defaultTree.statusCount() == 1
context.closeToast("")
doAssert toastSurface.frame()

# Keyboard focus pauses a finite toast until it leaves the toast.
customViewport = true
var heldToast = ui.Toast(id: "held", title: "Still here", action: "Dismiss",
  timeout: initDuration(milliseconds = 100))
discard context.addToast(heldToast)
doAssert toastSurface.frame()
doAssert toastSurface.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert toastSurface.frame()
doAssert shown == @["Still here"]
let remainingWhileFocused = left[0]
os.sleep(150)
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert toastSurface.frame()
doAssert shown == @["Still here"]
doAssert left[0] > initDuration()
doAssert left[0] <= remainingWhileFocused
context.closeToast("held")
doAssert toastSurface.frame()

# Hovering the toast also pauses its countdown.
var pointerToast = ui.Toast(id: "pointer", title: "Pointer pause",
  timeout: initDuration(milliseconds = 60))
discard context.addToast(pointerToast)
doAssert toastSurface.frame()
var pointerTree = toastSurface.accessibility()[0]
let toastStatus = pointerTree.statusNode()
let pointerX = toastStatus.bounds.x + toastStatus.bounds.w / 2
let pointerY = toastStatus.bounds.y + toastStatus.bounds.h / 2
discard toastSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: pointerX, y: pointerY))
doAssert toastSurface.frame()
os.sleep(90)
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert toastSurface.frame()
doAssert shown == @["Pointer pause"]

discard toastSurface.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 0, y: 0))
doAssert toastSurface.frame()
os.sleep(90)
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert toastSurface.frame()
doAssert shown.len == 0

# Losing the window focus pauses the same countdown.
var backgroundToast = ui.Toast(id: "background", title: "In background",
  timeout: initDuration(milliseconds = 60))
discard context.addToast(backgroundToast)
doAssert toastSurface.frame()
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceBlur))
doAssert toastSurface.frame()
os.sleep(90)
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert toastSurface.frame()
doAssert shown == @["In background"]
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceFocus))
doAssert toastSurface.frame()
os.sleep(90)
discard toastSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert toastSurface.frame()
doAssert shown.len == 0

toastWindow.destroy()
loop.shutdown()
