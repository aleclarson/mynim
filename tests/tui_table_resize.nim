import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui table resize test"))
app.initialized = true
app.handleReady()

proc newTableWindow(state: ui.ListState; rightToLeft = false):
    tuple[surface: fakeBackend.FakeSurface; window: Window] =
  let columns = [
    ui.TableColumn(title: "Name"),
    ui.TableColumn(title: "Kind", width: 100, minWidth: 60, maxWidth: 150),
    ui.TableColumn(title: "Size", width: 80, fixed: true)
  ]
  let content = ui.newContent(proc(ctx: ui.Context) =
    let table = ctx.table(state, columns, 1, proc(row, column: int) =
      discard ctx.text("Document")
    ).size(500, 100)
    if rightToLeft:
      discard table.direction(ui.Direction.RightToLeft)
  )
  let window = newWindow(WindowOptions(width: 500, height: 100,
    hidden: true, content: content))
  result = (fake.windows[^1].surface, window)

proc headerBounds(surface: fakeBackend.FakeSurface; label: string):
    platform.RectF =
  let (tree, _) = surface.accessibility()
  for node in tree.nodes:
    if node.role == platform.roleColumnHeader and node.label == label:
      return node.bounds
  raise newException(ValueError, "missing table header " & label)

proc pointer(surface: fakeBackend.FakeSurface;
             kind: platform.SurfaceEventKind; x, y: float64) =
  discard surface.send(platform.SurfaceEvent(kind: kind, x: x, y: y))

let resizeState = ui.newListState(1)
let (resizeSurface, resizeWindow) = newTableWindow(resizeState)
doAssert resizeSurface.frame()
doAssert resizeSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

let kindHeader = headerBounds(resizeSurface, "Kind")
let startX = kindHeader.x + kindHeader.w - 1
let startY = kindHeader.y + kindHeader.h / 2
pointer(resizeSurface, platform.pointerMove, startX, startY)
doAssert resizeSurface.surfaceCursor() == platform.cursorResizeEW
doAssert resizeSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: startX, y: startY))
pointer(resizeSurface, platform.pointerMove, startX + 30, startY)
doAssert resizeSurface.frame()
pointer(resizeSurface, platform.pointerUp, startX + 30, startY)
doAssert resizeSurface.frame()
doAssert resizeState.columns.widths["Kind"] == 130
doAssert resizeState.columns.widths["Name"] == 320,
  "resizing must freeze preceding flexible columns at their rendered width"
let resizedKind = headerBounds(resizeSurface, "Kind")
doAssert resizedKind.w == 130 and resizedKind.x + resizedKind.w - 1 ==
  startX + 30, "the resized edge should follow the pointer"

let minStart = resizedKind.x + resizedKind.w - 1
pointer(resizeSurface, platform.pointerDown, minStart, startY)
pointer(resizeSurface, platform.pointerMove, minStart - 130, startY)
doAssert resizeSurface.frame()
pointer(resizeSurface, platform.pointerUp, minStart - 130, startY)
doAssert resizeSurface.frame()
doAssert headerBounds(resizeSurface, "Kind").w == 60,
  "resizing must respect minWidth and the 16-DIP floor"

let fitHeader = headerBounds(resizeSurface, "Kind")
let fitX = fitHeader.x + fitHeader.w - 1
let fitY = fitHeader.y + fitHeader.h / 2
for clicks in [1, 2]:
  doAssert resizeSurface.send(platform.SurfaceEvent(
    kind: platform.pointerDown, x: fitX, y: fitY, clicks: clicks))
  doAssert resizeSurface.send(platform.SurfaceEvent(
    kind: platform.pointerUp, x: fitX, y: fitY, clicks: clicks))
doAssert resizeSurface.frame()
let fittedWidth = headerBounds(resizeSurface, "Kind").w
doAssert fittedWidth > 60 and fittedWidth <= 150,
  "double clicking the resize edge should fit its visible cell contents"

let maxHeader = headerBounds(resizeSurface, "Kind")
let maxStart = maxHeader.x + maxHeader.w - 1
pointer(resizeSurface, platform.pointerDown, maxStart, startY)
pointer(resizeSurface, platform.pointerMove, maxStart + 200, startY)
doAssert resizeSurface.frame()
pointer(resizeSurface, platform.pointerUp, maxStart + 200, startY)
doAssert resizeSurface.frame()
doAssert headerBounds(resizeSurface, "Kind").w == 150,
  "resizing must respect maxWidth"

let fixedBefore = headerBounds(resizeSurface, "Size").w
let fixedStart = headerBounds(resizeSurface, "Size")
pointer(resizeSurface, platform.pointerDown, fixedStart.x + 20, startY)
pointer(resizeSurface, platform.pointerMove, fixedStart.x + 60, startY)
pointer(resizeSurface, platform.pointerUp, fixedStart.x + 60, startY)
doAssert resizeSurface.frame()
doAssert headerBounds(resizeSurface, "Size").w == fixedBefore
resizeWindow.destroy()

let resizeRtlState = ui.newListState(1)
let (rtlSurface, rtlWindow) = newTableWindow(resizeRtlState,
  rightToLeft = true)
doAssert rtlSurface.frame()
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
let rtlKind = headerBounds(rtlSurface, "Kind")
let rtlStartX = rtlKind.x + 1
let rtlStartY = rtlKind.y + rtlKind.h / 2
pointer(rtlSurface, platform.pointerMove, rtlStartX, rtlStartY)
doAssert rtlSurface.surfaceCursor() == platform.cursorResizeEW
doAssert rtlSurface.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: rtlStartX, y: rtlStartY))
pointer(rtlSurface, platform.pointerMove, rtlStartX - 20, rtlStartY)
doAssert rtlSurface.frame()
pointer(rtlSurface, platform.pointerUp, rtlStartX - 20, rtlStartY)
doAssert rtlSurface.frame()
doAssert resizeRtlState.columns.widths["Kind"] == 120,
  "dragging the RTL column's left edge outward should widen it"
rtlWindow.destroy()
loop.shutdown()
