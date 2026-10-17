import std/[assertions, json, os, strutils, tempfiles]
import ../src/cmd/publish

const publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

proc githubConfig(tagPrefix = ""; s3 = false): JsonNode =
  var updates = newJObject()
  updates["publicKey"] = %publicKey
  updates["github"] = %"owner/app"
  if tagPrefix.len > 0:
    updates["tagPrefix"] = %tagPrefix
  if s3:
    updates["s3"] = newJObject()
  result = newJObject()
  result["updates"] = updates

proc writeFixture(path: string) =
  createDir(path.parentDir())
  writeFile(path, "fixture")

proc testReleaseNotes() =
  let changelog = """# Changelog

## [v1.2.3] - 2026-10-17

Added signed updates.

## 1.2.2
Earlier release.
"""
  doAssert releaseNotes(changelog, "1.2.3") == "Added signed updates."
  doAssert releaseNotes(changelog, "v1.2.3") == "Added signed updates."
  doAssert releaseNotes(changelog, "1.2.1").len == 0

proc testReleaseSettings() =
  let temporary = createTempDir("mynim-publish-settings-", "")
  defer: removeDir(temporary)
  writeFile(temporary / "CHANGELOG.md", "## 1.4.0\n\nRelease notes.\n")

  let defaultTag = prepareGitHubRelease(githubConfig(), temporary, "1.4.0")
  doAssert defaultTag.repo == "owner/app"
  doAssert defaultTag.tag == "v1.4.0"
  doAssert defaultTag.latest
  doAssert defaultTag.notes == "Release notes."

  let prefixedTag = prepareGitHubRelease(githubConfig("desktop-v"), temporary,
    "1.4.0")
  doAssert prefixedTag.tag == "desktop-v1.4.0"
  doAssert not prefixedTag.latest

  var emptyPrefix = githubConfig()
  emptyPrefix["updates"]["tagPrefix"] = %""
  doAssert prepareGitHubRelease(emptyPrefix, temporary, "1.4.0").tag ==
    "v1.4.0"
  var emptyChangelog = githubConfig()
  emptyChangelog["updates"]["changelog"] = %""
  doAssert prepareGitHubRelease(emptyChangelog, temporary, "1.4.0").notes ==
    "Release notes."

  doAssertRaises(ValueError):
    discard prepareGitHubRelease(parseJson("{}"), temporary, "1.4.0")
  doAssertRaises(ValueError):
    discard prepareGitHubRelease(githubConfig(s3 = true), temporary, "1.4.0")

proc testUploadSelection() =
  let temporary = createTempDir("mynim-publish-files-", "")
  defer: removeDir(temporary)
  let bundle = temporary / "Sample.app"
  createDir(bundle)
  let installer = temporary / "Sample Setup 1.0.exe"
  let dmg = temporary / "Sample 1.0.dmg"
  let deb = temporary / "sample.deb"
  let archive = temporary / "sample.tar.gz"
  let delta = temporary / "sample.delta"
  let manifest = temporary / "update-linux-amd64.json"
  let installScript = temporary / "install.sh"
  let secondScript = temporary / "linux" / "install.sh"
  let ignored = temporary / "sample.exe"
  for path in [installer, dmg, deb, archive, delta, manifest,
      installScript, secondScript, ignored]:
    writeFixture(path)

  let (files, manifests) = uploadFiles([
    bundle, installer, dmg, deb, archive, delta, installScript,
    secondScript, ignored, manifest])
  doAssert files == @[installer, dmg, deb, archive, delta, installScript]
  doAssert manifests == @[manifest]
  doAssertRaises(ValueError):
    discard uploadFiles([ignored])

when defined(posix):
  proc testGithubDraftUpload() =
    let temporary = createTempDir("mynim-publish-gh-", "")
    defer: removeDir(temporary)
    let bin = temporary / "bin"
    createDir(bin)
    let log = temporary / "gh-args.txt"
    let gh = bin / "gh"
    writeFile(gh, """#!/bin/sh
printf '<%s>' "$@" >> "$MYNIM_TEST_GH_LOG"
printf '\n' >> "$MYNIM_TEST_GH_LOG"
if [ "$2" = "view" ]; then exit 1; fi
exit 0
""")
    setFilePermissions(gh, {fpUserRead, fpUserWrite, fpUserExec})

    let first = temporary / "Sample 1.0.dmg"
    let manifest = temporary / "update-darwin-arm64.json"
    writeFixture(first)
    writeFixture(manifest)
    let oldPath = getEnv("PATH")
    let oldLog = getEnv("MYNIM_TEST_GH_LOG")
    putEnv("PATH", bin & ":" & oldPath)
    putEnv("MYNIM_TEST_GH_LOG", log)
    defer:
      putEnv("PATH", oldPath)
      putEnv("MYNIM_TEST_GH_LOG", oldLog)

    let release = GitHubRelease(repo: "owner/app", tag: "desktop-v1.0",
      notes: "Release notes.", latest: false)
    publishGitHub(release, [first, manifest])

    var calls = readFile(log).splitLines()
    if calls.len > 0 and calls[^1].len == 0:
      calls.setLen(calls.len - 1)
    doAssert calls.len == 4
    doAssert calls[0] == "<release><view><desktop-v1.0><--repo><owner/app>"
    doAssert calls[1].contains("<release><create><desktop-v1.0>")
    doAssert calls[1].contains("<--latest=false>")
    doAssert calls[2].contains("<release><upload><desktop-v1.0>")
    doAssert calls[2].contains("<" & first & ">")
    doAssert calls[3].contains("<" & manifest & ">")

testReleaseNotes()
testReleaseSettings()
testUploadSelection()
when defined(posix):
  testGithubDraftUpload()
