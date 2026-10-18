import std/assertions
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
