import std/[assertions, json, os, strutils, tempfiles]
import ../src/cmd/publish
import ../src/cmd/s3 as s3Upload
import ../src/cmd/update_artifacts as updateArtifacts

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

proc testS3Signing() =
  let signature = s3Upload.signRequestV4("PUT", "/test%24file.text",
    "examplebucket.s3.amazonaws.com", "us-east-1",
    "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "20130524T000000Z",
    "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
    [("date", "Fri, 24 May 2013 00:00:00 GMT"),
      ("x-amz-storage-class", "REDUCED_REDUNDANCY")])
  doAssert signature.signature ==
    "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
    signature.signature
  doAssert signature.signedHeaders ==
    "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"

proc s3Config(): JsonNode =
  var updates = newJObject()
  var s3 = newJObject()
  updates["publicKey"] = %publicKey
  updates["url"] = %"https://downloads.example.test/my-app/"
  s3["bucket"] = %"examplebucket"
  s3["prefix"] = %"/my-app/"
  s3["endpoint"] = %"https://s3.example.test"
  s3["pathStyle"] = %true
  updates["s3"] = s3
  result = newJObject()
  result["updates"] = updates

proc testS3Settings() =
  let oldAccessKey = getEnv("AWS_ACCESS_KEY_ID")
  let oldSecretKey = getEnv("AWS_SECRET_ACCESS_KEY")
  let oldToken = getEnv("AWS_SESSION_TOKEN")
  let oldRegion = getEnv("AWS_REGION")
  putEnv("AWS_ACCESS_KEY_ID", "test-access-key")
  putEnv("AWS_SECRET_ACCESS_KEY", "test-secret-key")
  putEnv("AWS_SESSION_TOKEN", "")
  putEnv("AWS_REGION", "eu-west-1")
  defer:
    putEnv("AWS_ACCESS_KEY_ID", oldAccessKey)
    putEnv("AWS_SECRET_ACCESS_KEY", oldSecretKey)
    putEnv("AWS_SESSION_TOKEN", oldToken)
    putEnv("AWS_REGION", oldRegion)

  let config = s3Config()
  let publisher = preparePublisher(config, ".", "1.0.0")
  doAssert publisher.kind == pkS3
  doAssert publisher.s3.bucket == "examplebucket"
  doAssert publisher.s3.prefix == "/my-app/"
  doAssert publisher.url == "https://downloads.example.test/my-app/"
  doAssert updateArtifacts.runtimeUpdateSettings(config, "linux-amd64").feed ==
    "https://downloads.example.test/my-app/update-linux-amd64.json"

  let client = s3Upload.newS3Client(publisher.s3)
  let location = client.objectUrl(client.objectKey("sample file.delta"))
  doAssert location.url ==
    "https://s3.example.test/examplebucket/my-app/sample%20file.delta"
  doAssert location.host == "s3.example.test"

  let noCurlPath = createTempDir("mynim-no-curl-", "")
  let oldPath = getEnv("PATH")
  try:
    putEnv("PATH", noCurlPath)
    doAssert findExe("curl").len == 0
    doAssertRaises IOError:
      discard preparePublisher(config, ".", "1.0.0")
  finally:
    putEnv("PATH", oldPath)
    removeDir(noCurlPath)

  var noUrl = s3Config()
  noUrl["updates"].delete("url")
  doAssertRaises ValueError:
    discard preparePublisher(noUrl, ".", "1.0.0")
  doAssertRaises ValueError:
    discard updateArtifacts.runtimeUpdateSettings(noUrl, "linux-amd64")

  var bothPublishers = s3Config()
  bothPublishers["updates"]["github"] = %"owner/app"
  doAssertRaises ValueError:
    discard preparePublisher(bothPublishers, ".", "1.0.0")
  doAssertRaises ValueError:
    discard updateArtifacts.runtimeUpdateSettings(bothPublishers,
      "linux-amd64")

  var badEndpoint = s3Config()
  badEndpoint["updates"]["s3"]["endpoint"] =
    %"https://s3.example.test/path"
  doAssertRaises ValueError:
    discard preparePublisher(badEndpoint, ".", "1.0.0")

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
  proc testS3UploadOrdering() =
    let temporary = createTempDir("mynim-publish-s3-", "")
    defer: removeDir(temporary)
    let bin = temporary / "bin"
    createDir(bin)
    let log = temporary / "curl-configs.txt"
    let curl = bin / "curl"
    writeFile(curl, """#!/bin/sh
config=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--config" ]; then
    config=$2
    shift 2
  else
    shift
  fi
done
output=$(sed -n 's/^output = "\(.*\)"$/\1/p' "$config")
headers=$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$config")
printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
: > "$output"
cat "$config" >> "$MYNIM_TEST_S3_LOG"
printf '\n---\n' >> "$MYNIM_TEST_S3_LOG"
exit 0
""")
    setFilePermissions(curl, {fpUserRead, fpUserWrite, fpUserExec})

    let archive = temporary / "sample.tar.gz"
    let delta = temporary / "sample.delta"
    let manifest = temporary / "update-linux-amd64.json"
    let installScript = temporary / "install.sh"
    for path in [archive, delta, manifest, installScript]:
      writeFixture(path)

    let oldPath = getEnv("PATH")
    let oldLog = getEnv("MYNIM_TEST_S3_LOG")
    putEnv("PATH", bin & ":" & oldPath)
    putEnv("MYNIM_TEST_S3_LOG", log)
    defer:
      putEnv("PATH", oldPath)
      putEnv("MYNIM_TEST_S3_LOG", oldLog)
    let oldAccessKey = getEnv("AWS_ACCESS_KEY_ID")
    let oldSecretKey = getEnv("AWS_SECRET_ACCESS_KEY")
    let oldToken = getEnv("AWS_SESSION_TOKEN")
    let oldRegion = getEnv("AWS_REGION")
    putEnv("AWS_ACCESS_KEY_ID", "test-access-key")
    putEnv("AWS_SECRET_ACCESS_KEY", "test-secret-key")
    putEnv("AWS_SESSION_TOKEN", "test-session-token")
    putEnv("AWS_REGION", "eu-west-1")
    defer:
      putEnv("AWS_ACCESS_KEY_ID", oldAccessKey)
      putEnv("AWS_SECRET_ACCESS_KEY", oldSecretKey)
      putEnv("AWS_SESSION_TOKEN", oldToken)
      putEnv("AWS_REGION", oldRegion)

    let config = s3Config()
    let publisher = preparePublisher(config, ".", "1.0.0")
    publish(publisher, [archive, delta, manifest, installScript])
    let output = readFile(log)
    doAssert output.count("url = ") == 4
    doAssert output.find("sample.tar.gz") < output.find("sample.delta")
    doAssert output.find("sample.delta") < output.find("install.sh")
    doAssert output.find("install.sh") <
      output.find("update-linux-amd64.json")
    doAssert output.contains("Cache-Control: no-cache")
    doAssert output.toLowerAscii().contains(
      "x-amz-security-token: test-session-token")
    doAssert output.toLowerAscii().count(
      "x-amz-security-token: test-session-token") == 4
    doAssert not output.contains("test-secret-key")

  testS3UploadOrdering()
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
testS3Signing()
testS3Settings()
testUploadSelection()
when defined(posix):
  testGithubDraftUpload()
