## Shared gamepad button, axis, and state types.

import std/math

type
  Button* {.pure.} = enum
    South, East, West, North,
    LeftShoulder, RightShoulder,
    LeftTrigger, RightTrigger,
    Back, Start,
    LeftStickButton, RightStickButton,
    Up, Down, Left, Right,
    Guide

  Axis* {.pure.} = enum
    LeftX, LeftY, RightX, RightY

  State* = object ## A snapshot of gamepad buttons and axes.
    buttons*: array[Button, float32]
    axes*: array[Axis, float32]

const
  ButtonCount* = ord(Button.high) + 1
  AxisCount* = ord(Axis.high) + 1
  Deadzone* = 0.15'f32 ## Radial dead zone for both sticks.
  pressThreshold = 0.25'f32

func value*(state: State; button: Button): float32 =
  ## Returns how far `button` is pressed, from 0 to 1.
  if ord(button) >= ButtonCount:
    return 0
  state.buttons[button]

func pressed*(state: State; button: Button): bool =
  ## Reports whether `button` is pressed; triggers use a quarter threshold.
  state.value(button) >= pressThreshold

func justPressed*(state, last: State; button: Button): bool =
  ## Reports whether `button` became pressed since `last`.
  state.pressed(button) and not last.pressed(button)

func justReleased*(state, last: State; button: Button): bool =
  ## Reports whether `button` stopped being pressed since `last`.
  not state.pressed(button) and last.pressed(button)

func axisValue*(state: State; axis: Axis): float32 =
  ## Returns the raw axis value from -1 to 1.
  if ord(axis) >= AxisCount:
    return 0
  state.axes[axis]

func stick(x, y: float32): tuple[x, y: float32] =
  let magnitude = float32(hypot(float64(x), float64(y)))
  if magnitude < Deadzone:
    return (0, 0)
  let scale = min((magnitude - Deadzone) / (1 - Deadzone), 1'f32) /
    magnitude
  (x * scale, y * scale)

func leftStick*(state: State): tuple[x, y: float32] =
  ## Returns the left stick with a radial dead zone and normalized reach.
  stick(state.axes[Axis.LeftX], state.axes[Axis.LeftY])

func rightStick*(state: State): tuple[x, y: float32] =
  ## Returns the right stick with a radial dead zone and normalized reach.
  stick(state.axes[Axis.RightX], state.axes[Axis.RightY])
