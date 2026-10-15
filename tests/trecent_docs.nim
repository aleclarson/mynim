import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "recent docs test"))
app.initialized = true

let dataDir = getTempDir() / ("mynim-recent-" & $getCurrentProcessId())
createDir(dataDir)
app.setPath(pathUserData, dataDir)
recentDocs.mu.acquire()
recentDocs.loaded = false
recentDocs.paths.setLen(0)
recentDocs.mu.release()

block addsAbsolutePathsDeduplicatesAndKeepsTen:
  let dir = getTempDir() / ("mynim-recent-files-" &
    $getCurrentProcessId())
  createDir(dir)
  let oldDir = getCurrentDir()
  var paths: seq[string]
  defer: setCurrentDir(oldDir)
  setCurrentDir(dir)
  defer:
    removeFile(dir / "relative.txt")
    for path in paths:
      if fileExists(path):
        removeFile(path)
    removeDir(dir)
  writeFile("relative.txt", "recent")
  doAssert app.addRecentDocument("relative.txt") == nil
  let relativePath = absolutePath("relative.txt")
  doAssert app.recentDocuments() == @[relativePath]

  for i in 0 ..< 12:
    let path = dir / ("file-" & $i & ".txt")
    writeFile(path, $i)
    paths.add path
    doAssert app.addRecentDocument(path) == nil
  doAssert app.addRecentDocument(paths[5]) == nil
  let recent = app.recentDocuments()
  doAssert recent.len == maxRecentDocuments
  doAssert recent[0] == paths[5]
  doAssert recent[1] == paths[11]
  doAssert paths[5] notin recent[1 .. ^1]

  removeFile(paths[11])
  doAssert paths[11] notin app.recentDocuments()

  recentDocs.mu.acquire()
  recentDocs.loaded = false
  recentDocs.paths.setLen(0)
  recentDocs.mu.release()
  doAssert app.recentDocuments()[0] == paths[5]
  doAssert app.addRecentDocument("") != nil


block recentMenuOpensAndClears:
  let folder = dataDir / "folder"
  createDir(folder)
  defer: removeDir(folder)
  doAssert app.addRecentDocument(folder) == nil
  let menu = newMenu([MenuItem(role: roleOpenRecent)])
  let recent = menu.items()[0].submenu
  doAssert recent.len == 3
  doAssert recent[0].label == "folder"
  doAssert recent[0].toolTip == folder
  doAssert recent[2].label == menuMessages().menuClearRecent()
  doAssert recent[2].disabled == false

  var opened: seq[string]
  let off = app.onOpenFile(proc(path: string) = opened.add path)
  recent[0].click(recent[0], nil)
  off()
  doAssert opened == @[folder]

  doAssert app.clearRecentDocuments() == nil
  doAssert app.recentDocuments().len == 0
  doAssert fake.recentDocuments.len == 0
  doAssert fake.recentCleared == 1

block updatesMenusAfterARecentChange:
  let folder = dataDir / "updated-folder"
  createDir(folder)
  defer: removeDir(folder)
  doAssert app.addRecentDocument(folder) == nil
  let menu = newMenu([MenuItem(role: roleOpenRecent)])
  app.setMenu(menu)
  app.mu.acquire()
  app.ready = true
  app.mu.release()
  updateRecentMenus()
  let recent = app.menu().items()[0].submenu
  doAssert recent.len == 3
  doAssert recent[0].toolTip == folder
  app.mu.acquire()
  app.ready = false
  app.mu.release()
  app.setMenu(nil)
  doAssert app.clearRecentDocuments() == nil

block clearMenuIsDisabledWhenEmpty:
  let menu = newMenu([MenuItem(role: roleOpenRecent)])
  let recent = menu.items()[0].submenu
  doAssert recent.len == 1
  doAssert recent[0].disabled

loop.shutdown()
if fileExists(dataDir / "recent-documents.json"):
  removeFile(dataDir / "recent-documents.json")
removeDir(dataDir)
