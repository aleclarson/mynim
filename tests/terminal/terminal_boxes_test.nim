import std/[assertions, options]

import mynim/internal/scene as scene
import mynim/plugins/terminal/internal/view_boxes as boxes
import mynim/plugins/terminal/internal/view_paint
import mynim/plugins/terminal/internal/vt/[frame, render]
import mynim/ui as ui

block custom_terminal_glyphs:
  doAssert boxes.drawn(0x2500'u32)
  doAssert boxes.drawn(0x256d'u32)
  doAssert boxes.drawn(0x2588'u32)
  doAssert boxes.drawn(0x2592'u32)
  doAssert boxes.drawn(0xe0b0'u32)
  doAssert not boxes.drawn(0x2505'u32)
  doAssert not boxes.drawn(0x25a0'u32)
  for codepoint in 0x2580'u32 .. 0x259f'u32:
    doAssert boxes.drawn(codepoint)

  var frame = TerminalFrame(
    cols: 3,
    rows: 1,
    cursor: RenderCursor(inView: true, x: 1, y: 0, visible: true,
      style: cursorBlock),
    colors: RenderColors(
      foreground: RGB(r: 220, g: 230, b: 240),
      background: RGB(r: 10, g: 15, b: 20)),
    viewport: @[
      TerminalFrameRow(selection: some(RowSelection(start: 0, finish: 0)),
        cells: @[
        TerminalFrameCell(cell: RenderCell(wide: cellNarrow),
          codepoints: @[0x2500'u32]),
        TerminalFrameCell(cell: RenderCell(wide: cellNarrow),
          codepoints: @[0x2588'u32]),
        TerminalFrameCell(cell: RenderCell(wide: cellNarrow),
          codepoints: @[0xe0b0'u32])])])

  let context = ui.newContext()
  context.build(proc(c: ui.Context) =
    discard c.box().size(160, 36).draw(proc(painter: var ui.Painter;
        bounds: ui.Rect) =
      var options = defaultTerminalPaintOptions()
      options.paddingX = 0
      options.paddingY = 0
      options.transparent = true
      options.selectionText = ui.rgb(240, 120, 20)
      options.cursor = ui.rgb(20, 120, 240)
      options.cursorText = ui.rgb(250, 250, 250)
      painter.paintFrame(bounds, frame, options)
    )
  )
  let painted = context.layout(ui.Rect(w: 160, h: 36)).paintScene(1)
  var fillOps, pathMaskOps = 0
  var sawSelected, sawForeground, sawCursorText = false
  for op in painted.ops:
    if op.kind == scene.opFill:
      inc fillOps
      sawSelected = sawSelected or op.color == scene.Color(
        r: 240, g: 120, b: 20, a: 255)
      sawForeground = sawForeground or op.color == scene.Color(
        r: 220, g: 230, b: 240, a: 255)
      sawCursorText = sawCursorText or op.color == scene.Color(
        r: 250, g: 250, b: 250, a: 255)
    elif op.kind == scene.opGlyphs:
      inc pathMaskOps
  doAssert fillOps >= 2, "box and block glyphs should emit vector fills"
  doAssert pathMaskOps >= 1, "Powerline glyph should emit a vector path mask"
  doAssert sawSelected, "selected vector glyph should use selection text color"
  doAssert sawForeground, "unselected vector glyph should keep its foreground"
  doAssert sawCursorText, "block cursor should redraw its vector glyph"
  context.close()
