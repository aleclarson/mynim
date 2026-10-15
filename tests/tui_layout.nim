import std/assertions

import mynim/ui

block row_padding_gap_and_alignment:
  let c = newContext()
  var row, first, second: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(100, 40).padding(4).gap(2)
    discard row.children(proc() =
      first = ctx.box().size(20, 10)
      second = ctx.box().size(30, 12)
    )
  )
  let layout = c.layout(100, 40)
  doAssert layout.len == 3
  doAssert layout.bounds(row) == Rect(x: 0, y: 0, w: 100, h: 40)
  doAssert layout.bounds(first) == Rect(x: 4, y: 15, w: 20, h: 10)
  doAssert layout.bounds(second) == Rect(x: 26, y: 14, w: 30, h: 12)

block grow_and_shrink:
  let c = newContext()
  var container, fixed, growing, last: Element
  c.build(proc(ctx: Context) =
    container = ctx.column().size(100, 100)
    discard container.children(proc() =
      fixed = ctx.box().size(100, 20)
      growing = ctx.box().grow()
      last = ctx.box().size(100, 10)
    )
  )
  let layout = c.layout(100, 100)
  doAssert layout.bounds(fixed) == Rect(x: 0, y: 0, w: 100, h: 20)
  doAssert layout.bounds(growing) == Rect(x: 0, y: 20, w: 100, h: 70)
  doAssert layout.bounds(last) == Rect(x: 0, y: 90, w: 100, h: 10)

  var row, left, right: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(60, 20)
    discard row.children(proc() =
      left = ctx.box().size(50, 10).minWidth(0)
      right = ctx.box().size(50, 10).minWidth(0)
    )
  )
  let shrunk = c.layout(60, 20)
  doAssert shrunk.bounds(left).w == 30
  doAssert shrunk.bounds(right).x == 30
  doAssert shrunk.bounds(right).w == 30

  c.build(proc(ctx: Context) =
    container = ctx.row().size(60, 20)
    discard container.children(proc() =
      fixed = ctx.box().size(50, 10)
      last = ctx.box().size(50, 10)
    )
  )
  let minContent = c.layout(60, 20)
  doAssert minContent.bounds(fixed).w == 50
  doAssert minContent.bounds(last).x == 50

block grow_in_content_sized_column:
  let c = newContext()
  var parent, growing, content, after: Element
  c.build(proc(ctx: Context) =
    parent = ctx.column()
    discard parent.children(proc() =
      growing = ctx.column().grow()
      discard growing.children(proc() = content = ctx.box().size(20, 20))
      after = ctx.box().size(20, 10)
    )
  )
  let layout = c.layout(100, 200)
  doAssert layout.bounds(parent).h == 30
  doAssert layout.bounds(growing).h == 20
  doAssert layout.bounds(content).h == 20
  doAssert layout.bounds(after).y == 20

block justify_and_auto_margin:
  let c = newContext()
  var row, first, second: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(100, 20).justify(Align.Center)
    discard row.children(proc() =
      first = ctx.box().size(10, 10)
      second = ctx.box().size(10, 10)
    )
  )
  var layout = c.layout(100, 20)
  doAssert layout.bounds(first).x == 40
  doAssert layout.bounds(second).x == 50

  c.build(proc(ctx: Context) =
    row = ctx.row().size(100, 20)
    discard row.children(proc() =
      first = ctx.box().size(20, 10).marginX(Auto)
    )
  )
  layout = c.layout(100, 20)
  doAssert layout.bounds(first).x == 40

block reverse_direction:
  let c = newContext()
  var row, first, second, column, upper, lower, endRow, endFirst, endSecond: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(100, 20).gap(10).reverse()
    discard row.children(proc() =
      first = ctx.box().size(20, 10).margin(0, 5, 0, 0)
      second = ctx.box().size(20, 10)
    )
    column = ctx.column().size(40, 100).reverse()
    discard column.children(proc() =
      upper = ctx.box().size(10, 20)
      lower = ctx.box().size(10, 20)
    )
    endRow = ctx.row().size(100, 20).reverse().justify(Align.End)
    discard endRow.children(proc() =
      endFirst = ctx.box().size(20, 10)
      endSecond = ctx.box().size(20, 10)
    )
  )
  let layout = c.layout(100, 160)
  doAssert layout.bounds(first) == Rect(x: 75, y: 5, w: 20, h: 10)
  doAssert layout.bounds(second) == Rect(x: 45, y: 5, w: 20, h: 10)
  doAssert layout.bounds(upper) == Rect(x: 0, y: 100, w: 10, h: 20)
  doAssert layout.bounds(lower) == Rect(x: 0, y: 80, w: 10, h: 20)
  doAssert layout.bounds(endFirst) == Rect(x: 20, y: 125, w: 20, h: 10)
  doAssert layout.bounds(endSecond) == Rect(x: 0, y: 125, w: 20, h: 10)

block absolute_and_relative_positioning:
  let c = newContext()
  var parent, flow, overlay, next, start, endAnchor, half, otherHalf: Element
  var stretched, centered, moved, following, percentage: Element
  var rightBottom, relativePercent: Element
  c.build(proc(ctx: Context) =
    parent = ctx.column().width(30)
    discard parent.children(proc() =
      flow = ctx.box().size(20, 10)
      overlay = ctx.box().absolute().size(60, 60)
      next = ctx.box().size(20, 10)
    )
    let padded = ctx.box().size(36, 20).borderWidth(1).padding(5)
    discard padded.children(proc() =
      start = ctx.box().absolute().left(3).top(3).size(14, 14)
      endAnchor = ctx.box().absolute().right(3).bottom(3).size(4, 4)
      half = ctx.box().absolute().leftPercent(50).topPercent(50).size(2, 2)
      otherHalf = ctx.box().absolute().rightPercent(50).bottomPercent(50)
        .size(2, 2)
    )
    let anchors = ctx.box().size(100, 80).borderWidth(2)
    discard anchors.children(proc() =
      stretched = ctx.box().absolute().left(10).right(20).top(5).bottom(15)
      centered = ctx.box().absolute().left(0).right(0).top(0).bottom(0)
        .size(40, 30).margin(Auto)
    )
    let row = ctx.row().size(100, 40)
    discard row.children(proc() =
      moved = ctx.box().size(20, 20).top(5).left(3)
      following = ctx.box().size(20, 20)
      percentage = ctx.box().size(20, 20).leftPercent(50).topPercent(25)
      rightBottom = ctx.box().size(20, 20).right(5).bottom(3)
      relativePercent = ctx.box().size(10, 10).rightPercent(10)
        .bottomPercent(10)
    )
  )
  let layout = c.layout(200, 300)
  doAssert layout.bounds(parent).h == 20
  doAssert layout.bounds(flow).y == 0
  doAssert layout.bounds(next).y == 10
  doAssert layout.bounds(overlay) == Rect(x: 0, y: 0, w: 60, h: 60)
  doAssert layout.bounds(start) == Rect(x: 4, y: 24, w: 14, h: 14)
  doAssert layout.bounds(endAnchor) == Rect(x: 28, y: 32, w: 4, h: 4)
  doAssert layout.bounds(half) == Rect(x: 18, y: 30, w: 2, h: 2)
  doAssert layout.bounds(otherHalf) == Rect(x: 16, y: 28, w: 2, h: 2)
  doAssert layout.bounds(stretched) == Rect(x: 12, y: 47, w: 66, h: 56)
  doAssert layout.bounds(centered) == Rect(x: 30, y: 65, w: 40, h: 30)
  doAssert layout.bounds(moved) == Rect(x: 3, y: 135, w: 20, h: 20)
  doAssert layout.bounds(following) == Rect(x: 20, y: 130, w: 20, h: 20)
  doAssert layout.bounds(percentage) == Rect(x: 90, y: 140, w: 20, h: 20)
  doAssert layout.bounds(rightBottom) == Rect(x: 55, y: 127, w: 20, h: 20)
  doAssert layout.bounds(relativePercent) == Rect(x: 70, y: 131, w: 10, h: 10)

block percentages_and_limits:
  let c = newContext()
  var row, child: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(200, 100)
    discard row.children(proc() =
      child = ctx.box().widthPercent(50).heightPercent(10)
        .minHeightPercent(30).maxWidth(80)
    )
  )
  let layout = c.layout(200, 100)
  doAssert layout.bounds(child) == Rect(x: 0, y: 35, w: 80, h: 30)

block aspect_ratio:
  let c = newContext()
  var row, fromWidth, rowGrowing, column, fromHeight, columnGrowing: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(200, 100).alignItems(Align.Start)
    discard row.children(proc() =
      fromWidth = ctx.box().width(90).aspectRatio(16'f32 / 9)
      rowGrowing = ctx.box().aspectRatio(2).grow()
    )
    column = ctx.column().size(200, 100).alignItems(Align.Start)
    discard column.children(proc() =
      fromHeight = ctx.box().height(50).aspectRatio(2)
      columnGrowing = ctx.box().aspectRatio(2).grow()
    )
  )
  let layout = c.layout(200, 200)
  let wide = layout.bounds(fromWidth)
  doAssert wide.w == 90 and abs(wide.h - 50.625'f32) < 0.01'f32
  let tall = layout.bounds(fromHeight)
  doAssert tall.h == 50 and tall.w == 100
  let rowGrow = layout.bounds(rowGrowing)
  doAssert rowGrow.w == 110 and rowGrow.h == 55
  let columnGrow = layout.bounds(columnGrowing)
  doAssert columnGrow.h == 50 and columnGrow.w == 100

block stale_layout_results:
  let c = newContext()
  var element: Element
  c.build(proc(ctx: Context) = element = ctx.box().size(5, 5))
  let previous = c.layout(10, 10)
  doAssert previous.bounds(element).w == 5
  let previousElement = element

  c.build(proc(ctx: Context) = element = ctx.box().size(8, 8))
  doAssertRaises ValueError:
    discard previous.bounds(previousElement)
  let current = c.layout(10, 10)
  doAssert current.bounds(element) == Rect(x: 0, y: 0, w: 8, h: 8)
  doAssertRaises ValueError:
    discard c.layout(Rect(w: Inf.float32, h: 10))
  c.close()
  doAssertRaises ValueError:
    discard previous.bounds(previousElement)

block layout_requires_successful_build:
  let c = newContext()
  doAssertRaises ValueError:
    discard c.layout(10, 10)
  doAssertRaises ValueError:
    c.build(proc(ctx: Context) = raise newException(ValueError, "failed view"))
  doAssertRaises ValueError:
    discard c.layout(10, 10)
