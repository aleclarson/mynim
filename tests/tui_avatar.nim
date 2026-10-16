import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/image as sourceImage
import mynim/ui as ui

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node

proc hasAccessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                   label: string): bool =
  tree.accessNode(role, label).id > 0

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui avatar test"))
app.initialized = true
app.handleReady()

let pixels = sourceImage.newRgba(sourceImage.rect(0, 0, 2, 2))
let bitmap = ui.newBitmap(pixels)
var displayName = "Ada Lovelace"
let avatarContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.row().gap(8).children(proc() =
    discard ctx.avatar(displayName)
    discard ctx.avatar("grace")
    discard ctx.avatar("東京 大阪")
    discard ctx.avatar("١٢ oranges")
    discard ctx.avatar("___")
    discard ctx.avatar("Profile Photo", bitmap)
  )
)
let win = newWindow(WindowOptions(width: 320, height: 80, hidden: true,
  content: avatarContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
let ada = tree.accessNode(platform.roleImage, "Ada Lovelace")
doAssert ada.id > 0
doAssert ada.bounds.w == 29.25 and ada.bounds.h == 29.25
doAssert tree.hasAccessNode(platform.roleText, "AL")
doAssert tree.hasAccessNode(platform.roleText, "G")
doAssert tree.hasAccessNode(platform.roleText, "東大")
doAssert tree.hasAccessNode(platform.roleText, "١O")
doAssert not tree.hasAccessNode(platform.roleText, "")
doAssert tree.accessNode(platform.roleImage, "Profile Photo").id > 0
doAssert not tree.hasAccessNode(platform.roleText, "PP")

displayName = "Grace Hopper"
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.accessNode(platform.roleImage, "Grace Hopper").id > 0
doAssert tree.hasAccessNode(platform.roleText, "GH")
doAssert not tree.hasAccessNode(platform.roleText, "AL")

win.destroy()
loop.shutdown()
