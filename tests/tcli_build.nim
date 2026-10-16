import std/[assertions, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/build
import ../src/cmd/init

proc testBuild() =
  let temporary = createTempDir("mynim-build-", "")
  defer: removeDir(temporary)

  let project = temporary / "project with spaces"
  doAssert runInit(@[
    "--name", "Ada & Counter",
    "--mygo", getCurrentDir(),
    project]) == 0

  let output = temporary / "build output"
  doAssert runBuild(@["-o", output, project]) == 0
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

  doAssert runBuild(@["-o", output, project]) == 0
  when hostOS == "macosx":
    doAssert fileExists(target / "ada-counter.app" / "Contents" / "MacOS" /
      executable)
  else:
    doAssert fileExists(target / executable)

  doAssert runBuild(@["-platform", "other/target", project]) == 1
  doAssert runBuild(@["-unknown", project]) == 2
  doAssert runBuild(@["--help"]) == 0

testBuild()
