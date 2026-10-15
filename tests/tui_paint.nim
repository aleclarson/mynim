import std/assertions

import mynim/internal/scene as scene
import mynim/ui

block solid_background_border_and_pixel_snap:
  let c = newContext()
  var root, child: Element
  c.build(proc(ctx: Context) =
    root = ctx.column().size(20, 20).background(rgb(12, 34, 56))
      .radius(1, 2, 3, 4).borderWidth(1, 2, 3, 4)
      .borderColor(rgb(200, 201, 202)).borderStyle(BorderStyle.Dashed)
    discard root.children(proc() =
      child = ctx.box().size(5.25, 6.25).alignSelf(Align.Start)
        .background(rgba(10, 20, 30, 0.5))
    )
  )

  let layout = c.layout(ui.Rect(x: 10.25, y: 20.5, w: 20, h: 20))
  let frame = layout.paintScene(2, rgb(3, 4, 5))
  doAssert frame.width == 40
  doAssert frame.height == 40
  doAssert frame.scale == 2
  doAssert frame.clear == scene.Color(r: 3, g: 4, b: 5, a: 255)
  doAssert frame.ops.len == 2

  let rootOp = frame.ops[0]
  doAssert rootOp.kind == scene.opFill
  doAssert rootOp.rect == scene.Rect(x: 0, y: 0, w: 40, h: 40)
  doAssert rootOp.radii == [2'f32, 4, 6, 8]
  doAssert rootOp.border == [2'f32, 4, 6, 8]
  doAssert rootOp.continuous == defined(macosx)
  doAssert rootOp.borderColor == scene.Color(r: 200, g: 201, b: 202, a: 255)
  doAssert rootOp.dashed
  doAssert rootOp.color == scene.Color(r: 12, g: 34, b: 56, a: 255)

  let childOp = frame.ops[1]
  doAssert childOp.rect == scene.Rect(x: 8, y: 2, w: 11, h: 13)
  doAssert childOp.color == scene.Color(r: 10, g: 20, b: 30, a: 128)
  doAssert not childOp.dashed

block linear_gradient_scene:
  let c = newContext()
  var element: Element
  let fromColor = oklch(0.8, 0.3, 145)
  let toColor = oklch(0.55, 0.3, 145)
  c.build(proc(ctx: Context) =
    element = ctx.box().size(100, 20).gradient(LinearGradient(
      fromColor: fromColor, toColor: toColor, angle: 90,
      start: 0.25, stop: 0.75, oklab: true))
      .border(1, rgb(20, 30, 40))
  )
  let frame = c.layout(100, 20).paintScene()
  doAssert frame.ops.len == 1
  let op = frame.ops[0]
  doAssert op.paint == scene.paintOklab
  doAssert op.color == scene.Color(r: fromColor.r, g: fromColor.g,
                                   b: fromColor.b, a: fromColor.a)
  doAssert op.color2 == scene.Color(r: toColor.r, g: toColor.g,
                                    b: toColor.b, a: toColor.a)
  doAssert abs(op.gradient[0] - 25) < 0.001
  doAssert abs(op.gradient[1] - 10) < 0.001
  doAssert abs(op.gradient[2] - 75) < 0.001
  doAssert abs(op.gradient[3] - 10) < 0.001
  doAssert op.border == [1'f32, 1, 1, 1]
  doAssert frame.wide.len == 1
  doAssert frame.wide[0].`set` == (scene.wideColor or scene.wideColor2)
  doAssert op.wide == 1

  c.build(proc(ctx: Context) =
    element = ctx.box().size(100, 20)
      .gradient(rgb(0, 0, 0), rgb(255, 255, 255), 90)
      .background(rgb(12, 34, 56))
  )
  let solid = c.layout(100, 20).paintScene().ops[0]
  doAssert solid.paint == scene.paintSolid
  doAssert solid.color == scene.Color(r: 12, g: 34, b: 56, a: 255)
  doAssert solid.color2.a == 0

  c.build(proc(ctx: Context) =
    discard ctx.box().size(100, 20).gradient(LinearGradient(
      fromColor: rgb(0, 0, 0), toColor: rgb(255, 255, 255), angle: NaN))
  )
  doAssertRaises ValueError:
    discard c.layout(100, 20).paintScene()

block outer_and_inset_shadows:
  let c = newContext()
  c.build(proc(ctx: Context) =
    discard ctx.box().size(40, 20).radius(4)
      .shadow(1, 2, 3, 4, rgb(0, 0, 0))
      .background(rgb(255, 255, 255))
      .insetShadow(1, 2, 3, 1, rgb(0, 0, 0))
  )
  let frame = c.layout(40, 20).paintScene()
  doAssert frame.ops.len == 3
  let outer = frame.ops[0]
  doAssert outer.kind == scene.opShadow
  doAssert outer.rect == scene.Rect(x: -3, y: -2, w: 48, h: 28)
  doAssert outer.radii == [8'f32, 8, 8, 8]
  doAssert outer.`cast` == scene.Rect(x: 0, y: 0, w: 40, h: 20)
  doAssert outer.castRadii == [4'f32, 4, 4, 4]
  doAssert outer.blur == 3
  doAssert frame.ops[1].kind == scene.opFill
  let inner = frame.ops[2]
  doAssert inner.kind == scene.opShadow and inner.inset
  doAssert inner.rect == scene.Rect(x: 2, y: 3, w: 38, h: 18)
  doAssert abs(inner.radii[0]) == 3 and abs(inner.radii[1]) == 3 and
    abs(inner.radii[2]) == 3 and abs(inner.radii[3]) == 3
  doAssert inner.`cast` == scene.Rect(x: 0, y: 0, w: 40, h: 20)
  doAssert abs(inner.castRadii[0]) == 4 and abs(inner.castRadii[1]) == 4 and
    abs(inner.castRadii[2]) == 4 and abs(inner.castRadii[3]) == 4
  doAssert inner.blur == 3

block absolute_children_paint_above_flow:
  let c = newContext()
  c.build(proc(ctx: Context) =
    let parent = ctx.box().size(20, 20)
    discard parent.children(proc() =
      discard ctx.box().absolute().size(20, 20).background(rgb(0, 0, 255))
      discard ctx.box().size(20, 20).background(rgb(255, 0, 0))
    )
  )
  let frame = c.layout(20, 20).paintScene()
  doAssert frame.ops.len == 2
  doAssert frame.ops[0].color == scene.Color(r: 255, g: 0, b: 0, a: 255)
  doAssert frame.ops[1].color == scene.Color(r: 0, g: 0, b: 255, a: 255)

block wide_color_reaches_scene_and_deduplicates:
  let c = newContext()
  let green = oklch(0.85, 0.3, 145).alpha(0.5)
  var root, child: Element
  c.build(proc(ctx: Context) =
    root = ctx.box().size(20, 20).background(green)
    discard root.children(proc() = child = ctx.box().fill().background(green))
  )
  let frame = c.layout(20, 20).paintScene()
  doAssert frame.ops.len == 2
  doAssert frame.wide.len == 1
  doAssert frame.ops[0].wide == 1
  doAssert frame.ops[1].wide == 1
  doAssert frame.wide[0].`set` == scene.wideColor
  doAssert frame.wide[0].color[3] > 0.49 and frame.wide[0].color[3] < 0.51
  doAssert frame.wide[0].color[1] > 1 or frame.wide[0].color[0] < 0

block wide_border_uses_its_own_scene_channel:
  let c = newContext()
  let green = oklch(0.85, 0.3, 145)
  c.build(proc(ctx: Context) =
    discard ctx.box().size(20, 20).border(2, green)
  )
  let frame = c.layout(20, 20).paintScene()
  doAssert frame.ops.len == 1
  doAssert frame.ops[0].wide == 1
  doAssert frame.wide[0].`set` == scene.wideBorder
  doAssert frame.wide[0].border[1] > 1 or frame.wide[0].border[0] < 0

block border_widths_inset_layout_children:
  let c = newContext()
  var root, child: Element
  c.build(proc(ctx: Context) =
    root = ctx.row().size(100, 30).borderWidth(2, 3, 4, 5)
    discard root.children(proc() = child = ctx.box().size(10, 10))
  )
  let layout = c.layout(100, 30)
  doAssert layout.bounds(child) == ui.Rect(x: 5, y: 9, w: 10, h: 10)

block stale_layout_and_invalid_scale:
  let c = newContext()
  var element: Element
  c.build(proc(ctx: Context) = element = ctx.box().size(10, 10)
    .background(rgb(1, 2, 3)))
  let previous = c.layout(10, 10)
  doAssert previous.paintScene().ops.len == 1

  c.build(proc(ctx: Context) = element = ctx.box().size(10, 10))
  doAssertRaises ValueError:
    discard previous.paintScene()
  doAssertRaises ValueError:
    discard c.layout(10, 10).paintScene(0)
  doAssertRaises ValueError:
    discard c.layout(10, 10).paintScene(NaN.float32)

  c.close()
  doAssertRaises ValueError:
    discard previous.paintScene()

block excessive_device_size:
  let c = newContext()
  c.build(proc(ctx: Context) = discard ctx.box())
  doAssertRaises ValueError:
    discard c.layout(high(int).float32, 10).paintScene(2)
