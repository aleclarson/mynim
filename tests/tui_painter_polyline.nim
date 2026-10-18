import std/[assertions, math]
import mynim/internal/scene as scene
import mynim/ui

block finite_runs_draw_and_single_points_do_not:
  let context = newContext()
  context.build(proc(ctx: Context) =
    discard ctx.box().size(60, 30).draw(proc(p: var Painter; rect: ui.Rect) =
      let points = [
        [rect.x + 2, rect.y + 3],
        [rect.x + 18, rect.y + 5],
        [float32(Inf), rect.y + 10],
        [rect.x + 28, rect.y + 18],
        [rect.x + 48, rect.y + 20],
        [float32(Inf), rect.y + 22],
        [rect.x + 55, rect.y + 24]]
      p.strokePolyline(points, 2, rgb(200, 30, 60))
    )
  )
  let frame = context.layout(60, 30).paintScene()
  doAssert frame.ops.len == 1
  doAssert frame.ops[0].kind == scene.opGlyphs
  doAssert frame.glyphs.len == 1
  context.close()

block opaque_gpu_polyline_uses_segment_capsules:
  let context = newContext()
  context.build(proc(ctx: Context) =
    discard ctx.box().size(60, 30).draw(proc(p: var Painter; rect: ui.Rect) =
      let points = [
        [rect.x + 2, rect.y + 3],
        [rect.x + 18, rect.y + 5],
        [float32(Inf), rect.y + 10],
        [rect.x + 28, rect.y + 18],
        [rect.x + 48, rect.y + 20],
        [float32(Inf), rect.y + 22],
        [rect.x + 55, rect.y + 24]]
      p.strokePolyline(points, 2, rgb(200, 30, 60))
    )
  )
  let frame = context.layout(60, 30).paintScene(gpuFastPaths = true)
  doAssert frame.ops.len == 2
  doAssert frame.ops[0].kind == scene.opFill
  doAssert frame.ops[0].rect.x == -1
  doAssert frame.ops[0].rect.y == -1
  doAssert frame.ops[0].rect.h == 2
  doAssert abs(frame.ops[0].rect.w - (sqrt(260'f32) + 2)) < 0.001
  doAssert frame.ops[0].radii == [1'f32, 1, 1, 1]
  doAssert frame.ops[0].transform.x == 2
  doAssert frame.ops[0].transform.y == 3
  doAssert frame.ops[1].kind == scene.opFill
  context.close()

block translucent_gpu_polyline_keeps_single_path_mask:
  let context = newContext()
  context.build(proc(ctx: Context) =
    discard ctx.box().size(40, 20).draw(proc(p: var Painter; rect: ui.Rect) =
      p.strokePolyline([[rect.x + 2, rect.y + 3],
                        [rect.x + 18, rect.y + 5]], 2,
        rgba(200, 30, 60, 0.5))
    )
  )
  let frame = context.layout(40, 20).paintScene(gpuFastPaths = true)
  doAssert frame.ops.len == 1
  doAssert frame.ops[0].kind == scene.opGlyphs
  context.close()

block isolated_points_draw_nothing:
  let context = newContext()
  context.build(proc(ctx: Context) =
    discard ctx.box().size(60, 30).draw(proc(p: var Painter; rect: ui.Rect) =
      let points = [[rect.x + 2, rect.y + 3],
                    [float32(Inf), rect.y + 10],
                    [rect.x + 28, rect.y + 18]]
      p.strokePolyline(points, 2, rgb(200, 30, 60))
    )
  )
  let frame = context.layout(60, 30).paintScene()
  doAssert frame.ops.len == 0
  context.close()
