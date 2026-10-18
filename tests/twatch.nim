import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "watch test"))
app.initialized = true

proc watchTarget(native: fakeBackend.FakeFileWatch; path: string):
    platform.FileWatchTarget =
  for target in native.allTargets():
    if target.path == path:
      return target
  raise newException(AssertionDefect, "no watch target for " & path)

block directoryEventsAndClose:
  let dir = getTempDir() / ("mynim-watch-" & randomText())
  createDir(dir)
  defer: removeDir(dir)
  let (watcher, startErr) = watchFiles(newCtx(), dir,
    FileWatchOptions(debounce: initDuration(milliseconds = -1)))
  doAssert startErr == nil
  doAssert watcher.root == expandFilename(dir)

  let child = dir / "created.txt"
  writeFile(child, "one")
  let native = fake.lastFileWatch()
  let target = watchTarget(native, watcher.root)
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchCreate, name: "created.txt"))
  let (events, nextErr) = watcher.next(newCtx())
  doAssert nextErr == nil
  doAssert events == @[FileEvent(op: FileCreate, path: "created.txt")]

  doAssert watcher.close() == nil
  watcher.waitDone()
  let (_, eof) = watcher.next(newCtx())
  doAssert isFileWatchEOF(eof)
  doAssert watcher.err == nil

block recursiveIgnoreAndDiff:
  let dir = getTempDir() / ("mynim-watch-recursive-" & randomText())
  createDir(dir)
  createDir(dir / "nested")
  createDir(dir / "ignored")
  defer:
    removeFile(dir / "nested" / "created.txt")
    removeDir(dir / "nested")
    removeDir(dir / "ignored")
    removeDir(dir)
  fake.fileWatchSubtree = false
  let (watcher, startErr) = watchFiles(newCtx(), dir,
    FileWatchOptions(recursive: true,
      ignore: proc(path: string; isDir: bool): bool = path == "ignored",
      debounce: initDuration(milliseconds = -1)))
  doAssert startErr == nil
  let native = fake.lastFileWatch()
  doAssert native.allTargets().len == 2
  let nestedTarget = watchTarget(native, watcher.root / "nested")
  writeFile(dir / "nested" / "created.txt", "nested")
  native.notifyNow(platform.FileWatchNotice(target: nestedTarget.id,
    kind: platform.fileWatchCreate, name: "created.txt"))
  let (events, nextErr) = watcher.next(newCtx())
  doAssert nextErr == nil
  doAssert events == @[FileEvent(op: FileCreate,
    path: "nested/created.txt")]
  doAssert watcher.close() == nil
  watcher.waitDone()

block renameAndRootRemoval:
  let dir = getTempDir() / ("mynim-watch-rename-" & randomText())
  createDir(dir)
  let oldPath = dir / "before.txt"
  let newPath = dir / "after.txt"
  writeFile(oldPath, "same file")
  defer:
    if fileExists(oldPath): removeFile(oldPath)
    if fileExists(newPath): removeFile(newPath)
    if dirExists(dir): removeDir(dir)
  let (watcher, startErr) = watchFiles(newCtx(), dir,
    FileWatchOptions(debounce: initDuration(milliseconds = -1)))
  doAssert startErr == nil
  let native = fake.lastFileWatch()
  let target = watchTarget(native, watcher.root)
  moveFile(oldPath, newPath)
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchMoveFrom, name: "before.txt"))
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchMoveTo, name: "after.txt"))
  let (events, nextErr) = watcher.next(newCtx())
  doAssert nextErr == nil
  doAssert events == @[FileEvent(op: FileRename,
    path: "after.txt", oldPath: "before.txt")]

  doAssert watcher.close() == nil
  watcher.waitDone()

block rootRemovalEndsWatch:
  let dir = getTempDir() / ("mynim-watch-gone-" & randomText())
  createDir(dir)
  let (watcher, startErr) = watchFiles(newCtx(), dir,
    FileWatchOptions(debounce: initDuration(milliseconds = -1)))
  doAssert startErr == nil
  let native = fake.lastFileWatch()
  let target = watchTarget(native, watcher.root)
  removeDir(dir)
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchLost))
  let (events, nextErr) = watcher.next(newCtx())
  doAssert nextErr == nil
  doAssert events == @[FileEvent(op: FileRemove, path: ".", isDir: true)]
  watcher.waitDone()
  let (_, eof) = watcher.next(newCtx())
  doAssert isFileWatchEOF(eof)

block maxEntriesValidation:
  let dir = getTempDir() / ("mynim-watch-limit-" & randomText())
  createDir(dir)
  writeFile(dir / "one", "1")
  defer:
    removeFile(dir / "one")
    removeDir(dir)
  let (watcher, startErr) = watchFiles(newCtx(), dir,
    FileWatchOptions(maxEntries: 1))
  doAssert watcher == nil
  doAssert startErr != nil and
    startErr.msg == "mynim: file watch entry limit exceeded"

block fileWatchAndCancellation:
  let dir = getTempDir() / ("mynim-watch-file-" & randomText())
  createDir(dir)
  let file = dir / "source.txt"
  writeFile(file, "old")
  defer:
    removeFile(file)
    removeDir(dir)
  let (parent, cancel) = newCtx().withCancel()
  let (watcher, startErr) = watchFiles(parent, file,
    FileWatchOptions(debounce: initDuration(milliseconds = -1)))
  doAssert startErr == nil
  let native = fake.lastFileWatch()
  let target = watchTarget(native, parentDir(watcher.root))
  writeFile(file, "new contents")
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchWrite, name: "source.txt"))
  let (events, nextErr) = watcher.next(newCtx())
  doAssert nextErr == nil
  doAssert events == @[FileEvent(op: FileWrite, path: ".")]
  removeFile(file)
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchRemove, name: "source.txt"))
  let (removed, removeErr) = watcher.next(newCtx())
  doAssert removeErr == nil
  doAssert removed == @[FileEvent(op: FileRemove, path: ".")]
  writeFile(file, "again")
  native.notifyNow(platform.FileWatchNotice(target: target.id,
    kind: platform.fileWatchCreate, name: "source.txt"))
  let (created, createErr) = watcher.next(newCtx())
  doAssert createErr == nil
  doAssert created == @[FileEvent(op: FileCreate, path: ".")]
  cancel()
  watcher.waitDone()
  let (_, eof) = watcher.next(newCtx())
  doAssert isFileWatchEOF(eof)
