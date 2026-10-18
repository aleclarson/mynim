import std/[strutils, unittest, unicode]
import mynim/plugins/terminal/internal/links

proc columnsFor(text: string): seq[int] =
  let runes = text.toRunes()
  result = newSeq[int](runes.len)
  for index in 0 ..< result.len:
    result[index] = index

suite "terminal link detection":
  test "matches printed URLs and trims sentence punctuation":
    let text = "See https://example.com/a(b)."
    let columns = columnsFor(text)
    let link = linkAt(text, columns, text.find("example") + 9,
      includePaths = false)
    check link.target == "https://example.com/a(b)"
    check not link.isPath
    check linkAt(text, columns, text.high, includePaths = false).target == ""
    let empty = "https:// https://example.com"
    check linkAt(empty, columnsFor(empty), 2,
      includePaths = false).target == ""

  test "matches mail links and keeps balanced URL brackets":
    let text = "mailto:dev@example.com https://example.com/x[y]"
    let columns = columnsFor(text)
    check linkAt(text, columns, 3, includePaths = false).target ==
      "mailto:dev@example.com"
    check linkAt(text, columns, text.high, includePaths = false).target ==
      "https://example.com/x[y]"

  test "matches file paths only when enabled":
    let text = "Open ./src/main.nim:12:4 now"
    let columns = columnsFor(text)
    let column = text.find("main") + 2
    check linkAt(text, columns, column, includePaths = false).target == ""
    let link = linkAt(text, columns, column, includePaths = true)
    check link.target == "./src/main.nim:12:4"
    check link.isPath

  test "matches absolute and file-and-line paths":
    let absolute = "/tmp/build output"
    let absoluteLink = linkAt(absolute, columnsFor(absolute), 5,
      includePaths = true)
    check absoluteLink.target == "/tmp/build"
    let filename = "error at main.nim:7"
    check linkAt(filename, columnsFor(filename), filename.find("main") + 1,
      includePaths = true).target == "main.nim:7"
    let invalidFilename = "main.nim-extra:7"
    check linkAt(invalidFilename, columnsFor(invalidFilename), 3,
      includePaths = true).target == ""

  test "only permits recognized system URL schemes":
    check safeTerminalUrl("https://example.com")
    check safeTerminalUrl("file:///tmp/readme")
    check not safeTerminalUrl("javascript:alert(1)")
    check not safeTerminalUrl("https://example.com\\path")
