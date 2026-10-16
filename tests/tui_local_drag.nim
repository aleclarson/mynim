import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

var clicks = 0
var dropped: seq[string]
var numberDrops = 0
var over = false
var dragging = false
var nativeNumberOver = false
var nativeDragging = false
let uiContent = ui.newContent(proc(c: ui.Context) =
  discard c.column().size(500, 260).gap(10).padding(10).children(proc() =
    discard c.row().size(480, 110).gap(10).padding(10).children(proc() =
      let source = c.box().size(80, 100).onClick(proc() = inc clicks)
        .drag("hello")
      dragging = source.dragging()
      let target = c.box().size(150, 100)
      over = target.dragOver(string).over
      let incoming = target.drop(string)
      if incoming.ok:
        dropped.add(incoming.value)
      let numbers = c.box().size(150, 100)
      nativeNumberOver = numbers.dragOver(int).over
      if numbers.drop(int).ok:
        inc numberDrops
    )
    discard c.row().size(480, 100).padding(10).children(proc() =
      let source = c.box().size(80, 80).drag(42)
        .dragData(transfer.textData("native typed drag"))
      nativeDragging = source.dragging()
    )
  )
)

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "local drag test"))
app.initialized = true
app.handleReady()
let win = newWindow(WindowOptions(width: 500, height: 260,
  hidden: true, content: uiContent))
let native = fake.windows[^1].fakeSurface()
doAssert native.frame()

# Movement below four DIPs remains a click.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
discard native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 22, y: 21))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 22, y: 21, button: 0, clicks: 1))
doAssert clicks == 1
doAssert dropped.len == 0

# A four-DIP move starts the local drag; the accepted inner target sees it.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 20))
doAssert native.frame()
doAssert dragging
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 110, y: 20))
doAssert native.frame()
doAssert over
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 110, y: 20, button: 0, clicks: 1))
doAssert native.frame()
doAssert dropped == @["hello"]
doAssert not over
doAssert not dragging
doAssert clicks == 1
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert dropped.len == 1

# A string drag is not accepted by the number target, and Escape cancels.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 20))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 270, y: 20))
doAssert native.frame()
doAssert not over
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 270, y: 20, button: 0))
doAssert native.frame()
doAssert numberDrops == 0
doAssert dropped.len == 1

doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 20, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 20))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 110, y: 20))
doAssert native.frame()
doAssert over
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyEscape))
doAssert native.frame()
doAssert not dragging
doAssert not over
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 110, y: 20, button: 0))
doAssert native.frame()
doAssert dropped.len == 1
doAssert clicks == 1

# A native drag carries its typed value through the process-local session.
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: 20, y: 140, button: 0))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerMove,
  x: 24, y: 140))
fake.step()
let request = native.activeDataDrag()
doAssert request != nil
doAssert native.frame()
doAssert nativeDragging
let nativeOver = platform.DataDragEvent(session: request.session,
  offer: transfer.Offer(operations: transfer.Copy,
    suggested: transfer.Copy))
doAssert native.send(platform.SurfaceEvent(kind: platform.dataDragOver,
  x: 270, y: 20, drag: nativeOver))
doAssert nativeOver.operation == transfer.Copy
doAssert native.frame()
doAssert nativeNumberOver
let nativeDrop = platform.DataDragEvent(session: request.session,
  offer: transfer.Offer(operations: transfer.Copy,
    suggested: transfer.Copy))
doAssert native.send(platform.SurfaceEvent(kind: platform.dataDrop,
  x: 270, y: 20, drag: nativeDrop))
doAssert nativeDrop.operation == transfer.Copy
doAssert nativeDrop.formats.len == 0
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: 270, y: 20, button: 0))
doAssert native.frame()
doAssert numberDrops == 1
native.finishDataDrag(transfer.Result(operation: transfer.Copy))
doAssert not nativeDragging
doAssert numberDrops == 1

win.destroy()
loop.shutdown()
