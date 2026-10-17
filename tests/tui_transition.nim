import std/[assertions, options, os, times]

import mynim/internal/scene as scene
import mynim/ui as ui

proc findFill(frame: scene.Scene; color: scene.Color):
    tuple[op: scene.Op, found: bool] =
  for op in frame.ops:
    if op.kind == scene.opFill and op.color.r == color.r and
        op.color.g == color.g and op.color.b == color.b:
      return (op, true)

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

block exit_fade_retains_a_paint_only_subtree_until_finished:
  var present = true
  let red = ui.rgb(255, 0, 0)
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 200), ease: ui.linear,
    position: true, exit: some(ui.Motion(opacity: 0)))
  let context = ui.newContext()
  let view = proc(ctx: ui.Context) =
    let parent = ctx.column().size(100, 60)
    discard parent.children(proc() =
      if present:
        let removed = ctx.box().size(30, 20).background(red)
          .label("exiting subtree")
        discard removed.transition(motion)
        discard removed.children(proc() =
          discard ctx.box().size(40, 10).background(ui.rgb(0, 255, 0))
        )
    )

  context.build(view)
  discard context.layout(100, 60)
  present = false
  context.build(view)
  let started = context.layout(100, 60).paintScene()
  let (startingFill, foundStartingFill) = findFill(started,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert foundStartingFill
  doAssert startingFill.opacity == 0 or startingFill.opacity > 0.9

  sleep(70)
  context.build(view)
  let moving = context.layout(100, 60).paintScene()
  let (movingFill, foundMovingFill) = findFill(moving,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  let (childFill, foundChildFill) = findFill(moving,
    scene.Color(r: 0, g: 255, b: 0, a: 255))
  doAssert foundMovingFill and movingFill.opacity > 0 and
    movingFill.opacity < 1
  doAssert foundChildFill and abs(childFill.rect.w - 40) < 0.01

  sleep(170)
  context.build(view)
  let finished = context.layout(100, 60).paintScene()
  let (_, foundFinishedFill) = findFill(finished,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert not foundFinishedFill
  context.close()

block exit_collapse_keeps_siblings_out_of_flow:
  var present = true
  let red = ui.rgb(255, 0, 0)
  let blue = ui.rgb(0, 0, 255)
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 240), ease: ui.linear,
    position: true, exit: some(ui.Motion(collapse: true)))
  let context = ui.newContext()
  let view = proc(ctx: ui.Context) =
    let parent = ctx.row().size(100, 30)
    discard parent.children(proc() =
      if present:
        let removed = ctx.box().key("exit").size(30, 20).background(red)
        discard removed.transition(motion)
      discard ctx.box().key("survivor").size(20, 20).background(blue)
    )

  context.build(view)
  let before = context.layout(100, 30).paintScene()
  let (beforeBlue, foundBeforeBlue) = findFill(before,
    scene.Color(r: 0, g: 0, b: 255, a: 255))
  doAssert foundBeforeBlue and abs(beforeBlue.rect.x - 30) < 0.01

  present = false
  context.build(view)
  let started = context.layout(100, 30).paintScene()
  let (startBlue, foundStartBlue) = findFill(started,
    scene.Color(r: 0, g: 0, b: 255, a: 255))
  doAssert foundStartBlue and abs(startBlue.rect.x) < 0.01
  sleep(70)
  context.build(view)
  let moving = context.layout(100, 30).paintScene()
  let (movingRed, foundMovingRed) = findFill(moving,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  let (movingBlue, foundMovingBlue) = findFill(moving,
    scene.Color(r: 0, g: 0, b: 255, a: 255))
  doAssert foundMovingRed and movingRed.rect.w > 0 and
    movingRed.rect.w < 30
  doAssert foundMovingBlue and abs(movingBlue.rect.x) < 0.01
  context.close()

block reappearing_elements_return_from_their_exit_state:
  var present = true
  let red = ui.rgb(255, 0, 0)
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 240), ease: ui.linear,
    position: true, exit: some(ui.Motion(opacity: 0)))
  let context = ui.newContext()
  let view = proc(ctx: ui.Context) =
    let parent = ctx.column().size(80, 40)
    discard parent.children(proc() =
      if present:
        let element = ctx.box().size(30, 20).background(red)
        discard element.transition(motion)
    )

  context.build(view)
  discard context.layout(80, 40)
  present = false
  context.build(view)
  discard context.layout(80, 40)
  sleep(70)
  context.build(view)
  let leaving = context.layout(80, 40).paintScene()
  let (leavingFill, foundLeavingFill) = findFill(leaving,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert foundLeavingFill and leavingFill.opacity > 0 and
    leavingFill.opacity < 1

  present = true
  context.build(view)
  let returning = context.layout(80, 40).paintScene()
  let (returningFill, foundReturningFill) = findFill(returning,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert foundReturningFill and returningFill.opacity > 0 and
    returningFill.opacity < 1
  sleep(70)
  context.build(view)
  let returned = context.layout(80, 40).paintScene()
  let (returnedFill, foundReturnedFill) = findFill(returned,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert foundReturnedFill and returnedFill.opacity > returningFill.opacity and
    returnedFill.opacity < 1
  context.close()

block exit_is_dropped_when_its_parent_disappears:
  var parentPresent = true
  let red = ui.rgb(255, 0, 0)
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 200), ease: ui.linear,
    position: true, exit: some(ui.Motion(opacity: 0)))
  let context = ui.newContext()
  let view = proc(ctx: ui.Context) =
    if parentPresent:
      let parent = ctx.box().size(80, 40)
      discard parent.children(proc() =
        let removed = ctx.box().size(20, 20).background(red)
        discard removed.transition(motion)
      )

  context.build(view)
  discard context.layout(100, 60)
  parentPresent = false
  context.build(view)
  let frame = context.layout(100, 60).paintScene()
  let (_, foundRed) = findFill(frame,
    scene.Color(r: 255, g: 0, b: 0, a: 255))
  doAssert not foundRed
  context.close()

block new_children_enter_from_their_motion:
  var showChild = false
  var reportsMoving = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 600), ease: ui.linear,
    enter: some(ui.Motion(x: 32)))
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().absolute().left(0).top(0).size(100, 70)
    discard parent.children(proc() =
      if showChild:
        let child = ctx.box().absolute().left(0).top(0).size(20, 20)
          .label("enter motion child")
        discard child.transition(motion)
        reportsMoving = child.transitioning
    )
  , 100, 80)
  defer: tester.close()

  showChild = true
  tester.frame()
  let (start, foundStart) = tester.find("enter motion child")
  doAssert foundStart and start.x >= 31
  sleep(300)
  tester.frame()
  let (moving, foundMoving) = tester.find("enter motion child")
  doAssert foundMoving and moving.x > 0 and moving.x < start.x
  doAssert reportsMoving
  sleep(350)
  tester.frame()
  tester.frame()
  let (finished, foundFinished) = tester.find("enter motion child")
  doAssert foundFinished and abs(finished.x) < 0.01
  doAssert not reportsMoving

block resizing_snaps_enter_motion:
  var showChild = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 600), ease: ui.linear,
    enter: some(ui.Motion(x: 32)))
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().absolute().left(0).top(0).size(100, 70)
    discard parent.children(proc() =
      if showChild:
        let child = ctx.box().absolute().left(0).top(0).size(20, 20)
          .label("resized enter child")
        discard child.transition(motion)
    )
  , 100, 80)
  defer: tester.close()

  showChild = true
  tester.frame()
  let (start, foundStart) = tester.find("resized enter child")
  doAssert foundStart and start.x >= 31
  tester.setSize(110, 80)
  let (bounds, found) = tester.find("resized enter child")
  doAssert found and abs(bounds.x) < 0.01

block children_of_a_new_parent_do_not_enter:
  var showSubtree = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 400), ease: ui.linear,
    enter: some(ui.Motion(x: 40)))
  let tester = ui.newTester(proc(ctx: ui.Context) =
    if showSubtree:
      let parent = ctx.box().absolute().left(0).top(0).size(80, 60)
      discard parent.children(proc() =
        let child = ctx.box().absolute().left(0).top(0).size(20, 20)
          .label("new subtree child")
        discard child.transition(motion)
      )
  , 100, 80)
  defer: tester.close()

  showSubtree = true
  tester.frame()
  let (bounds, found) = tester.find("new subtree child")
  doAssert found and abs(bounds.x) < 0.01

block reduced_motion_keeps_fade_but_snaps_position:
  var showChild = false
  var reportsMoving = false
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 400), ease: ui.linear,
    enter: some(ui.Motion(x: 40)))
  let tester = ui.newTester(proc(ctx: ui.Context) =
    let parent = ctx.box().absolute().left(0).top(0).size(100, 70)
    discard parent.children(proc() =
      if showChild:
        let child = ctx.box().absolute().left(0).top(0).size(20, 20)
          .label("reduced enter child")
        discard child.transition(motion)
        reportsMoving = child.transitioning
    )
  , 100, 80)
  defer: tester.close()

  tester.setPreferences(ui.Preferences(reduceMotion: true))
  showChild = true
  tester.frame()
  let (bounds, found) = tester.find("reduced enter child")
  doAssert found and abs(bounds.x) < 0.01
  sleep(50)
  tester.frame()
  doAssert reportsMoving

block collapse_enter_clips_without_reflowing_content:
  var showChild = false
  var child: ui.Element
  var content: ui.Element
  let context = ui.newContext()
  let motion = ui.ElementTransition(
    duration: initDuration(milliseconds = 500), ease: ui.linear,
    enter: some(ui.Motion(opacity: 1, collapse: true)))
  let view = proc(ctx: ui.Context) =
    let parent = ctx.row().absolute().left(0).top(0).size(100, 50)
    discard parent.children(proc() =
      if showChild:
        child = ctx.box().size(60, 30)
        discard child.transition(motion)
        discard child.children(proc() =
          content = ctx.box().absolute().left(0).top(0).size(80, 10)
        )
    )
  context.build(view)
  discard context.layout(100, 60)
  showChild = true
  context.build(view)
  let start = context.layout(100, 60)
  doAssert start.bounds(child).w == 0
  doAssert abs(start.bounds(content).w - 80) < 0.01
  sleep(150)
  context.build(view)
  let moving = context.layout(100, 60)
  doAssert moving.bounds(child).w > 0 and moving.bounds(child).w < 60
  doAssert abs(moving.bounds(content).w - 80) < 0.01
  context.close()
