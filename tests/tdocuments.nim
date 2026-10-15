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

for doc in docs.documents():
  doc.window().destroy()
loop.shutdown()
if fileExists(docTestDir / "recent-documents.json"):
  removeFile(docTestDir / "recent-documents.json")
if fileExists(docTestDir / "notes.txt"):
  removeFile(docTestDir / "notes.txt")
if fileExists(docTestDir / "from-dialog.txt"):
  removeFile(docTestDir / "from-dialog.txt")
removeDir(docTestDir)
