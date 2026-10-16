import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

let c = ui.newContext()
var rich: ui.Element
c.build(proc(ctx: ui.Context) =
  rich = ctx.richText(
    ui.Span(text: "é "),
    ui.Span(text: "report.md", size: 24, weight: 700,
      color: ui.rgb(12, 34, 56), underline: true,
      decorationColor: ui.rgb(80, 90, 100),
      background: ui.rgb(220, 230, 240), radius: 3))
    .textColor(ui.rgba(0, 0, 0, 0))
)

let layout = c.layout(240, 60)
let bounds = layout.bounds(rich)
doAssert bounds.h >= 24
let frame = layout.paintScene()

let textColor = scene.Color(r: 12, g: 34, b: 56, a: 255)
let backgroundColor = scene.Color(r: 220, g: 230, b: 240, a: 255)
let decorationColor = scene.Color(r: 80, g: 90, b: 100, a: 255)
var coloredGlyphs, backgrounds, decorations: int
for glyph in frame.glyphs:
  if glyph.color == textColor:
    inc coloredGlyphs
for op in frame.ops:
  if op.kind == scene.opFill and op.color == backgroundColor:
    inc backgrounds
    doAssert op.radii == [3'f32, 3, 3, 3]
  elif op.kind == scene.opFill and op.color == decorationColor:
    inc decorations
doAssert coloredGlyphs > 0
doAssert backgrounds > 0
doAssert decorations > 0
