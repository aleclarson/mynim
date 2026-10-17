import std/assertions

include "../src/mynim/plugins/game/gamepad"

type FakeDevice = ref object of Device
  id: string
  sample: State
  gone, closed: bool

method key(device: FakeDevice): string = device.id
method name(device: FakeDevice): string = "Fake " & device.id
method close(device: FakeDevice) = device.closed = true
method read(device: FakeDevice; state: var State): bool =
  state = device.sample
  not device.gone

block connect_keep_order_and_disconnect:
  connectedPads.setLen(0)
  let firstDevice = FakeDevice(id: "first")
  firstDevice.sample.buttons[Button.South] = 1
  let secondDevice = FakeDevice(id: "second")

  update(@[Device(firstDevice)])
  doAssert connectedPads.len == 1
  let firstPad = connectedPads[0]
  doAssert firstPad.name() == "Fake first"
  doAssert firstPad.connected()
  doAssert firstPad.state().pressed(Button.South)

  update(@[Device(secondDevice), Device(firstDevice)])
  doAssert connectedPads.len == 2
  doAssert connectedPads[0] == firstPad
  doAssert connectedPads[1].name() == "Fake second"

  firstDevice.gone = true
  let empty = firstPad.state()
  doAssert not empty.pressed(Button.South)
  doAssert not firstPad.connected()
  doAssert firstDevice.closed

  update(@[])
  doAssert connectedPads.len == 0
  doAssert secondDevice.closed
