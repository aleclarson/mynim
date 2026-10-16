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

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui badge test"))
app.initialized = true
app.handleReady()

let badgeContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.row().gap(8).children(proc() =
    discard ctx.badge("3")
    discard ctx.badge("99+")
  )
)
let win = newWindow(WindowOptions(width: 160, height: 64, hidden: true,
  content: badgeContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
let count = tree.accessNode(platform.roleText, "3")
let many = tree.accessNode(platform.roleText, "99+")
doAssert count.id > 0 and many.id > 0
doAssert count.bounds.w > 0 and many.bounds.w > count.bounds.w

win.destroy()
loop.shutdown()
