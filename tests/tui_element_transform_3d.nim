import std/assertions
import std/math

import mynim/internal/scene as scene
import mynim/ui as ui

block perspective_paint_transform_preserves_root_and_scale:
  let context = ui.newContext()
  context.build(proc(ctx: ui.Context) =
    discard ctx.box().size(200, 100).rotateY(40).perspective(400)
      .background(ui.rgb(40, 80, 120))
  )
  let layout = context.layout(ui.Rect(x: 40, y: 30, w: 400, h: 300))
  let frame = layout.paintScene(2)
  var found = false
  for op in frame.ops:
    if op.kind == scene.opFill and op.color == scene.Color(r: 40, g: 80,
        b: 120, a: 255):
      doAssert op.transform.perspective()
      let (x, y) = op.transform.point(40, 50)
      let angle = 40'f32 * PI.float32 / 180
      let divisor = 1 - sin(angle) * 80 / 400
      let expectedX = 2 * (100 - cos(angle) * 80 / divisor)
      let expectedY = 2 * (50 - 25 / divisor)
      doAssert abs(x - expectedX) < 0.01
      doAssert abs(y - expectedY) < 0.01
      found = true
  doAssert found
  context.close()

block perspective_rotation_changes_projected_bounds:
  var turn = 40'f32
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().size(200, 100).rotateY(turn).perspective(400)
      .label("front face").onClick(proc() = discard)
  , 400, 300)
  defer: tester.close()

  let (bounds, found) = tester.find("front face")
  doAssert found
  doAssert bounds.w < 200 and bounds.w > 100
  doAssert bounds.h > 100

block opposing_rotations_cancel:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().size(120, 60).rotateY(35).rotateY(-35)
      .label("flat again").onClick(proc() = discard)
  , 180, 100)
  defer: tester.close()

  let (bounds, found) = tester.find("flat again")
  doAssert found
  doAssert abs(bounds.w - 120) < 0.01
  doAssert abs(bounds.h - 60) < 0.01

block backface_hidden_removes_only_the_facing_away_element:
  var turn = 60'f32
  var frontClicks = 0
  var backClicks = 0
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().size(400, 300).children(proc() =
      discard ctx.box().absolute().left(100).top(100).size(200, 100)
        .rotateY(turn).perspective(400).backfaceHidden().label("front")
        .onClick(proc() = inc frontClicks)
      discard ctx.box().absolute().left(100).top(100).size(200, 100)
        .rotateY(turn + 180).perspective(400).backfaceHidden().label("back")
        .onClick(proc() = inc backClicks)
    )
  , 400, 300)
  defer: tester.close()

  let (frontBounds, frontFound) = tester.find("front")
  let (_, backFound) = tester.find("back")
  doAssert frontFound and not backFound
  tester.clickAt(frontBounds.x + frontBounds.w / 2,
    frontBounds.y + frontBounds.h / 2)
  doAssert frontClicks == 1 and backClicks == 0

  turn = 120
  tester.frame()
  let (_, frontFoundAfterTurn) = tester.find("front")
  let (backBounds, backFoundAfterTurn) = tester.find("back")
  doAssert not frontFoundAfterTurn and backFoundAfterTurn
  tester.clickAt(backBounds.x + backBounds.w / 2,
    backBounds.y + backBounds.h / 2)
  doAssert frontClicks == 1 and backClicks == 1

block perspective_requires_a_positive_finite_distance:
  var rejectedZero = false
  try:
    discard ui.perspective(0)
  except ValueError:
    rejectedZero = true
  doAssert rejectedZero

  var rejectedNegative = false
  try:
    discard ui.perspective(-1)
  except ValueError:
    rejectedNegative = true
  doAssert rejectedNegative
