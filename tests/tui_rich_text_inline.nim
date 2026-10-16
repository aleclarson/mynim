import std/assertions
import mynim/internal/scene as scene
import mynim/ui as ui

block inline_action_uses_its_text_range:
  var actions = 0
  let tester = ui.newTester(proc(c: ui.Context) =
    let paragraph = c.richText(ui.Span(text: "Read "))
    discard paragraph.children(proc() =
      discard c.link("this", "").onClick(proc() = inc actions)
        .label("inline action")
    )
  , 180, 48)
  defer: tester.close()

  let (paragraphBounds, paragraphFound) = tester.find("Read this")
  let (actionBounds, actionFound) = tester.find("inline action")
  doAssert paragraphFound and actionFound
  doAssert paragraphBounds.w > actionBounds.w
  doAssert actionBounds.x >= paragraphBounds.x
  doAssert tester.click("inline action") == nil
  doAssert actions == 1

  actions = 0
  tester.clickAt(paragraphBounds.x + 1,
    paragraphBounds.y + paragraphBounds.h / 2)
  doAssert actions == 0

block inline_text_wraps_in_parent_paragraph:
  let tester = ui.newTester(proc(c: ui.Context) =
    let paragraph = c.richText(ui.Span(text: "A "))
    discard paragraph.children(proc() =
      discard c.text("long inline text that wraps over several lines")
    )
  , 76, 100)
  defer: tester.close()

  let (paragraphBounds, paragraphFound) = tester.find(
    "A long inline text that wraps over several lines")
  doAssert paragraphFound
  doAssert paragraphBounds.h > 30
  var exactParagraphLabels = 0
  for label in tester.texts():
    if label == "A long inline text that wraps over several lines":
      inc exactParagraphLabels
  doAssert exactParagraphLabels == 1

block text_and_nested_rich_text_children_share_one_paragraph:
  let tester = ui.newTester(proc(c: ui.Context) =
    let paragraph = c.text("Reading ")
    discard paragraph.children(proc() =
      let nested = c.richText(ui.Span(text: "a "))
      discard nested.children(proc() =
        discard c.text("GPU")
      )
    )
  , 180, 48)
  defer: tester.close()

  doAssert tester.hasText("Reading a GPU")
  var exactParagraphLabels = 0
  for label in tester.texts():
    if label == "Reading a GPU":
      inc exactParagraphLabels
  doAssert exactParagraphLabels == 1

block inline_child_style_is_painted_by_parent:
  let context = ui.newContext()
  var paragraph, child: ui.Element
  context.build(proc(c: ui.Context) =
    paragraph = c.richText(ui.Span(text: "A "))
    discard paragraph.children(proc() =
      child = c.text("marked").textColor(ui.rgb(10, 20, 30))
        .background(ui.rgb(220, 210, 200))
    )
  )
  let layout = context.layout(160, 40)
  let childBounds = layout.bounds(child)
  doAssert childBounds.w > 0 and childBounds.h > 0
  let frame = layout.paintScene()
  let childColor = scene.Color(r: 10, g: 20, b: 30, a: 255)
  let highlight = scene.Color(r: 220, g: 210, b: 200, a: 255)
  var coloredGlyphs, highlightedRuns: int
  for glyph in frame.glyphs:
    if glyph.color == childColor:
      inc coloredGlyphs
  for op in frame.ops:
    if op.kind == scene.opFill and op.color == highlight:
      inc highlightedRuns
  doAssert coloredGlyphs > 0
  doAssert highlightedRuns > 0
  context.close()
