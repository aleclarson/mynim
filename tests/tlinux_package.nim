import std/[assertions, base64, json, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/linux_package

proc run(command: string; args: seq[string]; workingDir: string):
    tuple[code: int, output: string] =
  let process = startProcess(command, args = args, workingDir = workingDir,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc arMember(archive, wanted: string): string =
  doAssert archive.startsWith("!<arch>\n"), "not an ar archive"
  var offset = 8
  while offset + 60 <= archive.len:
    let header = archive[offset ..< offset + 60]
    let name = header[0 ..< 16].strip().strip(chars = {'/'})
    let size = parseInt(header[48 ..< 58].strip())
    let first = offset + 60
    let past = first + size
    doAssert past <= archive.len, "truncated ar member " & name
    if name == wanted:
      return archive[first ..< past]
    offset = past + (size mod 2)
  raise newException(AssertionDefect, "ar member not found: " & wanted)

proc testLinuxPackage() =
  let temporary = createTempDir("mynim-linux-package-test-", "")
  defer:
    if dirExists(temporary): removeDir(temporary)
  let project = temporary / "project"
  let stage = temporary / "stage"
  createDir(project / "resources")
  createDir(stage / "data")
  writeFile(project / "icon.png", decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/tjgAAAAASUVORK5CYII="))
  writeFile(stage / "sample-app", "native binary")
  setFilePermissions(stage / "sample-app", {fpUserRead, fpUserWrite,
    fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  writeFile(stage / "data" / "payload.txt", "payload")
  let config = parseJson("""{
    "name": "Sample App",
    "version": "v1.2.3-beta.1+build",
    "icon": "icon.png",
    "linux": {
      "maintainer": "Example Maintainer <maintainer@example.test>",
      "comment": "Notes and files",
      "categories": ["Office", "Utility"],
      "depends": ["libnotify4"],
      "command": "sample-cli"
    },
    "fileAssociations": [
      {"ext": ["note", "notes"], "name": "Note & draft"},
      {"ext": ["md"], "mimeType": "text/markdown"}
    ],
    "urlSchemes": ["sample"]
  }""")

  let metadataFiles = writeLinuxDesktop(project, stage, "Sample App",
    "sample-app", config)
  doAssert "sample-app.png" in metadataFiles
  doAssert "sample-app.xml" in metadataFiles
  doAssert "sample-app.desktop" in metadataFiles
  let desktop = readFile(stage / "sample-app.desktop")
  doAssert "Exec=sample-app %U\n" in desktop, desktop
  doAssert "Categories=Office;Utility;\n" in desktop, desktop
  doAssert "MimeType=application/x-sample-app-note;text/markdown;x-scheme-handler/sample;\n" in desktop, desktop
  doAssert "<comment>Note &amp; draft</comment>" in
    readFile(stage / "sample-app.xml")

  let entries = stageEntries(stage)
  let artifacts = writeLinuxArtifacts(project, stage, "Sample App",
    "sample-app", "v1.2.3-beta.1+build", "amd64", config, entries)
  doAssert artifacts.len == 2, $artifacts
  doAssert artifacts[0].endsWith(
    "sample-app-v1.2.3-beta.1+build-linux-amd64.tar.gz")
  doAssert artifacts[1].endsWith(
    "sample-app_1.2.3~beta.1~build_amd64.deb")
  let signedArchiveBytes = readFile(artifacts[0])
  discard writeLinuxArtifacts(project, stage, "Sample App", "sample-app",
    "v1.2.3-beta.1+build", "amd64", config, entries,
    reuseArchive = true)
  doAssert readFile(artifacts[0]) == signedArchiveBytes,
    "packaging replaced a previously signed update archive"

  let tar = findExe("tar")
  doAssert tar.len > 0
  let archiveList = run(tar, @["-tzf", artifacts[0]], temporary)
  doAssert archiveList.code == 0, archiveList.output
  doAssert "sample-app" in archiveList.output
  doAssert "sample-app.desktop" in archiveList.output
  doAssert "sample-app.xml" in archiveList.output

  let controlDir = temporary / "control"
  let dataDir = temporary / "package-data"
  createDir(controlDir)
  createDir(dataDir)
  let deb = readFile(artifacts[1])
  let ar = findExe("ar")
  doAssert ar.len > 0
  let arListing = run(ar, @["t", artifacts[1]], temporary)
  doAssert arListing.code == 0, arListing.output
  doAssert "debian-binary" in arListing.output, arListing.output
  doAssert "control.tar.gz" in arListing.output, arListing.output
  doAssert "data.tar.gz" in arListing.output, arListing.output
  writeFile(temporary / "control.tar.gz", arMember(deb, "control.tar.gz"))
  writeFile(temporary / "data.tar.gz", arMember(deb, "data.tar.gz"))
  let controlExtracted = run(tar,
    @["-xzf", temporary / "control.tar.gz", "-C", controlDir], temporary)
  doAssert controlExtracted.code == 0, controlExtracted.output
  let dataExtracted = run(tar,
    @["-xzf", temporary / "data.tar.gz", "-C", dataDir], temporary)
  doAssert dataExtracted.code == 0, dataExtracted.output
  let control = readFile(controlDir / "control")
  doAssert "Package: sample-app\n" in control, control
  doAssert "Version: 1.2.3~beta.1~build\n" in control, control
  doAssert "Architecture: amd64\n" in control, control
  doAssert "Maintainer: Example Maintainer <maintainer@example.test>\n" in control, control
  doAssert "Depends: libgtk-3-0 | libgtk-3-0t64, libwebkit2gtk-4.1-0, libnotify4\n" in control, control
  let installedApp = dataDir / "opt" / "sample-app"
  doAssert readFile(installedApp / "sample-app") == "native binary"
  doAssert readFile(installedApp / "data" / "payload.txt") == "payload"
  let commandLink = dataDir / "usr" / "bin" / "sample-cli"
  doAssert getFileInfo(commandLink, followSymlink = false).kind == pcLinkToFile
  doAssert fileExists(commandLink)
  let installedDesktop = readFile(dataDir / "usr" / "share" /
    "applications" / "sample-app.desktop")
  doAssert "Exec=/opt/sample-app/sample-app %U\n" in installedDesktop,
    installedDesktop
  doAssert "Icon=sample-app\n" in installedDesktop, installedDesktop
  doAssert fileExists(dataDir / "usr" / "share" / "icons" / "hicolor" /
    "1x1" / "apps" / "sample-app.png")
  doAssert "opt/sample-app/sample-app" in
    readFile(controlDir / "md5sums")

  let minimalProject = temporary / "minimal-project"
  let minimalStage = temporary / "minimal-stage"
  createDir(minimalProject)
  createDir(minimalStage)
  writeFile(minimalStage / "minimal-app", "minimal binary")
  writeFile(minimalStage / "minimal-app.png", "resource png")
  writeFile(minimalStage / "minimal-app.xml", "resource xml")
  let minimalConfig = parseJson("""{"name":"Minimal App","version":"1.0.0"}""")
  discard writeLinuxDesktop(minimalProject, minimalStage, "Minimal App",
    "minimal-app", minimalConfig)
  let minimalEntries = stageEntries(minimalStage)
  let minimalArtifacts = writeLinuxArtifacts(minimalProject, minimalStage,
    "Minimal App", "minimal-app", "1.0.0", "amd64", minimalConfig,
    minimalEntries)
  let minimalData = arMember(readFile(minimalArtifacts[1]), "data.tar.gz")
  writeFile(temporary / "minimal-data.tar.gz", minimalData)
  let minimalExtract = temporary / "minimal-data"
  createDir(minimalExtract)
  let minimalUnpack = run(tar,
    @["-xzf", temporary / "minimal-data.tar.gz", "-C", minimalExtract],
    temporary)
  doAssert minimalUnpack.code == 0, minimalUnpack.output
  doAssert readFile(minimalExtract / "opt" / "minimal-app" /
    "minimal-app.png") == "resource png"
  doAssert readFile(minimalExtract / "opt" / "minimal-app" /
    "minimal-app.xml") == "resource xml"

  let badConfig = parseJson("""{"linux":{"command":"../bad"}}""")
  let badStage = temporary / "bad-stage"
  createDir(badStage)
  var rejected = false
  try:
    discard writeLinuxDesktop(project, badStage, "Sample App", "sample-app",
      badConfig)
  except ValueError:
    rejected = true
  doAssert rejected, "accepted an invalid linux.command"

testLinuxPackage()
