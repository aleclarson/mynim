import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui Textf test"))
app.initialized = true
app.handleReady()

let textfContent = ui.newContent(proc(ctx: ui.Context) =
  discard ctx.textf("%d %s %v %t %%", 42, "notes", true, false)
  discard ctx.textf("%[1]03d: %[2]s", 7, "notes")
  discard ctx.textf("%.2f", 1.25)
  discard ctx.textf("%q %x %.4g", "a\n", "A", 1.25)
  discard ctx.textf("%+05d %+v", 7, -7)
  discard ctx.textf("missing:%d")
  discard ctx.textf("extra", "unused")
)
let win = newWindow(WindowOptions(width: 220, height: 100,
  hidden: true, content: textfContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let tree = native.accessibility()[0]
var labels: seq[string]
for node in tree.nodes:
  if node.role == platform.roleText:
    labels.add(node.label)
doAssert labels == @[
  "42 notes true false %",
  "007: notes",
  "1.25",
  "\"a\\n\" 41 1.25",
  "+0007 -7",
  "missing:%!d(MISSING)",
  "extra%!(EXTRA string=unused)"]

win.destroy()
loop.shutdown()
