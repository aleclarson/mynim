import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block transform_composition_uses_dips_and_scene_scale:
  let context = ui.newContext()
  context.build(proc(ctx: ui.Context) =
    discard ctx.box().size(200, 100).draw(proc(painter: var ui.Painter;
        rect: ui.Rect) =
      let transform = ui.translation(10, 0).then(ui.scaling(2, 2))
      painter.transform(transform, rect.x, rect.y, proc(p: var ui.Painter) =
        p.fill(ui.Rect(x: rect.x + 2, y: rect.y + 3, w: 10, h: 8),
          ui.rgb(40, 80, 120), 0)
      )
    )
  )

  let frame = context.layout(ui.Rect(x: 15.25, y: 22.5, w: 200, h: 100))
    .paintScene(2)
  doAssert frame.ops.len == 1
  let op = frame.ops[0]
  doAssert op.rect == scene.Rect(x: 4, y: 6, w: 20, h: 16)
  let (x, y) = op.transform.point(op.rect.x, op.rect.y)
  doAssert x == 48 and y == 12
  context.close()

block nested_transforms_apply_inner_then_outer:
  let context = ui.newContext()
  context.build(proc(ctx: ui.Context) =
    discard ctx.box().size(100, 100).draw(proc(painter: var ui.Painter;
        rect: ui.Rect) =
      painter.transform(ui.translation(10, 0), rect.x, rect.y,
          proc(outer: var ui.Painter) =
        outer.transform(ui.rotation(90), rect.x, rect.y,
            proc(inner: var ui.Painter) =
          inner.fill(ui.Rect(x: rect.x + 1, y: rect.y, w: 4, h: 4),
            ui.rgb(200, 40, 20), 0)
        )
      )
    )
  )

  let frame = context.layout(ui.Rect(x: 12, y: 18, w: 100, h: 100))
    .paintScene(2)
  doAssert frame.ops.len == 1
  let op = frame.ops[0]
  doAssert op.rect == scene.Rect(x: 2, y: 0, w: 8, h: 8)
  let (x, y) = op.transform.point(op.rect.x, op.rect.y)
  doAssert abs(x - 20) < 0.001 and abs(y - 2) < 0.001
  context.close()

block non_finite_transform_values_are_rejected:
  doAssertRaises ValueError:
    discard ui.translation(NaN.float32, 0)
  doAssertRaises ValueError:
    discard ui.skewing(0, Inf.float32)
  doAssertRaises ValueError:
    discard ui.scaling(1e30'f32, 1).then(ui.scaling(1e30'f32, 1))
