import std/[assertions, strutils]

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

block boxes_are_not_smaller_than_padding:
  let c = newContext()
  var column, columnChild, row, rowChild, grid, gridChild: Element
  c.build(proc(ctx: Context) =
    column = ctx.column().size(100, 40)
    discard column.children(proc() =
      columnChild = ctx.box().width(8).padding(0, 3, 0, 11)
    )
    row = ctx.row().size(100, 20)
    discard row.children(proc() =
      rowChild = ctx.box().width(8).padding(0, 3, 0, 11)
    )
    grid = ctx.grid().columns(1).size(100, 40)
    discard grid.children(proc() =
      gridChild = ctx.box().size(8, 8).padding(14, 3, 0, 11)
    )
  )
  let layout = c.layout(100, 100)
  doAssert layout.bounds(columnChild).w == 14
  doAssert layout.bounds(rowChild).w == 14
  doAssert layout.bounds(gridChild).w == 14
  doAssert layout.bounds(gridChild).h == 14

block flex_shrink_uses_inner_base_size:
  let c = newContext()
  var row, first, padded: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(300, 40).alignItems(Align.Start)
    discard row.children(proc() =
      first = ctx.box().basis(200)
      padded = ctx.box().basis(200).padding(0, 0, 0, 100)
    )
  )
  let layout = c.layout(300, 40)
  doAssert abs(layout.bounds(first).w - 133.333'f32) < 0.01'f32
  doAssert abs(layout.bounds(padded).w - 166.667'f32) < 0.01'f32

block flex_base_is_not_smaller_than_padding:
  let c = newContext()
  var column, padded, other: Element
  c.build(proc(ctx: Context) =
    column = ctx.column().size(100, 500)
    discard column.children(proc() =
      padded = ctx.box().height(9).padding(14, 0, 0, 0).grow()
      other = ctx.box().grow(2)
    )
  )
  let layout = c.layout(100, 500)
  doAssert abs(layout.bounds(padded).h - 176'f32) < 0.01'f32
  doAssert abs(layout.bounds(other).h - 324'f32) < 0.01'f32

block flex_base_is_not_clamped_by_minimum:
  let c = newContext()
  var column, first, minimum: Element
  c.build(proc(ctx: Context) =
    column = ctx.column().size(100, 500)
    discard column.children(proc() =
      first = ctx.box().grow()
      minimum = ctx.box().minHeight(166).grow()
    )
  )
  let layout = c.layout(100, 500)
  doAssert abs(layout.bounds(first).h - 250'f32) < 0.01'f32
  doAssert abs(layout.bounds(minimum).h - 250'f32) < 0.01'f32

block content_sized_row_respects_basis_limits:
  let c = newContext()
  var parent, fixed, capped: Element
  c.build(proc(ctx: Context) =
    parent = ctx.row()
    discard parent.children(proc() =
      fixed = ctx.row()
      discard fixed.children(proc() =
        discard ctx.box().basis(47).shrink(0)
      )
      capped = ctx.row()
      discard capped.children(proc() =
        discard ctx.box().basis(56).children(proc() =
          discard ctx.box().width(117)
        )
      )
    )
  )
  let layout = c.layout(600, 500)
  doAssert layout.bounds(fixed).w == 47
  doAssert layout.bounds(capped).w == 117

block minimum_wins_over_maximum:
  let c = newContext()
  var column, constrained, growing: Element
  c.build(proc(ctx: Context) =
    column = ctx.column().size(100, 200)
    discard column.children(proc() =
      constrained = ctx.box().height(100).minHeight(60).maxHeight(30)
      growing = ctx.box().height(10).grow()
    )
  )
  let layout = c.layout(100, 200)
  doAssert layout.bounds(constrained).h == 60
  doAssert layout.bounds(growing).h == 140

block wrapped_column_stretches_to_line:
  let c = newContext()
  var column, stretched, widest: Element
  c.build(proc(ctx: Context) =
    column = ctx.column().size(600, 500).wrap()
    discard column.children(proc() =
      stretched = ctx.row().height(10)
      widest = ctx.row().size(50, 10)
    )
  )
  let layout = c.layout(600, 500)
  doAssert layout.bounds(stretched).w == 50
  doAssert layout.bounds(widest).w == 50

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

block flex_wrap:
  let c = newContext()
  var row, first, second, third, reverseRow, reverseFirst, reverseSecond: Element
  var centeredRow, centeredFirst, centeredSecond, contentSized, contentFirst:
    Element
  var contentSecond: Element
  var column, columnFirst, columnSecond, columnThird: Element
  var reverseColumn, reverseColumnFirst, reverseColumnSecond: Element
  var growRow, growFirst, growSecond: Element
  c.build(proc(ctx: Context) =
    row = ctx.row().size(100, 50).gapX(5).gapY(3).wrap()
      .alignItems(Align.Start)
    discard row.children(proc() =
      first = ctx.box().size(60, 10)
      second = ctx.box().size(50, 20)
      third = ctx.box().size(20, 12)
    )
    reverseRow = ctx.row().size(100, 50).gapY(4).wrapReverse()
      .alignItems(Align.Start)
    discard reverseRow.children(proc() =
      reverseFirst = ctx.box().size(60, 10)
      reverseSecond = ctx.box().size(50, 20)
    )
    centeredRow = ctx.row().size(100, 50).wrap()
      .alignItems(Align.Start).alignContent(Align.Center)
    discard centeredRow.children(proc() =
      centeredFirst = ctx.box().size(60, 10)
      centeredSecond = ctx.box().size(50, 20)
    )
    contentSized = ctx.row().width(100).wrap().gapY(3)
      .alignItems(Align.Start)
    discard contentSized.children(proc() =
      contentFirst = ctx.box().size(60, 10)
      contentSecond = ctx.box().size(50, 20)
    )
    column = ctx.column().size(50, 100).gapX(4).wrap()
      .alignItems(Align.Start)
    discard column.children(proc() =
      columnFirst = ctx.box().size(20, 60)
      columnSecond = ctx.box().size(20, 50)
      columnThird = ctx.box().size(10, 30)
    )
    reverseColumn = ctx.column().size(50, 100).gapX(4).wrapReverse()
      .alignItems(Align.Start)
    discard reverseColumn.children(proc() =
      reverseColumnFirst = ctx.box().size(20, 60)
      reverseColumnSecond = ctx.box().size(20, 50)
    )
    growRow = ctx.row().size(100, 30).wrap().alignItems(Align.Start)
    discard growRow.children(proc() =
      growFirst = ctx.box().size(60, 10).grow()
      growSecond = ctx.box().size(60, 10).grow()
    )
  )
  let layout = c.layout(100, 100)
  doAssert layout.bounds(first) == Rect(x: 0, y: 0, w: 60, h: 10)
  doAssert layout.bounds(second) == Rect(x: 0, y: 13, w: 50, h: 20)
  doAssert layout.bounds(third) == Rect(x: 55, y: 13, w: 20, h: 12)
  doAssert layout.bounds(reverseFirst).y == layout.bounds(reverseRow).y + 40
  doAssert layout.bounds(reverseSecond).y == layout.bounds(reverseRow).y + 16
  doAssert layout.bounds(centeredFirst).y == layout.bounds(centeredRow).y + 10
  doAssert layout.bounds(centeredSecond).y == layout.bounds(centeredRow).y + 20
  doAssert layout.bounds(contentSized).h == 33
  doAssert layout.bounds(contentSecond).y == layout.bounds(contentSized).y + 13
  doAssert layout.bounds(columnFirst).x == layout.bounds(column).x
  doAssert layout.bounds(columnSecond).x == layout.bounds(column).x + 24
  doAssert layout.bounds(columnThird).y == layout.bounds(columnSecond).y + 50
  doAssert layout.bounds(reverseColumnFirst).x ==
    layout.bounds(reverseColumn).x + 30
  doAssert layout.bounds(reverseColumnSecond).x ==
    layout.bounds(reverseColumn).x + 6
  doAssert layout.bounds(growFirst).w == 100
  doAssert layout.bounds(growSecond).w == 100

  var measuredParent, constrainedWrap, constrainedFirst, constrainedSecond:
    Element
  c.build(proc(ctx: Context) =
    measuredParent = ctx.column().width(100)
    discard measuredParent.children(proc() =
      constrainedWrap = ctx.row().wrap().gapY(3).alignItems(Align.Start)
      discard constrainedWrap.children(proc() =
        constrainedFirst = ctx.box().size(60, 10)
        constrainedSecond = ctx.box().size(50, 20)
      )
    )
  )
  let constrainedLayout = c.layout(100, 100)
  doAssert constrainedLayout.bounds(constrainedWrap).h == 33
  doAssert constrainedLayout.bounds(measuredParent).h == 33
  doAssert constrainedLayout.bounds(constrainedSecond).y ==
    constrainedLayout.bounds(constrainedFirst).y + 13

block grid_layout:
  let c = newContext()
  var grid, a, b, header, d, e: Element
  var tracks, fixedItem, fitItem, oneFr, twoFr: Element
  var aligned, centered, selfStart, autoMargin: Element
  var spanningGrid, spanRows, rowTwoColumnTwo: Element
  var fittingRow, fittingGrid, fitLeft, fitRight: Element
  var stretchingGrid, stretchLeft, stretchRight: Element
  c.build(proc(ctx: Context) =
    grid = ctx.grid().columns(3).gap(10).padding(5).width(320)
    discard grid.children(proc() =
      a = ctx.box().height(20)
      b = ctx.box().height(40).columnSpan(2)
      header = ctx.box().height(10).columnSpan(-1)
      d = ctx.box().height(10).columnStart(3).rowStart(3)
      e = ctx.box().height(10)
    )
    tracks = ctx.grid().columnTracks(fixed(100), fitContent(), fr(), fr(2))
      .gapX(10).width(500)
    discard tracks.children(proc() =
      fixedItem = ctx.box().size(100, 10)
      fitItem = ctx.box().size(60, 10)
      oneFr = ctx.box().height(10)
      twoFr = ctx.box().height(10)
    )
    aligned = ctx.grid().columns(2).rowTracks(fixed(50)).width(200)
      .justifyItems(Align.Center).alignItems(Align.End)
    discard aligned.children(proc() =
      centered = ctx.box().size(20, 10)
      selfStart = ctx.box().size(20, 10).justifySelf(Align.Start)
        .alignSelf(Align.Start)
      autoMargin = ctx.box().size(20, 10).marginX(Auto)
    )
    spanningGrid = ctx.grid().columns(2)
      .rowTracks(fixed(30), fixed(40)).size(100, 100)
    discard spanningGrid.children(proc() =
      spanRows = ctx.box().columnStart(1).rowSpan(-1)
      rowTwoColumnTwo = ctx.box().columnStart(2).rowStart(2).size(10, 10)
    )
    fittingRow = ctx.row()
    discard fittingRow.children(proc() =
      fittingGrid = ctx.grid().columnTracks(fitContent(), fitContent())
      discard fittingGrid.children(proc() =
        fitLeft = ctx.box().size(30, 10)
        fitRight = ctx.box().size(50, 10)
      )
    )
    stretchingGrid = ctx.grid().columnTracks(fitContent(), fitContent())
      .width(200)
    discard stretchingGrid.children(proc() =
      stretchLeft = ctx.box().height(10).minWidth(30)
      stretchRight = ctx.box().height(10).minWidth(50)
    )
  )
  let layout = c.layout(600, 400)
  let column = (310'f32 - 20'f32) / 3'f32
  doAssert abs(layout.bounds(a).x - 5) < 0.01'f32
  doAssert abs(layout.bounds(a).y - 5) < 0.01'f32
  doAssert abs(layout.bounds(a).w - column) < 0.01'f32
  doAssert abs(layout.bounds(b).x - (5 + column + 10)) < 0.01'f32
  doAssert abs(layout.bounds(b).w - (2 * column + 10)) < 0.01'f32
  doAssert layout.bounds(header).y == 55
  doAssert layout.bounds(header).w == 310
  doAssert layout.bounds(d).x == 5 + 2 * column + 20
  doAssert layout.bounds(d).y == 75
  doAssert layout.bounds(e).x == 5
  doAssert layout.bounds(e).y == 75
  doAssert layout.bounds(fixedItem).w == 100
  doAssert layout.bounds(fitItem).x == 110
  doAssert layout.bounds(fitItem).w == 60
  doAssert abs(layout.bounds(oneFr).w - 310'f32 / 3'f32) < 0.01'f32
  doAssert abs(layout.bounds(twoFr).w - 620'f32 / 3'f32) < 0.01'f32
  doAssert layout.bounds(centered).x == layout.bounds(aligned).x + 40
  doAssert layout.bounds(centered).y == layout.bounds(aligned).y + 40
  doAssert layout.bounds(selfStart).x == layout.bounds(aligned).x + 100
  doAssert layout.bounds(selfStart).y == layout.bounds(aligned).y
  doAssert layout.bounds(autoMargin).x == layout.bounds(aligned).x + 40
  doAssert layout.bounds(spanRows).h == 70
  doAssert layout.bounds(rowTwoColumnTwo).x ==
    layout.bounds(spanningGrid).x + 50
  doAssert layout.bounds(rowTwoColumnTwo).y ==
    layout.bounds(spanningGrid).y + 30
  doAssert layout.bounds(fittingGrid).w == 80
  doAssert layout.bounds(fitRight).x == layout.bounds(fittingGrid).x + 30
  doAssert layout.bounds(stretchLeft).w == 90
  doAssert layout.bounds(stretchRight).w == 110

block nested_grid_layout:
  let c = newContext()
  var outer, inner, nestedFirst, nestedSecond, following: Element
  c.build(proc(ctx: Context) =
    outer = ctx.grid().columns(2).width(200)
    discard outer.children(proc() =
      inner = ctx.grid().columns(2).gapX(4)
      discard inner.children(proc() =
        nestedFirst = ctx.box().size(20, 10)
        nestedSecond = ctx.box().size(30, 12)
      )
      following = ctx.box().size(10, 10)
    )
  )
  let layout = c.layout(200, 100)
  doAssert layout.bounds(nestedFirst).w == 20
  doAssert layout.bounds(nestedSecond).x ==
    layout.bounds(inner).x + 52
  doAssert layout.bounds(following).x == layout.bounds(outer).x + 100
  doAssert layout.bounds(following).y == layout.bounds(outer).y

block grid_rows_remeasure_wrapped_text:
  let c = newContext()
  var grid, shortText, wrappedText, following: Element
  c.build(proc(ctx: Context) =
    grid = ctx.grid().columns(2).gapY(4).width(200)
    discard grid.children(proc() =
      shortText = ctx.text("one").alignSelf(Align.Start)
      wrappedText = ctx.text(repeat("word ", 30)).alignSelf(Align.Start)
      following = ctx.box().height(25)
    )
  )
  let layout = c.layout(200, 400)
  doAssert layout.bounds(wrappedText).h > layout.bounds(shortText).h
  doAssert layout.bounds(following).y >=
    layout.bounds(wrappedText).y + layout.bounds(wrappedText).h + 4
  doAssert layout.bounds(grid).h ==
    layout.bounds(following).y + 25 - layout.bounds(grid).y

block grid_track_distribution_in_spans:
  let c = newContext()
  var columns, wide, rows, tall: Element
  c.build(proc(ctx: Context) =
    columns = ctx.row().justify(Align.SpaceBetween)
      .columnTracks(fixed(20), fixed(20)).width(200).grid()
    discard columns.children(proc() =
      wide = ctx.box().height(10).columnSpan(2)
    )
    rows = ctx.row().alignItems(Align.Center)
      .rowTracks(fixed(10), fixed(10)).gapY(4).height(100)
      .alignContent(Align.SpaceBetween).grid()
    discard rows.children(proc() = tall = ctx.box().size(10, 10).rowSpan(-1))
  )
  let layout = c.layout(200, 200)
  doAssert layout.bounds(wide).w == 200
  doAssert layout.bounds(tall).h == 10
  doAssert layout.bounds(tall).y == layout.bounds(rows).y + 45

block grid_placement_bounds:
  let c = newContext()
  c.build(proc(ctx: Context) =
    let grid = ctx.grid().columns(32_767)
    discard grid.children(proc() =
      discard ctx.box().columnStart(high(int)).rowStart(high(int))
    )
  )
  doAssertRaises ValueError:
    discard c.layout(100, 100)

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
