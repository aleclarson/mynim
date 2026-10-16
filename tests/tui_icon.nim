import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let (vector, parseError) = ui.parseSvg(
  "<svg viewBox='0 0 10 20'><rect width='10' height='20'/></svg>")
doAssert parseError.len == 0 and vector != nil

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui icon test"))
app.initialized = true
app.handleReady()

let iconContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.column().fill().padding(10).children(proc() =
    discard ctx.icon(vector).label("Small icon")
    discard ctx.icon(vector).textSize(24).label("Large icon")
    discard ctx.icon(vector).size(40, 20).label("Sized icon")
    discard ctx.box().textSize(28).textColor(ui.rgb(10, 20, 30))
      .children(proc() =
        discard ctx.icon(vector).label("Inherited icon")
      )
    discard ctx.icon(vector)
  )
)
let win = newWindow(WindowOptions(width: 120, height: 100,
  hidden: true, content: iconContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
doAssert tree.nodes.len == 4
var sizes: seq[tuple[label: string, w, h: float64]]
for node in tree.nodes:
  if node.role == platform.roleImage:
    sizes.add((node.label, node.bounds.w, node.bounds.h))
doAssert sizes.len == 4
doAssert sizes[0].label == "Small icon"
doAssert sizes[0].w == sizes[0].h / 2
doAssert sizes[1].label == "Large icon"
doAssert sizes[1].w == 12 and sizes[1].h == 24
doAssert sizes[2].label == "Sized icon"
doAssert sizes[2].w == 40 and sizes[2].h == 20
doAssert sizes[3].label == "Inherited icon"
doAssert sizes[3].w == 14 and sizes[3].h == 28

win.destroy()
loop.shutdown()
