import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc hasLabel(tree: ref platform.AccessTree; label: string): bool =
  if tree != nil:
    for node in tree.nodes:
      if node.label == label:
        return true

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node
  raise newException(AssertionDefect, "missing accessibility node " & label)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui router transition test"))
app.initialized = true
app.handleReady()

let router = ui.newRouter("/notes")
doAssert router.transition() == ui.Transition.Auto
doAssert not router.hasAnimation()
var outgoingActionTriggered = false
let routerContent = ui.newContent(proc(ctx: ui.Context) =
  discard router.view(ctx, proc(route: ui.Route) =
    if route.match("/notes"):
      route.title("Notes")
      discard ctx.button("Outgoing action").onClick(proc() =
        outgoingActionTriggered = true)
    elif route.match("/notes/{id}/edit"):
      route.title("Edit note")
      discard ctx.text("Current edit")
    elif route.match("/notes/{id}"):
      route.title("Note")
      discard ctx.text("Current detail")
    else:
      route.title("Home")
      discard ctx.text("Current home")
  )
)
let win = newWindow(WindowOptions(width: 320, height: 180, hidden: true,
  content: routerContent))
let native = fake.windows[^1].fakeSurface()

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let outgoingAction = accessNode(native.accessibility()[0],
  platform.roleButton, "Outgoing action")
router.push("/notes/42")
doAssert native.frame()
var tree = native.accessibility()[0]
doAssert hasLabel(tree, "Note")
doAssert hasLabel(tree, "Current detail")
doAssert not hasLabel(tree, "Outgoing action"),
  "the outgoing page should be inert and absent from accessibility"
let oldButtonX = outgoingAction.bounds.x + outgoingAction.bounds.w / 2
let oldButtonY = outgoingAction.bounds.y + outgoingAction.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: oldButtonX, y: oldButtonY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: oldButtonX, y: oldButtonY))
doAssert not outgoingActionTriggered,
  "the outgoing page should not receive pointer activation during transition"

router.transition(ui.Transition.Fade)
doAssert router.transition() == ui.Transition.Fade
router.animation(ui.Animation(duration: initDuration(milliseconds = 80)))
doAssert router.hasAnimation()
router.push("/notes/42/edit")
doAssert native.frame()
tree = native.accessibility()[0]
doAssert hasLabel(tree, "Edit note") and hasLabel(tree, "Current edit")
doAssert not hasLabel(tree, "Current detail")

router.transition(ui.Transition.None)
router.push("/home")
doAssert native.frame()
tree = native.accessibility()[0]
doAssert hasLabel(tree, "Home") and hasLabel(tree, "Current home")
doAssert not hasLabel(tree, "Current edit"),
  "Transition.None should not retain the outgoing page in the current tree"
router.clearAnimation()
doAssert not router.hasAnimation()

win.destroy()
loop.shutdown()
