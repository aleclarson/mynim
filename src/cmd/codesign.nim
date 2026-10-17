## macOS code signing and notarization helpers.

import std/[json, os, osproc, streams, strutils]

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

proc signBundle*(path, identity, entitlements: string;
    production = true) =
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
