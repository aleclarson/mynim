import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui text anchor caret test"))
app.initialized = true
app.handleReady()

var value = "A😀B"
var requestedAnchor, requestedCaret: int
var selectionPending = true
var observed: tuple[anchor, caret: int]
var observedRange: tuple[start, `end`: int]
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let input = ctx.textInput(value).size(160, 34)
  if selectionPending:
    discard input.setTextSelection(requestedAnchor, requestedCaret)
    observed = input.textAnchorCaret()
    observedRange = input.textSelection()
    selectionPending = false
)
let win = newWindow(WindowOptions(width: 200, height: 80, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

requestedAnchor = 2
requestedCaret = 1
doAssert native.frame()
doAssert observed == (anchor: 2, caret: 1)
doAssert observedRange == (start: 1, `end`: 2)

requestedAnchor = 1
requestedCaret = 2
selectionPending = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert observed == (anchor: 1, caret: 2)
doAssert observedRange == (start: 1, `end`: 2)

win.destroy()
loop.shutdown()
