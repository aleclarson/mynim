## Generate the Ed25519 key pair used to sign app updates.

import std/[base64, os, osproc, strutils]

when defined(posix):
  import std/posix as posix

const usageKeygen = """Usage: nim-xplat keygen [flags]

Create the Ed25519 key pair that signs updates. Put the contents of
mygo-update.pub in updates.publicKey and keep mygo-update.key private.
OpenSSL 1.1.1 or later must be available on PATH.

Flags:
  -o <dir>   directory to write the keys to (default: mygo/update-keys
             in the user's configuration directory)
  -force     replace existing keys
  -h, --help show this help
"""

const
  ed25519PrivatePrefix: array[16, byte] = [
    0x30'u8, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
    0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
  ed25519PublicPrefix: array[12, byte] = [
    0x30'u8, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
    0x70, 0x03, 0x21, 0x00]

proc openssl(command, input: string): string =
  try:
    let process = execCmdEx(command, options = {poUsePath}, input = input)
    if process.exitCode != 0:
      raise newException(IOError,
        "OpenSSL could not generate an Ed25519 key pair")
    process.output.strip()
  except OSError as error:
    raise newException(IOError,
      "could not run OpenSSL; install OpenSSL 1.1.1 or later and ensure " &
      "openssl is on PATH (" & error.msg & ")")

proc derPayload(encoded: string; prefix: openArray[byte]): string =
  var der: string
  try:
    der = decode(encoded)
  except ValueError:
    raise newException(IOError, "OpenSSL returned an invalid Ed25519 key")

  if der.len != prefix.len + 32:
    raise newException(IOError, "OpenSSL returned an invalid Ed25519 key")
  for i, expected in prefix:
    if byte(ord(der[i])) != expected:
      raise newException(IOError, "OpenSSL returned an invalid Ed25519 key")
  der[prefix.len .. ^1]

proc generateKeyPair(): tuple[secret, public: string] =
  if findExe("openssl").len == 0:
    raise newException(IOError,
      "OpenSSL 1.1.1 or later must be available on PATH")
  # Keep the private key in process memory rather than writing an intermediate
  # PEM file. OpenSSL's PKCS#8 and SubjectPublicKeyInfo outputs have fixed
  # Ed25519 DER prefixes; their final 32 bytes are the seed and public key.
  let privatePem = openssl("openssl genpkey -algorithm ED25519", "")
  let privateDer = openssl(
    "openssl pkey -outform DER | openssl base64 -A", privatePem)
  let publicDer = openssl(
    "openssl pkey -pubout -outform DER | openssl base64 -A", privatePem)
  let seed = derPayload(privateDer, ed25519PrivatePrefix)
  result.public = derPayload(publicDer, ed25519PublicPrefix)
  result.secret = seed & result.public

proc writeKeyFile(path, contents: string; mode: uint16) =
  when defined(posix):
    let fd = posix.open(path.cstring,
      cint(O_WRONLY or O_CREAT or O_TRUNC), Mode(mode))
    if fd < 0:
      raiseOSError(osLastError(), path)
    try:
      var offset = 0
      while offset < contents.len:
        let written = posix.write(fd, unsafeAddr contents[offset],
          contents.len - offset)
        if written < 0:
          if osLastError().int == EINTR:
            continue
          raiseOSError(osLastError(), path)
        if written == 0:
          raise newException(IOError, "could not write " & path)
        offset += written
    finally:
      if posix.close(fd) != 0:
        raiseOSError(osLastError(), path)
  else:
    writeFile(path, contents)

proc runKeygen*(args: seq[string]): int =
  var outputDir = getConfigDir() / "mygo" / "update-keys"
  var force = false
  var positional: seq[string]
  var i = 0

  while i < args.len:
    let arg = args[i]
    if arg in ["-h", "--help"]:
      stdout.write(usageKeygen)
      return 0
    if arg == "--":
      if i + 1 < args.len:
        positional.add args[i + 1 .. ^1]
      break
    if arg == "-force" or arg == "--force":
      force = true
    elif arg.startsWith("-force=") or arg.startsWith("--force="):
      let value = arg.split('=', maxsplit = 1)[1]
      if value notin ["true", "false"]:
        stderr.writeLine("nim-xplat keygen: invalid boolean value for -force: " & value)
        return 2
      force = value == "true"
    elif arg == "-o" or arg == "--output":
      inc i
      if i >= args.len:
        stderr.writeLine("nim-xplat keygen: missing value for " & arg)
        stderr.write(usageKeygen)
        return 2
      outputDir = args[i]
    elif arg.startsWith("-o=") or arg.startsWith("--output="):
      outputDir = arg.split('=', maxsplit = 1)[1]
      if outputDir.len == 0:
        stderr.writeLine("nim-xplat keygen: missing value for -o")
        stderr.write(usageKeygen)
        return 2
    elif arg.startsWith('-'):
      stderr.writeLine("nim-xplat keygen: unknown flag " & arg)
      stderr.write(usageKeygen)
      return 2
    else:
      positional.add arg
    inc i

  if positional.len > 0:
    stderr.writeLine("nim-xplat keygen: does not accept positional arguments")
    stderr.write(usageKeygen)
    return 2
  if outputDir.len == 0:
    stderr.writeLine("nim-xplat keygen: output directory cannot be empty")
    return 2

  let secretPath = outputDir / "mygo-update.key"
  let publicPath = outputDir / "mygo-update.pub"
  if not force and (fileExists(secretPath) or fileExists(publicPath)):
    stderr.writeLine("nim-xplat keygen: " & outputDir &
      " already holds keys; pass -force to replace them")
    return 1

  try:
    let keys = generateKeyPair()
    when defined(posix):
      let existed = dirExists(outputDir)
    createDir(outputDir)
    when defined(posix):
      if not existed:
        setFilePermissions(outputDir,
          {fpUserRead, fpUserWrite, fpUserExec})
    writeKeyFile(secretPath, encode(keys.secret) & "\n", 0o600'u16)
    writeKeyFile(publicPath, encode(keys.public) & "\n", 0o644'u16)

    stdout.writeLine("Wrote " & secretPath & " (secret) and " & publicPath)
    stdout.write("Add to mygo.json, or mygo.config.ts:\n\n" &
      "  \"updates\": {\n" &
      "    \"publicKey\": \"" & encode(keys.public) & "\",\n" &
      "    \"github\": \"owner/name\"\n" &
      "  }\n")
    return 0
  except CatchableError as error:
    stderr.writeLine("nim-xplat keygen: " & error.msg)
    return 1
