import std/[assertions, os, strutils, tempfiles]
import ../src/cmd/codesign

proc testSigningArguments() =
  doAssert codesignArgs("Sample.app", "-", "", true) ==
    @["--force", "--deep", "--sign", "-", "Sample.app"]
  doAssert codesignArgs("Sample.app", "Developer ID: Example", "app.plist",
    true) == @["--force", "--deep", "--sign", "Developer ID: Example",
      "--options", "runtime", "--timestamp", "--entitlements", "app.plist",
      "Sample.app"]
  doAssert codesignArgs("Sample.app", "Apple Development: Example", "",
    false) == @["--force", "--deep", "--sign",
      "Apple Development: Example", "Sample.app"]
  doAssert diskImageSigningArgs("Sample.dmg", "Developer ID: Example") ==
    @["--force", "--timestamp", "--sign", "Developer ID: Example",
      "Sample.dmg"]

when defined(posix):
  proc testNotarization() =
    let temporary = createTempDir("mynim-notarize-", "")
    defer: removeDir(temporary)
    let bin = temporary / "bin"
    createDir(bin)
    let log = temporary / "xcrun-args.txt"
    let xcrun = bin / "xcrun"
    writeFile(xcrun, """#!/bin/sh
printf '<%s>' "$@" >> "$MYNIM_TEST_XCRUN_LOG"
printf '\n' >> "$MYNIM_TEST_XCRUN_LOG"
if [ "$1" = "notarytool" ]; then
  printf '{"id":"ticket-1","status":"%s","message":"review"}\n' "$MYNIM_TEST_NOTARY_STATUS"
fi
exit 0
""")
    setFilePermissions(xcrun, {fpUserRead, fpUserWrite, fpUserExec})

    let dmg = temporary / "Sample App.dmg"
    writeFile(dmg, "disk image fixture")
    let oldPath = getEnv("PATH")
    let oldLog = getEnv("MYNIM_TEST_XCRUN_LOG")
    let oldStatus = getEnv("MYNIM_TEST_NOTARY_STATUS")
    putEnv("PATH", bin & ":" & oldPath)
    putEnv("MYNIM_TEST_XCRUN_LOG", log)
    putEnv("MYNIM_TEST_NOTARY_STATUS", "Accepted")
    try:
      notarizeDmg(dmg, "notary", "login.keychain-db")
      var calls = readFile(log).splitLines()
      if calls.len > 0 and calls[^1].len == 0:
        calls.setLen(calls.len - 1)
      doAssert calls.len == 2
      doAssert calls[0].contains(
        "<notarytool><submit><" & dmg & "><--keychain-profile><notary>")
      doAssert calls[0].contains("<--wait><--output-format><json>")
      doAssert calls[0].contains("<--keychain><login.keychain-db>")
      doAssert calls[1] == "<stapler><staple><" & dmg & ">"

      writeFile(log, "")
      putEnv("MYNIM_TEST_NOTARY_STATUS", "Invalid")
      var rejected = false
      try:
        notarizeDmg(dmg, "notary", "")
      except IOError as error:
        rejected = error.msg.contains("notarization failed (Invalid review)") and
          error.msg.contains("notarytool log ticket-1")
      doAssert rejected
      calls = readFile(log).splitLines()
      if calls.len > 0 and calls[^1].len == 0:
        calls.setLen(calls.len - 1)
      doAssert calls.len == 1
    finally:
      putEnv("PATH", oldPath)
      putEnv("MYNIM_TEST_XCRUN_LOG", oldLog)
      putEnv("MYNIM_TEST_NOTARY_STATUS", oldStatus)

testSigningArguments()
when defined(posix):
  testNotarization()
