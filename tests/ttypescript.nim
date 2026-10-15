import std/assertions

include "../src/mynim.nim"

block empty_binding_set_writes_nothing:
  let path = getTempDir() / "mynim-tsgen-empty" /
    ($getCurrentProcessId()) / "client.ts"
  defer:
    let dir = path.parentDir.parentDir
    if fileExists(path): removeFile(path)
    if dirExists(path.parentDir): removeDir(path.parentDir)
    if dirExists(dir): removeDir(dir)

  writeTypeScript(path)
  doAssert not fileExists(path)
  doAssert not dirExists(path.parentDir)
  let handler: BoundMethod = proc(c: CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    (newJNull(), nil)
  `bind`("mynim:internal-only", [("hidden", handler)], internal = true)
  writeTypeScript(path)
  doAssert not fileExists(path)
  doAssert not dirExists(path.parentDir)

block typed_services_and_events:
  let handler: BoundMethod = proc(c: CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    (newJNull(), nil)
  `bind`("Greeter", [("Greet", handler)])
  bindTypeScript("Greeter", "Greet", [
    TypeScriptParam(name: "name", tsType: "string")], "string")

  `bind`("Tasks", [("Watch", handler), ("Fetch", handler)])
  bindTypeScript("Tasks", "Watch", [
    TypeScriptParam(name: "updates", tsType: "{ id: number }", channel: true),
    TypeScriptParam(name: "limit", tsType: "number")])
  bindChannels("Tasks", "Fetch", [1])
  discard newEvent[JsonNode]("task-added", "{ id: number; title: string }")

  let source = generateTypeScript()
  for expected in [
      "import { call, event, type Channel } from \"mygo-runtime\";",
      "export const Greeter = {",
      "greet(name: string): Promise<string>",
      "return call(\"Greeter.Greet\", name);",
      "watch(updates: Channel<{ id: number }>, limit: number): Promise<void>",
      "return call(\"Tasks.Watch\", updates, limit);",
      "fetch(arg0: unknown, arg1: Channel<unknown>, ...args: unknown[]): Promise<unknown>",
      "taskAdded: event<{ id: number; title: string }>(\"task-added\")"]:
    doAssert expected in source, "generated client lacks: " & expected & "\n" & source
  doAssert "mynim:internal-test" notin source

block write_creates_parent_and_preserves_unchanged_file:
  let dir = getTempDir() / "mynim-tsgen-write" / $getCurrentProcessId()
  let path = dir / "generated" / "client.ts"
  defer:
    if fileExists(path): removeFile(path)
    if dirExists(path.parentDir): removeDir(path.parentDir)
    if dirExists(path.parentDir.parentDir): removeDir(path.parentDir.parentDir)
    if dirExists(dir): removeDir(dir)
    if dirExists(dir.parentDir): removeDir(dir.parentDir)

  writeTypeScript(path)
  doAssert fileExists(path)
  let source = readFile(path)
  doAssert source.endsWith("\n")
  let sentinel = fromUnix(123)
  setLastModificationTime(path, sentinel)
  writeTypeScript(path)
  doAssert getLastModificationTime(path) == sentinel
