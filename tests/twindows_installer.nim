import std/[json, os, strutils, tempfiles, unittest]
import ../src/cmd/windows_installer as windowsInstaller
import ../src/cmd/windows_sign as windowsSign
import ../src/mynim/image as imagePackage

proc bytesString(value: openArray[byte]): string =
  result = newString(value.len)
  for index, ch in value:
    result[index] = char(ch)

suite "Windows installer packaging":
  test "creates an ICO with the standard Windows PNG sizes":
    let image = imagePackage.newNrgba(imagePackage.rect(0, 0, 1, 1))
    image.set(0, 0, imagePackage.Nrgba(r: 220, g: 80, b: 30, a: 255))
    let png = imagePackage.pngEncode(image)
    let ico = windowsInstaller.pngToIco(png)
    check ico[0] == 0
    check ico[1] == 0
    check ico[2] == 1
    check ico[4] == 7
    check ico[5] == 0
    check ico.len > 6 + 7 * 16

  test "compiles a per-user installer with resources, associations, and languages":
    let root = createTempDir("mynim-windows-installer-test-", "")
    defer:
      if dirExists(root):
        removeDir(root)
    let project = root / "project"
    let stage = root / "stage"
    let fakeBin = root / "tools"
    let locales = project / "locales"
    createDir(project / "resources")
    createDir(locales)
    createDir(stage / "assets")
    createDir(fakeBin)
    writeFile(stage / "my-app.exe", "windows executable fixture")
    writeFile(stage / "assets" / "data.bin", "resource fixture")
    writeFile(locales / "fr.json", "{}")
    writeFile(locales / "es-419.json", "{}")
    writeFile(locales / "zh-HK.json", "{}")

    let icon = imagePackage.newNrgba(imagePackage.rect(0, 0, 1, 1))
    icon.set(0, 0, imagePackage.Nrgba(r: 30, g: 120, b: 220, a: 255))
    writeFile(project / "resources" / "icon.png",
      bytesString(imagePackage.pngEncode(icon)))

    let capture = root / "captured.nsi"
    let signLog = root / "signed-files.txt"
    let fake = fakeBin / "makensis"
    let signer = fakeBin / "signer"
    writeFile(signer, """#!/bin/sh
printf '%s\n' "$1" >> "$MYNIM_TEST_SIGN_LOG"
""")
    setFilePermissions(signer, {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(fake, """#!/bin/sh
set -e
if [ "$1" = "-VERSION" ]; then
  printf 'v3.13\n'
  exit 0
fi
/bin/cp "$2" "$MYNIM_TEST_CAPTURE"
out=$(/usr/bin/sed -n 's/^OutFile "\(.*\)"$/\1/p' "$2")
: > "$out"
""")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let originalPath = getEnv("PATH")
    let hadCapture = existsEnv("MYNIM_TEST_CAPTURE")
    let originalCapture = getEnv("MYNIM_TEST_CAPTURE")
    let hadSignLog = existsEnv("MYNIM_TEST_SIGN_LOG")
    let originalSignLog = getEnv("MYNIM_TEST_SIGN_LOG")
    putEnv("PATH", fakeBin & ":" & originalPath)
    putEnv("MYNIM_TEST_CAPTURE", capture)
    putEnv("MYNIM_TEST_SIGN_LOG", signLog)
    defer:
      putEnv("PATH", originalPath)
      if hadCapture:
        putEnv("MYNIM_TEST_CAPTURE", originalCapture)
      else:
        delEnv("MYNIM_TEST_CAPTURE")
      if hadSignLog:
        putEnv("MYNIM_TEST_SIGN_LOG", originalSignLog)
      else:
        delEnv("MYNIM_TEST_SIGN_LOG")

    var config = newJObject()
    config["icon"] = %"resources/icon.png"
    config["i18n"] = %*{"source": "en", "dir": "locales"}
    config["fileAssociations"] = %*[
      {"ext": ["md", "markdown"], "name": "Markdown document"}]
    config["urlSchemes"] = %*["mynim"]
    config["windows"] = %*{"signCommand": signer & " %1"}
    let files = windowsInstaller.stageFiles(stage)
    check files == @["assets/data.bin", "my-app.exe"]

    let setup = windowsInstaller.writeWindowsInstaller(project, stage,
      "My App", "com.example.myapp", "1.2.3", "my-app.exe", "amd64",
      config, files)
    check setup == stage / "My App Setup 1.2.3 amd64.exe"
    check fileExists(setup)
    let script = readFile(capture)
    check script.contains("InstallDir \"$LOCALAPPDATA\\Programs\\My App\"")
    check script.contains("RequestExecutionLevel user")
    check script.contains("WriteUninstaller \"$INSTDIR\\Uninstall.exe\"")
    check script.contains("DisplayName")
    check script.contains("CreateDesktopShortcut")
    check script.contains("!uninstfinalize '")
    check script.contains("sign-uninstaller \"%1\"")
    check script.contains("SetOutPath \"$INSTDIR\\assets\"")
    check script.contains("Software\\Classes\\com.example.myapp.md")
    check script.contains("Software\\Classes\\mynim\\shell\\open\\command")
    check script.contains("!define MUI_ICON")
    check script.contains("!insertmacro MUI_LANGUAGE \"English\"")
    check script.contains("!insertmacro MUI_LANGUAGE \"SpanishInternational\"")
    check script.contains("!insertmacro MUI_LANGUAGE \"French\"")
    check script.contains("!insertmacro MUI_LANGUAGE \"TradChinese\"")
    check readFile(signLog).strip() == setup

  test "rejects unsupported catalog languages and unsafe identifiers":
    let root = createTempDir("mynim-windows-installer-invalid-", "")
    defer:
      if dirExists(root):
        removeDir(root)
    createDir(root / "locales")
    writeFile(root / "locales" / "xx.json", "{}")
    var config = newJObject()
    config["i18n"] = %*{"source": "en", "dir": "locales"}
    expect ValueError:
      discard windowsInstaller.installerScript(root, root, root / "app.exe",
        "App", "com.example.app", "1.0.0", "app.exe", config,
        @["app.exe"], "")

    config = newJObject()
    expect ValueError:
      discard windowsInstaller.installerScript(root, root, root / "app.exe",
        "App", "com.example/unsafe", "1.0.0", "app.exe", config,
        @["app.exe"], "")

  test "sanitizes the generated setup filename":
    check windowsInstaller.installerFileName("My: App", "1.2/3", "amd64") ==
      "My- App Setup 1.2-3 amd64.exe"

  test "the hidden NSIS callback signs the generated uninstaller":
    let root = createTempDir("mynim-uninstaller-sign-test-", "")
    defer:
      if dirExists(root):
        removeDir(root)
    let file = root / "Uninstall.exe"
    let signer = root / "signer"
    let log = root / "signed.txt"
    writeFile(file, "uninstaller fixture")
    writeFile(signer, """#!/bin/sh
printf '%s\n' "$1" > "$MYNIM_TEST_SIGN_LOG"
""")
    setFilePermissions(signer, {fpUserRead, fpUserWrite, fpUserExec})
    let hadSettings = existsEnv("MYNIM_WINDOWS_SIGN_SETTINGS")
    let originalSettings = getEnv("MYNIM_WINDOWS_SIGN_SETTINGS")
    let hadLog = existsEnv("MYNIM_TEST_SIGN_LOG")
    let originalLog = getEnv("MYNIM_TEST_SIGN_LOG")
    putEnv("MYNIM_TEST_SIGN_LOG", log)
    var settings = newJObject()
    settings["projectDir"] = %root
    settings["windows"] = %*{"signCommand": signer & " %1"}
    putEnv("MYNIM_WINDOWS_SIGN_SETTINGS", $settings)
    defer:
      if hadSettings:
        putEnv("MYNIM_WINDOWS_SIGN_SETTINGS", originalSettings)
      else:
        delEnv("MYNIM_WINDOWS_SIGN_SETTINGS")
      if hadLog:
        putEnv("MYNIM_TEST_SIGN_LOG", originalLog)
      else:
        delEnv("MYNIM_TEST_SIGN_LOG")

    check windowsSign.signUninstallerCommand(file) == 0
    check readFile(log).strip() == file
