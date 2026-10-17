## internal/webview2 (internal/webview2/webview2.go): finds the
## Microsoft Edge WebView2 Runtime as WebView2Loader.dll does. The
## Windows backend loads the runtime it finds, and `nim-xplat doctor`
## reports it, so the two never disagree; it builds everywhere, and
## finds no installed runtime but on Windows.

import std/[os, strutils, unicode]

when defined(windows):
  import std/dynlib

## download is where people get the runtime.
const download* =
  "https://go.microsoft.com/fwlink/p/?LinkId=2124703"

## channels are the runtime's EdgeUpdate channels, most stable first,
## the order WebView2Loader.dll tries them in.
const channels* = [
  "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", # Stable (Evergreen)
  "{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}", # Beta
  "{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}", # Dev
  "{65C35B14-6C1D-4122-AC46-7148CC9D6497}", # Canary
]

## A runtime's pieces: its browser process at the root of its
## directory, and its client library, which the loader calls, under
## EBWebView for the architecture of the process.
const
  browserExe* = "msedgewebview2.exe"
  clientDir* = "EBWebView"
  clientDLLName* = "EmbeddedBrowserWebView.dll"

when defined(windows):
  import std/widestrs

  proc u16p(s: string): pointer =
    cast[pointer](unsafeAddr newWideCString(s)[0])

  proc u16s(p: pointer): string =
    if p.isNil:
      return ""
    let a = cast[ptr UncheckedArray[uint16]](p)
    var i = 0
    var runes: seq[Rune]
    while a[i] != 0:
      var c = uint32(a[i])
      if c >= 0xD800 and c < 0xDC00 and a[i + 1] != 0:
        c = ((c - 0xD800) shl 10) + (uint32(a[i + 1]) - 0xDC00) +
          0x10000
        inc i
      runes.add Rune(c)
      inc i
    $runes

  var advapi32 = loadLib("advapi32.dll") ## a KnownDLL
  proc advapi(name: string): pointer =
    if advapi32.isNil: nil else: symAddr(advapi32, name)

  type
    regOpenKeyExW = proc(root, path: uint, opts, access,
      key: uint): uint {.stdcall.}
    regQueryValueExW = proc(key, name, reserved, typ, value,
      size: uint): uint {.stdcall.}
    regCloseKey = proc(key: uint): uint {.stdcall.}

  const
    hkeyCurrentUser = 0x80000001'u
    hkeyLocalMachine = 0x80000002'u
    keyQueryValue = 0x0001'u
    keyWow6432Key = 0x0200'u

  ## regString reads a string value from the 32-bit view of the
  ## registry, where EdgeUpdate records its clients.
  proc regString(machine: bool, path, name: string): string =
    var root = hkeyCurrentUser
    if machine:
      root = hkeyLocalMachine
    let open = cast[regOpenKeyExW](advapi("RegOpenKeyExW"))
    let query = cast[regQueryValueExW](advapi("RegQueryValueExW"))
    let close0 = cast[regCloseKey](advapi("RegCloseKey"))
    if open.isNil or query.isNil or close0.isNil:
      return ""
    var key: uint
    if open(root, cast[uint](u16p(path)), 0,
        keyQueryValue or keyWow6432Key,
        cast[uint](addr key)) != 0:
      return ""
    defer: discard close0(key)
    var typ, size: uint32
    if query(key, cast[uint](u16p(name)), 0,
        cast[uint](addr typ), 0,
        cast[uint](addr size)) != 0 or size == 0:
      return ""
    var buf = newSeq[uint16](int(size) div 2 + 1)
    if query(key, cast[uint](u16p(name)), 0,
        cast[uint](addr typ), cast[uint](addr buf[0]),
        cast[uint](addr size)) != 0:
      return ""
    u16s(cast[pointer](addr buf[0]))
else:
  ## regString finds nothing: only Windows has a registry.
  proc regString(machine: bool, path, name: string): string = ""

proc parseVersion(s: string): seq[int] =
  for part in s.split('.'):
    try:
      result.add parseInt(part)
    except ValueError:
      return @[]

proc compareVersions(a, b: seq[int]): int =
  var i = 0
  while i < a.len or i < b.len:
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y:
      return (if x < y: -1 else: 1)
    inc i
  0

proc archDir(): string =
  when defined(arm64):
    "arm64"
  elif defined(i386):
    "x86"
  else:
    "x64"

## clientDLL returns the client library of the runtime in dir, or ""
## when dir holds no runtime. The library alone is none: the Edge
## browser keeps one beside itself, whose environments fail with
## ERROR_NOT_SUPPORTED, so the runtime's browser process must be
## there too.
proc clientDLL*(dir: string): string =
  if not fileExists(dir / browserExe):
    return ""
  let p = dir / clientDir / archDir() / clientDLLName
  if not fileExists(p):
    return ""
  p

proc errNotInstalled(): ref CatchableError =
  newException(CatchableError,
    "the Microsoft Edge WebView2 Runtime is not installed; get it " &
      "from " & download)

## findRuntime is findRuntime with the environment's folder and the
## registry given: read returns a string value of the machine's
## (HKLM) or the user's (HKCU) key.
proc findRuntime(fixed: string,
    read: proc(machine: bool, path, name: string): string):
    tuple[dir: string, fixed: bool, err: ref CatchableError] =
  if fixed != "":
    if clientDLL(fixed) == "":
      return ("", false, newException(CatchableError,
        "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=" & fixed &
          " holds no WebView2 Runtime: no " & browserExe & ", or no " &
          clientDir / archDir() / clientDLLName))
    return (fixed, true, nil)
  ## EdgeUpdate records where it installed a channel's runtime, per
  ## machine and per user, and keeps the record after the files are
  ## gone.
  var stale = ""
  for channel in channels:
    var best = ""
    var bestVersion: seq[int]
    for machine in [true, false]:
      let dir = read(machine,
        r"SOFTWARE\Microsoft\EdgeUpdate\ClientState\" & channel,
        clientDir)
      if dir == "":
        continue
      if clientDLL(dir) == "":
        if stale == "":
          stale = dir
        continue
      let v = parseVersion(lastPathPart(dir))
      if best == "" or compareVersions(v, bestVersion) > 0:
        best = dir
        bestVersion = v
    if best != "":
      return (best, false, nil)
  if stale != "":
    return ("", false, newException(CatchableError,
      "the WebView2 Runtime registered at " & stale &
        " is missing or incomplete; reinstall it from " & download))
  ("", false, errNotInstalled())

## find returns the directory of the runtime a window showing a web
## page gets, and whether it is a fixed version runtime, named by
## WEBVIEW2_BROWSER_EXECUTABLE_FOLDER, rather than an installed one.
## Without a runtime, the error says why.
proc find*(): tuple[dir: string, fixed: bool,
    err: ref CatchableError] =
  findRuntime(getEnv("WEBVIEW2_BROWSER_EXECUTABLE_FOLDER"), regString)
