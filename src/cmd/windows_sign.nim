## Sign Windows executables and unsigned PE resources.

import std/[json, os, osproc, streams, strutils]
when hostOS == "windows":
  import std/algorithm

type
  SignSettings = object
    certificate, signCommand, timestampUrl: string

proc field(node: JsonNode; name, path: string): string =
  if node.kind != JObject or not node.hasKey(name):
    return ""
  if node[name].kind != JString:
    raise newException(ValueError, "mygo.json: " & path & " must be a string")
  node[name].getStr()

proc settings(config: JsonNode): SignSettings =
  if config.kind != JObject or not config.hasKey("windows") or
      config["windows"].kind == JNull:
    return
  let windows = config["windows"]
  if windows.kind != JObject:
    raise newException(ValueError, "mygo.json: windows must be an object")
  result.certificate = field(windows, "certificate", "windows.certificate")
  result.signCommand = field(windows, "signCommand", "windows.signCommand")
  result.timestampUrl = field(windows, "timestampUrl", "windows.timestampUrl")
  if result.certificate.len > 0 and result.signCommand.len > 0:
    raise newException(ValueError,
      "mygo.json: windows.certificate and windows.signCommand exclude each other")
  if result.timestampUrl.len == 0:
    result.timestampUrl = "http://timestamp.digicert.com"

proc signingEnabled*(config: JsonNode): bool =
  let value = settings(config)
  value.certificate.len > 0 or value.signCommand.len > 0

proc runTool(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc shellQuote(value: string): string =
  when hostOS == "windows":
    "\"" & value & "\""
  else:
    "'" & value.replace("'", "'\\''") & "'"

proc runSignCommand(command, projectDir, file: string) =
  let expanded = command.replace("%1", shellQuote(file))
  when hostOS == "windows":
    let shell = getEnv("COMSPEC", "cmd.exe")
    let process = startProcess(shell, args = @["/C", expanded],
      workingDir = projectDir, options = {poUsePath, poStdErrToStdOut})
  else:
    let process = startProcess("/bin/sh", args = @["-c", expanded],
      workingDir = projectDir, options = {poUsePath, poStdErrToStdOut})
  try:
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    if code != 0:
      # A custom signing command may print credentials or other secrets.
      raise newException(IOError,
        "windows.signCommand exited with status " & $code)
    discard output
  finally:
    process.close()

when hostOS == "windows":
  proc signtoolPath(): string =
    result = findExe("signtool.exe")
    if result.len == 0:
      result = findExe("signtool")
    if result.len > 0:
      return
    let arch = when hostCPU == "arm64": "arm64" else: "x64"
    let sdkRoot = getEnv("ProgramFiles(x86)") / "Windows Kits" / "10" / "bin"
    if not dirExists(sdkRoot):
      return
    var matches: seq[string]
    for versionDir in walkDirs(sdkRoot / "10.*"):
      let candidate = versionDir / arch / "signtool.exe"
      if fileExists(candidate):
        matches.add candidate
    matches.sort()
    if matches.len > 0:
      result = matches[^1]

proc signWindowsFile*(projectDir: string; config: JsonNode; file: string) =
  let win = settings(config)
  if win.signCommand.len > 0:
    runSignCommand(win.signCommand, projectDir, file)
    return
  if win.certificate.len == 0:
    return
  let certificate = if isAbsolute(win.certificate): win.certificate
    else: projectDir / win.certificate
  if not fileExists(certificate):
    raise newException(IOError,
      "mygo.json: windows.certificate does not exist: " & certificate)
  let password = getEnv("MYGO_WINDOWS_CERTIFICATE_PASSWORD")
  when hostOS == "windows":
    let tool = signtoolPath()
    if tool.len == 0:
      raise newException(IOError,
        "signing Windows apps needs signtool from the Windows SDK")
    var args = @[
      "sign", "/f", certificate, "/fd", "sha256", "/tr", win.timestampUrl,
      "/td", "sha256"]
    if password.len > 0:
      args.add ["/p", password]
    args.add file
    let signed = runTool(tool, args)
    if signed.code != 0:
      raise newException(IOError,
        "signtool failed with status " & $signed.code)
  else:
    let tool = findExe("osslsigncode")
    if tool.len == 0:
      raise newException(IOError,
        "signing Windows apps here needs osslsigncode (brew install osslsigncode, apt install osslsigncode)")
    let outputPath = file & ".signed"
    if fileExists(outputPath):
      removeFile(outputPath)
    defer:
      if fileExists(outputPath):
        removeFile(outputPath)
    var args = @[
      "sign", "-pkcs12", certificate, "-h", "sha256", "-ts",
      win.timestampUrl, "-in", file, "-out", outputPath]
    if password.len > 0:
      args.add ["-pass", password]
    let signed = runTool(tool, args)
    if signed.code != 0:
      raise newException(IOError,
        "osslsigncode failed with status " & $signed.code)
    moveFile(outputPath, file)

proc little16(data: openArray[byte]; offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc little32(data: openArray[byte]; offset: int): uint32 =
  uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)

proc readAt(file: File; offset: int64; buffer: var openArray[byte]): bool =
  try:
    setFilePos(file, offset)
    file.readBuffer(addr buffer[0], buffer.len) == buffer.len
  except CatchableError:
    false

proc peImage*(path: string): tuple[image, signed: bool] =
  var file: File
  if not open(file, path, fmRead):
    return
  defer: file.close()
  var dos: array[64, byte]
  if not readAt(file, 0, dos) or dos[0] != uint8('M') or dos[1] != uint8('Z'):
    return
  let peOffset = int64(little32(dos, 0x3c))
  var header: array[26, byte]
  if not readAt(file, peOffset, header) or header[0 .. 3] != [
      0x50'u8, 0x45'u8, 0x00'u8, 0x00'u8]:
    return
  result.image = true
  let optionalSize = int(little16(header, 20))
  var directoryOffset: int
  case little16(header, 24)
  of 0x10b: directoryOffset = 96
  of 0x20b: directoryOffset = 112
  else: return
  const securityDirectory = 4
  if optionalSize < directoryOffset + (securityDirectory + 1) * 8:
    return
  var directories: array[4 + (securityDirectory + 1) * 8, byte]
  if not readAt(file, peOffset + 24 + int64(directoryOffset - 4), directories):
    return
  let count = little32(directories, 0)
  result.signed = count > securityDirectory and
    little32(directories, 4 + securityDirectory * 8 + 4) > 0

proc signWindowsBuild*(projectDir, stage, executable: string;
    config: JsonNode) =
  if not signingEnabled(config):
    return
  signWindowsFile(projectDir, config, stage / executable)
  # The main executable was signed above; only copied resources are scanned.
  let executablePath = absolutePath(stage / executable)
  var pending = @[stage]
  while pending.len > 0:
    let directory = pending.pop()
    for kind, path in walkDir(directory):
      case kind
      of pcDir:
        pending.add path
      of pcFile:
        if absolutePath(path) == executablePath:
          continue
        let (image, signed) = peImage(path)
        if image and not signed:
          signWindowsFile(projectDir, config, path)
      else:
        discard

proc signUninstallerCommand*(file: string): int =
  ## Hidden NSIS callback used while compiling a signed installer.
  let settings = getEnv("MYNIM_WINDOWS_SIGN_SETTINGS")
  if settings.len == 0:
    stderr.writeLine("nim-xplat: missing Windows uninstaller signing settings")
    return 2
  try:
    let value = parseJson(settings)
    if value.kind != JObject or not value.hasKey("projectDir") or
        value["projectDir"].kind != JString:
      raise newException(ValueError, "invalid uninstaller signing settings")
    var config = newJObject()
    config["windows"] = if value.hasKey("windows"):
      value["windows"] else: newJObject()
    if not signingEnabled(config):
      raise newException(ValueError,
        "uninstaller signing settings contain no Windows signing method")
    signWindowsFile(value["projectDir"].getStr(), config, file)
    return 0
  except CatchableError as error:
    stderr.writeLine("nim-xplat: could not sign Windows uninstaller: " & error.msg)
    return 1
