import std/[assertions, os]

import mynim/internal/scene as scene
import mynim/ui as ui
import mynim/plugins/game as game

type GameFixture = ref object of game.Game
  keyPresses, keyReleases, pointerPresses, wheelEvents: int
  sawHeldKey, sawKeyB, sawFocused, sawButton, sawPointerOver: bool
  pointerX, pointerY: float32

method rate(g: GameFixture): int = 60

method update(g: GameFixture; input: game.Input) =
  if input.pressed(ui.keyA):
    inc g.keyPresses
  if input.released(ui.keyA):
    inc g.keyReleases
  g.sawHeldKey = g.sawHeldKey or input.down(ui.keyA)
  g.sawKeyB = g.sawKeyB or input.down(ui.keyB)
  g.sawFocused = g.sawFocused or input.focused()
  if input.pointerPressed(0):
    inc g.pointerPresses
  if input.pointerDown(0):
    g.sawButton = true
  if input.wheel() != (0'f32, 0'f32):
    inc g.wheelEvents
  let pointer = input.pointer()
  g.sawPointerOver = g.sawPointerOver or pointer.over
  g.pointerX = pointer.x
  g.pointerY = pointer.y

method draw(g: GameFixture; painter: var ui.Painter; rect: ui.Rect;
            alpha: float64) =
  discard

block game_input_and_fixed_step_view:
  let state = GameFixture()
  let tester = ui.newTester(proc(c: ui.Context) =
    discard game.view(c, state).size(120, 80)
  , 120, 80)
  defer: tester.close()

  tester.setFocused(true)
  sleep(20)
  tester.keyDown(ui.keyA)
  doAssert state.keyPresses > 0 and state.sawHeldKey
  doAssert state.sawFocused
  sleep(20)
  tester.keyUp(ui.keyA)
  doAssert state.keyReleases > 0

  sleep(20)
  tester.key(ui.modCtrl, ui.keyB)
  doAssert not state.sawKeyB

  sleep(20)
  tester.move(12, 18)
  sleep(20)
  tester.press(12, 18)
  doAssert state.pointerPresses > 0 and state.sawButton
  doAssert state.sawPointerOver
  doAssert abs(state.pointerX - 12) < 0.001
  doAssert abs(state.pointerY - 18) < 0.001
  sleep(20)
  tester.scroll(12, 18, 3, 4)
  doAssert state.wheelEvents > 0

  sleep(20)
  tester.keyDown(ui.keyA)
  let keyReleasesBeforeBlur = state.keyReleases
  sleep(20)
  tester.setFocused(false)
  doAssert state.keyReleases > keyReleasesBeforeBlur

block pointer_down_without_prior_move:
  let state = GameFixture()
  let tester = ui.newTester(proc(c: ui.Context) =
    discard game.view(c, state).size(120, 80)
  , 120, 80)
  defer: tester.close()

  tester.setFocused(true)
  sleep(20)
  tester.press(12, 18)
  doAssert state.pointerPresses > 0
  doAssert state.sawPointerOver

block camera_and_integer_fit:
  let camera = game.Camera(x: 50, y: 60, zoom: 2)
  let center = camera.toWorld(ui.Rect(x: 10, y: 20, w: 100, h: 80), 50, 40)
  doAssert center == (50'f32, 60'f32)
  let visible = camera.visible(ui.Rect(w: 100, h: 80))
  doAssert visible == ui.Rect(x: 25, y: 40, w: 50, h: 40)

  let rotated = game.Camera(x: 4, y: 5, zoom: 2, rotation: 90)
  let point = rotated.toWorld(ui.Rect(w: 100, h: 80), 60, 40)
  doAssert abs(point.x - 4) < 0.001 and abs(point.y - 10) < 0.001

  let cameraContext = ui.newContext()
  cameraContext.build(proc(c: ui.Context) =
    discard c.box().size(100, 80).draw(proc(painter: var ui.Painter;
        rect: ui.Rect) =
      camera.draw(painter, rect, proc(world: var ui.Painter) =
        world.fill(ui.Rect(x: 50, y: 60, w: 1, h: 1),
          ui.rgb(40, 80, 120), 0)
      )
    )
  )
  let cameraFrame = cameraContext.layout(
    ui.Rect(x: 10, y: 20, w: 100, h: 80)).paintScene(2)
  doAssert cameraFrame.ops.len == 3
  doAssert cameraFrame.ops[0].kind == scene.opPushClip
  doAssert cameraFrame.ops[1].kind == scene.opFill
  let (screenX, screenY) = cameraFrame.ops[1].transform.point(
    cameraFrame.ops[1].rect.x, cameraFrame.ops[1].rect.y)
  doAssert abs(screenX - 100) < 0.001 and abs(screenY - 80) < 0.001
  doAssert cameraFrame.ops[2].kind == scene.opPopClip
  cameraContext.close()

  let context = ui.newContext()
  var fit: tuple[rect: ui.Rect, scale: int]
  context.build(proc(c: ui.Context) =
    discard c.box().size(1, 1).draw(proc(painter: var ui.Painter;
        rect: ui.Rect) =
      fit = game.integerFit(painter, 480, 270,
        ui.Rect(x: 10, y: 20, w: 700, h: 400))
    )
  )
  discard context.layout(ui.Rect(w: 720, h: 440)).paintScene(2)
  doAssert fit.scale == 2
  doAssert fit.rect == ui.Rect(x: 120, y: 85, w: 480, h: 270)
  context.close()
