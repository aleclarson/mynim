import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc accessNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleButton and node.label == label:
        return node
  raise newException(AssertionDefect, "missing button " & label)

proc click(native: fakeBackend.FakeSurface; label: string) =
  let node = accessNode(native.accessibility()[0], label)
  let x = node.bounds.x + node.bounds.w / 2
  let y = node.bounds.y + node.bounds.h / 2
  doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
    x: x, y: y))
  doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
    x: x, y: y))
  doAssert native.frame()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui router retention test"))
app.initialized = true
app.handleReady()

let router = ui.newRouter("/settings/page/0")
router.transition(ui.Transition.None)
let routerContent = ui.newContent(proc(ctx: ui.Context) =
  discard router.view(ctx, proc(route: ui.Route) =
    if route.match("/settings/{section...}"):
      route.title("Settings")
      discard route.view(ctx, proc(inner: ui.Route) =
        if inner.match("/page/{id}"):
          inner.title("Page " & inner.param("id"))
          let stateScope = ctx.box()
          let count = stateScope.local("count", proc(): int = 0)
          discard ctx.button("Count " & $count.value).onClick(proc() =
            inc count.value)
        else:
          discard ctx.text("Not found")
      )
    else:
      discard ctx.text("Not found")
  )
)
let win = newWindow(WindowOptions(width: 320, height: 180, hidden: true,
  content: routerContent))
let native = fake.windows[^1].fakeSurface()

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
native.click("Count 0")
doAssert accessNode(native.accessibility()[0], "Count 1").label == "Count 1"

router.push("/settings/page/1")
doAssert native.frame()
router.back()
doAssert native.frame()
doAssert accessNode(native.accessibility()[0], "Count 1").label == "Count 1",
  "a nearby history page should restore its element-local state"

for index in 1..11:
  router.push("/settings/page/" & $index)
  doAssert native.frame()
router.go(-11)
doAssert native.frame()
doAssert accessNode(native.accessibility()[0], "Count 0").label == "Count 0",
  "a page more than ten history entries away should release its local state"

native.click("Count 0")
router.replace("/settings/page/replaced")
doAssert native.frame()
router.replace("/settings/page/0")
doAssert native.frame()
doAssert accessNode(native.accessibility()[0], "Count 0").label == "Count 0",
  "replacing a page should discard the replaced page's local state"

win.destroy()
loop.shutdown()
