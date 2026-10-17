import std/[assertions, base64, json, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/update_artifacts
import ../src/mynim/internal/update as updateRuntime
import ../src/mynim/internal/update_delta

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

  proc signArchive(openssl, archive, privateKey, work: string): string =
    let privatePrefix = hexBytes("302e020100300506032b657004220420")
    let privatePath = work / "fixture-update-key.der"
    let digestPath = work / "fixture-update.sha256"
    let signaturePath = work / "fixture-update.signature"
    writeFile(privatePath, privatePrefix & privateKey[0 ..< 32])
    let hashed = run(openssl,
      @[
        "dgst", "-sha256", "-binary", "-out", digestPath, archive])
    doAssert hashed.code == 0, hashed.output
    let signed = run(openssl, @[
      "pkeyutl", "-sign", "-rawin", "-inkey", privatePath,
      "-keyform", "DER", "-in", digestPath, "-out", signaturePath])
    doAssert signed.code == 0, signed.output
    encode(readFile(signaturePath))

  proc downloaderFor(archive, expectedUrl: string;
      expectedSize: int64): updateRuntime.FileDownloader =
    result = proc(url, path: string; size: int64;
        progress: updateRuntime.UpdateProgress) =
      doAssert url == expectedUrl
      doAssert size == expectedSize
      if progress != nil:
        progress(0, size)
      copyFile(archive, path)
      if progress != nil:
        progress(size, size)

  proc putFile(root, relative, contents: string) =
    let path = root / relative
    createDir(path.parentDir())
    writeFile(path, contents)

  proc testSignedInstall() =
    let openssl = findExe("openssl")
    let tar = findExe("tar")
    if openssl.len == 0 or tar.len == 0:
      return

    let publicKey = hexBytes(
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let privateKey = hexBytes(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60") &
      publicKey

    let temporary = createTempDir("mynim-update-install-", "")
    defer: removeDir(temporary)
    let project = temporary / "project"
    let stage = temporary / "stage"
    let stagedApp = stage / "sample-app.app"
    createDir(project)
    createDir(stagedApp / "Contents" / "MacOS")
    writeFile(stagedApp / "Contents" / "MacOS" / "sample-app",
      "updated native app")
    createSymlink("sample-app", stagedApp / "Contents" / "MacOS" / "current")

    let privatePath = project / "update.key"
    writeFile(privatePath, encode(privateKey) & "\n")
    var config = newJObject()
    var updates = newJObject()
    updates["publicKey"] = %encode(publicKey)
    updates["github"] = %"owner/app"
    updates["privateKey"] = %privatePath
    updates["deltas"] = %0
    config["updates"] = updates
    let previousKey = getEnv("MYGO_UPDATER_PRIVATE_KEY")
    putEnv("MYGO_UPDATER_PRIVATE_KEY", "")
    var artifacts: seq[string]
    try:
      artifacts = writeUpdateArtifacts(config, project, stage, "Sample App",
        "1.2.3", "darwin-arm64")
    finally:
      putEnv("MYGO_UPDATER_PRIVATE_KEY", previousKey)
    doAssert artifacts.len == 2
    let archive = artifacts[0]
    let manifest = updateRuntime.parseManifest(readFile(artifacts[1]))

    let installRoot = temporary / "installed"
    when defined(macosx):
      let target = installRoot / "sample-app.app"
      createDir(target / "Contents" / "MacOS")
      writeFile(target / "Contents" / "MacOS" / "sample-app", "old app")
      let installedBundle = target
    else:
      let target = installRoot
      createDir(target)
      writeFile(target / "old app", "old app")
      let installedBundle = target / "sample-app.app"

    var progressCalls = 0
    var finalProgress = false
    let progress: updateRuntime.UpdateProgress = proc(downloaded,
        total: int64) =
      inc progressCalls
      if downloaded == total:
        finalProgress = true
    let download = downloaderFor(archive, manifest.url, manifest.size)
    let installError = updateRuntime.installUpdate(manifest, encode(publicKey),
      target, progress, download)
    doAssert installError.isNil,
      (if installError.isNil: "" else: installError.msg)
    doAssert progressCalls >= 2
    doAssert finalProgress
    doAssert readFile(installedBundle / "Contents" / "MacOS" / "sample-app") ==
      "updated native app"
    doAssert readFile(installedBundle / "Contents" / "MacOS" / "current") ==
      "updated native app"

    writeFile(installedBundle / "Contents" / "MacOS" / "sample-app",
      "current app")
    var badSignature = manifest
    badSignature.signature = encode(repeat('x', 64))
    let badSignatureError = updateRuntime.installUpdate(badSignature,
      encode(publicKey), target, nil, download)
    doAssert badSignatureError != nil
    doAssert readFile(installedBundle / "Contents" / "MacOS" / "sample-app") ==
      "current app"

    let unsafeStage = temporary / "unsafe-stage"
    createDir(unsafeStage / "Contents")
    createSymlink("../../outside", unsafeStage / "Contents" / "outside")
    let unsafeArchive = temporary / "unsafe.tar.gz"
    let packed = run(tar,
      @["-czf", unsafeArchive, "-C", unsafeStage, "Contents"])
    doAssert packed.code == 0, packed.output
    let unsafeSignature = signArchive(openssl, unsafeArchive, privateKey,
      temporary)
    var unsafeManifest = manifest
    unsafeManifest.url = "https://updates.example.test/unsafe.tar.gz"
    unsafeManifest.size = getFileSize(unsafeArchive)
    unsafeManifest.signature = unsafeSignature
    let unsafeDownload = downloaderFor(unsafeArchive, unsafeManifest.url,
      unsafeManifest.size)
    let unsafeError = updateRuntime.installUpdate(unsafeManifest,
      encode(publicKey), target, nil, unsafeDownload)
    doAssert unsafeError != nil
    doAssert unsafeError.msg.contains("link points outside the app")
    doAssert readFile(installedBundle / "Contents" / "MacOS" / "sample-app") ==
      "current app"

  proc testSignedDeltaInstallAndFallback() =
    let openssl = findExe("openssl")
    let tar = findExe("tar")
    if openssl.len == 0 or tar.len == 0:
      return
    let publicKey = hexBytes(
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let privateKey = hexBytes(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60") &
      publicKey
    let temporary = createTempDir("mynim-update-delta-install-", "")
    defer: removeDir(temporary)
    let target = when defined(macosx):
      temporary / "installed" / "sample.app"
    else:
      temporary / "installed"
    let newDir = when defined(macosx):
      temporary / "stage" / "sample.app"
    else:
      temporary / "stage"
    createDir(target)
    createDir(newDir)
    when defined(macosx):
      let binaryRelative = "Contents/MacOS/sample"
      putFile(target, binaryRelative, "old app image")
      putFile(newDir, binaryRelative, "new app image with a small edit")
    else:
      let binaryRelative = "sample"
      putFile(target, binaryRelative, "old app image")
      putFile(newDir, binaryRelative, "new app image with a small edit")

    let deltaPath = temporary / "sample.delta"
    let deltaBytes = writeDelta("1.0.0", "2.0.0", target, newDir)
    var deltaContents = newString(deltaBytes.len)
    for i, value in deltaBytes:
      deltaContents[i] = char(value)
    writeFile(deltaPath, deltaContents)
    let deltaSignature = signArchive(openssl, deltaPath, privateKey, temporary)

    let fullArchive = temporary / "sample.tar.gz"
    let packed = when defined(macosx):
      run(tar, @["-czf", fullArchive, "-C", temporary / "stage", "sample.app"])
    else:
      run(tar, @["-czf", fullArchive, "-C", newDir, "sample"])
    doAssert packed.code == 0, packed.output
    let fullSignature = signArchive(openssl, fullArchive, privateKey, temporary)
    let deltaUrl = "https://updates.example.test/sample.delta"
    let fullUrl = "https://updates.example.test/sample.tar.gz"
    var manifest = updateRuntime.Manifest(
      version: "2.0.0", url: fullUrl, size: getFileSize(fullArchive),
      signature: fullSignature,
      deltas: @[updateRuntime.Delta(fromVersion: "1.0.0", url: deltaUrl,
        size: getFileSize(deltaPath), signature: deltaSignature)])
    var requested: seq[string]
    let downloader: updateRuntime.FileDownloader = proc(url, path: string;
        size: int64; progress: updateRuntime.UpdateProgress) =
      requested.add url
      let source = if url == deltaUrl: deltaPath
        elif url == fullUrl: fullArchive
        else: raise newException(ValueError, "unexpected fixture URL " & url)
      doAssert size == getFileSize(source)
      if progress != nil: progress(0, size)
      copyFile(source, path)
      if progress != nil: progress(size, size)

    let deltaError = updateRuntime.installUpdate(manifest, encode(publicKey),
      target, nil, downloader, "1.0.0")
    doAssert deltaError.isNil,
      (if deltaError.isNil: "" else: deltaError.msg)
    doAssert requested == @[deltaUrl]
    doAssert readFile(target / binaryRelative) == "new app image with a small edit"

    putFile(target, binaryRelative, "old app image")
    writeFile(deltaPath, "not a delta")
    manifest.deltas[0].size = getFileSize(deltaPath)
    manifest.deltas[0].signature =
      signArchive(openssl, deltaPath, privateKey, temporary)
    requested.setLen(0)
    let fallbackError = updateRuntime.installUpdate(manifest,
      encode(publicKey), target, nil, downloader, "1.0.0")
    doAssert fallbackError.isNil,
      (if fallbackError.isNil: "" else: fallbackError.msg)
    doAssert requested == @[deltaUrl, fullUrl]
    doAssert readFile(target / binaryRelative) == "new app image with a small edit"

  proc testDesktopEntryRefresh() =
    let temporary = createTempDir("mynim-desktop-refresh-", "")
    defer: removeDir(temporary)
    let name = "sample"
    let appDirectory = temporary / "installed"
    let data = temporary / "xdg-data"
    createDir(appDirectory)
    createDir(data / "applications")
    createDir(data / "mime" / "packages")
    let executable = appDirectory / name
    writeFile(executable, "app")
    writeFile(appDirectory / (name & ".png"), "icon")
    writeFile(appDirectory / (name & ".desktop"),
      "[Desktop Entry]\nName=Sample\nExec=sample --flag\nIcon=sample\n")
    writeFile(appDirectory / (name & ".xml"), "<mime-package>new</mime-package>\n")
    let entryPath = data / "applications" / (name & ".desktop")
    writeFile(entryPath, "[Desktop Entry]\nName=Sample\nExec=\"" &
      executable & "\" --flag\nIcon=old-icon\n")
    let mimePath = data / "mime" / "packages" / (name & ".xml")
    writeFile(mimePath, "<mime-package>old</mime-package>\n")

    let previousDataHome = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", data)
    try:
      let refreshError = updateRuntime.refreshDesktopEntry(appDirectory, name)
      doAssert refreshError.isNil,
        (if refreshError.isNil: "" else: refreshError.msg)
      let refreshed = readFile(entryPath)
      doAssert refreshed.contains("Exec=\"" & executable & "\" --flag")
      doAssert refreshed.contains(
        "Icon=" & (appDirectory / (name & ".png")))
      doAssert readFile(mimePath) == "<mime-package>new</mime-package>\n"

      removeFile(appDirectory / (name & ".xml"))
      let removeError = updateRuntime.refreshDesktopEntry(appDirectory, name)
      doAssert removeError.isNil,
        (if removeError.isNil: "" else: removeError.msg)
      doAssert not fileExists(mimePath)
    finally:
      putEnv("XDG_DATA_HOME", previousDataHome)

  testSignedInstall()
  testSignedDeltaInstallAndFallback()
  testDesktopEntryRefresh()
