import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/image as sourceImage
import mynim/ui as ui

let imageSource = sourceImage.newRgba(sourceImage.rect(0, 0, 1, 1))
imageSource.set(0, 0, sourceImage.Rgba(r: 30, g: 60, b: 90, a: 255))
let bitmap = ui.newBitmap(imageSource)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui accessibility test"))
app.initialized = true
app.handleReady()

var presses = 0
var saveClicked = false
let content = ui.newContent(proc(ctx: ui.Context) =
  let panel = ctx.column().size(180, 120).label("Panel")
  discard panel.children(proc() =
    discard ctx.text("Status")
    let save = ctx.box().size(80, 36).label("Save")
      .onClick(proc() = inc presses)
    saveClicked = save.clicked()
    discard ctx.image(bitmap).size(16, 16)
    discard ctx.image(bitmap).size(16, 16).label("Logo")
  )
)
let win = newWindow(WindowOptions(width: 200, height: 140, hidden: true,
  content: content))
let native = fake.windows[^1].surface

doAssert native.frame()
let (emptyTree, initialUpdates) = native.accessibility()
doAssert emptyTree == nil and initialUpdates == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let (tree, updates) = native.accessibility()
doAssert tree != nil and updates == 1
doAssert tree.nodes.len == 4
doAssert tree.nodes[0].role == platform.roleGroup
doAssert tree.nodes[0].label == "Panel" and tree.nodes[0].parent == -1
doAssert tree.nodes[1].role == platform.roleText
doAssert tree.nodes[1].label == "Status" and tree.nodes[1].parent == 0
doAssert tree.nodes[2].role == platform.roleButton
doAssert tree.nodes[2].label == "Save" and tree.nodes[2].parent == 0
doAssert tree.nodes[2].states == platform.accessFocusable
doAssert tree.nodes[2].actions ==
  (platform.actionFocus or platform.actionPress)
doAssert tree.nodes[3].role == platform.roleImage
doAssert tree.nodes[3].label == "Logo" and tree.nodes[3].parent == 0
doAssert not saveClicked

doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: tree.nodes[2].id, action: platform.accessPress))
doAssert presses == 1
doAssert native.frame()
doAssert saveClicked
let (_, refreshed) = native.accessibility()
doAssert refreshed == 2

win.destroy()
loop.shutdown()
