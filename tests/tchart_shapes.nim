import std/assertions
import mynim/internal/scene as scene
import mynim/ui
import mynim/ui/chart

let context = newContext()
context.build(proc(ctx: Context) =
  discard ctx.box().size(100, 100).draw(proc(p: var Painter; r: ui.Rect) =
    let xs = [0'f32, 0.5'f32, 1'f32]
    let ys = [0.1'f32, 0.9'f32, 0.4'f32]
    for curve in [curveLinear, curveMonotone,
        curveStepAfter, curveStepBefore, curveStep]:
      p.strokePath(line(r, xs, ys, curve), 2, rgb(20, 30, 40))

    p.fillPath(area(r, xs, [], ys, curveMonotone),
      rgb(100, 30, 20))
    let splitXs = [0'f32, 0.25'f32, 0.5'f32, 0.75'f32, 1'f32]
    let splitLow = [0.1'f32, 0.2'f32, 0.3'f32, 0.4'f32, 0.5'f32]
    let splitHigh = [0.5'f32, 0.6'f32, float32(NaN), 0.7'f32, 0.9'f32]
    p.fillPath(area(r, splitXs, splitLow, splitHigh),
      rgb(40, 100, 20))

    let slices = pie([1.0, 2.0, 3.0], 0.03)
    p.fillPath(sector(r.x + 50, r.y + 50, 0, 30, slices[0]),
      rgb(10, 90, 130))
    p.fillPath(sector(r.x + 50, r.y + 50, 12, 30, slices[1]),
      rgb(130, 90, 10))

    let short = newPath().moveTo(r.x + 10, r.y + 10)
      .lineTo(r.x + 20, r.y + 10).trim(0, 0.5)
    p.strokePathGradient(short, 20, LinearGradient(
      fromColor: rgb(0, 160, 100), toColor: rgb(100, 40, 200), angle: 90))
  )
)

let frame = context.layout(100, 100).paintScene()
doAssert frame.ops.len == 10
doAssert frame.glyphs.len == 10
doAssert frame.maskAtlas != nil
for op in frame.ops:
  doAssert op.kind == scene.opGlyphs
  doAssert op.last == op.first + 1

# A trimmed gradient stroke fades both endpoints when its kept length is
# shorter than its width, matching the solid stroke behavior.
doAssert frame.ops[^1].color.a > 0 and frame.ops[^1].color.a < 255
doAssert frame.ops[^1].color2.a > 0 and frame.ops[^1].color2.a < 255

let emptyContext = newContext()
emptyContext.build(proc(ctx: Context) =
  discard ctx.box().size(20, 20).draw(proc(p: var Painter; r: ui.Rect) =
    p.fillPath(line(r, [], [], curveLinear), rgb(255, 0, 0))
    p.fillPath(area(r, [], [], [], curveLinear), rgb(0, 255, 0))
    p.fillPath(sector(10, 10, 0, 5,
      PieSlice(start: 1, `end`: 1)), rgb(0, 0, 255))
  )
)
doAssert emptyContext.layout(20, 20).paintScene().ops.len == 0

echo "chart shape scene tests passed"
