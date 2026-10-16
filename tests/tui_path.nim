import std/assertions
import mynim/internal/scene as scene
import mynim/ui

let context = newContext()
context.build(proc(ctx: Context) =
  discard ctx.box().size(80, 50).draw(proc(p: var Painter; r: ui.Rect) =
    let area = newPath()
      .moveTo(r.x + 5, r.y + 5)
      .lineTo(r.x + 30, r.y + 8)
      .quadTo(r.x + 40, r.y + 15, r.x + 30, r.y + 25)
      .cubeTo(r.x + 20, r.y + 40, r.x + 10, r.y + 30, r.x + 5, r.y + 5)
      .close()
    p.fillPath(area, rgb(200, 20, 30))

    let curve = newPath().moveTo(r.x + 5, r.y + 40)
      .cubeTo(r.x + 20, r.y + 20, r.x + 45, r.y + 45, r.x + 60, r.y + 10)
      .trim(0.1, 0.9)
    p.strokePath(curve, 3, rgb(20, 30, 200))

    let ring = newPath().circle(r.x + 68, r.y + 25, 8)
    p.strokePathGradient(ring, 2, LinearGradient(
      fromColor: rgb(0, 160, 100), toColor: rgb(100, 40, 200), angle: 90))
  )
)

let frame = context.layout(80, 50).paintScene()
doAssert frame.ops.len == 3
doAssert frame.glyphs.len == 3
doAssert frame.maskAtlas != nil
for op in frame.ops:
  doAssert op.kind == scene.opGlyphs
  doAssert op.last == op.first + 1

echo "ui path scene tests passed"
