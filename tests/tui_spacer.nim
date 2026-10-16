import std/assertions

include "../src/mynim.nim"
import mynim/ui as ui

let context = ui.newContext()
var rowSpacer: ui.Element
context.build(proc(ctx: ui.Context) =
  discard ctx.row().size(100, 20).children(proc() =
    discard ctx.box().size(10, 10)
    rowSpacer = ctx.spacer()
    discard ctx.box().size(10, 10)
  )
)
let rowLayout = context.layout(100, 20)
let rowBounds = rowLayout.bounds(rowSpacer)
doAssert rowBounds.x == 10 and rowBounds.w == 80

var columnSpacer: ui.Element
context.build(proc(ctx: ui.Context) =
  discard ctx.column().size(20, 100).children(proc() =
    discard ctx.box().size(10, 10)
    columnSpacer = ctx.spacer()
    discard ctx.box().size(10, 10)
  )
)
let columnLayout = context.layout(20, 100)
let columnBounds = columnLayout.bounds(columnSpacer)
doAssert columnBounds.y == 10 and columnBounds.h == 80
context.close()
