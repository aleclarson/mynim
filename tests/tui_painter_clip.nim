import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block painter_clip_uses_surface_scale_and_composes_with_transform:
  let context = ui.newContext()
  var painterScale = 0'f32
  context.build(proc(ctx: ui.Context) =
    discard ctx.box().size(20, 10).draw(proc(painter: var ui.Painter;
        rect: ui.Rect) =
      painterScale = painter.scale()
      painter.transform(ui.translation(3, 4), rect.x, rect.y,
          proc(transformed: var ui.Painter) =
        transformed.clip(rect, 2, proc(clipped: var ui.Painter) =
          clipped.fill(rect, ui.rgb(40, 80, 120), 0)
        )
      )
    )
  )

  let frame = context.layout(ui.Rect(x: 10, y: 15, w: 80, h: 60))
    .paintScene(2)
  doAssert painterScale == 2
  doAssert frame.ops.len == 3
  let clip = frame.ops[0]
  doAssert clip.kind == scene.opPushClip
  doAssert clip.rect == scene.Rect(x: 0, y: 0, w: 40, h: 20)
  doAssert clip.radii == [4'f32, 4, 4, 4]
  let (clipX, clipY) = clip.transform.point(0, 0)
  doAssert abs(clipX - 6) < 0.001 and abs(clipY - 8) < 0.001
  doAssert frame.ops[1].kind == scene.opFill
  doAssert frame.ops[2].kind == scene.opPopClip
  context.close()
