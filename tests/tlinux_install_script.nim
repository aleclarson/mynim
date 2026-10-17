import std/[base64, json, os, osproc, streams, strutils, tempfiles, unittest]
import ../src/cmd/linux_install_script as installer
import ../src/cmd/linux_package as linuxPackage

proc writeExecutable(path, contents: string) =
  writeFile(path, contents)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc run(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc fixtureArchive(stage, archive: string) =
  let tar = findExe("tar")
  doAssert tar.len > 0
  let entries = linuxPackage.stageEntries(stage)
  let process = startProcess(tar, args = @["-czf", archive, "-C", stage,
    "--"] & entries, options = {poUsePath, poStdErrToStdOut})
  try:
    let output = process.outputStream.readAll()
    doAssert process.waitForExit() == 0, output
  finally:
    process.close()

proc configWithDesktop(): JsonNode =
  result = newJObject()
  result["linux"] = newJObject()
  result["linux"]["command"] = %"my-app"
  result["fileAssociations"] = %*[
    {"ext": ["note"], "name": "Note"}]
  result["urlSchemes"] = %*["my-app"]

proc makeApp(stage, version: string; config: JsonNode) =
  createDir(stage)
  writeExecutable(stage / "my-app", "#!/bin/sh\necho " & version & "\n")
  writeFile(stage / "my-app.png", "fixture icon")
  discard linuxPackage.writeLinuxDesktop(".", stage, "My App", "my-app",
    config)
  var desktop = readFile(stage / "my-app.desktop")
  desktop = desktop.replace("Icon=", "Icon=my-app")
  writeFile(stage / "my-app.desktop", desktop)

proc fakeLinuxBin(path: string) =
  createDir(path)
  writeExecutable(path / "uname", "#!/bin/sh\ncase \"$1\" in\n" &
    "-s) echo Linux ;;\n-m) echo x86_64 ;;\nesac\n")
  writeExecutable(path / "id", "#!/bin/sh\n[ \"$1\" = -u ] && echo 1000\n")

suite "Linux install script":
  test "installs the sibling archive, preserves other commands, and uninstalls only app files":
    let originalPath = getEnv("PATH")
    let originalHome = getEnv("HOME")
    let originalXdg = getEnv("XDG_DATA_HOME")
    defer:
      putEnv("PATH", originalPath)
      putEnv("HOME", originalHome)
      putEnv("XDG_DATA_HOME", originalXdg)

    let root = createTempDir("mynim-linux-install-", "")
    defer: removeDir(root)
    let fakeBin = root / "bin"
    fakeLinuxBin(fakeBin)
    putEnv("PATH", fakeBin & PathSep & originalPath)
    let home = root / "Jane Doe"
    putEnv("HOME", home)
    putEnv("XDG_DATA_HOME", "")
    let binDir = home / ".local" / "bin"
    createDir(binDir)
    writeExecutable(binDir / "my-app", "#!/bin/sh\necho another app\n")

    let config = configWithDesktop()
    let output = root / "output"
    createDir(output)
    let stage = root / "build-stage"
    makeApp(stage, "1.0.0", config)
    let archive = output / "my-app-1.0.0-linux-amd64.tar.gz"
    fixtureArchive(stage, archive)
    let script = installer.writeInstallScript(output, config, "My App",
      "1.0.0", "amd64")
    check fpUserExec in getFilePermissions(script)
    let archiveListing = run(findExe("tar"), @["-tzf", archive])
    check archiveListing.code == 0
    check "install.sh" notin archiveListing.output

    let syntax = run(findExe("sh"), @["-n", script])
    check syntax.code == 0
    let install = run(findExe("sh"), @[script])
    check install.code == 0
    check "Leaving " & (binDir / "my-app") & " alone" in install.output
    check "Installed My App" in install.output

    let appDir = home / ".local" / "my-app.app"
    let desktopPath = home / ".local" / "share" / "applications" / "my-app.desktop"
    let desktop = readFile(desktopPath)
    check "Exec=\"" & appDir / "my-app" & "\" %U\n" in desktop
    check "Icon=" & appDir / "my-app.png\n" in desktop
    check "MimeType=application/x-my-app-note;x-scheme-handler/my-app;\n" in desktop
    check readFile(home / ".local" / "share" / "mime" / "packages" /
      "my-app.xml").contains("*.note")
    check run(appDir / "my-app", @[]).output == "1.0.0\n"
    check readFile(binDir / "my-app").contains("another app")

    removeFile(binDir / "my-app")
    let reinstall = run(findExe("sh"), @[script, archive])
    check reinstall.code == 0
    check (binDir / "my-app").symLinkExists
    check expandSymlink(binDir / "my-app") == appDir / "my-app"

    let dataDir = home / ".local" / "share" / "My App"
    createDir(dataDir)
    writeFile(dataDir / "settings.json", "{}")
    let handlerDir = home / ".local" / "share" / "applications"
    let appHandler = handlerDir / "com.mygo.my-app.url-handler.desktop"
    let otherHandler = handlerDir / "other.url-handler.desktop"
    writeFile(appHandler, "Exec=\"" & appDir / "my-app" & "\" %u\n")
    writeFile(otherHandler, "Exec=/usr/bin/other %u\n")
    let uninstall = run(findExe("sh"), @[script, "--uninstall"])
    check uninstall.code == 0
    check not dirExists(appDir)
    check not fileExists(binDir / "my-app")
    check not fileExists(desktopPath)
    check not fileExists(home / ".local" / "share" / "mime" / "packages" /
      "my-app.xml")
    check not fileExists(appHandler)
    check fileExists(otherHandler)
    check fileExists(dataDir / "settings.json")

  test "downloads the archive named by the update manifest":
    let originalPath = getEnv("PATH")
    let originalHome = getEnv("HOME")
    defer:
      putEnv("PATH", originalPath)
      putEnv("HOME", originalHome)

    let root = createTempDir("mynim-linux-update-install-", "")
    defer: removeDir(root)
    let fakeBin = root / "bin"
    fakeLinuxBin(fakeBin)
    let server = root / "server"
    createDir(server)
    let manifest = server / "update.json"
    let remoteArchive = server / "app.tar.gz"
    writeExecutable(fakeBin / "curl", "#!/bin/sh\n" &
      "for url do :; done\n" &
      "case \"$url\" in\n" &
      "https://downloads.example.test/app/update-linux-amd64.json) cat \"$MANIFEST\" ;;\n" &
      "https://downloads.example.test/app/my-app-2.0.0-linux-amd64.tar.gz) cat \"$ARCHIVE\" ;;\n" &
      "*) exit 22 ;;\nesac\n")
    putEnv("PATH", fakeBin & PathSep & originalPath)
    putEnv("HOME", root / "Home")
    putEnv("MANIFEST", manifest)
    putEnv("ARCHIVE", remoteArchive)

    let config = configWithDesktop()
    let updates = newJObject()
    updates["publicKey"] = %encode(repeat("\0", 32))
    updates["url"] = %"https://downloads.example.test/app/"
    config["updates"] = updates
    let stage = root / "build-stage"
    makeApp(stage, "2.0.0", config)
    fixtureArchive(stage, remoteArchive)
    writeFile(manifest, "{\n  \"version\": \"2.0.0\",\n" &
      "  \"url\": \"https://downloads.example.test/app/" &
      "my-app-2.0.0-linux-amd64.tar.gz\",\n  \"size\": 1\n}\n")
    let scriptDir = root / "script"
    createDir(scriptDir)
    let script = installer.writeInstallScript(scriptDir, config, "My App",
      "2.0.0", "amd64")
    check "curl -fsSL https://downloads.example.test/app/install.sh | sh" in
      readFile(script)
    let syntax = run(findExe("sh"), @["-n", script])
    check syntax.code == 0
    let install = run(findExe("sh"), @[script])
    check install.code == 0
    check "Downloading My App 2.0.0" in install.output
    check run(getEnv("HOME") / ".local" / "my-app.app" / "my-app", @[]).output ==
      "2.0.0\n"

  test "custom GitHub tag prefixes select releases and emit a versioned script URL":
    var config = configWithDesktop()
    let updates = newJObject()
    updates["publicKey"] = %encode(repeat("\0", 32))
    updates["github"] = %"owner/app"
    updates["tagPrefix"] = %"desktop-v"
    config["updates"] = updates
    let script = installer.installScript(config, "My App", "1.2.3", "amd64")
    check "api.github.com/repos/owner/app/releases?per_page=100" in script
    check "desktop-v" in script
    check "releases/download/desktop-v1.2.3/install.sh" in script

    let latestConfig = configWithDesktop()
    let latestUpdates = newJObject()
    latestUpdates["publicKey"] = %encode(repeat("\0", 32))
    latestUpdates["github"] = %"owner/app"
    latestConfig["updates"] = latestUpdates
    let latestScript = installer.installScript(latestConfig, "My App",
      "1.2.3", "amd64")
    check "releases='https://github.com/owner/app/releases/latest/download/'" in
      latestScript
    check "curl -fsSL https://github.com/owner/app/releases/latest/download/install.sh | sh" in
      latestScript
    check "api=''" in latestScript

  test "custom GitHub tag lookup skips drafts and prereleases":
    let originalPath = getEnv("PATH")
    let originalHome = getEnv("HOME")
    defer:
      putEnv("PATH", originalPath)
      putEnv("HOME", originalHome)

    let root = createTempDir("mynim-linux-github-install-", "")
    defer: removeDir(root)
    let fakeBin = root / "bin"
    fakeLinuxBin(fakeBin)
    let server = root / "server"
    createDir(server)
    let releases = server / "releases.json"
    let manifest = server / "update.json"
    let remoteArchive = server / "app.tar.gz"
    writeExecutable(fakeBin / "curl", "#!/bin/sh\n" &
      "for url do :; done\n" &
      "case \"$url\" in\n" &
      "\"https://api.github.com/repos/owner/app/releases?per_page=100&page=1\") cat \"$RELEASES\" ;;\n" &
      "\"https://github.com/owner/app/releases/download/desktop-v1.1.0/update-linux-amd64.json\") cat \"$MANIFEST\" ;;\n" &
      "\"https://github.com/owner/app/releases/download/desktop-v1.1.0/my-app-1.1.0-linux-amd64.tar.gz\") cat \"$ARCHIVE\" ;;\n" &
      "*) exit 22 ;;\nesac\n")
    putEnv("PATH", fakeBin & PathSep & originalPath)
    putEnv("HOME", root / "Home")
    putEnv("RELEASES", releases)
    putEnv("MANIFEST", manifest)
    putEnv("ARCHIVE", remoteArchive)
    let config = configWithDesktop()
    let updates = newJObject()
    updates["publicKey"] = %encode(repeat("\0", 32))
    updates["github"] = %"owner/app"
    updates["tagPrefix"] = %"desktop-v"
    config["updates"] = updates

    let stage = root / "build-stage"
    makeApp(stage, "1.1.0", config)
    fixtureArchive(stage, remoteArchive)
    writeFile(manifest, "{\n  \"version\": \"1.1.0\",\n" &
      "  \"url\": \"https://github.com/owner/app/releases/download/" &
      "desktop-v1.1.0/my-app-1.1.0-linux-amd64.tar.gz\",\n  \"size\": 1\n}\n")
    writeFile(releases, "[\n" &
      "  {\"tag_name\":\"cli-v2.0.0\",\"draft\":false,\"prerelease\":false},\n" &
      "  {\"tag_name\":\"desktop-v1.3.0\",\"draft\":true,\"prerelease\":false},\n" &
      "  {\"tag_name\":\"desktop-v1.2.0-beta.1\",\"draft\":false,\"prerelease\":true},\n" &
      "  {\"tag_name\":\"desktop-v1.1.0\",\"draft\":false,\"prerelease\":false}\n]\n")
    let scriptDir = root / "script"
    createDir(scriptDir)
    let script = installer.writeInstallScript(scriptDir, config, "My App",
      "1.0.0", "amd64")
    let install = run(findExe("sh"), @[script])
    check install.code == 0
    check "Downloading My App 1.1.0" in install.output
    check run(getEnv("HOME") / ".local" / "my-app.app" / "my-app", @[]).output ==
      "1.1.0\n"

  test "does not replace an app resource named install.sh":
    let stage = createTempDir("mynim-linux-installer-collision-", "")
    defer: removeDir(stage)
    writeFile(stage / "install.sh", "app-owned script\n")
    expect ValueError:
      discard installer.writeInstallScript(stage, configWithDesktop(),
        "My App", "1.0.0", "amd64")
    check readFile(stage / "install.sh") == "app-owned script\n"

  test "quotes app names and rejects desktop-unsafe install paths":
    let originalPath = getEnv("PATH")
    let originalHome = getEnv("HOME")
    defer:
      putEnv("PATH", originalPath)
      putEnv("HOME", originalHome)

    let root = createTempDir("mynim-linux-install-path-", "")
    defer: removeDir(root)
    let fakeBin = root / "bin"
    fakeLinuxBin(fakeBin)
    putEnv("PATH", fakeBin & PathSep & originalPath)
    putEnv("HOME", root / "Jane\" Doe")
    let script = installer.installScript(newJObject(), "O'Reilly Notes",
      "1.0.0", "amd64")
    check "app_name='O'\\''Reilly Notes'" in script
    let scriptPath = root / "install.sh"
    writeExecutable(scriptPath, script)
    let help = run(findExe("sh"), @[scriptPath, "--help"])
    check help.code == 0
    check "O'Reilly Notes" in help.output
    let install = run(findExe("sh"), @[scriptPath])
    check install.code != 0
    check "characters a desktop entry cannot hold" in install.output
