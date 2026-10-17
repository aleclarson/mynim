import std/[json, os, strutils, tempfiles, unittest]
import ../src/cmd/windows_sign as windowsSign

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc put16(data: var string; offset: int; value: uint16) =
  data[offset] = char(value and 0xff)
  data[offset + 1] = char(value shr 8)

proc put32(data: var string; offset: int; value: uint32) =
  for index in 0 ..< 4:
    data[offset + index] = char((value shr (index * 8)) and 0xff)

proc writePe(path: string; signed: bool; optionalSize = 224) =
  var data = newString(512)
  data[0] = 'M'
  data[1] = 'Z'
  put32(data, 0x3c, 64)
  data[64 .. 67] = "PE\0\0"
  put16(data, 64 + 20, uint16(optionalSize))
  put16(data, 64 + 24, 0x10b)
  if optionalSize >= 96 + 5 * 8:
    put32(data, 64 + 24 + 92, 16)
    if signed:
      put32(data, 64 + 24 + 96 + 4 * 8 + 4, 128)
  writeFile(path, data)

proc emptyWindowsConfig(): JsonNode =
  result = newJObject()
  result["windows"] = newJObject()

suite "Windows code signing":
  test "recognizes PE images and preserves signatures":
    let dir = createTempDir("mynim-pe-", "")
    defer: removeDir(dir)
    writeFile(dir / "text.txt", "not a program")
    writePe(dir / "unsigned.exe", signed = false)
    writePe(dir / "signed.dll", signed = true)
    writePe(dir / "short-header.exe", signed = false, optionalSize = 120)

    check windowsSign.peImage(dir / "text.txt") == (image: false, signed: false)
    check windowsSign.peImage(dir / "unsigned.exe") == (image: true, signed: false)
    check windowsSign.peImage(dir / "signed.dll") == (image: true, signed: true)
    check windowsSign.peImage(dir / "short-header.exe") == (image: true, signed: false)

  test "runs a custom signing command with a safely quoted file path":
    let oldPath = getEnv("PATH")
    defer: putEnv("PATH", oldPath)
    let root = createTempDir("mynim-sign-command-", "")
    defer: removeDir(root)
    let file = root / "Jane's App.exe"
    writeFile(file, "executable")
    let log = root / "signed paths.txt"
    var config = emptyWindowsConfig()
    config["windows"]["signCommand"] =
      %("printf '%s\\n' %1 >> '" & log.replace("'", "'\\''") & "'")

    windowsSign.signWindowsFile(root, config, file)
    check readFile(log).strip() == file

  test "uses osslsigncode with the configured timestamp and password":
    let oldPath = getEnv("PATH")
    let oldPassword = getEnv("MYGO_WINDOWS_CERTIFICATE_PASSWORD")
    defer:
      putEnv("PATH", oldPath)
      putEnv("MYGO_WINDOWS_CERTIFICATE_PASSWORD", oldPassword)
    let root = createTempDir("mynim-osslsign-", "")
    defer: removeDir(root)
    let tools = root / "bin"
    createDir(tools)
    let argsLog = root / "arguments.txt"
    writeExecutable(tools / "osslsigncode", "#!/bin/sh\n" &
      "printf '%s\\n' \"$@\" > \"$SIGN_ARGS\"\n" &
      "output=\nwhile [ $# -gt 0 ]; do\n" &
      "  if [ \"$1\" = -out ]; then shift; output=$1; fi\n" &
      "  shift\ndone\n" &
      "[ -n \"$output\" ] || exit 2\nprintf signed > \"$output\"\n")
    putEnv("PATH", tools & PathSep & oldPath)
    putEnv("MYGO_WINDOWS_CERTIFICATE_PASSWORD", "test password")
    putEnv("SIGN_ARGS", argsLog)
    let certificate = root / "signing.pfx"
    writeFile(certificate, "fixture")
    let file = root / "App.exe"
    writeFile(file, "unsigned executable")
    var config = emptyWindowsConfig()
    config["windows"]["certificate"] = %"signing.pfx"
    config["windows"]["timestampUrl"] = %"https://tsa.example.test"

    windowsSign.signWindowsFile(root, config, file)
    let args = readFile(argsLog)
    check "-pkcs12\n" in args
    check "signing.pfx\n" in args
    check "-ts\nhttps://tsa.example.test\n" in args
    check "-pass\ntest password\n" in args
    check readFile(file) == "signed"
    check not fileExists(file & ".signed")

  test "signs only unsigned PE resources and rejects conflicting settings":
    let oldPath = getEnv("PATH")
    defer: putEnv("PATH", oldPath)
    let root = createTempDir("mynim-sign-resources-", "")
    defer: removeDir(root)
    let stage = root / "stage"
    let nested = stage / "helpers"
    createDir(nested)
    let app = stage / "app.exe"
    let helper = nested / "helper.dll"
    let signedHelper = nested / "vendor.dll"
    writeFile(app, "compiled executable")
    writePe(helper, signed = false)
    writePe(signedHelper, signed = true)
    writeFile(nested / "notes.txt", "not a binary")
    let signLog = root / "sign.log"
    var config = emptyWindowsConfig()
    config["windows"]["signCommand"] =
      %("printf '%s\\n' %1 >> '" & signLog & "'")

    windowsSign.signWindowsBuild(root, stage, "app.exe", config)
    let signed = readFile(signLog).strip().splitLines()
    check signed.len == 2
    check signed[0] == app
    check signed[1] == helper

    config["windows"]["certificate"] = %"another.pfx"
    expect ValueError:
      discard windowsSign.signingEnabled(config)
