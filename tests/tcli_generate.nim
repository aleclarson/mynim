import std/[assertions, json, os, strutils, tempfiles]
import ../src/cmd/generate
import ../src/cmd/init

proc testGenerateClient() =
  let temporary = createTempDir("mynim-generate-test-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)

  let project = temporary / "project with spaces"
  doAssert runInit(@["--mygo", getCurrentDir(), project]) == 0
  let mainPath = project / "src" / "main.nim"
  writeFile(mainPath, """import std/json
import mynim

let handler: BoundMethod = proc(c: CallContext; args: seq[JsonNode]):
    tuple[v: JsonNode, err: ref CatchableError] =
  (newJString("hello"), nil)
`bind`("Greeter", [("Greet", handler)])
bindTypeScript("Greeter", "Greet", [
  TypeScriptParam(name: "name", tsType: "string")], "string")
app.run()
""")
  let output = "frontend/client.ts"
  doAssert runGenerate(@["-o", output, project]) == 0
  let generated = project / output
  doAssert fileExists(generated)
  let source = readFile(generated)
  doAssert "export const Greeter" in source
  doAssert "greet(name: string): Promise<string>" in source
  doAssert "return call(\"Greeter.Greet\", name);" in source

  let configPath = project / "mygo.json"
  var config = parseFile(configPath)
  config["bindings"] = %"configured/client.ts"
  writeFile(configPath, config.pretty & "\n")
  doAssert runGenerate(@[project]) == 0
  let configured = project / "configured" / "client.ts"
  doAssert fileExists(configured)
  doAssert "export const Greeter" in readFile(configured)

proc testNoDefaultOutputWithoutFrontend() =
  let temporary = createTempDir("mynim-generate-empty-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)

  let project = temporary / "native"
  doAssert runInit(@["--mygo", getCurrentDir(), project]) == 0
  doAssert runGenerate(@[project]) == 0
  doAssert not fileExists(project / "mygo.ts")
  doAssert not fileExists(project / "src" / "mygo.ts")

testGenerateClient()
testNoDefaultOutputWithoutFrontend()
