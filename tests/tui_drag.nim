import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

var providerCalls = 0
var clickCalls = 0
var doneCalls = 0
var doneResult: transfer.Result
var data = transfer.textData("drag payload")

proc onDragDone(result: transfer.Result) =
  inc doneCalls
  doneResult = result

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui drag test"))
app.initialized = true
app.handleReady()

let uiContent = ui.newContent(proc(c: ui.Context) =
  discard c.column().size(120, 80).children(proc() =
    let source = c.box().size(100, 60).onClick(proc() = inc clickCalls)
    discard source.dragDataFrom(proc(): transfer.Data =
      inc providerCalls
      data,
      transfer.DragOptions(done: onDragDone))
  )
)
let win = newWindow(WindowOptions(width: 120, height: 80,
  hidden: true, content: uiContent))
let native = fake.windows[^1].fakeSurface()
doAssert native.frame()

# A press released before the threshold stays an ordinary click and never
# evaluates the lazy source provider.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 20, y: 20, button: 0, clicks: 1))
doAssert clickCalls == 1
doAssert providerCalls == 0

# Crossing four DIPs starts the native drag once. Releasing it is not a click.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 23, y: 20)) == false
doAssert providerCalls == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 20))
doAssert providerCalls == 1
fake.step()
let request = native.activeDataDrag()
doAssert request != nil
doAssert request.data.formats() == @[transfer.Text]
doAssert request.preview.len > 0
doAssert request.hotX == 20
doAssert request.hotY == 20
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 24, y: 20, button: 0, clicks: 1))
doAssert clickCalls == 1
native.finishDataDrag(transfer.Result(operation: transfer.Copy))
doAssert doneResult.operation == transfer.Copy
doAssert not doneResult.canceled
doAssert doneCalls == 1

# Immediate validation failures are reported through Done too.
data = transfer.Data()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 20))
doAssert providerCalls == 2
doAssert doneCalls == 2
doAssert doneResult.err != nil
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 24, y: 20, button: 0, clicks: 1))
doAssert clickCalls == 1

win.destroy()
loop.shutdown()
