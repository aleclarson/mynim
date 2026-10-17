import mynim/ui as ui

let context = ui.newContext()
var visible, partiallyClipped, fullyClipped, outsideViewport: bool

proc build() =
  context.build(proc(ctx: ui.Context) =
    discard ctx.column().size(100, 100).children(proc() =
      visible = ctx.box().size(10, 10).inView()
      discard ctx.box().size(20, 20).clip().children(proc() =
        partiallyClipped = ctx.box().size(10, 10).margin(0, 0, 0, 15)
          .inView()
        fullyClipped = ctx.box().size(10, 10).margin(0, 0, 0, 30)
          .inView()
      )
      discard ctx.box().height(100).shrink(0)
      outsideViewport = ctx.box().size(10, 10).inView()
    )
  )

build()
doAssert not visible and not partiallyClipped and not fullyClipped
doAssert not outsideViewport
discard context.layout(100, 100)

build()
doAssert visible
doAssert partiallyClipped
doAssert not fullyClipped
doAssert not outsideViewport
discard context.layout(100, 100)
context.close()
