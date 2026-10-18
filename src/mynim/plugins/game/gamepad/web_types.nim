## Maps the W3C standard Gamepad control order into the shared state.

import ./types

proc standardState*(buttons, axes: openArray[float32]): State =
  ## Copies standard-mapped browser controls, clamping values to their range.
  for index in 0 ..< min(buttons.len, ButtonCount):
    result.buttons[Button(index)] = min(max(buttons[index], 0'f32), 1'f32)
  for index in 0 ..< min(axes.len, AxisCount):
    result.axes[Axis(index)] = min(max(axes[index], -1'f32), 1'f32)
