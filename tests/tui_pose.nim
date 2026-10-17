import std/[assertions, math, os, times]

import mynim/internal/scene as scene
import mynim/ui as ui

block pose_moves_visual_geometry_and_hit_testing:
  var target = ui.Pose()
  var layoutBounds: ui.Rect
  var clicks = 0
  var builds = 0
  let tester = ui.newTester(proc(ctx: ui.Context) =
    inc builds
    let card = ctx.box().size(40, 40)
      .animatePose(target, ui.Animation(
        duration: initDuration(milliseconds = 180), ease: ui.linear))
      .label("posed card")
    layoutBounds = card.bounds()
    discard card.onClick(proc() = inc clicks)
  , 220, 140)
  defer: tester.close()

  let (initial, initiallyFound) = tester.find("posed card")
  doAssert initiallyFound
  target = ui.Pose(x: 80, y: 40, scale: 1.5, rotate: 90)
  tester.frame()
  let buildsAfterRetarget = builds
  sleep(50)
  tester.frame()
  doAssert builds == buildsAfterRetarget
  let (middle, movingFound) = tester.find("posed card")
  doAssert movingFound
  doAssert middle.x > initial.x and middle.x < initial.x + 80
  doAssert abs(layoutBounds.w - 40) < 0.01
  doAssert abs(layoutBounds.h - 40) < 0.01
  tester.clickAt(middle.x + middle.w / 2, middle.y + middle.h / 2)
  doAssert clicks == 1

  sleep(200)
  tester.frame()
  let (finished, finishedFound) = tester.find("posed card")
  doAssert finishedFound
  doAssert abs(finished.x - 70) < 0.01
  doAssert abs(finished.y - 30) < 0.01
  doAssert abs(finished.w - 60) < 0.01
  doAssert abs(finished.h - 60) < 0.01

block pose_fade_changes_scene_opacity_without_changing_layout:
  let context = ui.newContext()
  var pose = ui.Pose()
  var card: ui.Element
  let view = proc(ctx: ui.Context) =
    card = ctx.box().size(24, 16).background(ui.rgb(18, 90, 140))
      .animatePose(pose, ui.Animation(
        duration: initDuration(milliseconds = 180), ease: ui.linear))

  context.build(view)
  let initial = context.layout(100, 80)
  let initialBounds = initial.bounds(card)
  pose.fade = 1
  context.build(view)
  sleep(50)
  context.build(view)
  let moving = context.layout(100, 80)
  doAssert moving.bounds(card) == initialBounds
  var foundPartialOpacity = false
  for op in moving.paintScene().ops:
    if op.kind == scene.opFill and op.color == scene.Color(r: 18, g: 90,
        b: 140, a: 255):
      doAssert op.opacity > 0 and op.opacity < 1
      foundPartialOpacity = true
  doAssert foundPartialOpacity

  sleep(200)
  context.build(view)
  var foundFill = false
  for op in context.layout(100, 80).paintScene().ops:
    if op.kind == scene.opFill and op.color == scene.Color(r: 18, g: 90,
        b: 140, a: 255):
      foundFill = true
  doAssert not foundFill
  context.close()

block nested_poses_update_together_without_rebuilding:
  var parentPose = ui.Pose()
  var childPose = ui.Pose()
  var builds = 0
  let animation = ui.Animation(
    duration: initDuration(milliseconds = 180), ease: ui.linear)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    inc builds
    discard ctx.box().size(80, 80).animatePose(parentPose, animation)
      .children(proc() =
        discard ctx.box().size(20, 20).animatePose(childPose, animation)
          .label("nested pose")
      )
  , 180, 120)
  defer: tester.close()

  parentPose = ui.Pose(x: 40)
  childPose = ui.Pose(y: 20)
  tester.frame()
  let buildsAfterRetarget = builds
  sleep(50)
  tester.frame()
  doAssert builds == buildsAfterRetarget
  let (bounds, found) = tester.find("nested pose")
  doAssert found and bounds.x > 0 and bounds.x < 40
  doAssert bounds.y > 0 and bounds.y < 20

block other_animation_keeps_the_build_path_active:
  var pose = ui.Pose()
  var valueTarget = 0'f32
  var builds = 0
  let animation = ui.Animation(
    duration: initDuration(milliseconds = 180), ease: ui.linear)
  let tester = ui.newTester(proc(ctx: ui.Context) =
    inc builds
    discard ctx.box().size(32, 24).animatePose(pose, animation)
      .label("mixed pose")
    discard ctx.box().animate("other", valueTarget, animation)
  , 180, 120)
  defer: tester.close()

  pose = ui.Pose(x: 40)
  valueTarget = 1
  tester.frame()
  let buildsAfterRetarget = builds
  sleep(50)
  tester.frame()
  doAssert builds > buildsAfterRetarget

block reduced_motion_keeps_pose_fade_animated_but_snaps_geometry:
  var target = ui.Pose()
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.box().size(32, 24).animatePose(target, ui.Animation(
      duration: initDuration(milliseconds = 180), ease: ui.linear))
      .label("reduced motion pose")
  , 200, 80)
  defer: tester.close()

  tester.setPreferences(ui.Preferences(reduceMotion: true))
  target = ui.Pose(x: 90, fade: 1)
  tester.frame()
  let (bounds, found) = tester.find("reduced motion pose")
  doAssert found and abs(bounds.x - 90) < 0.01

block pose_rejects_non_finite_values:
  let context = ui.newContext()
  var rejected = false
  try:
    context.build(proc(ctx: ui.Context) =
      discard ctx.box().animatePose(ui.Pose(rotate: NaN.float32),
        ui.Animation())
    )
  except ValueError:
    rejected = true
  doAssert rejected
  context.close()
