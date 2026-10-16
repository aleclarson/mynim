import std/assertions
import mynim/ui as ui
import mynim/ui/chart as charts

proc near(a, b: float32): bool = abs(a - b) < 0.1'f32

let context = ui.newContext()
var area, bar, dotMark, ruleXMark, ruleYMark, anchored: ui.Element
var labels: array[4, seq[ui.Element]]
var sides: set[charts.Side]
context.build(proc(ctx: ui.Context) =
  let axes = charts.Axes(
    left: @[
      charts.Tick(at: 0, label: "bottom"),
      charts.Tick(at: 1, label: "top")
    ],
    right: @[charts.Tick(at: 0.5, label: "right")],
    top: @[charts.Tick(at: 0.5, label: "top")],
    bottom: @[charts.Tick(at: 0.5, label: "bottom")],
    label: proc(side: charts.Side; tick: charts.Tick) =
      sides.incl(side)
      labels[ord(side)].add(ctx.text(tick.label).noWrap())
  )
  let chartElement = plot(ctx, axes, proc(plotArea: ui.Element) =
    area = plotArea
    bar = rect(ctx, charts.Span(lo: 0.2, hi: 0.6),
      charts.Span(lo: 0.25, hi: 0.75))
      .background(ui.rgb(30, 80, 160))
    dotMark = point(ctx, 0.6, 0.5, 8, 6)
    ruleXMark = ruleX(ctx, 0.25, 2)
    ruleYMark = ruleY(ctx, 0.75, 2)
    anchored = anchor(ctx, 0.8, 0.8, ui.Align.End, ui.Align.End, proc() =
      discard ctx.text("selection").noWrap()
    )
  )
  discard chartElement.height(180).gap(4)
)

doAssert sides == {charts.Side.left, charts.Side.right,
  charts.Side.top, charts.Side.bottom}
doAssert labels[ord(charts.Side.left)].len == 2
doAssert labels[ord(charts.Side.right)].len == 1
doAssert labels[ord(charts.Side.top)].len == 1
doAssert labels[ord(charts.Side.bottom)].len == 1

let layout = context.layout(320, 220)
let areaBounds = layout.bounds(area)
doAssert areaBounds.w > 0 and areaBounds.h > 0

let barBounds = layout.bounds(bar)
doAssert near(barBounds.x, areaBounds.x + areaBounds.w * 0.2'f32)
doAssert near(barBounds.y, areaBounds.y + areaBounds.h * 0.25'f32)
doAssert near(barBounds.w, areaBounds.w * 0.4'f32)
doAssert near(barBounds.h, areaBounds.h * 0.5'f32)

let pointBounds = layout.bounds(dotMark)
doAssert near(pointBounds.x + pointBounds.w / 2,
  areaBounds.x + areaBounds.w * 0.6'f32)
doAssert near(pointBounds.y + pointBounds.h / 2,
  areaBounds.y + areaBounds.h * 0.5'f32)

let xRuleBounds = layout.bounds(ruleXMark)
let yRuleBounds = layout.bounds(ruleYMark)
doAssert near(xRuleBounds.x + xRuleBounds.w / 2,
  areaBounds.x + areaBounds.w * 0.25'f32)
doAssert near(yRuleBounds.y + yRuleBounds.h / 2,
  areaBounds.y + areaBounds.h * 0.25'f32)

let topTick = layout.bounds(labels[ord(charts.Side.left)][0])
let bottomTick = layout.bounds(labels[ord(charts.Side.left)][1])
doAssert topTick.y < bottomTick.y
let anchorBounds = layout.bounds(anchored)
doAssert near(anchorBounds.x, areaBounds.x + areaBounds.w * 0.8'f32)
doAssert near(anchorBounds.y, areaBounds.y + areaBounds.h * 0.2'f32)

echo "chart plot layout tests passed"
