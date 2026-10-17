## Environment diagnostics for the nim-xplat development tool.

import std/[os, osproc, streams, strutils]

when defined(linux) or defined(windows):
  import std/algorithm

when defined(windows):
  import ../mynim/internal/webview2

const nsisVersion = "3.13"

proc commandOutput(command: string; args: seq[string]):
    tuple[output: string, code: int] =
  try:
    let process = startProcess(command, args = args,
      options = {poUsePath, poStdErrToStdOut})
    try:
      result.output = process.outputStream.readAll()
      result.code = process.waitForExit()
    finally:
      process.close()
  except OSError:
    result.code = -1

proc toolOutput(name: string; args: seq[string]):
    tuple[found: bool, detail: string] =
  let path = findExe(name)
  if path.len == 0:
    return (false, "")
  let (output, code) = commandOutput(path, args)
  (code == 0, output.strip())

proc nsisCompiler(): string =
  result = findExe("makensis")
  if result.len > 0:
    return
  when defined(windows):
    for envName in ["ProgramFiles(x86)", "ProgramFiles"]:
      let candidate = getEnv(envName) / "NSIS" / "makensis.exe"
      if fileExists(candidate):
        return candidate
    let cached = getEnv("LOCALAPPDATA") / "mygo" / ("nsis-" & nsisVersion)
    for candidate in [cached / "Bin" / "makensis.exe", cached / "makensis.exe"]:
      if fileExists(candidate):
        return candidate

proc windowsSignTool(): string =
  result = findExe("signtool.exe")
  if result.len > 0:
    return
  when defined(windows):
    let arch = when defined(arm64): "arm64" else: "x64"
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

proc runDoctor*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["-h", "--help"]:
    stderr.writeLine("Usage: nim-xplat doctor")
    stderr.writeLine("Checks the tools and system libraries nim-xplat needs.")
    return 0
  if args.len > 0:
    stderr.writeLine("nim-xplat doctor: unexpected argument: " & args[0])
    stderr.writeLine("Usage: nim-xplat doctor")
    return 2

  var ok = true
  proc check(name: string; good: bool; detail: string) =
    let mark = if good: "\x1b[32m✓\x1b[0m" else: "\x1b[31m✗\x1b[0m"
    if not good:
      ok = false
    stdout.writeLine(mark & " " & name.alignLeft(10) & " " & detail)

  let (nimFound, nimDetail) = toolOutput("nim", @["--version"])
  check("nim", nimFound, nimDetail)

  let (bunFound, bunDetail) = toolOutput("bun", @["--version"])
  if bunFound:
    stdout.writeLine("\x1b[32m✓\x1b[0m " & "bun".alignLeft(10) & " " & bunDetail)
  else:
    stdout.writeLine("- " & "bun".alignLeft(10) &
      " not found (optional, used by the frontend template: https://bun.sh)")

  when defined(macosx):
    let (versionOut, code) = commandOutput("sw_vers", @["-productVersion"])
    let version = versionOut.strip()
    var major = -1
    if version.len > 0:
      try:
        major = parseInt(version.split('.')[0])
      except ValueError:
        discard
    check("macOS", code == 0 and major >= 12,
      version & " (WKWebView; macOS 12 or later is required)")
  elif defined(linux):
    let (ldconfig, code) = commandOutput("ldconfig", @["-p"])
    var libraries: seq[string]
    if code == 0:
      for line in ldconfig.splitLines():
        let fields = line.strip().splitWhitespace()
        if fields.len > 0 and
            (fields[0].startsWith("libwebkit2gtk-4.0.so") or
             fields[0].startsWith("libwebkit2gtk-4.1.so")) and
            fields[0] notin libraries:
          libraries.add fields[0]
    libraries.sort()
    let detail = if libraries.len > 0: libraries.join(", ") else:
      "WebKitGTK not found: install libwebkit2gtk-4.1-0 (Debian/Ubuntu) or webkit2gtk4.1 (Fedora)"
    check("webkit", libraries.len > 0, detail)
  elif defined(windows):
    let (dir, _, err) = webview2.find()
    check("webview2", err.isNil, if err.isNil: dir else: err.msg)
  else:
    check(hostOS, false, "no nim-xplat backend for this platform yet")

  let nsis = nsisCompiler()
  if nsis.len > 0 or not defined(windows):
    if nsis.len > 0:
      stdout.writeLine("\x1b[32m✓\x1b[0m " & "makensis".alignLeft(10) & " " & nsis)
    else:
      stdout.writeLine("- " & "makensis".alignLeft(10) &
        " not found (optional: the Windows installer, https://nsis.sourceforge.io)")
  else:
    stdout.writeLine("- " & "makensis".alignLeft(10) &
      " not found (nim-xplat build downloads NSIS " & nsisVersion & " for the Windows installer)")

  when defined(windows):
    let signTool = windowsSignTool()
    if signTool.len > 0:
      stdout.writeLine("\x1b[32m✓\x1b[0m " & "signtool".alignLeft(10) & " " & signTool)
    else:
      stdout.writeLine("- " & "signtool".alignLeft(10) &
        " not found (optional: signing Windows apps, from the Windows SDK)")
  else:
    let signTool = findExe("osslsigncode")
    if signTool.len > 0:
      stdout.writeLine("\x1b[32m✓\x1b[0m " & "osslsign".alignLeft(10) & " " & signTool)
    else:
      stdout.writeLine("- " & "osslsign".alignLeft(10) &
        " not found (optional: signing Windows apps here (osslsigncode))")

  let gh = findExe("gh")
  if gh.len > 0:
    stdout.writeLine("\x1b[32m✓\x1b[0m " & "gh".alignLeft(10) & " " & gh)
  else:
    stdout.writeLine("- " & "gh".alignLeft(10) &
      " not found (optional: nim-xplat build -upload to GitHub releases or updates.s3)")

  when defined(macosx):
    let (identities, _) = commandOutput("security", @[
      "find-identity", "-v", "-p", "codesigning"])
    let count = identities.count("Developer ID Application")
    if count > 0:
      stdout.writeLine("\x1b[32m✓\x1b[0m " & "codesign".alignLeft(10) &
        " " & $count & " Developer ID identities")
    else:
      stdout.writeLine("- " & "codesign".alignLeft(10) &
        " not found (optional: a Developer ID to sign apps for other Macs)")

  if ok: 0 else: 1
