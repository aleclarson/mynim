import std/[assertions, os, osproc, streams, strutils, tempfiles]
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
    "--mygo", getCurrentDir(),
    project]) == 0

  doAssert fileExists(project / "counter_app.nimble")
  doAssert fileExists(project / "mygo.json")
  doAssert fileExists(project / "config.nims")
  doAssert fileExists(project / "resources" / "icon.png")
  doAssert fileExists(project / ".agents" / "skills" / "mynim-maintenance" /
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

  doAssert runInit(@["--template", "web", temporary / "web-app"]) == 1
  doAssert not dirExists(temporary / "web-app")
  doAssert runInit(@["--bad", "value", temporary / "bad-app"]) == 2
  doAssert runInit(@["--help"]) == 0

testInit()
