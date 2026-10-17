import std/assertions
import mynim/transfer as transfer
import mynim/ui as ui

var services: ui.Services
let tester = ui.newTester(proc(c: ui.Context) =
  services = c.services()
  discard c.text("Services")
, 240, 80)

tester.setClipboard("plain text")
doAssert services.readClipboard() == "plain text"
services.writeClipboard("updated text")
doAssert tester.clipboard() == "updated text"

let data = transfer.newData(transfer.newItem(
  transfer.bytes(transfer.Text, "plain"),
  transfer.bytes(transfer.HTML, "<b>rich</b>")))
tester.setClipboardData(data)
doAssert services.clipboardFormats() == @[transfer.Text, transfer.HTML]
doAssert services.readClipboardData().formats() ==
  @[transfer.Text, transfer.HTML]
doAssert services.readClipboardData(transfer.HTML).formats() ==
  @[transfer.HTML]
services.writeClipboardData(data)
doAssert tester.clipboardData().formats() == @[transfer.Text, transfer.HTML]

services.openUrl("https://example.com")
doAssert tester.openedUrls() == @["https://example.com"]
services.invalidate()
tester.frame()

let openedBeforeClose = tester.openedUrls()
tester.close()
doAssert services.readClipboard().len == 0
doAssert services.clipboardFormats().len == 0
services.writeClipboard("after close")
services.writeClipboardData(data)
services.openUrl("https://after-close.example")
services.invalidate()
doAssert tester.openedUrls() == openedBeforeClose

let empty = ui.Services()
doAssert empty.readClipboard().len == 0
doAssert empty.readClipboardData().items().len == 0
empty.writeClipboard("ignored")
empty.openUrl("https://ignored.example")
empty.invalidate()
