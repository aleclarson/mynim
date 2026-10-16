import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc progressNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleProgress and node.label == label:
        return node

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui spinner test"))
app.initialized = true
app.handleReady()

let spinnerContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.spinner().label("Loading")
    .svgColor(ui.rgb(40, 80, 160))
)
let win = newWindow(WindowOptions(width: 120, height: 80, hidden: true,
  content: spinnerContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
let spinner = tree.progressNode("Loading")
doAssert spinner.id > 0
doAssert spinner.min == 0 and spinner.max == 1 and spinner.now == -1
doAssert native.frame() # The activity indicator requests its next frame.
fake.setPreferences(platform.Preferences(reduceMotion: true))
doAssert native.frame()
doAssert not native.frame()

win.destroy()
loop.shutdown()
