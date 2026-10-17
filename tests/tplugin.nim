import std/assertions

include "../src/mynim.nim"

var setupCalls = 0
var nestedSetupCalls = 0

let ping: BoundMethod = proc(c: CallContext; args: seq[JsonNode]):
    tuple[v: JsonNode, err: ref CatchableError] =
  (newJString("pong"), nil)

use(Plugin(
  name: "test-ping",
  service: @[ (name: "Ping", fn: ping) ],
  setup: proc(): ref CatchableError =
    inc setupCalls
    nil))

doAssert setupCalls == 1
let pingMethod = lookupMethod("plugin:test-ping.Ping")
doAssert pingMethod != nil
let (pingResult, pingError) = pingMethod.fn(nil, @[])
doAssert pingError == nil
doAssert pingResult.getStr() == "pong"

let missingPlugin = notBound("plugin:test-unused.Ping")
doAssert "the test-unused plugin is not used" in missingPlugin.msg
doAssert "before app.run" in missingPlugin.msg
doAssert notBound("plugin:test-ping.Missing").msg ==
  "method plugin:test-ping.Missing is not bound"

use(Plugin(
  name: "test-parent",
  setup: proc(): ref CatchableError =
    use(Plugin(
      name: "test-child",
      setup: proc(): ref CatchableError =
        inc nestedSetupCalls
        nil))
    nil))
doAssert nestedSetupCalls == 1
doAssert notBound("plugin:test-child.Missing").msg ==
  "method plugin:test-child.Missing is not bound"

let generated = generateTypeScript()
doAssert "plugin:test-ping" notin generated
doAssert "test-ping" notin generated

proc expectValueError(action: proc() {.closure.}; detail: string) =
  var caught = false
  try:
    action()
  except ValueError as error:
    caught = true
    doAssert detail in error.msg, error.msg
  doAssert caught, "expected ValueError containing: " & detail

expectValueError(proc() = use(Plugin(name: "test-ping")),
  "plugin test-ping is already used")
expectValueError(proc() = use(Plugin(name: "")),
  "must be lowercase letters")
expectValueError(proc() = use(Plugin(name: "Bad")),
  "must be lowercase letters")
expectValueError(proc() = use(Plugin(name: "mygo")), "is reserved")

expectValueError(proc() =
  use(Plugin(name: "test-setup-error", setup: proc(): ref CatchableError =
    newException(IOError, "setup failed"))),
  "plugin test-setup-error: setup failed")
doAssert notBound("plugin:test-setup-error.Missing").msg ==
  "method plugin:test-setup-error.Missing is not bound"

`bind`("plugin:test-collision", [("occupied", ping)], internal = true)
expectValueError(proc() = use(Plugin(
  name: "test-collision",
  service: @[ (name: "Ping", fn: ping) ])),
  "plugin test-collision: a service named plugin:test-collision is already bound")
doAssert "the test-collision plugin is not used" in
  notBound("plugin:test-collision.Ping").msg
