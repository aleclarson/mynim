import std/assertions
import mynim/ui as ui

block context_animation_frame:
  var builds = 0
  let tester = ui.newTester(proc(c: ui.Context) =
    inc builds
    if builds == 1:
      c.animationFrame()
  , 40, 20)
  defer: tester.close()
  doAssert builds >= 2
