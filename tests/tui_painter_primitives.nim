import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block painter_primitives:
  let context = ui.newContext()
  let fillColor = ui.rgb(30, 80, 210)
  let borderColor = ui.rgb(190, 40, 60)
  let gradient = ui.LinearGradient(fromColor: ui.rgb(0, 160, 100),
    toColor: ui.rgb(100, 40, 200), angle: 90)
  context.build(proc(ctx: ui.Context) =
    discard ctx.box().size(100, 80).opacity(0.5'f32)
      .draw(proc(p: var ui.Painter; r: ui.Rect) =
        p.fill(ui.Rect(x: r.x + 2, y: r.y + 2, w: 12, h: 10),
          fillColor, 3)
        p.fillGradient(ui.Rect(x: r.x + 20, y: r.y + 2, w: 12, h: 10),
          gradient, 2)
        p.stroke(ui.Rect(x: r.x + 40, y: r.y + 2, w: 12, h: 10),
          borderColor, 2, 1.25'f32)
        p.strokeDashed(ui.Rect(x: r.x + 60, y: r.y + 2, w: 12, h: 10),
          borderColor, 2, 1)
        p.line(r.x + 5, r.y + 50, r.x + 25, r.y + 50, 2, fillColor)
        p.shadow(ui.Rect(x: r.x + 5, y: r.y + 5, w: 10, h: 8),
          2, 1, 2, 3, 1, borderColor)
      )
  )

  let frame = context.layout(ui.Rect(x: 15.25, y: 22.5, w: 100, h: 80))
    .paintScene(2)
  doAssert frame.ops.len == 6

  let solid = frame.ops[0]
  doAssert solid.kind == scene.opFill
  doAssert solid.rect == scene.Rect(x: 4, y: 4, w: 24, h: 20)
  doAssert solid.radii == [6'f32, 6, 6, 6]
  doAssert solid.color == scene.Color(r: 30, g: 80, b: 210, a: 255)
  doAssert solid.opacity == 0.5'f32

  let fillGradient = frame.ops[1]
  doAssert fillGradient.paint == scene.paintLinear
  doAssert fillGradient.rect == scene.Rect(x: 40, y: 4, w: 24, h: 20)
  doAssert fillGradient.gradient == [40'f32, 14, 64, 14]
  doAssert fillGradient.radii == [4'f32, 4, 4, 4]
  doAssert fillGradient.opacity == 0.5'f32

  let stroke = frame.ops[2]
  doAssert stroke.rect == scene.Rect(x: 80, y: 4, w: 24, h: 20)
  doAssert stroke.border == [3'f32, 3, 3, 3]
  doAssert stroke.borderColor == scene.Color(r: 190, g: 40, b: 60, a: 255)
  doAssert not stroke.dashed

  let dashed = frame.ops[3]
  doAssert dashed.border == [2'f32, 2, 2, 2]
  doAssert dashed.dashed

  let line = frame.ops[4]
  doAssert line.rect == scene.Rect(x: 10, y: 98, w: 40, h: 4)
  doAssert line.color == scene.Color(r: 30, g: 80, b: 210, a: 255)

  let shadow = frame.ops[5]
  doAssert shadow.kind == scene.opShadow
  doAssert shadow.`cast` == scene.Rect(x: 10, y: 10, w: 20, h: 16)
  doAssert shadow.rect == scene.Rect(x: 10, y: 12, w: 24, h: 20)
  doAssert shadow.castRadii == [4'f32, 4, 4, 4]
  doAssert shadow.radii == [6'f32, 6, 6, 6]
  doAssert shadow.blur == 6'f32
  doAssert shadow.opacity == 0.5'f32
  context.close()
