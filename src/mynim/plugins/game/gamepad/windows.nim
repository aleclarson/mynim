## Windows XInput backend for game controllers.

import ./device
import ./types

type
  XInputGamepad {.bycopy.} = object
    buttons: uint16
    leftTrigger, rightTrigger: uint8
    thumbLeftX, thumbLeftY, thumbRightX, thumbRightY: int16

  XInputState {.bycopy.} = object
    packet: uint32
    gamepad: XInputGamepad

  XInputGetState = proc(slot: uint32; state: ptr XInputState): uint32 {.stdcall.}

  XInputPad = ref object of Device
    slot: int

const
  success = 0'u32
  slotCount = 4

  dpadUp = 0x0001'u16
  dpadDown = 0x0002'u16
  dpadLeft = 0x0004'u16
  dpadRight = 0x0008'u16
  startButton = 0x0010'u16
  backButton = 0x0020'u16
  thumbLeftButton = 0x0040'u16
  thumbRightButton = 0x0080'u16
  shoulderLeft = 0x0100'u16
  shoulderRight = 0x0200'u16
  guideButton = 0x0400'u16
  buttonSouth = 0x1000'u16
  buttonEast = 0x2000'u16
  buttonWest = 0x4000'u16
  buttonNorth = 0x8000'u16

proc loadLibraryA(name: cstring): pointer
  {.importc, dynlib: "kernel32.dll", stdcall.}
proc getProcAddress(module: pointer; name: cstring): pointer
  {.importc, dynlib: "kernel32.dll", stdcall.}
proc getSystemDirectoryA(buffer: cstring; size: uint32): uint32
  {.importc, dynlib: "kernel32.dll", stdcall.}

var
  xinputGetState: XInputGetState
  loadedXinput: bool

proc systemDirectory(): string =
  var buffer: array[260, char]
  let size = getSystemDirectoryA(cast[cstring](addr buffer[0]),
    uint32(buffer.len))
  if size == 0 or size >= uint32(buffer.len):
    return "C:\\Windows\\System32"
  $cast[cstring](addr buffer[0])

proc loadXinput() =
  if loadedXinput:
    return
  loadedXinput = true
  let root = systemDirectory()
  let ordinal = cast[cstring](cast[pointer](100))
  for name in ["xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll"]:
    let module = loadLibraryA((root & "\\" & name).cstring)
    if not module.isNil:
      var address = getProcAddress(module, ordinal)
      if address.isNil:
        address = getProcAddress(module, "XInputGetState")
      if not address.isNil:
        xinputGetState = cast[XInputGetState](address)
        return

proc readState(slot: int; state: var XInputState): bool =
  loadXinput()
  not xinputGetState.isNil and
    xinputGetState(uint32(slot), addr state) == success

method key(device: XInputPad): string = "xinput" & $device.slot
method name(device: XInputPad): string =
  "Xbox Controller " & $(device.slot + 1)
method close(device: XInputPad) = discard

proc scan*(known: openArray[Device]): seq[Device] =
  loadXinput()
  if xinputGetState.isNil:
    return
  for slot in 0 ..< slotCount:
    let key = "xinput" & $slot
    var existing: Device
    for device in known:
      if device.key() == key:
        existing = device
        break
    if existing != nil:
      result.add(existing)
    else:
      var state: XInputState
      if readState(slot, state):
        result.add(XInputPad(slot: slot))

proc thumb(value: int16): float32 =
  max(float32(value) / 32767, -1'f32)

method read(device: XInputPad; state: var State): bool =
  var sample: XInputState
  if not readState(device.slot, sample):
    return false
  state = State()
  let gamepad = sample.gamepad
  for (button, mask) in [
      (Button.South, buttonSouth), (Button.East, buttonEast),
      (Button.West, buttonWest), (Button.North, buttonNorth),
      (Button.LeftShoulder, shoulderLeft),
      (Button.RightShoulder, shoulderRight), (Button.Back, backButton),
      (Button.Start, startButton), (Button.LeftStickButton, thumbLeftButton),
      (Button.RightStickButton, thumbRightButton), (Button.Up, dpadUp),
      (Button.Down, dpadDown), (Button.Left, dpadLeft),
      (Button.Right, dpadRight), (Button.Guide, guideButton)]:
    if (gamepad.buttons and mask) != 0:
      state.buttons[button] = 1
  state.buttons[Button.LeftTrigger] = float32(gamepad.leftTrigger) / 255
  state.buttons[Button.RightTrigger] = float32(gamepad.rightTrigger) / 255
  state.axes[Axis.LeftX] = thumb(gamepad.thumbLeftX)
  state.axes[Axis.LeftY] = -thumb(gamepad.thumbLeftY)
  state.axes[Axis.RightX] = thumb(gamepad.thumbRightX)
  state.axes[Axis.RightY] = -thumb(gamepad.thumbRightY)
  true
