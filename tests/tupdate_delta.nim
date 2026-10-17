import std/[assertions, os, tempfiles]
import ../src/mynim/internal/update_delta

proc putFile(root, relative, contents: string; executable = false) =
  let path = root / relative
  createDir(path.parentDir())
  writeFile(path, contents)
  if executable:
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

block delta_roundtrip:
  let temporary = createTempDir("mynim-delta-", "")
  defer:
    if dirExists(temporary): removeDir(temporary)
  let oldDir = temporary / "old"
  let newDir = temporary / "new"
  let outDir = temporary / "out"
  createDir(oldDir)
  createDir(newDir)

  var oldCode = newString(100_000)
  for i in 0 ..< oldCode.len:
    oldCode[i] = char((i * 73 + i div 19) and 0xff)
  var newCode = oldCode
  for i in countup(101, newCode.high, 997):
    newCode[i] = char((ord(newCode[i]) + 1) and 0xff)

  putFile(oldDir, "app.exe", oldCode, executable = true)
  putFile(oldDir, "res/same.txt", "unchanged")
  putFile(oldDir, "res/moved.txt", "moved file")
  putFile(oldDir, "res/removed.txt", "removed file")
  putFile(oldDir, "res/empty", "")
  putFile(oldDir, "Contents/CodeResources", "old stapled ticket")
  putFile(oldDir, "lib/v1/lib.so", "library")
  when not defined(windows):
    createSymlink("v1/lib.so", oldDir / "lib/current")

  putFile(newDir, "app.exe", newCode, executable = true)
  putFile(newDir, "res/same.txt", "unchanged")
  putFile(newDir, "res/other/moved.txt", "moved file")
  putFile(newDir, "res/changed.txt", "changed contents")
  putFile(newDir, "res/empty", "")
  putFile(newDir, "res/new-empty/marker", "")
  putFile(newDir, "Contents/CodeResources", "new stapled ticket")
  putFile(newDir, "lib/v1/lib.so", "library")
  when not defined(windows):
    createSymlink("v1/lib.so", newDir / "lib/current")

  let delta = writeDelta("1.0.0", "1.1.0", oldDir, newDir)
  doAssert delta.len < 10_000
  applyDelta(delta, "1.0.0", "1.1.0", oldDir, outDir)
  doAssert readFile(outDir / "app.exe") == newCode
  doAssert readFile(outDir / "res/same.txt") == "unchanged"
  doAssert readFile(outDir / "res/other/moved.txt") == "moved file"
  doAssert not fileExists(outDir / "res/removed.txt")
  doAssert readFile(outDir / "Contents/CodeResources") == "new stapled ticket"
  doAssert fpUserExec in getFilePermissions(outDir / "app.exe")
  when not defined(windows):
    doAssert expandSymlink(outDir / "lib/current") == "v1/lib.so"

  var wrongVersion = false
  try:
    applyDelta(delta, "0.9.0", "1.1.0", oldDir, temporary / "wrong")
  except ValueError:
    wrongVersion = true
  doAssert wrongVersion

  var truncated = false
  try:
    applyDelta(delta[0 ..< delta.high], "1.0.0", "1.1.0", oldDir,
      temporary / "truncated")
  except CatchableError:
    truncated = true
  doAssert truncated

block selected_paths_only:
  let temporary = createTempDir("mynim-delta-selected-", "")
  defer:
    if dirExists(temporary): removeDir(temporary)
  let oldDir = temporary / "old"
  let newDir = temporary / "new"
  createDir(oldDir)
  createDir(newDir)
  putFile(oldDir, "app", "old")
  putFile(oldDir, "resource", "old resource")
  putFile(newDir, "app", "new")
  putFile(newDir, "resource", "new resource")
  let delta = writeDelta("1", "2", oldDir, newDir, @["app"])
  applyDelta(delta, "1", "2", oldDir, temporary / "out")
  doAssert readFile(temporary / "out" / "app") == "new"
  doAssert not fileExists(temporary / "out" / "resource")

block refuses_outward_symlinks:
  when not defined(windows):
    let temporary = createTempDir("mynim-delta-link-", "")
    defer:
      if dirExists(temporary): removeDir(temporary)
    let oldDir = temporary / "old"
    let newDir = temporary / "new"
    createDir(oldDir)
    createDir(newDir)
    createSymlink("../outside", newDir / "escape")
    doAssertRaises ValueError:
      discard writeDelta("1", "2", oldDir, newDir)
