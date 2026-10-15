import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

func relativeX(layout: ui.LayoutResult; child, parent: ui.Element): float32 =
  layout.bounds(child).x - layout.bounds(parent).x

block direction_inheritance_and_rows:
  let c = ui.newContext()
  var root, row, first, second, reverseRow, reverseFirst, reverseSecond: ui.Element
  var ltrRow, ltrFirst, lateRow, lateChild: ui.Element
  var directions: array[2, ui.Direction]
  c.build(proc(ctx: ui.Context) =
    root = ctx.column().size(300, 140).direction(ui.Direction.RightToLeft)
    discard root.children(proc() =
      directions[0] = ctx.direction()
      row = ctx.row().size(100, 20).gapX(5)
      discard row.children(proc() =
        first = ctx.box().size(20, 10).shrink(0)
        second = ctx.box().size(30, 10).shrink(0)
      )
      reverseRow = ctx.row().size(100, 20).gapX(5).reverse()
      discard reverseRow.children(proc() =
        reverseFirst = ctx.box().size(20, 10).shrink(0)
        reverseSecond = ctx.box().size(30, 10).shrink(0)
      )
      ltrRow = ctx.row().size(100, 20).direction(ui.Direction.LeftToRight)
      discard ltrRow.children(proc() =
        directions[1] = ctx.direction()
        ltrFirst = ctx.box().size(20, 10).shrink(0)
      )
      lateRow = ctx.row().size(100, 20).paddingStart(10)
      discard lateRow.children(proc() =
        lateChild = ctx.box().size(20, 10).shrink(0)
      )
      discard lateRow.direction(ui.Direction.RightToLeft)
    )
  )
  let layout = c.layout(300, 140)
  doAssert directions[0] == ui.Direction.RightToLeft
  doAssert directions[1] == ui.Direction.LeftToRight
  doAssert layout.relativeX(first, row) == 80
  doAssert layout.relativeX(second, row) == 45
  doAssert layout.relativeX(reverseFirst, reverseRow) == 0
  doAssert layout.relativeX(reverseSecond, reverseRow) == 25
  doAssert layout.relativeX(ltrFirst, ltrRow) == 0
  doAssert layout.relativeX(lateChild, lateRow) == 70
  c.close()

block rtl_column_alignment_and_logical_edges:
  let c = ui.newContext()
  var column, startBox, endBox, centered, stretched: ui.Element
  var padded, paddedChild, physical, physicalChild, overridden: ui.Element
  var overriddenChild, bordered, borderChild: ui.Element
  c.build(proc(ctx: ui.Context) =
    column = ctx.column().size(300, 100)
      .direction(ui.Direction.RightToLeft).alignItems(ui.Align.Start)
    discard column.children(proc() =
      startBox = ctx.box().size(30, 10)
      endBox = ctx.box().size(30, 10).alignSelf(ui.Align.End)
      centered = ctx.box().size(30, 10).alignSelf(ui.Align.Center)
      stretched = ctx.box().height(10).alignSelf(ui.Align.Stretch)
        .marginStart(20)
    )
    padded = ctx.row().size(100, 20).paddingStart(10).paddingEnd(20)
      .direction(ui.Direction.RightToLeft)
    discard padded.children(proc() = paddedChild = ctx.box().size(10, 10))
    physical = ctx.row().size(100, 20).padding(0, 0, 0, 7)
      .direction(ui.Direction.RightToLeft)
    discard physical.children(proc() = physicalChild = ctx.box().size(10, 10))
    overridden = ctx.row().size(100, 20).paddingStart(12)
      .padding(0, 0, 0, 7).direction(ui.Direction.RightToLeft)
    discard overridden.children(proc() =
      overriddenChild = ctx.box().size(10, 10)
    )
    bordered = ctx.row().size(100, 20).borderStartWidth(5)
      .direction(ui.Direction.RightToLeft)
    discard bordered.children(proc() = borderChild = ctx.box().size(10, 10))
  )
  let layout = c.layout(300, 120)
  doAssert layout.relativeX(startBox, column) == 270
  doAssert layout.relativeX(endBox, column) == 0
  doAssert layout.relativeX(centered, column) == 135
  doAssert layout.relativeX(stretched, column) == 0
  doAssert layout.bounds(stretched).w == 280
  doAssert layout.relativeX(paddedChild, padded) == 80
  doAssert layout.relativeX(physicalChild, physical) == 90
  doAssert layout.relativeX(overriddenChild, overridden) == 90
  doAssert layout.relativeX(borderChild, bordered) == 85
  c.close()

block rtl_grid_and_absolute_edges:
  let c = ui.newContext()
  var grid, first, second, wide, sparseGrid, sparseCell: ui.Element
  var parent, start, finish, left, staticChild, percentStart,
    percentEnd, lateParent, insetChild: ui.Element
  c.build(proc(ctx: ui.Context) =
    grid = ctx.grid().size(300, 40)
      .columnTracks(ui.fixed(100), ui.fixed(100), ui.fixed(100))
      .justifyItems(ui.Align.Start).direction(ui.Direction.RightToLeft)
    discard grid.children(proc() =
      first = ctx.box().size(20, 10)
      second = ctx.box().size(20, 10)
      wide = ctx.box().size(20, 10).columnSpan(2).justifySelf(ui.Align.End)
    )
    sparseGrid = ctx.grid().size(300, 30)
      .columnTracks(ui.fixed(50), ui.fixed(50)).justify(ui.Align.Start)
      .direction(ui.Direction.RightToLeft)
    discard sparseGrid.children(proc() =
      sparseCell = ctx.box().size(10, 10)
    )
    parent = ctx.box().size(100, 40).direction(ui.Direction.RightToLeft)
    discard parent.children(proc() =
      start = ctx.box().size(10, 10).absolute().startInset(6)
      finish = ctx.box().size(10, 10).absolute().endInset(6)
      left = ctx.box().size(10, 10).absolute().left(6)
      staticChild = ctx.box().size(10, 10).absolute()
      percentStart = ctx.box().size(10, 10).absolute().startPercent(10)
      percentEnd = ctx.box().size(10, 10).absolute().endPercent(10)
    )
    lateParent = ctx.box().size(100, 40)
    discard lateParent.children(proc() =
      insetChild = ctx.box().size(10, 10).absolute().endInset(6).top(3)
        .direction(ui.Direction.RightToLeft)
    )
  )
  let layout = c.layout(300, 100)
  doAssert layout.relativeX(first, grid) == 280
  doAssert layout.relativeX(second, grid) == 180
  doAssert layout.relativeX(wide, grid) == 100
  doAssert layout.relativeX(sparseCell, sparseGrid) == 250
  doAssert layout.relativeX(start, parent) == 84
  doAssert layout.relativeX(finish, parent) == 6
  doAssert layout.relativeX(left, parent) == 6
  doAssert layout.relativeX(staticChild, parent) == 90
  doAssert layout.relativeX(percentStart, parent) == 80
  doAssert layout.relativeX(percentEnd, parent) == 10
  doAssert layout.relativeX(insetChild, lateParent) == 6
  c.close()

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui direction test"))
app.initialized = true
app.handleReady()

var alignment = ui.Align.Start
let uiContent = ui.newContent(proc(ctx: ui.Context) =
  let panel = ctx.box().size(200, 60).background(ui.rgb(255, 255, 255))
  discard panel.children(proc() =
    discard ctx.text("Hello").size(200, 40).textSize(20)
      .textAlign(alignment).direction(ui.Direction.RightToLeft)
      .textColor(ui.rgb(0, 0, 0))
  )
)
let win = newWindow(WindowOptions(width: 200, height: 60, hidden: true,
  content: uiContent))
let nativeSurface = fake.windows[^1].surface
doAssert nativeSurface.frame()

proc inkBounds(): tuple[lo, hi: int] =
  result.lo = high(int)
  result.hi = -1
  for y in 0..<60:
    for x in 0..<200:
      let pixel = nativeSurface.pixel(x, y)
      if pixel[3] > 0 and pixel[0] < 100 and pixel[1] < 100 and pixel[2] < 100:
        result.lo = min(result.lo, x)
        result.hi = max(result.hi, x)

var ink = inkBounds()
doAssert ink.lo > 100
alignment = ui.Align.End
discard nativeSurface.send(platform.SurfaceEvent(kind: platform.surfaceResize))
doAssert nativeSurface.frame()
ink = inkBounds()
doAssert ink.hi < 100

win.destroy()
loop.shutdown()
