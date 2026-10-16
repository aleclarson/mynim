import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

proc asBytes(value: string): seq[byte] =
  for ch in value:
    result.add(byte(ord(ch)))

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui drop test"))
app.initialized = true
app.handleReady()

let jsonFormat: transfer.Format = "application/vnd.mynim.test+json"
var providerCalls = 0
var dragOver = false
var currentOffer: transfer.Offer
var offerFormats: seq[transfer.Format]
var received: seq[transfer.Drop]
var accept = true
var fileOver = false
var receivedFiles: seq[string]
let dropOptions = transfer.DropOptions(
  formats: @[jsonFormat],
  operations: transfer.Copy or transfer.Move)
let data = transfer.newData(transfer.newItem(
  transfer.bytes(transfer.Text, "plain text fallback"),
  transfer.lazy(jsonFormat, proc(): tuple[data: seq[byte],
      err: ref CatchableError] =
    inc providerCalls
    (asBytes("{\"id\":7}"), nil))))
let uiContent = ui.newContent(proc(c: ui.Context) =
  discard c.column().size(220, 140).children(proc() =
    let zone = c.box().size(220, 100).disabled(not accept)
    let current = zone.dataDragOver(dropOptions)
    dragOver = current.over
    currentOffer = current.offer
    offerFormats = current.offer.formats
    let incoming = zone.dropData(dropOptions)
    if incoming.ok:
      received.add(incoming.value)
    fileOver = zone.fileDragOver()
    receivedFiles = zone.droppedFiles()
  )
)
let win = newWindow(WindowOptions(width: 240, height: 160,
  hidden: true, content: uiContent))
let native = fake.windows[^1].fakeSurface()
doAssert native.frame()

let overEvent = platform.DataDragEvent(offer: transfer.Offer(
  formats: @[transfer.Text, jsonFormat],
  operations: transfer.Copy or transfer.Move,
  suggested: transfer.Move))
doAssert native.send(platform.SurfaceEvent(kind: platform.dataDragOver,
  x: 20, y: 20, drag: overEvent))
doAssert overEvent.operation == transfer.Move
doAssert overEvent.formats == @[jsonFormat]
doAssert providerCalls == 0
doAssert native.frame()
doAssert dragOver
doAssert offerFormats == @[transfer.Text, jsonFormat]
let changedOffer = platform.DataDragEvent(offer: transfer.Offer(
  formats: @[transfer.Text, jsonFormat],
  operations: transfer.Copy or transfer.Move,
  suggested: transfer.Copy))
doAssert native.send(platform.SurfaceEvent(kind: platform.dataDragOver,
  x: 20, y: 20, drag: changedOffer))
doAssert changedOffer.operation == transfer.Copy
doAssert native.frame()
doAssert currentOffer.suggested == transfer.Copy

let dropEvent = platform.DataDragEvent(offer: transfer.Offer(
  formats: @[transfer.Text, jsonFormat],
  operations: transfer.Copy or transfer.Move,
  suggested: transfer.Move), data: data)
doAssert native.send(platform.SurfaceEvent(kind: platform.dataDrop,
  x: 20, y: 20, drag: dropEvent))
doAssert dropEvent.operation == transfer.Move
doAssert dropEvent.formats == @[jsonFormat]
doAssert native.frame()
doAssert received.len == 1
doAssert received[0].operation == transfer.Move
doAssert providerCalls == 1
let (payload, payloadErr) = received[0].data.read(jsonFormat)
doAssert payloadErr == nil
doAssert transfer.bytesToString(payload) == "{\"id\":7}"
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert received.len == 1

let mismatch = platform.DataDragEvent(offer: transfer.Offer(
  formats: @[transfer.PNG], operations: transfer.Copy))
doAssert not native.send(platform.SurfaceEvent(kind: platform.dataDragOver,
  x: 20, y: 20, drag: mismatch))
doAssert mismatch.operation == transfer.None
accept = false
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
let disabled = platform.DataDragEvent(offer: transfer.Offer(
  formats: @[jsonFormat], operations: transfer.Copy))
doAssert not native.send(platform.SurfaceEvent(kind: platform.dataDragOver,
  x: 20, y: 20, drag: disabled))
doAssert disabled.operation == transfer.None

accept = true
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.fileDragOver,
  x: 20, y: 20))
doAssert native.frame()
doAssert fileOver
doAssert native.send(platform.SurfaceEvent(kind: platform.fileDrop,
  x: 20, y: 20, files: @["/tmp/a.txt", "/tmp/b.txt"]))
doAssert native.frame()
doAssert receivedFiles == @["/tmp/a.txt", "/tmp/b.txt"]
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert receivedFiles.len == 0
doAssert not native.send(platform.SurfaceEvent(kind: platform.fileDragLeave))
discard native.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert native.frame()
doAssert not fileOver

win.destroy()
loop.shutdown()
