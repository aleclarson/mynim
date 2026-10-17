## macOS code signing and notarization helpers.

import std/[algorithm, json, os, osproc, streams, strutils, tables]

type
  NestedCode = object
    path, name: string
    bundle: bool

proc codesignArgs*(path, identity, entitlements: string;
    production: bool): seq[string] =
  result = @["--force", "--deep", "--sign", identity]
  if production and identity != "-":
    result.add ["--options", "runtime", "--timestamp"]
  if entitlements.len > 0:
    result.add ["--entitlements", entitlements]
  result.add path

proc diskImageSigningArgs*(path, identity: string): seq[string] =
  @["--force", "--timestamp", "--sign", identity, path]

proc nestedCodesignArgs*(identity, entitlements: string;
    production: bool): seq[string] =
  result = @["--force", "--sign", identity]
  if production and identity != "-":
    result.add ["--options", "runtime", "--timestamp"]
  if entitlements.len > 0:
    result.add ["--entitlements", entitlements]
  else:
    result.add "--preserve-metadata=entitlements"
proc runTool(name: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let executable = findExe(name)
  if executable.len == 0:
    raise newException(IOError, name & " was not found on PATH")
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc resourceName(value: string): string =
  let normalized = value.replace('\\', '/')
  if normalized.isAbsolute():
    raise newException(ValueError,
      "macos.helperEntitlements paths must be relative to app resources")
  var parts: seq[string]
  for part in normalized.split('/'):
    case part
    of "", ".":
      discard
    of "..":
      if parts.len == 0:
        raise newException(ValueError,
          "macos.helperEntitlements path escapes app resources: " & value)
      parts.setLen(parts.len - 1)
    else:
      parts.add part
  if parts.len == 0:
    raise newException(ValueError,
      "macos.helperEntitlements path is empty")
  parts.join("/")

proc helperEntitlements*(macos: JsonNode; projectDir: string):
    Table[string, string] =
  result = initTable[string, string]()
  if macos.kind != JObject or not macos.hasKey("helperEntitlements") or
      macos["helperEntitlements"].kind == JNull:
    return
  let configured = macos["helperEntitlements"]
  if configured.kind != JObject:
    raise newException(ValueError,
      "mygo.json: macos.helperEntitlements must be an object")
  for name, file in configured.pairs:
    if name.len == 0 or file.kind != JString or file.getStr().len == 0:
      raise newException(ValueError,
        "mygo.json: macos.helperEntitlements maps resource paths to " &
        "entitlements files")
    let entitlements = file.getStr()
    result[resourceName(name)] =
      if entitlements.isAbsolute(): entitlements
      else: projectDir / entitlements

proc machoFile(path: string): bool =
  var file: File
  if not open(file, path, fmRead):
    return false
  var header: array[8, byte]
  let bytesRead = file.readBuffer(addr header[0], header.len)
  file.close()
  if bytesRead != header.len:
    return false
  let magic = (uint32(header[0]) shl 24) or
    (uint32(header[1]) shl 16) or
    (uint32(header[2]) shl 8) or uint32(header[3])
  if magic in [0xfeedface'u32, 0xfeedfacf'u32, 0xcefaedfe'u32,
      0xcffaedfe'u32]:
    return true
  if magic notin [0xcafebabe'u32, 0xcafebabf'u32, 0xbebafeca'u32,
      0xbfbafeca'u32]:
    return false
  var architectures = (uint32(header[4]) shl 24) or
    (uint32(header[5]) shl 16) or (uint32(header[6]) shl 8) or
    uint32(header[7])
  if magic in [0xbebafeca'u32, 0xbfbafeca'u32]:
    architectures = ((architectures and 0x000000ff'u32) shl 24) or
      ((architectures and 0x0000ff00'u32) shl 8) or
      ((architectures and 0x00ff0000'u32) shr 8) or
      ((architectures and 0xff000000'u32) shr 24)
  # CAFEBABE also starts Java class files; their version is not an arch count.
  if magic == 0xcafebabe'u32 and architectures >= 20:
    return false
  architectures > 0

proc codeBundle(path: string): bool =
  if splitFile(path).ext.toLowerAscii() notin
      [".app", ".appex", ".bundle", ".framework", ".plugin", ".xpc"]:
    return false
  for plist in ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"]:
    if fileExists(path / plist):
      return true

proc collectNested(path, root: string; files, bundles: var seq[NestedCode]) =
  var children: seq[tuple[kind: PathComponent, path: string]]
  for kind, child in walkDir(path):
    if not child.lastPathPart().startsWith("."):
      children.add (kind, child)
  children.sort(proc(a, b: tuple[kind: PathComponent, path: string]): int =
    cmp(a.path, b.path))
  for child in children:
    case child.kind
    of pcDir:
      if codeBundle(child.path):
        bundles.add NestedCode(path: child.path,
          name: relativePath(child.path, root).replace('\\', '/'), bundle: true)
      collectNested(child.path, root, files, bundles)
    of pcFile:
      if machoFile(child.path):
        files.add NestedCode(path: child.path,
          name: relativePath(child.path, root).replace('\\', '/'))
    else:
      discard

proc containsCode(bundle: string; code: openArray[NestedCode]): bool =
  for entry in code:
    if entry.name.startsWith(bundle & "/"):
      return true

proc verified(path: string): bool =
  runTool("codesign", ["--verify", path]).code == 0

proc signNestedCode(app, identity: string;
    entitlements: Table[string, string]; production: bool) =
  let resources = app / "Contents" / "Resources"
  var files, bundles: seq[NestedCode]
  if dirExists(resources):
    collectNested(resources, resources, files, bundles)
  var code = files
  for bundle in bundles:
    if containsCode(bundle.name, files):
      code.add bundle
  code.sort(proc(a, b: NestedCode): int =
    let aDepth = a.name.count('/')
    let bDepth = b.name.count('/')
    if aDepth == bDepth: cmp(a.name, b.name)
    else: cmp(bDepth, aDepth))

  var unknown: seq[string]
  for name in entitlements.keys:
    var found = false
    for entry in code:
      if entry.name == name:
        found = true
        break
    if not found:
      unknown.add name
  if unknown.len > 0:
    unknown.sort()
    raise newException(ValueError,
      "mygo.json: macos.helperEntitlements names no executable, library, " &
      "or code bundle in app resources: " & unknown.join(", "))

  var signed: seq[NestedCode]
  for entry in code:
    let customEntitlements = entitlements.getOrDefault(entry.name)
    if identity == "-" and customEntitlements.len == 0:
      if not entry.bundle and verified(entry.path):
        continue
      if entry.bundle and not containsCode(entry.name, signed) and
          verified(entry.path):
        continue
    var args = nestedCodesignArgs(identity, customEntitlements, production)
    args.add entry.path
    let signedResult = runTool("codesign", args)
    if signedResult.code != 0:
      raise newException(IOError, "codesign " & entry.name &
        " failed with status " & $signedResult.code & "\n" &
        signedResult.output.strip())
    signed.add entry

proc signBundle*(path, identity, entitlements: string;
    helpers: Table[string, string];
    production = true) =
  signNestedCode(path, identity, helpers, production)
  let args = codesignArgs(path, identity, entitlements, production)
  let signed = runTool("codesign", args)
  if signed.code != 0:
    raise newException(IOError, "codesign " & path.lastPathPart() &
      " failed with status " & $signed.code & "\n" & signed.output.strip())

proc signDiskImage*(path, identity: string) =
  if identity == "-":
    return
  let args = diskImageSigningArgs(path, identity)
  let signed = runTool("codesign", args)
  if signed.code != 0:
    raise newException(IOError, "codesign " & path.lastPathPart() &
      " failed with status " & $signed.code & "\n" & signed.output.strip())

proc staple*(path: string) =
  let stapled = runTool("xcrun", ["stapler", "staple", path])
  if stapled.code != 0:
    raise newException(IOError, "xcrun stapler staple " & path.lastPathPart() &
      " failed with status " & $stapled.code & "\n" & stapled.output.strip())

proc field(node: JsonNode; name: string): string =
  if node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    result = node[name].getStr()

proc notarizeDmg*(path, keychainProfile, keychain: string) =
  if keychainProfile.len == 0:
    raise newException(ValueError,
      "macos.notarize needs a keychainProfile")
  var args = @["notarytool", "submit", path, "--keychain-profile",
    keychainProfile, "--wait", "--output-format", "json"]
  if keychain.len > 0:
    args.add ["--keychain", keychain]
  let submitted = runTool("xcrun", args)

  var id, status, message: string
  let jsonStart = submitted.output.rfind('{')
  if jsonStart >= 0:
    try:
      let response = parseJson(submitted.output[jsonStart .. ^1])
      id = field(response, "id")
      status = field(response, "status")
      message = field(response, "message")
    except JsonParsingError:
      discard
  if submitted.code != 0 or status != "Accepted":
    var detail = "notarization failed (" & status
    if message.len > 0:
      detail.add " " & message
    if submitted.code != 0:
      detail.add ": xcrun exited with status " & $submitted.code
    detail.add ")"
    if id.len > 0:
      detail.add "; see xcrun notarytool log " & id &
        " --keychain-profile " & keychainProfile
    detail.add "\n" & submitted.output.strip()
    raise newException(IOError, detail)
  staple(path)
