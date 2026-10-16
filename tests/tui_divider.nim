import std/assertions

include "../src/mynim.nim"
import mynim/ui as ui

let context = ui.newContext()
var verticalRule, horizontalRule: ui.Element
context.build(proc(ctx: ui.Context) =
  discard ctx.row().size(100, 20).children(proc() =
    verticalRule = ctx.divider()
  )
)
var layout = context.layout(100, 20)
var ruleBounds = layout.bounds(verticalRule)
doAssert ruleBounds.w == 1 and ruleBounds.h == 20

context.build(proc(ctx: ui.Context) =
  discard ctx.column().size(20, 100).children(proc() =
    horizontalRule = ctx.divider()
  )
)
layout = context.layout(20, 100)
ruleBounds = layout.bounds(horizontalRule)
doAssert ruleBounds.w == 20 and ruleBounds.h == 1
context.close()
