import std/[assertions, os, times]

import mynim/internal/scene as scene
import mynim/ui as ui

block keyed_siblings_move_from_their_previous_positions:
  var order = @["A", "B"]
  var transitioningDuringBuild = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 160), ease: ui.linear,
    position: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    transitioningDuringBuild = false
    discard ctx.column().children(proc() =
      for value in order:
        let row = ctx.box().key(value).size(120, 20).label(value)
        discard row.transition(motion)
        transitioningDuringBuild = transitioningDuringBuild or
          row.transitioning
    )
  , 180, 100)
  defer: tester.close()

  let (before, foundBefore) = tester.find("B")
  doAssert foundBefore and before.y > 0
  order = @["B", "A"]
  tester.frame()
  sleep(60)
  tester.frame()
  let (moving, foundMoving) = tester.find("B")
  doAssert foundMoving and moving.y > 0 and moving.y < before.y
  doAssert transitioningDuringBuild
  sleep(150)
  tester.frame()
  let (finished, foundFinished) = tester.find("B")
  doAssert foundFinished and abs(finished.y) < 0.01
  tester.frame()
  doAssert not transitioningDuringBuild

block parent_position_transition_moves_descendants:
  var x = 0'f32
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 160), ease: ui.linear,
    position: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().absolute().left(x).top(10).size(80, 60)
    discard parent.transition(motion)
    discard parent.children(proc() =
      discard ctx.box().size(20, 20).label("nested transition child")
    )
  , 180, 100)
  defer: tester.close()

  let (before, foundBefore) = tester.find("nested transition child")
  doAssert foundBefore
  x = 40
  tester.frame()
  sleep(60)
  tester.frame()
  let (moving, foundMoving) = tester.find("nested transition child")
  doAssert foundMoving and moving.x > before.x and moving.x < before.x + 40

block scrolling_does_not_retarget_element_position:
  let state = ui.newScrollState()
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 160), ease: ui.linear,
    position: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let viewport = ctx.scroll(state).size(80, 20)
    discard viewport.children(proc() =
      discard ctx.box().size(80, 20).shrink(0).label("first row")
        .transition(motion)
      discard ctx.box().size(80, 20).shrink(0).label("second row")
        .transition(motion)
    )
  , 80, 20)
  defer: tester.close()

  state.scrollTo(0, 10)
  tester.frame()
  let (second, foundSecond) = tester.find("second row")
  doAssert foundSecond and abs(second.y - 10) < 0.01

block size_transition_reflows_descendants:
  var width = 40'f32
  var reportsMoving = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 800), ease: ui.linear,
    size: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    reportsMoving = false
    let panel = ctx.row().absolute().left(0).top(0).size(width, 80)
      .wrap().label("transition size panel")
    discard panel.transition(motion)
    reportsMoving = panel.transitioning
    discard panel.children(proc() =
      discard ctx.box().size(30, 20).shrink(0).label("size first item")
      discard ctx.box().size(30, 20).shrink(0).label("size second item")
    )
  , 120, 100)
  defer: tester.close()

  let (beforePanel, foundBeforePanel) = tester.find("transition size panel")
  let (beforeSecond, foundBeforeSecond) = tester.find("size second item")
  doAssert foundBeforePanel and abs(beforePanel.w - 40) < 0.01
  doAssert foundBeforeSecond and beforeSecond.y > 0

  width = 80
  tester.frame()
  sleep(500)
  tester.frame()
  let (movingPanel, foundMovingPanel) = tester.find("transition size panel")
  let (movingSecond, foundMovingSecond) = tester.find("size second item")
  doAssert foundMovingPanel and movingPanel.w > 60 and movingPanel.w < 80
  doAssert foundMovingSecond and abs(movingSecond.y) < 0.01
  doAssert reportsMoving
  sleep(350)
  tester.frame()
  tester.frame()
  doAssert not reportsMoving

block size_transition_rewraps_text:
  var width = 30'f32
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 800), ease: ui.linear,
    size: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let panel = ctx.column().absolute().left(0).top(0).size(width, 160)
    discard panel.transition(motion)
    discard panel.children(proc() =
      discard ctx.text("alpha beta gamma delta epsilon zeta eta theta iota kappa")
        .label("transition size text")
    )
  , 140, 180)
  defer: tester.close()

  let (before, foundBefore) = tester.find("transition size text")
  doAssert foundBefore and before.h > 20
  width = 100
  tester.frame()
  sleep(500)
  tester.frame()
  let (moving, foundMoving) = tester.find("transition size text")
  doAssert foundMoving and moving.h < before.h

block transition_colors_mix_without_reading_pixels:
  let context = ui.newContext()
  var background = ui.rgba(0, 0, 255, 1)
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 160), ease: ui.linear)
  let view = proc(ctx: ui.Context) =
    discard ctx.box().size(50, 40).background(background).transition(motion)
  let color = proc(layout: ui.LayoutResult): scene.Color =
    for op in layout.paintScene().ops:
      if op.kind == scene.opFill:
        return op.color

  context.build(view)
  let first = color(context.layout(100, 80))
  doAssert first.b == 255 and first.r == 0
  background = ui.rgba(255, 0, 0, 1)
  context.build(view)
  discard context.layout(100, 80)
  sleep(60)
  context.build(view)
  let moving = color(context.layout(100, 80))
  doAssert moving.r > 0 and moving.r < 255
  doAssert moving.b > 0 and moving.b < 255
  sleep(150)
  context.build(view)
  let finished = color(context.layout(100, 80))
  doAssert finished.r == 255 and finished.b == 0
  context.close()

block resizing_snaps_position_transitions:
  var x = 0'f32
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 200), ease: ui.linear,
    position: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().absolute().left(x).top(0).size(20, 20)
      .label("resize transition")
      .transition(motion)
  , 100, 60)
  defer: tester.close()

  x = 50
  tester.frame()
  tester.setSize(120, 60)
  let (bounds, found) = tester.find("resize transition")
  doAssert found and abs(bounds.x - 50) < 0.01

block reduced_motion_snaps_position_transitions:
  var x = 0'f32
  let motion = ui.ElementTransition(position: true)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().absolute().left(x).top(0).size(20, 20)
      .label("reduced transition")
      .transition(motion)
  , 100, 60)
  defer: tester.close()

  tester.setPreferences(ui.Preferences(reduceMotion: true))
  x = 50
  tester.frame()
  let (bounds, found) = tester.find("reduced transition")
  doAssert found and abs(bounds.x - 50) < 0.01

block transitioning_includes_pose_motion:
  var pose = ui.Pose()
  var reportsMoving = false
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let element = ctx.box().size(20, 20).animatePose(pose, ui.Animation(
      duration: initDuration(milliseconds = 160), ease: ui.linear))
    reportsMoving = element.transitioning
  , 80, 60)
  defer: tester.close()

  pose = ui.Pose(x: 30)
  tester.frame()
  doAssert reportsMoving
