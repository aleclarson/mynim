## Layout, axes, and marks for native UI charts.

import mynim/ui as ui
import ./scales

type
  Side* {.pure.} = enum
    ## The side of a plot on which an axis is shown.
    left
    right
    top
    bottom

  TickLabel* = proc(side: Side; tick: Tick) {.closure.}

  Axes* = object
    ## Ticks shown along each edge of a plot.
    left*, right*, top*, bottom*: seq[Tick]
    ## Builds a tick label; nil uses the tick's own label as no-wrap text.
    label*: TickLabel

proc stableSortTicks(ticks: openArray[Tick]; vertical: bool): seq[Tick] =
  result = @ticks
  proc position(tick: Tick): float32 =
    if vertical: 1 - tick.at else: tick.at
  for i in 1 ..< result.len:
    let item = result[i]
    let itemPosition = position(item)
    var j = i
    while j > 0 and position(result[j - 1]) > itemPosition:
      result[j] = result[j - 1]
      dec j
    result[j] = item

proc chartAxis(c: ui.Context; side: Side; ticks: openArray[Tick];
               label: TickLabel): ui.Element =
  let vertical = side in {Side.left, Side.right}
  let sorted = stableSortTicks(ticks, vertical)
  result = if vertical: c.column() else: c.row()
  discard result.children(proc() =
    var previous = 0'f32
    for tick in sorted:
      var position = if vertical: 1 - tick.at else: tick.at
      if position < -1e-4 or position > 1 + 1e-4:
        continue
      position = max(previous, min(1'f32, position))
      discard c.box().basis(0).grow(position - previous)
      let slot = case side
        of Side.left:
          c.row().height(0).alignItems(ui.Align.Center).justify(ui.Align.End)
        of Side.right:
          c.row().height(0).alignItems(ui.Align.Center)
        of Side.top:
          c.column().width(0).alignItems(ui.Align.Center).justify(ui.Align.End)
        of Side.bottom:
          c.column().width(0).alignItems(ui.Align.Center)
      let labelSide = side
      let labelTick = tick
      discard slot.children(proc() =
        if label != nil:
          label(labelSide, labelTick)
        else:
          discard c.text(labelTick.label).noWrap()
      )
      previous = position
    discard c.box().basis(0).grow(1 - previous)
  )

proc plot*(c: ui.Context; axes: Axes;
           build: proc(area: ui.Element) {.closure.}): ui.Element =
  ## Builds a grid with axis labels around the central plot area.
  var columns = @[ui.fr()]
  var rows = @[ui.fr()]
  var plotColumn = 1
  var plotRow = 1
  if axes.left.len > 0:
    columns.insert(ui.fitContent(), 0)
    plotColumn = 2
  if axes.right.len > 0:
    columns.add(ui.fitContent())
  if axes.top.len > 0:
    rows.insert(ui.fitContent(), 0)
    plotRow = 2
  if axes.bottom.len > 0:
    rows.add(ui.fitContent())

  var label = axes.label
  if label == nil:
    label = proc(side: Side; tick: Tick) =
      discard side
      discard c.text(tick.label).noWrap()
  result = c.grid().columnTracks(columns).rowTracks(rows)
  discard result.children(proc() =
    let area = c.box().columnStart(plotColumn).rowStart(plotRow)
    discard area.children(proc() =
      if build != nil:
        build(area)
    )
    if axes.left.len > 0:
      discard chartAxis(c, Side.left, axes.left, label)
        .columnStart(1).rowStart(plotRow)
    if axes.right.len > 0:
      discard chartAxis(c, Side.right, axes.right, label)
        .columnStart(plotColumn + 1).rowStart(plotRow)
    if axes.top.len > 0:
      discard chartAxis(c, Side.top, axes.top, label)
        .columnStart(plotColumn).rowStart(1)
    if axes.bottom.len > 0:
      discard chartAxis(c, Side.bottom, axes.bottom, label)
        .columnStart(plotColumn).rowStart(plotRow + 1)
  )

proc percent(fraction: float32): float32 = fraction * 100

proc rect*(c: ui.Context; x, y: scales.Span): ui.Element =
  ## Places a rectangular mark across x and y fractions of the plot area.
  let x0 = min(x.lo, x.hi)
  let x1 = max(x.lo, x.hi)
  let y0 = min(y.lo, y.hi)
  let y1 = max(y.lo, y.hi)
  result = c.box().absolute().leftPercent(percent(x0))
    .widthPercent(percent(x1 - x0)).topPercent(percent(1 - y1))
    .heightPercent(percent(y1 - y0))

proc point*(c: ui.Context; x, y, width, height: float32): ui.Element =
  ## Centers a fixed-size mark on a point in the plot area.
  result = c.box().absolute().leftPercent(percent(x)).topPercent(percent(1-y))
    .size(width, height).margin(-height / 2, 0, 0, -width / 2)

proc ruleX*(c: ui.Context; x, width: float32): ui.Element =
  ## Places a vertical rule at x across the plot area.
  result = c.box().absolute().leftPercent(percent(x)).top(0).bottom(0)
    .width(width).margin(0, 0, 0, -width / 2)

proc ruleY*(c: ui.Context; y, height: float32): ui.Element =
  ## Places a horizontal rule at y across the plot area.
  result = c.box().absolute().topPercent(percent(1-y)).left(0).right(0)
    .height(height).margin(-height / 2, 0, 0, 0)

proc anchor*(c: ui.Context; x, y: float32; horizontal, vertical: ui.Align;
             build: proc() {.closure.}): ui.Element =
  ## Builds content attached to a point in the plot area.
  result = c.row().absolute().leftPercent(percent(x)).topPercent(percent(1-y))
    .size(0, 0).alignItems(vertical).children(proc() =
      discard c.column().width(0).alignItems(horizontal).children(build)
    )
