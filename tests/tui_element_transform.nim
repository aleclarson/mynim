import std/assertions

import mynim/internal/scene as scene
import mynim/ui as ui

block transform_changes_paint_without_changing_layout_bounds:
  let context = ui.newContext()
  var element: ui.Element
  context.build(proc(ctx: ui.Context) =
    element = ctx.box().size(20, 10).translate(30, 5)
      .background(ui.rgb(40, 80, 120))
  )

  let layout = context.layout(ui.Rect(x: 10, y: 15, w: 100, h: 80))
  doAssert layout.bounds(element) == ui.Rect(x: 10, y: 15, w: 20, h: 10)
  let frame = layout.paintScene(2)
  var foundFill = false
  for op in frame.ops:
    if op.kind == scene.opFill and op.color == scene.Color(r: 40, g: 80,
        b: 120, a: 255):
      let (x, y) = op.transform.point(op.rect.x, op.rect.y)
      doAssert abs(x - 60) < 0.001 and abs(y - 10) < 0.001
      foundFill = true
  doAssert foundFill
  context.close()

block transformed_parent_child_hit_and_accessibility_bounds:
  var clicks = 0
  var pointer: tuple[x, y: float32, over: bool]
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().size(100, 60).translate(50, 20)
    discard parent.children(proc() =
      let child = ctx.box().size(20, 10).transformOrigin(0, 0)
        .rotate(90).label("rotated target")
      discard child.onClick(proc() =
        inc clicks
      )
      pointer = child.pointerPosition()
    )
  , 180, 100)
  defer: tester.close()

  let (bounds, found) = tester.find("rotated target")
  doAssert found
  doAssert bounds == ui.Rect(x: 40, y: 20, w: 10, h: 20)
  tester.move(45, 35)
  doAssert abs(pointer.x - 15) < 0.001
  doAssert abs(pointer.y - 5) < 0.001
  tester.clickAt(45, 35)
  doAssert clicks == 1

block transformed_clip_tracks_its_parent:
  var clicks = 0
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().size(20, 20).translate(30, 20).clip()
    discard parent.children(proc() =
      discard ctx.box().size(40, 40).onClick(proc() = inc clicks)
    )
  , 100, 80)
  defer: tester.close()

  tester.clickAt(45, 25)
  tester.clickAt(75, 25)
  doAssert clicks == 1

block draggable_offsets_follow_the_transformed_parent_axes:
  var offset = ui.Point()
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().size(80, 80).transformOrigin(0, 0).scale(2, 2)
    discard parent.children(proc() =
      discard ctx.box().size(20, 20).draggable(offset)
    )
  , 200, 200)
  defer: tester.close()

  tester.press(10, 10)
  tester.move(30, 30)
  doAssert offset == ui.Point(x: 10, y: 10)

block text_input_bounds_follow_element_transform:
  var value = "text"
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.textInput(value).size(100, 34).translate(30, 20)
      .label("transformed input")
  , 160, 80)
  defer: tester.close()

  let (bounds, found) = tester.find("transformed input")
  doAssert found and bounds.x == 30 and bounds.y == 20
  tester.clickAt(50, 35)
  doAssert tester.textInputActive()
  let (caret, active) = tester.textCaret()
  doAssert active and caret.x >= 30 and caret.y >= 20
