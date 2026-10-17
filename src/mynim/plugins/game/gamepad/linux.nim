## Linux evdev backend for game controllers.

import std/[os, posix, strutils, tables]

import ./device
import ./types

const
  eventKey = 0x01
  eventAbs = 0x03

  buttonSouth = 0x130
  buttonEast = 0x131
  buttonNorth = 0x133
  buttonWest = 0x134
  buttonShoulderL = 0x136
  buttonShoulderR = 0x137
  buttonTriggerL = 0x138
  buttonTriggerR = 0x139
  buttonSelect = 0x13a
  buttonStart = 0x13b
  buttonMode = 0x13c
  buttonThumbL = 0x13d
  buttonThumbR = 0x13e
  buttonUp = 0x220
  buttonDown = 0x221
  buttonLeft = 0x222
  buttonRight = 0x223

  axisX = 0x00
  axisY = 0x01
  axisZ = 0x02
  axisRightX = 0x03
  axisRightY = 0x04
  axisRightZ = 0x05
  axisHatX = 0x10
  axisHatY = 0x11
  axisMax = 0x3f
  keyMax = 0x2ff

  readIoctl = 2
  nonblocking = 0x800
  closeOnExec = 0x80000
  eagain = 11
  eintr = 4

type
  AbsInfo {.bycopy.} = object
    value, minimum, maximum, fuzz, flat, resolution: int32

  InputId {.bycopy.} = object
    bus, vendor, product, version: uint16

  EvdevPad = ref object of Device
    path: string
    fd: cint
    title: string
    xbox, rightOnZ: bool
    abs: array[axisMax + 1, AbsInfo]
    hasAbs: array[axisMax + 1, bool]
    keys: array[keyMax + 1, bool]
    axes: array[axisMax + 1, int32]

proc ioctl(fd: cint; request: culong; arg: pointer): cint
  {.importc, header: "<sys/ioctl.h>".}

proc request(dir, number, size: culong): culong =
  (dir shl 30) or (size shl 16) or (culong(ord('E')) shl 8) or number

proc requestName(size: int): culong = request(readIoctl, 0x06, culong(size))
proc requestBits(eventType, size: int): culong =
  request(readIoctl, culong(0x20 + eventType), culong(size))
proc requestAbs(axis: int): culong = request(readIoctl,
  culong(0x40 + axis), culong(sizeof(AbsInfo)))
proc requestKeys(size: int): culong = request(readIoctl, 0x18, culong(size))
proc requestId(): culong = request(readIoctl, 0x02, culong(sizeof(InputId)))

func bit(data: openArray[byte]; index: int): bool =
  index div 8 < data.len and
    (data[index div 8] and byte(1 shl (index mod 8))) != 0

func little16(data: openArray[byte]; index: int): uint16 =
  uint16(data[index]) or (uint16(data[index + 1]) shl 8)

func little32(data: openArray[byte]; index: int): int32 =
  cast[int32](uint32(data[index]) or (uint32(data[index + 1]) shl 8) or
    (uint32(data[index + 2]) shl 16) or (uint32(data[index + 3]) shl 24))

proc openPad(path: string): EvdevPad =
  let fd = posix.open(path.cstring, cint(nonblocking or closeOnExec))
  if fd < 0:
    return nil
  var keys: array[keyMax div 8 + 1, byte]
  if ioctl(fd, requestBits(eventKey, keys.len), addr keys[0]) < 0 or
      not bit(keys, buttonSouth):
    discard posix.close(fd)
    return nil
  result = EvdevPad(path: path, fd: fd)
  var name: array[256, char]
  if ioctl(fd, requestName(name.len), addr name[0]) == 0:
    result.title = $cast[cstring](addr name[0])
  var id: InputId
  if ioctl(fd, requestId(), addr id) == 0:
    result.xbox = id.vendor == 0x045e or id.vendor == 0x28de
  let driverPath = "/sys/class/input/" & path.extractFilename &
    "/device/device/driver"
  try:
    result.xbox = result.xbox or extractFilename(expandFilename(driverPath)) ==
      "xpad"
  except OSError:
    discard
  var absBits: array[axisMax div 8 + 1, byte]
  discard ioctl(fd, requestBits(eventAbs, absBits.len), addr absBits[0])
  for axis in 0 .. axisMax:
    if bit(absBits, axis) and
        ioctl(fd, requestAbs(axis), addr result.abs[axis]) == 0:
      result.hasAbs[axis] = true
      result.axes[axis] = result.abs[axis].value
  result.rightOnZ = not result.hasAbs[axisRightX] and
    result.hasAbs[axisZ]
  var initialKeys: array[keyMax div 8 + 1, byte]
  if ioctl(fd, requestKeys(initialKeys.len), addr initialKeys[0]) == 0:
    for key in 0 .. keyMax:
      result.keys[key] = bit(initialKeys, key)

method key(device: EvdevPad): string = device.path
method name(device: EvdevPad): string = device.title
method close(device: EvdevPad) = discard posix.close(device.fd)

proc scan*(known: openArray[Device]): seq[Device] =
  var knownByPath = initTable[string, Device]()
  for device in known:
    knownByPath[device.key()] = device
  for path in walkFiles("/dev/input/event*"):
    if knownByPath.hasKey(path):
      result.add(knownByPath[path])
    else:
      let device = openPad(path)
      if device != nil:
        result.add(device)

proc drain(device: EvdevPad): bool =
  var buffer: array[24 * 64, byte]
  while true:
    let count = posix.read(device.fd, addr buffer[0], buffer.len)
    if count < 0:
      return posix.errno == eagain or posix.errno == eintr
    if count == 0:
      return false
    var offset = 0
    while offset + 24 <= count:
      let eventType = little16(buffer, offset + 16)
      let code = little16(buffer, offset + 18).int
      let value = little32(buffer, offset + 20)
      if eventType == eventKey and code <= keyMax:
        device.keys[code] = value != 0
      elif eventType == eventAbs and code <= axisMax:
        device.axes[code] = value
      offset += 24
    if count < buffer.len:
      return true

proc normalized(device: EvdevPad; axis: int; half = false): float32 =
  if not device.hasAbs[axis]:
    return 0
  let info = device.abs[axis]
  let low = float32(info.minimum)
  let high = float32(info.maximum)
  if high <= low:
    return 0
  let ratio = (float32(device.axes[axis]) - low) / (high - low)
  if half:
    min(max(ratio, 0'f32), 1'f32)
  else:
    min(max(ratio * 2 - 1, -1'f32), 1'f32)

method read(device: EvdevPad; state: var State): bool =
  if not device.drain():
    return false
  state = State()
  template press(button: Button; code: int) =
    if device.keys[code]:
      state.buttons[button] = 1
  press(Button.South, buttonSouth)
  press(Button.East, buttonEast)
  if device.xbox:
    press(Button.West, buttonNorth)
    press(Button.North, buttonWest)
  else:
    press(Button.North, buttonNorth)
    press(Button.West, buttonWest)
  press(Button.LeftShoulder, buttonShoulderL)
  press(Button.RightShoulder, buttonShoulderR)
  press(Button.Back, buttonSelect)
  press(Button.Start, buttonStart)
  press(Button.Guide, buttonMode)
  press(Button.LeftStickButton, buttonThumbL)
  press(Button.RightStickButton, buttonThumbR)
  press(Button.Up, buttonUp)
  press(Button.Down, buttonDown)
  press(Button.Left, buttonLeft)
  press(Button.Right, buttonRight)
  if device.hasAbs[axisHatX]:
    if device.axes[axisHatX] < 0:
      state.buttons[Button.Left] = 1
    elif device.axes[axisHatX] > 0:
      state.buttons[Button.Right] = 1
  if device.hasAbs[axisHatY]:
    if device.axes[axisHatY] < 0:
      state.buttons[Button.Up] = 1
    elif device.axes[axisHatY] > 0:
      state.buttons[Button.Down] = 1
  state.axes[Axis.LeftX] = device.normalized(axisX)
  state.axes[Axis.LeftY] = device.normalized(axisY)
  if device.rightOnZ:
    state.axes[Axis.RightX] = device.normalized(axisZ)
    state.axes[Axis.RightY] = device.normalized(axisRightZ)
  else:
    state.axes[Axis.RightX] = device.normalized(axisRightX)
    state.axes[Axis.RightY] = device.normalized(axisRightY)
    state.buttons[Button.LeftTrigger] = device.normalized(axisZ, true)
    state.buttons[Button.RightTrigger] = device.normalized(axisRightZ, true)
  press(Button.LeftTrigger, buttonTriggerL)
  press(Button.RightTrigger, buttonTriggerR)
  true
