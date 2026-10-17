## Standardized gamepad buttons, axes, polling, and connection state.

import std/[locks, monotimes, tables, times]

import ./gamepad/device
import ./gamepad/types

when defined(macosx):
  import ./gamepad/macos as backend
elif defined(linux) and (defined(amd64) or defined(arm64)):
  import ./gamepad/linux as backend
elif defined(windows) and (defined(amd64) or defined(arm64)):
  import ./gamepad/windows as backend
else:
  import ./gamepad/other as backend

export types

type Pad* = ref object ## A controller, stable until it disconnects.
  device: Device
  title: string
  isConnected: bool

var
  connectedPads: seq[Pad]
  scanLock: Lock
  lastScan: MonoTime

initLock(scanLock)

proc name*(pad: Pad): string =
  ## Returns the controller's reported name.
  if pad == nil: "" else: pad.title

proc connected*(pad: Pad): bool =
  ## Reports whether the controller is still connected.
  if pad == nil:
    return false
  withLock scanLock:
    result = pad.isConnected

proc disconnect(pad: Pad) =
  pad.isConnected = false
  pad.device.close()
  for index, current in connectedPads:
    if current == pad:
      connectedPads.delete(index)
      break

proc state*(pad: Pad): State =
  ## Reads current controls; a disconnected controller returns an empty state.
  if pad == nil:
    return
  withLock scanLock:
    if not pad.isConnected:
      return
    if not pad.device.read(result):
      pad.disconnect()
      result = State()

proc update(found: seq[Device]) =
  var present = initTable[string, bool]()
  for device in found:
    present[device.key()] = true
  for pad in connectedPads:
    if not present.hasKey(pad.device.key()):
      pad.isConnected = false
      pad.device.close()
  var retained: seq[Pad]
  for pad in connectedPads:
    if pad.isConnected:
      retained.add(pad)
  connectedPads = move(retained)
  var have = initTable[string, bool]()
  for pad in connectedPads:
    have[pad.device.key()] = true
  for device in found:
    let key = device.key()
    if not have.hasKey(key):
      have[key] = true
      connectedPads.add(Pad(device: device, title: device.name(),
        isConnected: true))

proc pads*(): seq[Pad] =
  ## Returns connected controllers in connection order, scanning at most once a second.
  withLock scanLock:
    let now = getMonoTime()
    if lastScan == MonoTime() or
        (now - lastScan).inNanoseconds >= 1_000_000_000:
      lastScan = now
      var known = newSeqOfCap[Device](connectedPads.len)
      for pad in connectedPads:
        known.add(pad.device)
      update(backend.scan(known))
    result = newSeqOfCap[Pad](connectedPads.len)
    for pad in connectedPads:
      result.add(pad)
