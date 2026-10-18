import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

type RecordingEffect = ref object of ui.Effect
  called: bool
  size: tuple[width, height: int]
  inset: ui.Point

method effectMargin(effect: RecordingEffect): ui.Point =
  ui.Point(x: 4, y: 2)

method paintEffect(effect: RecordingEffect; painter: var ui.Painter;
                   box: ui.Rect; content: ui.Bitmap; inset: ui.Point) =
  effect.called = true
  effect.size = content.size()
  effect.inset = inset
  let scale = painter.scale()
  painter.image(content, ui.Rect(
    x: box.x - inset.x / scale,
    y: box.y - inset.y / scale,
    w: effect.size.width.float32 / scale,
    h: effect.size.height.float32 / scale), ui.Fit.FillBox)

block custom_effect_draws_the_captured_content:
  let context = ui.newContext()
  let effect = RecordingEffect()
  var effected: ui.Element
  context.build(proc(ctx: ui.Context) =
    effected = ctx.box().size(20, 10).background(ui.rgb(240, 20, 30))
      .effect(effect).opacity(0.75'f32)
    discard effected.children(proc() =
      discard ctx.box().size(4, 3).background(ui.rgb(10, 80, 220))
    )
  )

  let frame = context.layout(80, 60).paintScene(2)
  doAssert effect.called
  doAssert effect.size == (56, 28)
  doAssert effect.inset == ui.Point(x: 8, y: 4)
  doAssert frame.ops.len == 1
  doAssert frame.ops[0].kind == scene.opImage
  doAssert frame.ops[0].rect == scene.Rect(x: -8, y: -4, w: 56, h: 28)
  doAssert frame.ops[0].src == scene.Rect(w: 56, h: 28)
  doAssert frame.ops[0].opacity == 0.75'f32
  doAssert frame.ops[0].blur == 0
  context.close()
