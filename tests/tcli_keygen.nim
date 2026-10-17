import std/[assertions, base64, os, osproc, strutils, tempfiles]
import ../src/cmd/keygen

proc testGenerateUpdateKeys() =
  let temporary = createTempDir("mynim-keygen-test-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)

  let output = temporary / "keys with spaces"
  if findExe("openssl").len == 0:
    doAssert runKeygen(@["-o", output]) == 1
    doAssert not dirExists(output)
    return
  doAssert runKeygen(@["-o", output]) == 0

  let secretPath = output / "mygo-update.key"
  let publicPath = output / "mygo-update.pub"
  doAssert fileExists(secretPath)
  doAssert fileExists(publicPath)
  let privateKey = decode(readFile(secretPath).strip())
  let publicKey = decode(readFile(publicPath).strip())
  doAssert privateKey.len == 64
  doAssert publicKey.len == 32
  doAssert privateKey[32 .. ^1] == publicKey
  let privateDer = "\x30\x2e\x02\x01\x00\x30\x05\x06\x03" &
    "\x2b\x65\x70\x04\x22\x04\x20" & privateKey[0 .. 31]
  let derivedPublic = execCmdEx(
    "openssl pkey -inform DER -pubout -outform DER | openssl base64 -A",
    options = {poUsePath}, input = privateDer)
  doAssert derivedPublic.exitCode == 0
  let publicDer = decode(derivedPublic.output.strip())
  doAssert publicDer.len == 44
  doAssert publicDer[12 .. ^1] == publicKey

  when defined(posix):
    doAssert getFilePermissions(secretPath) == {fpUserRead, fpUserWrite}
    let publicPermissions = getFilePermissions(publicPath)
    doAssert fpUserRead in publicPermissions and fpUserWrite in publicPermissions
    doAssert fpGroupWrite notin publicPermissions and
      fpOthersWrite notin publicPermissions
    doAssert getFilePermissions(output) ==
      {fpUserRead, fpUserWrite, fpUserExec}

  let originalSecret = readFile(secretPath)
  let originalPublic = readFile(publicPath)
  doAssert runKeygen(@["-o", output]) == 1
  doAssert readFile(secretPath) == originalSecret
  doAssert readFile(publicPath) == originalPublic

  doAssert runKeygen(@["--output=" & output, "--force=true"]) == 0
  doAssert readFile(secretPath) != originalSecret

proc testKeygenFlags() =
  doAssert runKeygen(@["--force=maybe"]) == 2
  doAssert runKeygen(@["-o"]) == 2
  doAssert runKeygen(@["--unknown"]) == 2
  doAssert runKeygen(@["unexpected"]) == 2

testGenerateUpdateKeys()
testKeygenFlags()
