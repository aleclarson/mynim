import std/assertions

import mynim/plugins/game/gamepad/types as gamepadTypes
import mynim/plugins/game/gamepad/web_types as browserGamepad

block standard_button_order:
  var buttons = newSeq[float32](gamepadTypes.ButtonCount)
  buttons[0] = 1
  buttons[1] = 0.5
  buttons[6] = 0.75
  buttons[16] = 1
  let state = browserGamepad.standardState(buttons, @[0.4'f32, -0.6, 2, -2])
  doAssert state.buttons[gamepadTypes.Button.South] == 1
  doAssert state.buttons[gamepadTypes.Button.East] == 0.5
  doAssert state.buttons[gamepadTypes.Button.LeftTrigger] == 0.75
  doAssert state.buttons[gamepadTypes.Button.Guide] == 1
  doAssert abs(state.axes[gamepadTypes.Axis.LeftX] - 0.4'f32) < 0.00001
  doAssert abs(state.axes[gamepadTypes.Axis.LeftY] + 0.6'f32) < 0.00001
  doAssert state.axes[gamepadTypes.Axis.RightX] == 1
  doAssert state.axes[gamepadTypes.Axis.RightY] == -1

block missing_controls_default_to_zero:
  let state = browserGamepad.standardState(@[0.25'f32], @[])
  doAssert state.buttons[gamepadTypes.Button.South] == 0.25
  doAssert state.buttons[gamepadTypes.Button.North] == 0
  doAssert state.axes[gamepadTypes.Axis.LeftX] == 0
