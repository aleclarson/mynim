import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block blur_captures_the_element_subtree:
  let context = ui.newContext()
  var blurred: ui.Element
  context.build(proc(ctx: ui.Context) =
    blurred = ctx.box().size(20, 10).background(ui.rgb(240, 20, 30))
      .blur(2).opacity(0.5'f32).translate(4, 2)
    discard blurred.children(proc() =
      discard ctx.box().size(4, 3).background(ui.rgb(10, 80, 220))
    )
  )

  let frame = context.layout(80, 60).paintScene()
  doAssert frame.ops.len == 1
  let layerOp = frame.ops[0]
  doAssert layerOp.kind == scene.opImage
  doAssert layerOp.blur == 2'f32
  doAssert layerOp.opacity == 0.5'f32
  doAssert layerOp.rect == scene.Rect(x: -6, y: -6, w: 32, h: 22)
  doAssert layerOp.src == scene.Rect(w: 32, h: 22)
  doAssert layerOp.image != nil and layerOp.image.scene != nil
  let (x, y) = layerOp.transform.point(layerOp.rect.x, layerOp.rect.y)
  doAssert abs(x - (layerOp.rect.x + 4)) < 0.001
  doAssert abs(y - (layerOp.rect.y + 2)) < 0.001

  var fills = 0
  for op in layerOp.image.scene.ops:
    if op.kind == scene.opFill:
      inc fills
      doAssert op.opacity == 1'f32
  doAssert fills == 2

  let cachedLayer = layerOp.image
  context.build(proc(ctx: ui.Context) =
    blurred = ctx.box().size(20, 10).background(ui.rgb(240, 20, 30))
      .blur(2).opacity(0.5'f32).translate(4, 2)
    discard blurred.children(proc() =
      discard ctx.box().size(4, 3).background(ui.rgb(10, 80, 220))
    )
  )
  let nextFrame = context.layout(80, 60).paintScene()
  doAssert nextFrame.ops.len == 1
  doAssert nextFrame.ops[0].image == cachedLayer
  context.close()

block oversized_blur_falls_back_to_regular_paint:
  let context = ui.newContext()
  var blurred: ui.Element
  context.build(proc(ctx: ui.Context) =
    blurred = ctx.box().size(20, 20).background(ui.rgb(240, 20, 30))
      .blur(2000)
    discard blurred.children(proc() =
      discard ctx.box().size(4, 3).background(ui.rgb(10, 80, 220))
    )
  )
  let frame = context.layout(80, 60).paintScene()
  doAssert frame.ops.len == 2
  for op in frame.ops:
    doAssert op.kind == scene.opFill
    doAssert op.blur == 0
  context.close()
