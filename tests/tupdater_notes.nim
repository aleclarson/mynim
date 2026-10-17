import std/assertions

import mynim/plugins/updater/markdown
import mynim/plugins/updater/notes as notes
import mynim/ui as ui

block native_notes:
  let
    state = notes.newNotesState()
    blocks = markdown.parse("## Update ready\n\n" &
      "A **small** release with [details](https://example.com).\n\n" &
      "- First change\n- Second change\n\n" &
      "```nim\nlet answer = 42\n```")
    tester = ui.newTester(proc(context: ui.Context) =
      discard notes.render(state, context, context.theme(), blocks)
    , 520, 360)
  defer: tester.close()

  doAssert tester.hasText("Update ready")
  doAssert tester.hasText("small")
  doAssert tester.hasText("details")
  doAssert tester.hasText("First change")
  doAssert tester.hasText("Second change")
  doAssert tester.hasText("let answer = 42")
