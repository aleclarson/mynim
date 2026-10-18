## Browser Gamepad API backend for standard-mapped controllers.

import mynim/internal/web/js as js
import ./device
import ./types
import ./web_types as webTypes

type BrowserPad = ref object of Device
  index: int
  identifier: string
  title: string

proc gamepads(): js.JsValue =
  let navigator = js.jsGet(js.jsGlobal(), "navigator")
  if js.jsType(navigator) != js.jsObject:
    js.jsRelease(navigator)
    return js.jsUndef
  let getGamepadsMethod = js.jsGet(navigator, "getGamepads")
  let supported = js.jsType(getGamepadsMethod) == js.jsFunction
  js.jsRelease(getGamepadsMethod)
  if not supported:
    js.jsRelease(navigator)
    return js.jsUndef
  let (values, ok) = js.jsTryCall(navigator, "getGamepads", [])
  js.jsRelease(navigator)
  if not ok or js.jsType(values) != js.jsObject:
    js.jsRelease(values)
    return js.jsUndef
  values

proc stringField(value: js.JsValue; name: string): string =
  let field = js.jsGet(value, name)
  if js.jsType(field) == js.jsStringT:
    result = js.jsString(field)
  js.jsRelease(field)

proc boolField(value: js.JsValue; name: string): bool =
  let field = js.jsGet(value, name)
  if js.jsType(field) == js.jsBoolean:
    result = js.jsBool(field)
  js.jsRelease(field)

proc intField(value: js.JsValue; name: string; fallback: int): int =
  let field = js.jsGet(value, name)
  result = if js.jsType(field) == js.jsNumber: js.jsInt(field) else: fallback
  js.jsRelease(field)

proc valuesField(value: js.JsValue; name: string; count: int): seq[float32] =
  result = newSeq[float32](count)
  discard js.jsFloatArray(value, name.cstring, result)

method key(device: BrowserPad): string =
  $device.index & ":" & device.identifier

method name(device: BrowserPad): string = device.title
method close(device: BrowserPad) = discard

proc scan*(known: openArray[Device]): seq[Device] =
  ## Returns connected controllers the browser identifies with standard mapping.
  let values = gamepads()
  defer: js.jsRelease(values)
  if js.jsType(values) != js.jsObject:
    return
  for slot in 0..<js.jsLen(values):
    let value = js.jsGetIx(values, slot)
    if js.jsType(value) != js.jsObject:
      js.jsRelease(value)
      continue
    let connected = boolField(value, "connected")
    let standard = stringField(value, "mapping") == "standard"
    if connected and standard:
      let index = intField(value, "index", slot)
      let identifier = stringField(value, "id")
      let key = $index & ":" & identifier
      var existing: Device
      for device in known:
        if device.key() == key:
          existing = device
          break
      if existing != nil:
        result.add(existing)
      else:
        let title = if identifier.len > 0: identifier
          else: "Gamepad " & $(index + 1)
        result.add(BrowserPad(index: index, identifier: identifier,
          title: title))
    js.jsRelease(value)

method read(device: BrowserPad; state: var State): bool =
  let values = gamepads()
  defer: js.jsRelease(values)
  if js.jsType(values) != js.jsObject or device.index < 0 or
      device.index >= js.jsLen(values):
    return false
  let value = js.jsGetIx(values, device.index)
  defer: js.jsRelease(value)
  if js.jsType(value) != js.jsObject or
      not boolField(value, "connected") or
      stringField(value, "mapping") != "standard" or
      stringField(value, "id") != device.identifier:
    return false
  state = webTypes.standardState(valuesField(value, "buttons", ButtonCount),
    valuesField(value, "axes", AxisCount))
  true
