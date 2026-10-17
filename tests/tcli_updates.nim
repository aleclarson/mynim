import std/[assertions, base64, json, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/update_artifacts

proc hexBytes(value: string): string =
  doAssert value.len mod 2 == 0
  for index in countup(0, value.len - 1, 2):
    result.add char(parseHexInt(value[index .. index + 1]))

when defined(posix):
  proc run(executable: string; args: seq[string]):
      tuple[code: int, output: string] =
    let process = startProcess(executable, args = args,
      options = {poUsePath, poStdErrToStdOut})
    try:
      result.output = process.outputStream.readAll()
      result.code = process.waitForExit()
    finally:
      process.close()

  proc testSignedUpdate() =
    let openssl = findExe("openssl")
    let tar = findExe("tar")
    if openssl.len == 0 or tar.len == 0:
      return

    let publicKey = hexBytes(
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let privateKey = hexBytes(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60") &
      publicKey

    let temporary = createTempDir("mynim-signed-update-", "")
    defer: removeDir(temporary)
    let project = temporary / "project"
    let stage = temporary / "stage"
    let app = stage / "sample-app.app"
    createDir(project)
    createDir(app / "Contents" / "MacOS")
    let executable = app / "Contents" / "MacOS" / "sample-app"
    writeFile(executable, "native app")
    createSymlink("sample-app", app / "Contents" / "MacOS" / "current")
    writeFile(project / "CHANGELOG.md",
      "## [1.2.3] - 2026-10-17\n\nUpdate release notes.\n")

    let privatePath = temporary / "update.key"
    writeFile(privatePath, encode(privateKey) & "\n")
    var config = newJObject()
    var updates = newJObject()
    updates["publicKey"] = %encode(publicKey)
    updates["github"] = %"owner/app"
    updates["tagPrefix"] = %"desktop-v"
    updates["privateKey"] = %privatePath
    config["updates"] = updates

    let previousKey = getEnv("MYGO_UPDATER_PRIVATE_KEY")
    putEnv("MYGO_UPDATER_PRIVATE_KEY", "")
    var files: seq[string]
    try:
      files = writeUpdateArtifacts(config, project, stage, "Sample App",
        "1.2.3", "darwin-arm64")
    finally:
      putEnv("MYGO_UPDATER_PRIVATE_KEY", previousKey)

    doAssert files.len == 2
    let archive = stage / "sample-app-1.2.3-darwin-arm64.tar.gz"
    let manifestPath = stage / "update-darwin-arm64.json"
    doAssert files == @[archive, manifestPath]
    let manifest = parseFile(manifestPath)
    doAssert manifest["version"].getStr() == "1.2.3"
    doAssert manifest["notes"].getStr() == "Update release notes."
    doAssert manifest["url"].getStr() ==
      "https://github.com/owner/app/releases/download/" &
      "desktop-v1.2.3/sample-app-1.2.3-darwin-arm64.tar.gz"
    doAssert manifest["size"].getInt() == getFileSize(archive)
    let signature = decode(manifest["signature"].getStr())
    doAssert signature.len == 64

    let archiveList = run(tar, @["-tzf", archive])
    doAssert archiveList.code == 0, archiveList.output
    doAssert archiveList.output.contains(
      "sample-app.app/Contents/MacOS/sample-app")
    doAssert archiveList.output.contains(
      "sample-app.app/Contents/MacOS/current")

    let publicDer = temporary / "update-public.der"
    let digest = temporary / "archive.sha256"
    let signaturePath = temporary / "archive.signature"
    let publicPrefix = hexBytes("302a300506032b6570032100")
    writeFile(publicDer, publicPrefix & publicKey)
    writeFile(signaturePath, signature)
    let hashed = run(openssl,
      @["dgst", "-sha256", "-binary", "-out", digest, archive])
    doAssert hashed.code == 0, hashed.output
    let verified = run(openssl, @["pkeyutl", "-verify", "-rawin", "-pubin",
      "-inkey", publicDer, "-keyform", "DER", "-in", digest,
      "-sigfile", signaturePath])
    doAssert verified.code == 0, verified.output

    var urlConfig = newJObject()
    var urlUpdates = newJObject()
    urlUpdates["publicKey"] = %encode(publicKey)
    urlUpdates["privateKey"] = %privatePath
    urlUpdates["url"] = %"https://downloads.example.test/my-app/"
    urlUpdates["deltas"] = %0
    urlConfig["updates"] = urlUpdates
    let urlStage = temporary / "url-stage"
    createDir(urlStage / "sample-app.app" / "Contents" / "MacOS")
    writeFile(urlStage / "sample-app.app" / "Contents" / "MacOS" /
      "sample-app", "native app")
    putEnv("MYGO_UPDATER_PRIVATE_KEY", "")
    try:
      discard writeUpdateArtifacts(urlConfig, project, urlStage, "Sample App",
        "1.2.3", "darwin-arm64")
    finally:
      putEnv("MYGO_UPDATER_PRIVATE_KEY", previousKey)
    let urlManifest = parseFile(urlStage / "update-darwin-arm64.json")
    doAssert urlManifest["url"].getStr() ==
      "https://downloads.example.test/my-app/" &
      "sample-app-1.2.3-darwin-arm64.tar.gz"

when defined(posix):
  testSignedUpdate()
