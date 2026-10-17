import std/[assertions, options, strutils]
import ../src/mynim/internal/update as updateRuntime

block versionOrdering:
  doAssert updateRuntime.compareVersions("1.10.0", "1.9.9") > 0
  doAssert updateRuntime.compareVersions("2.0.0-alpha.2",
    "2.0.0-alpha.10") < 0
  doAssert updateRuntime.compareVersions("2.0.0-rc.3", "2.0.0") < 0
  doAssert updateRuntime.compareVersions("v2.0.0+build.1",
    "2.0.0+build.2") == 0
  doAssert updateRuntime.compareVersions("1.0.0", "1.0.0") == 0

block manifestValidation:
  let manifest = updateRuntime.parseManifest("""{
    "version":"1.2.3",
    "notes":"Release notes",
    "date":"2026-10-17T12:00:00Z",
    "url":"https://example.test/app.tar.gz",
    "size":42,
    "signature":"c2ln",
    "deltas":[{"from":"1.2.2","url":"https://example.test/app.delta",
      "size":20,"signature":"ZGVsdGE="}],
    "previous":[{"version":"1.2.2","url":"https://example.test/old.tar.gz",
      "size":40,"signature":"b2xk"}]
  }""")
  doAssert manifest.version == "1.2.3"
  doAssert manifest.notes == "Release notes"
  doAssert manifest.size == 42
  doAssert manifest.deltas.len == 1
  doAssert manifest.deltas[0].fromVersion == "1.2.2"
  doAssert manifest.previous.len == 1
  doAssertRaises ValueError:
    discard updateRuntime.parseManifest(
      """{"version":"1.2.3","url":"https://example.test/a"}""")
  doAssertRaises ValueError:
    discard updateRuntime.parseManifest("""{
      "version":"", "url":"https://example.test/a", "signature":"c2ln"
    }""")

block resolveTaggedFeedAndCheck:
  const feed = updateRuntime.taggedFeedPrefix &
    "owner%2Fapp/desktop-v/update-darwin-arm64.json"
  const manifestUrl = "https://github.com/owner/app/releases/download/" &
    "desktop-v1.9.0/update-darwin-arm64.json"
  const response = """[
    {"tag_name":"desktop-v2.0.0","draft":true,"prerelease":false},
    {"tag_name":"desktop-v1.10.0","draft":false,"prerelease":true},
    {"tag_name":"desktop-v1.9.0","draft":false,"prerelease":false},
    {"tag_name":"v9.0.0","draft":false,"prerelease":false}
  ]"""
  const manifestBody = """{
    "version":"1.9.0","notes":"A release",
    "url":"https://github.com/owner/app/releases/download/desktop-v1.9.0/app.tar.gz",
    "size":100,"signature":"c2ln"
  }"""
  var requested: seq[string]
  let getter: updateRuntime.HttpGetter = proc(url: string;
      maxBytes: int): string =
    doAssert maxBytes > 0
    requested.add url
    if url.startsWith("https://api.github.com/"):
      response
    elif url == manifestUrl:
      manifestBody
    else:
      raise newException(ValueError, "unexpected update request: " & url)

  let found = updateRuntime.checkUpdate(feed, "1.8.0", getter)
  doAssert found.isSome
  doAssert found.get().version == "1.9.0"
  doAssert found.get().notes == "A release"
  doAssert requested.len == 2
  doAssert requested[0].contains("/releases?per_page=100&page=1")
  doAssert requested[1] == manifestUrl

  let noRelease: updateRuntime.HttpGetter = proc(url: string;
      maxBytes: int): string = "[]"
  doAssertRaises IOError:
    discard updateRuntime.resolveFeed(feed, noRelease)

block alreadyCurrent:
  let getter: updateRuntime.HttpGetter = proc(url: string;
      maxBytes: int): string =
    """{"version":"1.2.3","url":"https://example.test/app.tar.gz",
      "signature":"c2ln"}"""
  let found = updateRuntime.checkUpdate("https://example.test/update.json",
    "v1.2.3", getter)
  doAssert found.isNone

block requiresHttpsOutsideLoopback:
  doAssertRaises IOError:
    discard updateRuntime.httpGet("http://updates.example.test/update.json",
      "Mynim/test", 1024)
