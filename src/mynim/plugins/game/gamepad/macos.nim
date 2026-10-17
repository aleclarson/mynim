## GameController.framework backend for macOS.

import std/dynlib

import mynim/internal/darwin as objc
import ./device
import ./types

const gameControllerFramework =
  "/System/Library/Frameworks/GameController.framework/GameController"

type GameControllerPad = ref object of Device
  controller: objc.id
  title: string

var
  gameControllerLib: LibHandle
  selectors: array[Button, objc.SEL]
  dpadSelector, leftStickSelector, rightStickSelector: objc.SEL
  upSelector, downSelector, leftSelector, rightSelector: objc.SEL

proc messageFloat32(receiver: objc.id; selector: objc.SEL): float32
  {.importc: "objc_msgSend", dynlib: objc.libObjC, cdecl.}

proc loadGameController(): bool =
  if gameControllerLib == nil:
    gameControllerLib = loadLib(gameControllerFramework)
    if gameControllerLib == nil:
      return false
  objc.loadFrameworks()
  if not objc.hasClass("GCController"):
    return false
  if dpadSelector.isNil:
    dpadSelector = objc.sel("dpad")
    leftStickSelector = objc.sel("leftThumbstick")
    rightStickSelector = objc.sel("rightThumbstick")
    upSelector = objc.sel("up")
    downSelector = objc.sel("down")
    leftSelector = objc.sel("left")
    rightSelector = objc.sel("right")
    for (button, name) in [
        (Button.South, "buttonA"), (Button.East, "buttonB"),
        (Button.West, "buttonX"), (Button.North, "buttonY"),
        (Button.LeftShoulder, "leftShoulder"),
        (Button.RightShoulder, "rightShoulder"),
        (Button.LeftTrigger, "leftTrigger"),
        (Button.RightTrigger, "rightTrigger"),
        (Button.Back, "buttonOptions"), (Button.Start, "buttonMenu"),
        (Button.LeftStickButton, "leftThumbstickButton"),
        (Button.RightStickButton, "rightThumbstickButton"),
        (Button.Guide, "buttonHome")]:
      selectors[button] = objc.sel(name)
  true

proc controllers(): seq[objc.id] =
  let list = objc.send(objc.`class`("GCController"), "controllers")
  if list.isNil:
    return
  let count = objc.sendInt(list, "count")
  for index in 0 ..< count:
    result.add(objc.send(list, "objectAtIndex:", index))

method key(device: GameControllerPad): string = $cast[uint](device.controller)
method name(device: GameControllerPad): string = device.title
method close(device: GameControllerPad) = objc.release(device.controller)

proc scan*(known: openArray[Device]): seq[Device] =
  if not loadGameController():
    return
  var knownByKey: seq[tuple[key: string, device: Device]]
  var devices: seq[Device]
  for device in known:
    knownByKey.add((device.key(), device))
  objc.withPool(proc() =
    for controller in controllers():
      if not objc.send(controller, "extendedGamepad").isNil:
        let key = $cast[uint](controller)
        var existing: Device
        for (knownKey, device) in knownByKey:
          if knownKey == key:
            existing = device
            break
        if existing != nil:
          devices.add(existing)
        else:
          let title = objc.goString(objc.send(controller, "vendorName"))
          devices.add(GameControllerPad(controller: objc.retain(controller),
            title: title))
  )
  result = devices

method read(device: GameControllerPad; state: var State): bool =
  if not loadGameController():
    return false
  var found = false
  var sampled: State
  objc.withPool(proc() =
    for controller in controllers():
      if controller == device.controller:
        found = true
        break
    if found:
      let pad = objc.send(device.controller, "extendedGamepad")
      found = not pad.isNil
      if found:
        for button, selector in selectors:
          if not selector.isNil and
              objc.sendBool(pad, "respondsToSelector:", objc.argu(selector)):
            let input = objc.sendSel(pad, selector)
            if not input.isNil:
              sampled.buttons[button] = messageFloat32(input,
                objc.sel("value"))
        let dpad = objc.sendSel(pad, dpadSelector)
        if not dpad.isNil:
          for (button, selector) in [(Button.Up, upSelector),
              (Button.Down, downSelector), (Button.Left, leftSelector),
              (Button.Right, rightSelector)]:
            let input = objc.sendSel(dpad, selector)
            if not input.isNil:
              sampled.buttons[button] = messageFloat32(input,
                objc.sel("value"))
        let leftStick = objc.sendSel(pad, leftStickSelector)
        if not leftStick.isNil:
          sampled.axes[Axis.LeftX] = messageFloat32(
            objc.send(leftStick, "xAxis"), objc.sel("value"))
          sampled.axes[Axis.LeftY] = -messageFloat32(
            objc.send(leftStick, "yAxis"), objc.sel("value"))
        let rightStick = objc.sendSel(pad, rightStickSelector)
        if not rightStick.isNil:
          sampled.axes[Axis.RightX] = messageFloat32(
            objc.send(rightStick, "xAxis"), objc.sel("value"))
          sampled.axes[Axis.RightY] = -messageFloat32(
            objc.send(rightStick, "yAxis"), objc.sel("value"))
  )
  state = sampled
  found
