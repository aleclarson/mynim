import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/plugins/updater/markdown
import mynim/plugins/updater/notes as notes
import mynim/ui as ui

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(
  name: "updater release notes selection test"))
app.initialized = true
app.handleReady()

let expected = "Update ready\n\nA small release with details.\n\n" &
  "• First change\n• Second change\n\nlet answer = 42"
let blocks = markdown.parse("## Update ready\n\n" &
  "A **small** release with [details](https://example.com).\n\n" &
  "- First change\n- Second change\n\n```nim\nlet answer = 42\n```")
let notesState = notes.newNotesState()
let uiContent = ui.newContent(proc(context: ui.Context) =
  discard notes.render(notesState, context, context.theme(), blocks)
)
let updateWindow = newWindow(WindowOptions(width: 520, height: 380, hidden: true,
  content: uiContent))
let native = fake.windows[^1].surface

doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var fieldId = 0'u64
for node in native.accessibility()[0].nodes:
  if node.role == platform.roleTextField and node.label == "Release notes":
    fieldId = node.id
    doAssert node.value == expected
    doAssert (node.actions and platform.actionSetValue) ==
      platform.AccessActions(0)
doAssert fieldId != 0
doAssert native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: fieldId, action: platform.accessFocus))
doAssert native.frame()

let command = when defined(macosx): platform.modSuper else: platform.modCtrl
doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyA, mods: command))
doAssert native.frame()
let selected = native.lastTextInput().client.selection().`range`
doAssert selected.start == 0 and selected.`end` == platform.utf16Len(expected)

doAssert native.send(platform.SurfaceEvent(kind: platform.keyPressed,
  key: platform.keyC, mods: command))
let copied = fake.clipboardData.read(transfer.Text)
doAssert copied.err == nil
doAssert transfer.bytesToString(copied.data) == expected

doAssert native.send(platform.SurfaceEvent(kind: platform.textInput,
  text: "This text must not replace release notes"))
doAssert native.frame()
doAssert native.lastTextInput().text == expected

updateWindow.destroy()
loop.shutdown()
