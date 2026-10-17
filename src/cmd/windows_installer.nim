## Build the per-user Windows installer with NSIS.

import std/[algorithm, json, math, os, osproc, sequtils, streams, strtabs,
  strutils, tables, tempfiles]
import ../mynim/image as imagePackage
import ../mynim/i18n as i18nPackage
import ./windows_sign as windowsSign

const nsisLanguageNames = {
  "af": "Afrikaans", "ar": "Arabic", "be": "Belarusian",
  "bg": "Bulgarian", "bs": "Bosnian", "ca": "Catalan",
  "cs": "Czech", "cy": "Welsh", "da": "Danish", "de": "German",
  "el": "Greek", "en": "English", "es": "Spanish",
  "es-419": "SpanishInternational", "et": "Estonian", "eu": "Basque",
  "fa": "Farsi", "fi": "Finnish", "fr": "French", "ga": "Irish",
  "gl": "Galician", "he": "Hebrew", "hr": "Croatian",
  "hu": "Hungarian", "hy": "Armenian", "id": "Indonesian",
  "is": "Icelandic", "it": "Italian", "ja": "Japanese",
  "ka": "Georgian", "ko": "Korean", "lb": "Luxembourgish",
  "lt": "Lithuanian", "lv": "Latvian", "mk": "Macedonian",
  "mn": "Mongolian", "ms": "Malay", "nb": "Norwegian", "nl": "Dutch",
  "nn": "NorwegianNynorsk", "no": "Norwegian", "pl": "Polish",
  "pt": "PortugueseBR", "pt-br": "PortugueseBR",
  "pt-pt": "Portuguese", "ro": "Romanian", "ru": "Russian",
  "sk": "Slovak", "sl": "Slovenian", "sq": "Albanian",
  "sr": "Serbian", "sr-latn": "SerbianLatin", "sv": "Swedish",
  "th": "Thai", "tr": "Turkish", "uk": "Ukrainian", "uz": "Uzbek",
  "vi": "Vietnamese", "zh-hans": "SimpChinese",
  "zh-hant": "TradChinese"}.toTable

proc configString(node: JsonNode; key, path, fallback: string): string =
  if node.kind != JObject or not node.hasKey(key):
    return fallback
  if node[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & path & " must be a string")
  node[key].getStr()

proc configArray(node: JsonNode; key, path: string): seq[string] =
  if node.kind != JObject or not node.hasKey(key):
    return
  if node[key].kind != JArray:
    raise newException(ValueError, "mygo.json: " & path & " must be an array")
  for value in node[key]:
    if value.kind != JString or value.getStr().len == 0:
      raise newException(ValueError,
        "mygo.json: " & path & " entries must be nonempty strings")
    result.add value.getStr()

proc fsName(value: string): string =
  for ch in value:
    if ord(ch) < 32 or ch in {'<', '>', ':', '"', '/', '\\', '|', '?', '*'}:
      result.add '-'
    else:
      result.add ch
  result = result.strip(chars = {' ', '.'})
  if result.len == 0 or result in [".", ".."]:
    result = "app"
  let reserved = result.toUpperAscii()
  if reserved in ["CON", "PRN", "AUX", "NUL"] or
      (reserved.len == 4 and reserved[0 .. 2] in ["COM", "LPT"] and
        reserved[3] in {'1'..'9'}):
    result.add '-'

proc installerFileName*(name, version, arch: string): string =
  fsName(name) & " Setup " & fsName(version) & " " & fsName(arch) & ".exe"

proc nsisEscape(value: string): string =
  for ch in value:
    case ch
    of '$': result.add "$$"
    of '"': result.add "$\""
    of '\n': result.add "$\\n"
    of '\r': result.add "$\\r"
    of '\t': result.add "$\\t"
    else:
      if ord(ch) < 32 or ord(ch) == 127:
        raise newException(ValueError,
          "Windows installer text cannot contain control characters")
      result.add ch

proc nsisString(value: string): string = "\"" & nsisEscape(value) & "\""

proc runtimeNsisString(value: string): string =
  ## Escape a string while preserving NSIS's $INSTDIR expansion.
  nsisString(value).replace("$$INSTDIR", "$INSTDIR")

proc windowsLanguages(config: JsonNode; projectDir: string): seq[string] =
  result = @["en"]
  if config.kind != JObject or not config.hasKey("i18n") or
      config["i18n"].kind == JNull:
    return
  let i18n = config["i18n"]
  if i18n.kind != JObject:
    raise newException(ValueError, "mygo.json: i18n must be an object")
  let source = configString(i18n, "source", "i18n.source", "en")
  let canonicalSource = i18nPackage.normalize(source)
  if canonicalSource.len == 0:
    raise newException(ValueError,
      "mygo.json: i18n.source is not a language tag: " & source)
  result = @[canonicalSource]
  let configuredDir = configString(i18n, "dir", "i18n.dir", "locales")
  let directory = if isAbsolute(configuredDir): configuredDir
    else: projectDir / configuredDir
  if not dirExists(directory):
    return
  var tags: seq[string]
  for kind, path in walkDir(directory):
    if kind == pcFile and path.splitFile().ext == ".json":
      let tag = i18nPackage.normalize(path.lastPathPart().splitFile().name)
      if tag.len == 0:
        raise newException(ValueError,
          "Windows installer language filename is not a language tag: " & path)
      if tag.toLowerAscii() != canonicalSource.toLowerAscii() and
          tag.toLowerAscii() notin result.mapIt(it.toLowerAscii()):
        tags.add tag
  tags.sort(proc(a, b: string): int = cmp(a.toLowerAscii(), b.toLowerAscii()))
  for tag in tags:
    if tag.toLowerAscii() notin result.mapIt(it.toLowerAscii()):
      result.add tag

proc languageName(tag: string): string =
  let normalized = i18nPackage.normalize(tag).toLowerAscii()
  if nsisLanguageNames.hasKey(normalized):
    return nsisLanguageNames[normalized]
  let parts = normalized.split('-')
  if parts.len == 0:
    return ""
  let language = parts[0]
  var script, region: string
  for part in parts[1 .. ^1]:
    if part.len == 4:
      script = part
    elif part.len == 2 or (part.len == 3 and part.allCharsInSet({'0'..'9'})):
      region = part
  if language == "zh" and script.len == 0:
    script = if region in ["tw", "hk", "mo"]: "hant" else: "hans"
  if region.len > 0:
    let regional = language & "-" & region
    if nsisLanguageNames.hasKey(regional):
      return nsisLanguageNames[regional]
  if script.len > 0:
    let scripted = language & "-" & script
    if nsisLanguageNames.hasKey(scripted):
      return nsisLanguageNames[scripted]
  if nsisLanguageNames.hasKey(language):
    return nsisLanguageNames[language]
  ""

proc languageMacros(config: JsonNode; projectDir: string): string =
  var emitted = initTable[string, bool]()
  for tag in windowsLanguages(config, projectDir):
    let name = languageName(tag)
    if name.len == 0:
      raise newException(ValueError,
        "Windows installer has no NSIS language for " & tag)
    if not emitted.hasKey(name):
      emitted[name] = true
      result.add "!insertmacro MUI_LANGUAGE " & nsisString(name) & "\n"
  if result.len == 0:
    result = "!insertmacro MUI_LANGUAGE \"English\"\n"

proc validExtension(value: string): bool =
  if value.len == 0 or value[0] notin {'a'..'z', 'A'..'Z', '0'..'9'}:
    return false
  for ch in value:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '+', '-'}:
      return false
  true

proc installerAssociations(config: JsonNode; name, identifier,
    executable: string): tuple[register, unregister: string] =
  var register, unregister: string
  if config.kind == JObject and config.hasKey("fileAssociations"):
    if config["fileAssociations"].kind != JArray:
      raise newException(ValueError,
        "mygo.json: fileAssociations must be an array")
    var prefix = ""
    for ch in identifier:
      if ch in {'a'..'z', 'A'..'Z', '0'..'9', '.'}:
        prefix.add ch
    for index in 0 ..< config["fileAssociations"].len:
      let association = config["fileAssociations"][index]
      if association.kind != JObject:
        raise newException(ValueError,
          "mygo.json: fileAssociations[" & $index & "] must be an object")
      let extensions = configArray(association, "ext",
        "fileAssociations[" & $index & "].ext")
      if extensions.len == 0:
        raise newException(ValueError,
          "mygo.json: fileAssociations[" & $index & "] has no ext")
      let description = configString(association, "name",
        "fileAssociations[" & $index & "].name", "")
      for extension in extensions:
        if not validExtension(extension):
          raise newException(ValueError,
            "mygo.json: fileAssociations[" & $index & "] has invalid extension " &
              extension)
        let progId = prefix & "." & extension.toLowerAscii()
        let classKey = "Software\\Classes\\" & progId
        let label = if description.len > 0: description
          else: "." & extension & " file"
        register.add "  WriteRegStr HKCU " & nsisString(classKey) & " \"\" " &
          nsisString(label) & "\n"
        register.add "  WriteRegStr HKCU " &
          nsisString(classKey & "\\DefaultIcon") & " \"\" " &
          runtimeNsisString("$INSTDIR\\" & executable & ",0") & "\n"
        let openCommand = runtimeNsisString("\"$INSTDIR\\" & executable &
          "\" \"%1\"")
        register.add "  WriteRegStr HKCU " &
          nsisString(classKey & "\\shell\\open\\command") & " \"\" " &
          openCommand & "\n"
        register.add "  WriteRegStr HKCU " &
          nsisString("Software\\Classes\\." & extension & "\\OpenWithProgids") &
          " " & nsisString(progId) & " \"\"\n"
        unregister.add "  DeleteRegKey HKCU " & nsisString(classKey) & "\n"
        unregister.add "  DeleteRegValue HKCU " &
          nsisString("Software\\Classes\\." & extension & "\\OpenWithProgids") &
          " " & nsisString(progId) & "\n"

  let schemes = configArray(config, "urlSchemes", "urlSchemes")
  for scheme in schemes:
    if scheme.len == 0 or scheme[0] notin {'a'..'z', 'A'..'Z'}:
      raise newException(ValueError,
        "mygo.json: urlSchemes contains an invalid scheme")
    for ch in scheme:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'}:
        raise newException(ValueError,
          "mygo.json: urlSchemes contains an invalid scheme")
    let key = "Software\\Classes\\" & scheme
    register.add "  WriteRegStr HKCU " & nsisString(key) & " \"\" " &
      nsisString("URL:" & name) & "\n"
    register.add "  WriteRegStr HKCU " & nsisString(key) &
      " \"URL Protocol\" \"\"\n"
    let openCommand = runtimeNsisString("\"$INSTDIR\\" & executable &
      "\" \"%1\"")
    register.add "  WriteRegStr HKCU " &
      nsisString(key & "\\shell\\open\\command") & " \"\" " &
      openCommand & "\n"
    unregister.add "  DeleteRegKey HKCU " & nsisString(key) & "\n"
  if register.len > 0:
    let notify = "  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'\n"
    register.add notify
    unregister.add notify
  (register, unregister)

proc appendLe(output: var seq[byte]; value: uint16) =
  output.add byte(value and 0xff)
  output.add byte(value shr 8)

proc appendLe(output: var seq[byte]; value: uint32) =
  for shift in [0, 8, 16, 24]:
    output.add byte((value shr shift) and 0xff)

proc scaledIconImage(source: imagePackage.NrgbaImage; size: int):
    imagePackage.NrgbaImage =
  let bounds = source.bounds()
  let width = bounds.dx
  let sourceHeight = bounds.dy
  if width <= 0 or sourceHeight <= 0:
    raise newException(ValueError, "icon must have nonzero dimensions")
  if width != sourceHeight:
    raise newException(ValueError, "Windows installer icon must be square")
  let sx = width.float64 / size.float64
  let sy = sourceHeight.float64 / size.float64
  result = imagePackage.newNrgba(imagePackage.rect(0, 0, size, size))
  proc sample(x, y: int): array[4, float64] =
    let pixel = source.nrgbaAt(bounds.min.x + clamp(x, 0, width - 1),
      bounds.min.y + clamp(y, 0, sourceHeight - 1))
    let alpha = pixel.a.float64
    [pixel.r.float64 * alpha, pixel.g.float64 * alpha,
      pixel.b.float64 * alpha, alpha]
  for y in 0 ..< size:
    for x in 0 ..< size:
      var rgba: array[4, float64]
      var total = 0.0
      if sx >= 1.0:
        let x0 = int(x.float64 * sx)
        let x1 = max(int((x + 1).float64 * sx), x0 + 1)
        let y0 = int(y.float64 * sy)
        let y1 = max(int((y + 1).float64 * sy), y0 + 1)
        for py in y0 ..< y1:
          for px in x0 ..< x1:
            let color = sample(px, py)
            for channel in 0 ..< 4:
              rgba[channel] += color[channel]
            total += 1.0
      else:
        let fx = (x.float64 + 0.5) * sx - 0.5
        let fy = (y.float64 + 0.5) * sy - 0.5
        let x0 = int(floor(fx))
        let y0 = int(floor(fy))
        let dx = fx - x0.float64
        let dy = fy - y0.float64
        for tap in [
            (x: x0, y: y0, weight: (1.0 - dx) * (1.0 - dy)),
            (x: x0 + 1, y: y0, weight: dx * (1.0 - dy)),
            (x: x0, y: y0 + 1, weight: (1.0 - dx) * dy),
            (x: x0 + 1, y: y0 + 1, weight: dx * dy)]:
          let color = sample(tap.x, tap.y)
          for channel in 0 ..< 4:
            rgba[channel] += color[channel] * tap.weight
          total += tap.weight
      if rgba[3] > 0.0 and total > 0.0:
        result.set(x, y, imagePackage.Nrgba(
          r: uint8(clamp(int(rgba[0] / rgba[3] + 0.5), 0, 255)),
          g: uint8(clamp(int(rgba[1] / rgba[3] + 0.5), 0, 255)),
          b: uint8(clamp(int(rgba[2] / rgba[3] + 0.5), 0, 255)),
          a: uint8(clamp(int(rgba[3] / total + 0.5), 0, 255))))

proc pngToIco*(source: openArray[byte]): seq[byte] =
  let decoded = imagePackage.pngDecode(@source)
  if decoded.err != nil:
    raise newException(ValueError, "icon must be a PNG: " & decoded.err.msg)
  const sizes = [16, 24, 32, 48, 64, 128, 256]
  var images: seq[seq[byte]]
  for size in sizes:
    images.add imagePackage.pngEncode(scaledIconImage(decoded.img, size))
  result.appendLe(0'u16)
  result.appendLe(1'u16)
  result.appendLe(uint16(sizes.len))
  var offset = 6 + sizes.len * 16
  for index, size in sizes:
    let dimension = if size >= 256: 0'u8 else: uint8(size)
    result.add dimension
    result.add dimension
    result.add 0'u8
    result.add 0'u8
    result.appendLe(1'u16)
    result.appendLe(32'u16)
    result.appendLe(uint32(images[index].len))
    result.appendLe(uint32(offset))
    offset += images[index].len
  for image in images:
    result.add image

proc stringBytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for index, ch in value:
    result[index] = byte(ord(ch))

proc bytesString(value: openArray[byte]): string =
  result = newString(value.len)
  for index, ch in value:
    result[index] = char(ch)

proc stageFiles*(stage: string): seq[string] =
  ## Return the app files to install, relative to stage, in stable order.
  var pending = @[stage]
  while pending.len > 0:
    let directory = pending.pop()
    for kind, path in walkDir(directory):
      case kind
      of pcFile:
        result.add relativePath(path, stage).replace('\\', '/')
      of pcDir:
        pending.add path
      else:
        raise newException(ValueError,
          "Windows installer does not support resource links: " & path)
  result.sort()

proc installedFiles(files: openArray[string]; stage: string): string =
  for relative in files:
    let normalized = relative.replace('\\', '/')
    if normalized.len == 0 or normalized.startsWith("/") or
        normalized.split('/').anyIt(it in ["", ".", ".."]) or
        normalized.contains(':'):
      raise newException(ValueError,
        "invalid staged path for Windows installer: " & relative)
    let components = normalized.split('/')
    if components.len > 1:
      var destination = "$INSTDIR"
      for component in components[0 ..< components.high]:
        destination.add "\\" & nsisEscape(component)
      result.add "  SetOutPath \"" & destination & "\"\n"
    else:
      result.add "  SetOutPath \"$INSTDIR\"\n"
    let source = stage / normalized.replace('/', DirSep)
    if not fileExists(source):
      raise newException(IOError,
        "Windows installer payload disappeared: " & source)
    result.add "  File " & nsisString(source.replace('\\', '/')) & "\n"

proc installerScript*(projectDir, stage, output, name, identifier, version,
    executable: string; config: JsonNode; files: openArray[string];
    iconPath: string): string =
  for value in [name, identifier, version, executable]:
    if value.len == 0:
      raise newException(ValueError,
        "Windows installer needs a nonempty name, identifier, version, and executable")
  for ch in identifier:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_'}:
      raise newException(ValueError,
        "mygo.json: identifier contains characters unsafe for Windows registration")
  let shortcut = fsName(name) & ".lnk"
  let uninstallKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\" &
    identifier
  let associations = installerAssociations(config, name, identifier, executable)
  var iconDefines = ""
  if iconPath.len > 0:
    let icon = nsisString(iconPath.replace('\\', '/'))
    iconDefines = "!define MUI_ICON " & icon & "\n" &
      "!define MUI_UNICON " & icon & "\n"
  let languages = languageMacros(config, projectDir)
  let filesScript = installedFiles(files, stage)
  result = """Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma
Name """ & nsisString(name) & "\nOutFile " &
    nsisString(output.replace('\\', '/')) & "\n" &
    "InstallDir \"$LOCALAPPDATA\\Programs\\" & nsisEscape(fsName(name)) &
      "\"\nRequestExecutionLevel user\nBrandingText \" \"\n" &
    iconDefines & "!define MUI_FINISHPAGE_RUN \"$INSTDIR\\" &
      nsisEscape(executable) & "\"\n" &
    "!define MUI_FINISHPAGE_SHOWREADME\n" &
    "!define MUI_FINISHPAGE_SHOWREADME_TEXT \"Create a desktop shortcut\"\n" &
    "!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateDesktopShortcut\n" &
    "!include \"MUI2.nsh\"\n" &
    "!insertmacro MUI_PAGE_DIRECTORY\n!insertmacro MUI_PAGE_INSTFILES\n" &
    "!insertmacro MUI_PAGE_FINISH\n!insertmacro MUI_UNPAGE_CONFIRM\n" &
    "!insertmacro MUI_UNPAGE_INSTFILES\n" & languages &
    "Section\n  SetOutPath \"$INSTDIR\"\n" & filesScript &
    "  WriteUninstaller \"$INSTDIR\\Uninstall.exe\"\n" &
    "  CreateShortCut \"$SMPROGRAMS\\" & nsisEscape(shortcut) &
      "\" \"$INSTDIR\\" & nsisEscape(executable) & "\"\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"DisplayName\" " &
      nsisString(name) & "\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"DisplayVersion\" " &
      nsisString(version) & "\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"DisplayIcon\" " &
      runtimeNsisString("$INSTDIR\\" & executable) & "\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"InstallLocation\" " &
      runtimeNsisString("$INSTDIR") & "\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"UninstallString\" " &
      runtimeNsisString("\"$INSTDIR\\Uninstall.exe\"") & "\n" &
    "  WriteRegStr HKCU " & nsisString(uninstallKey) & " \"QuietUninstallString\" " &
      runtimeNsisString("\"$INSTDIR\\Uninstall.exe\" /S") & "\n" &
    "  WriteRegDWORD HKCU " & nsisString(uninstallKey) & " \"NoModify\" 1\n" &
    "  WriteRegDWORD HKCU " & nsisString(uninstallKey) & " \"NoRepair\" 1\n" &
    associations.register & "SectionEnd\n\n" &
    "Function CreateDesktopShortcut\n  SetOutPath \"$INSTDIR\"\n" &
    "  CreateShortCut \"$DESKTOP\\" & nsisEscape(shortcut) &
      "\" \"$INSTDIR\\" & nsisEscape(executable) & "\"\nFunctionEnd\n\n" &
    "Function un.DeleteShortcut\n  Exch $0\n  Push $1\n  StrCpy $1 50\n" &
    "retry:\n    ClearErrors\n    Delete $0\n    IfErrors 0 done\n" &
    "    IntOp $1 $1 - 1\n    IntCmp $1 0 done\n    Sleep 100\n" &
    "    Goto retry\n  done:\n  Pop $1\n  Pop $0\nFunctionEnd\n\n" &
    "Section \"Uninstall\"\n  Push \"$SMPROGRAMS\\" &
      nsisEscape(shortcut) & "\"\n  Call un.DeleteShortcut\n" &
    "  Push \"$DESKTOP\\" & nsisEscape(shortcut) &
      "\"\n  Call un.DeleteShortcut\n" &
    "  DeleteRegKey HKCU " & nsisString(uninstallKey) & "\n" &
    associations.unregister &
    "  RMDir /r \"$INSTDIR\"\nSectionEnd\n"

when hostOS == "windows":
  import std/[base64, unicode]

  proc powershellEncode(script: string): string =
    var utf16 = newStringOfCap(script.len * 2)
    for rune in script.runes:
      let value = int(rune)
      if value <= 0xffff:
        utf16.add char(value and 0xff)
        utf16.add char(value shr 8)
      else:
        let scalar = value - 0x10000
        let high = 0xd800 + (scalar shr 10)
        let low = 0xdc00 + (scalar and 0x3ff)
        utf16.add char(high and 0xff)
        utf16.add char(high shr 8)
        utf16.add char(low and 0xff)
        utf16.add char(low shr 8)
    base64.encode(utf16)

  proc windowsNsisPath(): string =
    for envName in ["ProgramFiles(x86)", "ProgramFiles"]:
      let candidate = getEnv(envName) / "NSIS" / "makensis.exe"
      if fileExists(candidate):
        return candidate

  proc nsisCacheDir(): string =
    let local = getEnv("LOCALAPPDATA")
    if local.len == 0:
      raise newException(IOError,
        "cannot find the Windows NSIS cache directory: LOCALAPPDATA is unset")
    local / "mygo" / "nsis-3.13"

  proc runPowerShell(script: string) =
    let shell = findExe("powershell.exe")
    if shell.len == 0:
      raise newException(IOError,
        "downloading NSIS needs Windows PowerShell")
    let process = startProcess(shell, args = @[
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
      "-EncodedCommand", powershellEncode(script)],
      options = {poUsePath, poStdErrToStdOut})
    try:
      let output = process.outputStream.readAll()
      let code = process.waitForExit()
      if code != 0:
        raise newException(IOError,
          "could not download NSIS 3.13: " & output.strip())
    finally:
      process.close()

  proc downloadNsis(): string =
    result = nsisCacheDir() / "Bin" / "makensis.exe"
    if fileExists(result):
      return
    let destination = nsisCacheDir()
    let parent = destination.parentDir()
    createDir(parent)
    let work = createTempDir(".nsis-", "", parent)
    defer:
      if dirExists(work):
        removeDir(work)
    let archive = work / "nsis.zip"
    let unpacked = work / "unpacked"
    var script = """
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$urls = @(
  'https://github.com/egoist/mygo/releases/download/nsis-3.13/nsis-3.13.zip',
  'https://downloads.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13.zip'
)
"""
    script.add("$archive = '" & archive.replace("'", "''") & "'\n")
    script.add """$expected = 'ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8'
$valid = $false
foreach ($url in $urls) {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 600
    if ((Get-Item $archive).Length -gt 67108864) { throw 'NSIS archive is too large' }
    if ((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant() -ne $expected) { throw 'NSIS archive SHA-256 does not match' }
    $valid = $true; break
  } catch { Remove-Item -Force -ErrorAction SilentlyContinue $archive }
}
if (-not $valid) { throw 'Neither NSIS download matched the expected SHA-256' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
"""
    script.add("$unpacked = '" & unpacked.replace("'", "''") & "'\n")
    script.add """[System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $unpacked)
$roots = @(Get-ChildItem -LiteralPath $unpacked -Directory)
if ($roots.Count -ne 1 -or -not (Test-Path (Join-Path $roots[0].FullName 'Bin\makensis.exe'))) { throw 'NSIS archive has an unexpected layout' }
"""
    script.add("Move-Item -LiteralPath $roots[0].FullName -Destination '" &
      destination.replace("'", "''") & "'\n")
    try:
      runPowerShell(script)
    except CatchableError:
      if not fileExists(result):
        raise

  proc nsisCompiler(): string =
    result = findExe("makensis.exe")
    if result.len > 0:
      return
    result = windowsNsisPath()
    if result.len > 0:
      return
    result = downloadNsis()

else:
  proc nsisCompiler(): string =
    result = findExe("makensis")
    if result.len == 0:
      raise newException(IOError,
        "Windows installer generation needs NSIS (makensis) on PATH")

proc nsisVersion(tool: string): tuple[major, minor: int] =
  let process = startProcess(tool, args = @["-VERSION"],
    options = {poUsePath, poStdErrToStdOut})
  try:
    let output = process.outputStream.readAll().strip()
    if process.waitForExit() == 0:
      let value = output.strip(chars = {'v', 'V', ' ', '\n', '\r'})
      let parts = value.split('.')
      if parts.len >= 2:
        try:
          var minor = ""
          for ch in parts[1]:
            if ch notin {'0'..'9'}:
              break
            minor.add ch
          result.major = parseInt(parts[0])
          result.minor = parseInt(minor)
        except ValueError:
          discard
  finally:
    process.close()

proc writeWindowsInstaller*(projectDir, stage, name, identifier, version,
    executable, arch: string; config: JsonNode; files: openArray[string]): string =
  let output = stage / installerFileName(name, version, arch)
  if fileExists(output) or dirExists(output):
    raise newException(IOError,
      "Windows installer output collides with a staged resource: " & output)
  let tool = nsisCompiler()
  let work = createTempDir(".mygo-nsis-", "", stage.parentDir())
  defer:
    if dirExists(work):
      removeDir(work)
  var iconPath = ""
  let configuredIcon = configString(config, "icon", "icon", "")
  let projectIcon = if configuredIcon.len == 0:
    projectDir / "resources" / "icon.png"
    elif isAbsolute(configuredIcon): configuredIcon
    else: projectDir / configuredIcon
  if fileExists(projectIcon):
    iconPath = work / "installer.ico"
    writeFile(iconPath, bytesString(pngToIco(stringBytes(readFile(projectIcon)))))
  elif configuredIcon.len > 0:
    raise newException(IOError,
      "mygo.json: icon does not exist: " & projectIcon)

  let nsi = work / "installer.nsi"
  writeFile(nsi, installerScript(projectDir, stage, output, name,
    identifier, version, executable, config, files, iconPath))
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  if windowsSign.signingEnabled(config):
    let versionInfo = nsisVersion(tool)
    if versionInfo.major > 3 or
        (versionInfo.major == 3 and versionInfo.minor >= 8):
      let settings = newJObject()
      settings["projectDir"] = %projectDir
      settings["windows"] = if config.hasKey("windows"):
        config["windows"] else: newJObject()
      env["MYNIM_WINDOWS_SIGNER"] = getAppFilename()
      env["MYNIM_WINDOWS_SIGN_SETTINGS"] = $settings
      let signer = when hostOS == "windows":
        "\"%MYNIM_WINDOWS_SIGNER%\""
      else:
        "\"$MYNIM_WINDOWS_SIGNER\""
      let finalizer = "!uninstfinalize '" & signer &
        " sign-uninstaller \"%1\"' = 0\n"
      var script = readFile(nsi)
      let marker = "SetCompressor /SOLID lzma\n"
      script = script.replace(marker, marker & finalizer)
      writeFile(nsi, script)
    else:
      stderr.writeLine("nim-xplat build: NSIS " & $versionInfo.major & "." &
        $versionInfo.minor & " cannot sign Uninstall.exe; NSIS 3.08 or later is required")

  let process = startProcess(tool, args = @["-V2", nsi], env = env,
    options = {poUsePath, poStdErrToStdOut})
  try:
    let outputText = process.outputStream.readAll()
    let code = process.waitForExit()
    if code != 0:
      raise newException(IOError,
        "makensis failed with status " & $code & ":\n" & outputText)
  finally:
    process.close()
  if not fileExists(output):
    raise newException(IOError,
      "makensis completed without creating " & output)
  windowsSign.signWindowsFile(projectDir, config, output)
  result = output
