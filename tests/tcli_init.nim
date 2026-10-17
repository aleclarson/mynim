import std/[assertions, json, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/init

proc runNimble(project, task: string) =
  let process = startProcess("nimble", args = @[task], workingDir = project,
    options = {poUsePath, poStdErrToStdOut})
  try:
    let output = process.outputStream.readAll()
    doAssert process.waitForExit() == 0, output
  finally:
    process.close()

proc testInit() =
  let temporary = createTempDir("mynim-init-", "")
  defer: removeDir(temporary)

  let project = temporary / "project with spaces"
  doAssert runInit(@[
    "--template", "native",
    "--name", "Ada \"Counter\"",
    "--package", "counter-app",
    "--nim-xplat", getCurrentDir(),
    project]) == 0

  doAssert fileExists(project / "counter_app.nimble")
  doAssert fileExists(project / "mygo.json")
  doAssert fileExists(project / "config.nims")
  doAssert fileExists(project / "resources" / "icon.png")
  doAssert fileExists(project / ".agents" / "skills" / "nim-xplat-maintenance" /
    "SKILL.md")
  doAssert getFileSize(project / "resources" / "icon.png") > 0
  doAssert readFile(project / "src" / "main.nim").contains("Ada \\\"Counter\\\"")
  doAssert readFile(project / "config.nims").contains("/src\"")
  runNimble(project, "test")
  runNimble(project, "build")

  let occupied = temporary / "occupied"
  createDir(occupied)
  writeFile(occupied / "keep.txt", "keep")
  doAssert runInit(@[occupied]) == 1
  doAssert readFile(occupied / "keep.txt") == "keep"

  let webProject = temporary / "web-app"
  doAssert runInit(@[
    "--template", "web",
    "--name", "Web <App>",
    "--nim-xplat", getCurrentDir(),
    webProject]) == 0
  doAssert fileExists(webProject / "src" / "main.nim")
  doAssert fileExists(webProject / "src" / "main.ts")
  doAssert fileExists(webProject / "src" / "style.css")
  doAssert fileExists(webProject / "index.html")
  doAssert fileExists(webProject / "package.json")
  doAssert fileExists(webProject / "vite.config.ts")
  doAssert fileExists(webProject / "tsconfig.json")
  doAssert readFile(webProject / "index.html").contains(
    "<h1>Web &lt;App&gt;</h1>")
  doAssert "$<HTMLInputElement>" in readFile(webProject / "src" / "main.ts")
  let webConfig = parseFile(webProject / "mygo.json")
  doAssert webConfig["bindings"].getStr() == "src/mygo.ts"
  doAssert webConfig["devCommand"].getStr() == "npm run dev:web"
  doAssert webConfig["buildCommand"].getStr() == "npm run build:web"
  doAssert webConfig["frontendDist"].getStr() == "dist"
  doAssert "mygo-runtime" in parseFile(webProject / "package.json")[
    "dependencies"]
  runNimble(webProject, "test")
  runNimble(webProject, "build")

  doAssert runInit(@[
    "--template", "unknown", temporary / "unknown-app"]) == 1
  doAssert not dirExists(temporary / "unknown-app")
  doAssert runInit(@["--bad", "value", temporary / "bad-app"]) == 2
  doAssert runInit(@["--help"]) == 0

testInit()
