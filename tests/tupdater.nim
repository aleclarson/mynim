import std/assertions

include "../src/mynim.nim"

block old_update_files:
  let dir = getTempDir() / ("mynim-updater-" & $getCurrentProcessId())
  createDir(dir)
  let oldFile = dir / ".app.old-123"
  let oldDirectory = dir / ".data.old-123"
  let keep = dir / "app.old-123"
  defer:
    if fileExists(oldFile): removeFile(oldFile)
    if dirExists(oldDirectory): removeDir(oldDirectory)
    if fileExists(keep): removeFile(keep)
    removeDir(dir)

  writeFile(oldFile, "old executable")
  createDir(oldDirectory)
  writeFile(oldDirectory / "nested", "old data")
  writeFile(keep, "current file")

  cleanOldUpdateFiles(dir)
  doAssert not fileExists(oldFile)
  doAssert not dirExists(oldDirectory)
  doAssert fileExists(keep)
