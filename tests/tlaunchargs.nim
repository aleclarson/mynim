import std/[assertions, os, uri, strutils]
import mynim/internal/launchargs

block url_scheme_validation:
  doAssert isURLScheme("my-app+2.x")
  doAssert isURLScheme("a")
  doAssert not isURLScheme("")
  doAssert not isURLScheme("2app")
  doAssert not isURLScheme("my_app")

block handled_url_arguments:
  doAssert urlArgs(
    ["myapp://open", "OTHER://open", "C:\\files\\note.txt", "not a URL"],
    ["myapp"]) == @["myapp://open"]
  doAssert urlArgs(["MYAPP:open"], ["myapp"]) == @["MYAPP:open"]

block associated_file_arguments:
  let dir = getTempDir() / ("mynim-launchargs-" & $getCurrentProcessId())
  createDir(dir)

  let relative = "notes.MD"
  let absolute = dir / relative
  let urlFile = dir / "url note.md"
  defer:
    removeFile(absolute)
    removeFile(urlFile)
    removeDir(dir / "folder.md")
    removeDir(dir)
  writeFile(absolute, "relative")
  writeFile(urlFile, "URL")
  createDir(dir / "folder.md")

  let fileUri = "file://" & encodeUrl(urlFile, usePlus = false).replace("%2F", "/")
  doAssert fileArgs([relative, "missing.md", dir / "folder.md"], dir,
    [".md"]) == @[absolute]
  doAssert fileArgs([fileUri], dir, ["MD"]) == @[urlFile]
  doAssert fileArgs([relative], dir, []) == @[]
