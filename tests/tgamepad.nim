import std/[assertions, math]

import mynim/plugins/game/gamepad as gamepad

block standardized_state:
  var previous, current: gamepad.State
  current.buttons[gamepad.Button.South] = 1
  current.buttons[gamepad.Button.LeftTrigger] = 0.2
  current.buttons[gamepad.Button.RightTrigger] = 0.3
  doAssert current.pressed(gamepad.Button.South)
  doAssert not current.pressed(gamepad.Button.LeftTrigger)
  doAssert current.pressed(gamepad.Button.RightTrigger)
  doAssert current.justPressed(previous, gamepad.Button.South)
  doAssert not current.justPressed(current, gamepad.Button.South)
  doAssert previous.justReleased(current, gamepad.Button.South)
  doAssert abs(current.value(gamepad.Button.LeftTrigger) - 0.2) < 0.000001
  doAssert current.axisValue(gamepad.Axis.LeftX) == 0
  doAssert current.value(cast[gamepad.Button](255)) == 0
  doAssert current.axisValue(cast[gamepad.Axis](255)) == 0

block radial_deadzone:
  var state: gamepad.State
  state.axes[gamepad.Axis.LeftX] = 0.1
  state.axes[gamepad.Axis.LeftY] = 0.05
  doAssert state.leftStick() == (0'f32, 0'f32)
  state.axes[gamepad.Axis.LeftX] = 0.7071
  state.axes[gamepad.Axis.LeftY] = 0.7071
  let (x, y) = state.leftStick()
  doAssert abs(sqrt(x * x + y * y) - 1) < 0.001
  state.axes[gamepad.Axis.RightX] = -(gamepad.Deadzone +
    (1 - gamepad.Deadzone) / 2)
  let (rightX, _) = state.rightStick()
  doAssert abs(rightX + 0.5) < 0.0001

block native_poll:
  for pad in gamepad.pads():
    discard pad.name()
    discard pad.state()
