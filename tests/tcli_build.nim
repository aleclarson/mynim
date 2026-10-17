import std/[assertions, json, os, osproc, streams, strtabs, strutils, tempfiles]
import ../src/cmd/build
import ../src/cmd/init
when hostOS == "macosx":
  import ../src/cmd/dmg as dmgPackage
  import std/posix

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

when hostOS == "macosx":
  proc verifyDmg(dmg, appName, mountPoint: string) =
    createDir(mountPoint)
    var disk = ""
    try:
      let attach = startProcess("/usr/bin/hdiutil", args = @[
        "attach", "-readonly", "-noverify", "-noautoopen", "-nobrowse",
        "-mountpoint", mountPoint, dmg],
        options = {poUsePath, poStdErrToStdOut})
      let attachLog = attach.outputStream.readAll()
      let attachCode = attach.waitForExit()
      attach.close()
      doAssert attachCode == 0, attachLog
      for line in attachLog.splitLines:
        let fields = line.splitWhitespace
        if fields.len > 0 and fields[0].startsWith("/dev/disk"):
          disk = fields[0]
          break
      doAssert disk.len > 0, attachLog
      doAssert fileExists(mountPoint / ".DS_Store")
      doAssert dirExists(mountPoint / appName)
      doAssert readFile(mountPoint / ".VolumeIcon.icns") ==
        "MYNIM-ICON-FIXTURE"
      var linkTarget = newString(4096)
      let linkLength = posix.readlink((mountPoint / "Applications").cstring,
        linkTarget.cstring, linkTarget.len)
      doAssert linkLength > 0
      linkTarget.setLen(linkLength)
      doAssert linkTarget == "/Applications"
      let flags = startProcess("/usr/bin/xattr", args = @[
        "-px", "com.apple.FinderInfo", mountPoint],
        options = {poUsePath, poStdErrToStdOut})
      let flagsOutput = flags.outputStream.readAll()
      let flagsCode = flags.waitForExit()
      flags.close()
      doAssert flagsCode == 0, flagsOutput
      doAssert flagsOutput.splitWhitespace.join("") ==
        "0000000000000000040000000000000000000000000000000000000000000000"
    finally:
      if disk.len > 0:
        let detach = startProcess("/usr/bin/hdiutil",
          args = @["detach", disk], options = {poUsePath, poStdErrToStdOut})
        let detachLog = detach.outputStream.readAll()
        let detachCode = detach.waitForExit()
        detach.close()
        doAssert detachCode == 0, detachLog
      if dirExists(mountPoint): removeDir(mountPoint)

proc testBuild() =
  let temporary = createTempDir("mynim-build-", "")
  defer: removeDir(temporary)

  let project = temporary / "project with spaces"
  doAssert runInit(@[
    "--name", "Ada & Counter",
    "--mygo", getCurrentDir(),
    project]) == 0

  createDir(project / "resources")
  writeFile(project / "resources" / "AppIcon.icns", "MYNIM-ICON-FIXTURE")

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
    let dmg = target / dmgPackage.dmgFileName("Ada & Counter",
      config["version"].getStr(), hostCPU)
    doAssert fileExists(dmg)
    verifyDmg(dmg, "ada-counter.app", temporary / "dmg mount")
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
  doAssert runBuild(@["-skip-build-command", "-skip-dmg", "-o", output,
    project]) == 0
  doAssert not fileExists(buildMarker)

  doAssert runBuild(@["-skip-dmg", "-o", output, project]) == 0
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
  config["i18n"] = parseJson("""{"source":"en","dir":"locales"}""")
  writeFile(configPath, config.pretty & "\n")
  createDir(project / "locales")
  writeFile(project / "locales" / "en.json", """{"hello": "Hello"}""")
  writeFile(project / "locales" / "de.json", """{"hello": "Hallo"}""")
  writeFile(project / "src" / "main.nim", """import mynim
import catalog_gen

doAssert catalog_gen.inLocale("de").hello() == "Hallo"
app.run()
""")
  doAssert runBuild(@["-skip-dmg", "-o", output, project]) == 0
  doAssert fileExists(project / "src" / "catalog_gen.nim")
  when defined(posix):
    writeFile(project / "resources" / "release.tar.gz", "release fixture")
    config["updates"] = parseJson(
      """{"publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","github":"owner/app"}""")
    writeFile(configPath, config.pretty & "\n")

    let fakeBin = temporary / "fake-bin"
    createDir(fakeBin)
    let ghLog = temporary / "gh-args.txt"
    let fakeGh = fakeBin / "gh"
    writeFile(fakeGh, """#!/bin/sh
printf '<%s>' "$@" >> "$MYNIM_TEST_GH_LOG"
printf '\n' >> "$MYNIM_TEST_GH_LOG"
if [ "$2" = "view" ]; then exit 1; fi
exit 0
""")
    setFilePermissions(fakeGh, {fpUserRead, fpUserWrite, fpUserExec})
    let oldPath = getEnv("PATH")
    let oldGhLog = getEnv("MYNIM_TEST_GH_LOG")
    putEnv("PATH", fakeBin & ":" & oldPath)
    putEnv("MYNIM_TEST_GH_LOG", ghLog)
    try:
      doAssert runBuild(@["-upload", "-skip-build-command", "-o", output,
        project]) == 0
    finally:
      putEnv("PATH", oldPath)
      putEnv("MYNIM_TEST_GH_LOG", oldGhLog)
    var ghCalls = readFile(ghLog).splitLines()
    if ghCalls.len > 0 and ghCalls[^1].len == 0:
      ghCalls.setLen(ghCalls.len - 1)
    doAssert ghCalls.len == 3
    doAssert ghCalls[0].contains("<release><view><v0.1.0>")
    doAssert ghCalls[1].contains("<release><create><v0.1.0>")
    doAssert ghCalls[2].contains("<release><upload><v0.1.0>")

  doAssert runBuild(@["-platform", "other/target", project]) == 1
  doAssert runBuild(@["-unknown", project]) == 2
  doAssert runBuild(@["--help"]) == 0

testBuild()
