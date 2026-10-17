import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block painter_text:
  let context = ui.newContext()
  let foreground = ui.rgb(30, 80, 210)
  let plainColor = ui.rgb(120, 20, 160)
  let background = ui.rgb(230, 235, 250)
  let decoration = ui.rgb(190, 40, 60)
  let first = ui.Span(text: "Native ", size: 20, weight: 700,
    color: foreground, background: background, radius: 2)
  let second = ui.Span(text: "GPU text", underline: true,
    decorationColor: decoration)
  var expected, measured, drawn, wrapped: tuple[width, height: float32]

  context.build(proc(ctx: ui.Context) =
    var theme = ui.darkTheme()
    theme.fontSize = 17
    theme.font = "monospace"
    ctx.setTheme(theme)
    expected = ctx.measureText(0, first, second)
    discard ctx.box().size(180, 100).opacity(0.5'f32)
      .draw(proc(p: var ui.Painter; r: ui.Rect) =
        measured = p.measureText(0, first, second)
        wrapped = p.measureText(40, first, second)
        drawn = p.richText(r.x + 4, r.y + 4, 0, first, second)
        p.text(r.x + 4, r.y + 60, "Plain text", 14, plainColor)
      )
  )

  let frame = context.layout(ui.Rect(x: 20, y: 30, w: 180, h: 100))
    .paintScene()
  doAssert expected == measured
  doAssert measured == drawn
  doAssert wrapped.height > measured.height

  let foregroundColor = scene.Color(r: foreground.r, g: foreground.g,
    b: foreground.b, a: foreground.a)
  let plainSceneColor = scene.Color(r: plainColor.r, g: plainColor.g,
    b: plainColor.b, a: plainColor.a)
  let theme = ui.darkTheme()
  let themeTextColor = scene.Color(r: theme.text.r, g: theme.text.g,
    b: theme.text.b, a: theme.text.a)
  let backgroundColor = scene.Color(r: background.r, g: background.g,
    b: background.b, a: background.a)
  let decorationColor = scene.Color(r: decoration.r, g: decoration.g,
    b: decoration.b, a: decoration.a)
  var foregroundGlyphs, plainGlyphs, themedGlyphs, backgrounds,
    decorations: int
  var leftmostGlyph = float32.high
  var glyphOpacity = 0'f32
  for glyph in frame.glyphs:
    leftmostGlyph = min(leftmostGlyph, glyph.x)
    if glyph.color == foregroundColor:
      inc foregroundGlyphs
    elif glyph.color == plainSceneColor:
      inc plainGlyphs
    elif glyph.color == themeTextColor:
      inc themedGlyphs
  for op in frame.ops:
    if op.kind == scene.opGlyphs:
      glyphOpacity = op.opacity
    if op.kind == scene.opFill and op.color == backgroundColor:
      inc backgrounds
      doAssert op.opacity == 0.5'f32
      doAssert op.radii == [2'f32, 2, 2, 2]
    elif op.kind == scene.opFill and op.color == decorationColor:
      inc decorations
  doAssert foregroundGlyphs > 0
  doAssert plainGlyphs > 0
  doAssert themedGlyphs > 0
  doAssert backgrounds > 0
  doAssert decorations > 0
  doAssert glyphOpacity == 0.5'f32
  doAssert leftmostGlyph < 10'f32
  context.close()
