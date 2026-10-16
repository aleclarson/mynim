import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc ratingNode(tree: ref platform.AccessTree; label: string):
    platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == platform.roleSlider and node.label == label:
        return node

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui rating test"))
app.initialized = true
app.handleReady()

var score = 2
var changeCount = 0
let ratingContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.rating(score, 5).label("Quality")
    .onChange(proc() = inc(changeCount))
)
let win = newWindow(WindowOptions(width: 220, height: 60, hidden: true,
  content: ratingContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
var rating = tree.ratingNode("Quality")
doAssert rating.id > 0
doAssert rating.min == 0 and rating.max == 5 and rating.now == 2
doAssert rating.step == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyTab))
doAssert native.frame()
tree = native.accessibility()[0]
rating = tree.ratingNode("Quality")
doAssert tree.focus == rating.id

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyRight))
doAssert native.frame()
doAssert score == 3 and changeCount == 1
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyHome))
doAssert native.frame()
doAssert score == 0 and changeCount == 2
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEnd))
doAssert native.frame()
doAssert score == 5 and changeCount == 3

# Pointer clicks choose a star, and clicking that same star clears the rating.
tree = native.accessibility()[0]
rating = tree.ratingNode("Quality")
let starThreeX = rating.bounds.x + rating.bounds.w * 0.5
let starY = rating.bounds.y + rating.bounds.h / 2
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: starThreeX, y: starY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: starThreeX, y: starY, clicks: 1))
doAssert native.frame()
doAssert score == 3 and changeCount == 4
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: starThreeX, y: starY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: starThreeX, y: starY, clicks: 1))
doAssert native.frame()
doAssert score == 0 and changeCount == 5

doAssertRaises ValueError:
  discard ui.newContext().rating(score, 0)

win.destroy()
loop.shutdown()
