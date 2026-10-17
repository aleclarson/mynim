import std/[assertions, strutils]
import mynim/ui as ui

block safe_external_url_schemes:
  for (url, want) in [
      ("https://example.com/a b", true),
      ("HTTP://x", true),
      ("mailto:a@b.c", true),
      ("calc", false),
      ("file:///etc/passwd", false),
      ("\\\\host\\share\\x.exe", false),
      ("javascript:alert(1)", false),
      (" https://x", false),
      ("https://x\n", false),
      ("https:\\\\x", false),
      ("/notes/1", false),
      ("", false)]:
    doAssert ui.safeToOpen(url) == want, "unexpected SafeToOpen result for " &
      url.escape()

block links_only_open_safe_external_urls:
  let urls = @[
    "https://example.com/docs",
    "mailto:a@b.c",
    "javascript:alert(1)",
    "file:///etc/passwd",
    "/notes/1",
    "\\\\host\\share\\x.exe",
    "//example.com/path",
    "https://example.com/\n"
  ]
  let tester = ui.newTester(proc(c: ui.Context) =
    discard c.column().children(proc() =
      for i, url in urls:
        discard c.link("Link " & $i, url)
    )
  , 240, 240)
  defer: tester.close()

  for i in 0 ..< urls.len:
    doAssert tester.click("Link " & $i) == nil

  doAssert tester.openedUrls() == @[
    "https://example.com/docs", "mailto:a@b.c"]
