import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block shaped_glyph_painting:
  let font = ui.Font(family: "monospace", size: 14, weight: 400)
  let metrics = font.metrics()
  doAssert metrics.ascent > 0
  doAssert metrics.descent >= 0

  let glyphs = ui.shape("AV", font)
  doAssert glyphs.len >= 2
  doAssert glyphs[0].cluster == 0
  doAssert glyphs[0].advance > 0

  let context = ui.newContext()
  context.build(proc(c: ui.Context) =
    discard c.box().size(120, 40).draw(proc(p: var ui.Painter; r: ui.Rect) =
      p.glyphs(glyphs, r.x + 2, r.y + 24, ui.rgb(30, 70, 180))
    )
  )
  for _ in 0 ..< 128:
    let frame = context.layout(ui.Rect(w: 120, h: 40)).paintScene(1)
    doAssert frame.glyphs.len > 0
    var foundGlyphOp = false
    for op in frame.ops:
      if op.kind == scene.opGlyphs:
        foundGlyphOp = true
        break
    doAssert foundGlyphOp
  context.close()
