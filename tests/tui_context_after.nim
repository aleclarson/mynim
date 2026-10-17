import std/[assertions, times]
import mynim/ui as ui

block context_after:
  var builds = 0
  var context: ui.Context
  let tester = ui.newTester(proc(c: ui.Context) =
    context = c
    inc builds
  , 40, 20)
  defer: tester.close()

  let before = builds
  context.after(initDuration())
  doAssert builds == before
  tester.frame()
  doAssert builds > before
