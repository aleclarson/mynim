import std/[assertions, json, os, strutils, tables, tempfiles]
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
  doAssert nestedCodesignArgs("Developer ID: Example", "", true) ==
    @["--force", "--sign", "Developer ID: Example", "--options", "runtime",
      "--timestamp", "--preserve-metadata=entitlements"]
  doAssert nestedCodesignArgs("-", "helper.plist", true) ==
    @["--force", "--sign", "-", "--entitlements", "helper.plist"]

when defined(posix):
  proc testNestedSigning() =
    let temporary = createTempDir("mynim-nested-sign-", "")
    defer: removeDir(temporary)
    let app = temporary / "Sample.app"
    let resources = app / "Contents" / "Resources"
    let plugin = resources / "Plugin.bundle"
    let pluginTool = plugin / "Contents" / "MacOS" / "tool"
    let helper = resources / "bin" / "tool"
    let javaClass = resources / "classes" / "Main.class"
    createDir(pluginTool.parentDir())
    createDir(helper.parentDir())
    createDir(javaClass.parentDir())
    writeFile(plugin / "Info.plist", "<plist/>")
    writeFile(pluginTool, "\xCF\xFA\xED\xFE" & "plugin Mach-O")
    writeFile(helper, "\xCF\xFA\xED\xFE" & "helper Mach-O")
    writeFile(javaClass, "\xCA\xFE\xBA\xBE\x00\x00\x00\x3D" &
      "Java class")
    writeFile(temporary / "helper.plist", "<plist/>")

    let macos = parseJson(
      """{"helperEntitlements":{"bin/tool":"helper.plist"}}""")
    let helpers = helperEntitlements(macos, temporary)
    doAssert helpers["bin/tool"] == temporary / "helper.plist"

    let bin = temporary / "bin-tools"
    createDir(bin)
    let log = temporary / "codesign-args.txt"
    let codesign = bin / "codesign"
    writeFile(codesign, """#!/bin/sh
printf '<%s>' "$@" >> "$MYNIM_TEST_CODESIGN_LOG"
printf '\n' >> "$MYNIM_TEST_CODESIGN_LOG"
if [ "$1" = "--verify" ]; then exit 1; fi
exit 0
""")
    setFilePermissions(codesign, {fpUserRead, fpUserWrite, fpUserExec})
    let oldPath = getEnv("PATH")
    let oldLog = getEnv("MYNIM_TEST_CODESIGN_LOG")
    putEnv("PATH", bin & ":" & oldPath)
    putEnv("MYNIM_TEST_CODESIGN_LOG", log)
    try:
      signBundle(app, "-", "", helpers)
      var calls = readFile(log).splitLines()
      if calls.len > 0 and calls[^1].len == 0:
        calls.setLen(calls.len - 1)
      doAssert calls.len == 5
      doAssert calls[0].startsWith("<--verify><" & pluginTool & ">")
      doAssert calls[1].contains("<--preserve-metadata=entitlements>")
      doAssert calls[1].endsWith("<" & pluginTool & ">")
      doAssert calls[2].contains("<--entitlements><" &
        (temporary / "helper.plist") & ">")
      doAssert calls[2].endsWith("<" & helper & ">")
      doAssert calls[3].endsWith("<" & plugin & ">")
      doAssert calls[4].contains("<--deep><--sign><->")
      doAssert calls[4].endsWith("<" & app & ">")
    finally:
      putEnv("PATH", oldPath)
      putEnv("MYNIM_TEST_CODESIGN_LOG", oldLog)

    doAssertRaises(ValueError):
      discard helperEntitlements(parseJson(
        """{"helperEntitlements":{"../../outside":"bad.plist"}}"""),
        temporary)
    doAssertRaises(ValueError):
      discard helperEntitlements(parseJson(
        """{"helperEntitlements":{"\\outside":"bad.plist"}}"""),
        temporary)

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
  testNestedSigning()
  testNotarization()
