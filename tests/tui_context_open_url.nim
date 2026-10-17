import std/assertions
import mynim/ui as ui

block context_invalidation:
  var builds = 0
  let tester = ui.newTester(proc(c: ui.Context) =
    inc builds
    if builds == 1:
      c.invalidate()
  , 40, 20)
  defer: tester.close()
  doAssert builds >= 2

block context_open_url_result:
  var completionCount = 0
  var outcome: ref CatchableError
  let tester = ui.newTester(proc(c: ui.Context) =
    discard c.button("Open").onClick(proc() =
      c.openUrlThen("x-unknown://a", proc(err: ref CatchableError) =
        outcome = err
        inc completionCount))
    discard c.button("Plain").onClick(proc() =
      c.openUrl("https://example.com"))
    if completionCount > 0 and outcome != nil:
      discard c.text("Couldn't open the link")
    elif completionCount > 0:
      discard c.text("Opened")
  , 240, 100)
  defer: tester.close()

  tester.failOpenUrl(newException(IOError, "no app"))
  doAssert tester.click("Open") == nil
  doAssert completionCount == 1
  doAssert outcome != nil
  doAssert tester.hasText("Couldn't open the link")
  doAssert tester.openedUrls() == @["x-unknown://a"]

  tester.failOpenUrl(nil)
  doAssert tester.click("Open") == nil
  doAssert completionCount == 2
  doAssert outcome == nil
  doAssert tester.hasText("Opened")

  doAssert tester.click("Plain") == nil
  doAssert tester.openedUrls() == @[
    "x-unknown://a", "x-unknown://a", "https://example.com"]
