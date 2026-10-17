import std/[assertions, json, os, osproc, streams, strtabs, strutils, tempfiles]
import ../src/cmd/build
import ../src/cmd/init

proc runFrontendCheck(binary, workingDir: string): int =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["MYGO_FRONTEND_TEST"] = "1"
  let process = startProcess(binary, workingDir = workingDir, env = env,
    options = {poUsePath, poParentStreams})
  try:
    result = process.waitForExit()
  finally:
    process.close()

proc testBuild() =
  let temporary = createTempDir("mynim-build-", "")
  defer: removeDir(temporary)

  let project = temporary / "project with spaces"
  doAssert runInit(@[
    "--name", "Ada & Counter",
    "--mygo", getCurrentDir(),
    project]) == 0

  let buildStep = project / "build_step.nim"
  let buildMarker = project / "build-step-ran.txt"
  writeFile(buildStep, """import std/os
if not fileExists("client-generation-ran.txt"):
  quit(17)
createDir("frontend-dist")
writeFile("frontend-dist/index.html", "NIM-EMBEDDED-FRONTEND-MARKER")
writeFile("build-step-ran.txt", "yes")
""")
  let configPath = project / "mygo.json"
  var config = parseFile(configPath)
  config["buildCommand"] = %"nim r build_step.nim"
  config["frontendDist"] = %"frontend-dist"
  writeFile(configPath, config.pretty & "\n")
  writeFile(project / "src" / "main.nim", """import std/os
import mynim

if getEnv("MYNIM_GENERATE").len > 0:
  writeFile("client-generation-ran.txt", "yes")

when defined(mynimGeneratedFrontend):
  import mynim/internal/vfs as mynimVfs
  if getEnv("MYGO_FRONTEND_TEST") == "1":
    let (body, err) = mynimVfs.readFile(mynim_frontend.embeddedFrontend(),
      "index.html")
    if err != nil:
      quit(2)
    var content = newString(body.len)
    for index, value in body:
      content[index] = char(value)
    if content != "NIM-EMBEDDED-FRONTEND-MARKER":
      quit(3)
    quit(0)

app.run()
""")

  let output = temporary / "build output"
  doAssert runBuild(@["-o", output, project]) == 0
  doAssert readFile(buildMarker) == "yes"
  let targetOs = if hostOS == "macosx": "darwin" else: hostOS
  let target = output / (targetOs & "-" & hostCPU)
  let executable = "ada-counter" & (when hostOS == "windows": ".exe" else: "")
  when hostOS == "macosx":
    let bundle = target / "ada-counter.app"
    doAssert fileExists(bundle / "Contents" / "MacOS" / executable)
    doAssert fileExists(bundle / "Contents" / "Resources" / "icon.png")
    doAssert not dirExists(target / ".nimcache")
    let infoPlist = bundle / "Contents" / "Info.plist"
    let plist = readFile(infoPlist)
    doAssert plist.contains("Ada &amp; Counter")
    doAssert plist.contains("com.example.adacounter")
    doAssert fileExists(output / ".mynim-build" / target.lastPathPart())
    doAssert not fileExists(target / ".mynim-build")
    let process = startProcess("plutil", args = @["-lint", infoPlist],
      options = {poUsePath, poStdErrToStdOut})
    try:
      let log = process.outputStream.readAll()
      doAssert process.waitForExit() == 0, log
    finally:
      process.close()
  else:
    doAssert fileExists(target / executable)
    doAssert fileExists(target / "icon.png")

  var binary = target / executable
  when hostOS == "macosx":
    binary = target / "ada-counter.app" / "Contents" / "MacOS" / executable
  doAssert runFrontendCheck(binary, project) == 0
  for kind, path in walkDir(project):
    if kind == pcDir:
      doAssert not path.lastPathPart().startsWith(".mygo-frontend-")

  removeFile(buildMarker)
  doAssert runBuild(@["-skip-build-command", "-o", output, project]) == 0
  doAssert not fileExists(buildMarker)

  doAssert runBuild(@["-o", output, project]) == 0
  doAssert fileExists(buildMarker)
  when hostOS == "macosx":
    doAssert fileExists(target / "ada-counter.app" / "Contents" / "MacOS" /
      executable)
  else:
    doAssert fileExists(target / executable)

  writeFile(buildStep, "quit(17)\n")
  doAssert runBuild(@["-o", output, project]) == 1

  writeFile(project / "src" / "main.nim", "import mynim\napp.run()\n")
  config["buildCommand"] = %""
  config["frontendDist"] = %""
  writeFile(configPath, config.pretty & "\n")
  doAssert runBuild(@["-o", output, project]) == 0
  doAssert runBuild(@["-platform", "other/target", project]) == 1
  doAssert runBuild(@["-unknown", project]) == 2
  doAssert runBuild(@["--help"]) == 0

testBuild()
