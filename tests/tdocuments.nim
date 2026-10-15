import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "documents test"))
app.initialized = true
app.mu.acquire()
app.ready = true
app.mu.release()

let docTestDir = getTempDir() / ("mynim-documents-" & $getCurrentProcessId())
createDir(docTestDir)
app.setPath(pathUserData, docTestDir)

let docs = newDocuments[string](DocumentsOptions[string](
  types: @[DocumentType(name: "Text", extensions: @["txt"])],
  read: proc(input: streams.Stream): string = input.readAll(),
  write: proc(output: streams.Stream; content: string) = output.write(content),
  window: proc(doc: Document[string]): Window =
    newWindow(WindowOptions(title: doc.name()))))

block createEditAndSave:
  let doc = docs.new()
  doAssert doc.name() == "Untitled 1"
  doAssert not doc.isEdited()
  doc.set("first draft")
  doAssert doc.isEdited()
  let path = docTestDir / "notes.txt"
  doAssert doc.saveAs(path) == nil
  doAssert readFile(path) == "first draft"
  doAssert doc.path() == absolutePath(path)
  doAssert not doc.isEdited()
  doAssert path in app.recentDocuments()
  let permissions = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
  setFilePermissions(path, permissions)
  doc.set("first draft v2")
  doAssert doc.save() == nil
  doAssert getFilePermissions(path) == permissions
  doc.set("first draft")
  doAssert doc.save() == nil

block openFocusesExistingDocument:
  let path = docTestDir / "notes.txt"
  let opened = docs.open(path)
  doAssert opened.err == nil
  doAssert opened.doc.content() == "first draft"
  doAssert docs.documents().len == 1
  let again = docs.open(path)
  doAssert again.err == nil
  doAssert again.doc == opened.doc
  doAssert docs.documents().len == 1

block recentSelectionUsesDocumentController:
  let path = absolutePath(docTestDir / "notes.txt")
  var found = false
  for item in recentMenuItems():
    if item.toolTip == path:
      found = true
      item.click(item, nil)
      break
  doAssert found
  doAssert docs.documents().len == 1

block revertRestoresSavedContent:
  let doc = docs.documents()[0]
  doc.set("temporary edit")
  doAssert doc.isEdited()
  doAssert doc.revert() == nil
  doAssert doc.content() == "first draft"
  doAssert not doc.isEdited()

block detectsExternalChanges:
  let doc = docs.documents()[0]
  let path = doc.path()
  doc.set("local revision")
  writeFile(path, "external revision")
  doAssert doc.save() == ErrDocumentChanged
  doAssert doc.hasConflict()
  doAssert readFile(path) == "external revision"
  doAssert doc.saveAnyway() == nil
  doAssert readFile(path) == "local revision"

block opensFilesFromDialog:
  let path = docTestDir / "from-dialog.txt"
  writeFile(path, "dialog content")
  fake.onOpenDialog = proc(options: platform.OpenDialogOptions): seq[string] =
    @[path]
  let selected = docs.openDialog()
  doAssert selected.err == nil
  doAssert selected.documents.len == 1
  doAssert selected.documents[0].content() == "dialog content"
  fake.onOpenDialog = nil

block renameAndMove:
  let doc = docs.documents()[0]
  let renamed = docTestDir / "renamed.txt"
  doAssert doc.rename("renamed.txt") == nil
  doAssert not fileExists(docTestDir / "notes.txt")
  doAssert readFile(renamed) == "local revision"
  doAssert doc.path() == absolutePath(renamed)
  doAssert doc.name() == "renamed.txt"
  doAssert doc.rename("../outside.txt") != nil

  let dialogRenamed = docTestDir / "dialog-renamed.txt"
  var sawRenameDialog = false
  fake.onSaveDialog = proc(options: platform.SaveDialogOptions): string =
    sawRenameDialog = options.title == "Rename" and
      options.buttonLabel == "Rename" and
      options.nameFieldLabel == "Rename To:"
    docTestDir / "dialog-renamed"
  doAssert doc.rename() == nil
  fake.onSaveDialog = nil
  doAssert sawRenameDialog
  doAssert fileExists(dialogRenamed)
  doAssert doc.path() == absolutePath(dialogRenamed)

  let movedDir = docTestDir / "moved"
  createDir(movedDir)
  doAssert doc.moveTo(movedDir) == nil
  let moved = movedDir / "dialog-renamed.txt"
  doAssert not fileExists(dialogRenamed)
  doAssert readFile(moved) == "local revision"
  doAssert doc.path() == absolutePath(moved)

  let replaceDir = docTestDir / "replace"
  createDir(replaceDir)
  let replaceTarget = replaceDir / "dialog-renamed.txt"
  writeFile(replaceTarget, "old destination")
  var sawReplacePrompt = false
  fake.onMessageBox = proc(options: platform.MessageBoxOptions):
      platform.MessageBoxResult =
    sawReplacePrompt = options.buttons.len == 2 and
      options.buttons[0] == "Replace" and options.buttons[1] == "Cancel"
    platform.MessageBoxResult(response: 0)
  doAssert doc.moveTo(replaceDir) == nil
  doAssert sawReplacePrompt
  doAssert not fileExists(moved)
  doAssert readFile(replaceTarget) == "local revision"
  doAssert doc.path() == absolutePath(replaceTarget)

  let cancelDir = docTestDir / "cancel-move"
  createDir(cancelDir)
  let cancelTarget = cancelDir / "dialog-renamed.txt"
  writeFile(cancelTarget, "keep destination")
  fake.onMessageBox = proc(options: platform.MessageBoxOptions):
      platform.MessageBoxResult = platform.MessageBoxResult(response: 1)
  doAssert doc.moveTo(cancelDir) == ErrCanceled
  doAssert doc.path() == absolutePath(replaceTarget)
  doAssert readFile(cancelTarget) == "keep destination"
  fake.onMessageBox = nil

  let pickedDir = docTestDir / "picked"
  createDir(pickedDir)
  var sawDirectoryDialog = false
  fake.onOpenDialog = proc(options: platform.OpenDialogOptions): seq[string] =
    sawDirectoryDialog = options.openDirectories and options.createDirectories
    @[pickedDir]
  doAssert doc.moveTo() == nil
  fake.onOpenDialog = nil
  let pickedPath = pickedDir / "dialog-renamed.txt"
  doAssert sawDirectoryDialog
  doAssert doc.path() == absolutePath(pickedPath)
  doAssert readFile(pickedPath) == "local revision"

  let untitledDir = docTestDir / "untitled-move"
  createDir(untitledDir)
  let untitled = docs.new()
  untitled.set("new content")
  let untitledPath = untitledDir / (untitled.name() & ".txt")
  doAssert untitled.moveTo(untitledDir) == nil
  doAssert untitled.path() == absolutePath(untitledPath)
  doAssert readFile(untitledPath) == "new content"
  doAssert not untitled.isEdited()
  fake.onOpenDialog = nil
  fake.onSaveDialog = nil
  fake.onMessageBox = nil

for doc in docs.documents():
  doc.window().destroy()
loop.shutdown()
if fileExists(docTestDir / "recent-documents.json"):
  removeFile(docTestDir / "recent-documents.json")
for path in [docTestDir / "notes.txt", docTestDir / "renamed.txt",
    docTestDir / "dialog-renamed.txt", docTestDir / "moved" / "dialog-renamed.txt",
    docTestDir / "replace" / "dialog-renamed.txt",
    docTestDir / "cancel-move" / "dialog-renamed.txt",
    docTestDir / "picked" / "dialog-renamed.txt",
    docTestDir / "untitled-move" / "Untitled 1.txt"]:
  if fileExists(path):
    removeFile(path)
if fileExists(docTestDir / "from-dialog.txt"):
  removeFile(docTestDir / "from-dialog.txt")
for dir in [docTestDir / "moved", docTestDir / "replace",
    docTestDir / "cancel-move", docTestDir / "picked",
    docTestDir / "untitled-move"]:
  if dirExists(dir):
    removeDir(dir)
removeDir(docTestDir)
