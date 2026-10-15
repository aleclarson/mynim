## document.go + document_flow.go — typed documents, basic file flow,
## and the File menu hooks.

import std/streams

type
  DocumentType* = object
    ## Describes a file kind shown by document dialogs.
    name*: string
    ## Extensions omit the leading dot, for example `@["md", "markdown"]`.
    extensions*: seq[string]

  DocumentsOptions*[T] = object
    ## Types accepted by this controller; the first is used for new files.
    types*: seq[DocumentType]
    ## Makes the initial content of an untitled document.
    new*: proc(): T {.closure.}
    ## Reads content from a stream. Exceptions are returned by `open`.
    read*: proc(input: streams.Stream): T {.closure.}
    ## Writes a content snapshot to a stream.
    write*: proc(output: streams.Stream; content: T) {.closure.}
    ## Copies mutable content before a background save.
    snapshot*: proc(content: T): T {.closure.}
    ## Compares a document with the content it last saved or opened.
    equal*: proc(a, b: T): bool {.closure.}
    ## Creates the window for a document. Called on the UI thread.
    window*: proc(doc: Document[T]): Window {.closure.}
    noUntitled*: bool

  DocumentState* = object
    ## The file and edit state shown by a document.
    name*: string
    path*: string
    edited*: bool
    readOnly*: bool
    conflict*: bool
    deleted*: bool

  DocumentFileStamp = object
    modified: Time
    size: int64
    id: tuple[device: DeviceId, file: FileId]

  DocKind = ref object
    types: seq[DocumentType]
    noUntitled: bool
    mu: Lock
    docs: seq[DocBase]
    createUntitled: proc(name: string): DocBase {.closure.}
    readDocument: proc(path: string): tuple[doc: DocBase,
        err: ref CatchableError] {.closure.}

  DocBase = ref object of RootObj
    kind: DocKind
    mu: Lock
    path, name: string
    edited, readOnly, conflict, deleted, closed: bool
    changes, savedAt: uint64
    savedKnown: bool
    stamp: DocumentFileStamp
    stampKnown: bool
    window: Window
    closing, discarded: bool
    makeWindow: proc(): Window {.closure.}
    saveDocument: proc(): ref CatchableError {.closure.}
    saveAsDocument: proc(): ref CatchableError {.closure.}
    duplicateDocument: proc(): DocBase {.closure.}
    revertDocument: proc(): ref CatchableError {.closure.}
    onState: Listeners[proc(state: DocumentState) {.closure.}]
    onReload: Listeners[proc() {.closure.}]

  Documents*[T] = ref object
    kind: DocKind
    opts: DocumentsOptions[T]

  Document*[T] = ref object of DocBase
    ## The content is protected by the lock inherited from DocBase.
    ds: Documents[T]
    content, saved: T

  DocumentsRegistry = object
    mu: Lock
    kinds: seq[DocKind]
    launched: bool
    pending: seq[string]

var documentsRegistry = block:
  var registry: DocumentsRegistry
  registry.mu.initLock()
  registry

let ErrCanceled* = newException(IOError, "mynim: canceled")
let ErrDocumentChanged* = newException(IOError,
  "mynim: the file was changed by another application")

proc docKinds(): seq[DocKind] =
  documentsRegistry.mu.acquire()
  result = documentsRegistry.kinds
  documentsRegistry.mu.release()

proc defaultDocKind(): DocKind =
  documentsRegistry.mu.acquire()
  if documentsRegistry.kinds.len > 0:
    result = documentsRegistry.kinds[0]
  documentsRegistry.mu.release()

proc hasDocuments(): bool = defaultDocKind() != nil

proc docList(k: DocKind): seq[DocBase] =
  k.mu.acquire()
  result = k.docs
  k.mu.release()

proc allDocuments(): seq[DocBase] =
  for k in docKinds():
    result.add k.docList()

proc findDocument(path: string): DocBase =
  var id: tuple[device: DeviceId, file: FileId]
  var hasID = false
  try:
    id = getFileInfo(path).id
    hasID = true
  except CatchableError:
    discard
  for doc in allDocuments():
    doc.mu.acquire()
    let same = not doc.closed and (doc.path == path or
      (hasID and doc.stampKnown and doc.stamp.id == id))
    doc.mu.release()
    if same:
      return doc

proc nameLocked(doc: DocBase): string =
  if doc.path != "": doc.path.extractFilename() else: doc.name

proc stateLocked(doc: DocBase): DocumentState =
  DocumentState(name: doc.nameLocked(), path: doc.path, edited: doc.edited,
    readOnly: doc.readOnly, conflict: doc.conflict, deleted: doc.deleted)

proc state*[T](doc: Document[T]): DocumentState =
  doc.mu.acquire()
  result = doc.stateLocked()
  doc.mu.release()

proc path*[T](doc: Document[T]): string =
  ## The absolute path of the file, or an empty string while untitled.
  doc.mu.acquire()
  result = doc.path
  doc.mu.release()

proc name*[T](doc: Document[T]): string =
  ## The filename, or the untitled document's name.
  doc.mu.acquire()
  result = doc.nameLocked()
  doc.mu.release()

proc isEdited*[T](doc: Document[T]): bool =
  doc.mu.acquire()
  result = doc.edited
  doc.mu.release()

proc isReadOnly*[T](doc: Document[T]): bool =
  doc.mu.acquire()
  result = doc.readOnly
  doc.mu.release()

proc hasConflict*[T](doc: Document[T]): bool =
  doc.mu.acquire()
  result = doc.conflict
  doc.mu.release()

proc window*[T](doc: Document[T]): Window =
  doc.mu.acquire()
  result = doc.window
  doc.mu.release()

proc windowOf(doc: DocBase): Window =
  doc.mu.acquire()
  result = doc.window
  doc.mu.release()

proc pathOf(doc: DocBase): string =
  doc.mu.acquire()
  result = doc.path
  doc.mu.release()

proc editedOf(doc: DocBase): bool =
  doc.mu.acquire()
  result = doc.edited
  doc.mu.release()

proc documentTitle(name: string): string =
  when defined(macosx) or defined(emscripten): name
  else: name & " - " & app.name()

proc notifyDocument(doc: DocBase) =
  discard postMain(proc() =
    doc.mu.acquire()
    let state = doc.stateLocked()
    let win = doc.window
    doc.mu.release()
    if win != nil and not win.isDestroyed():
      win.setDocumentEdited(state.edited)
      win.setRepresentedFile(state.path)
      win.setTitle(documentTitle(state.name))
    fire1(doc.onState, state)
    refreshDocumentMenus())

proc changed(doc: DocBase; edited: bool) =
  doc.mu.acquire()
  let didChange = doc.edited != edited
  doc.edited = edited
  doc.mu.release()
  if didChange:
    doc.notifyDocument()

proc closeDocument(doc: DocBase) =
  let win = doc.windowOf()
  if win != nil:
    win.close()

proc askSaveBeforeClose(doc: DocBase) =
  let win = doc.windowOf()
  doc.mu.acquire()
  let name = doc.nameLocked()
  doc.mu.release()
  var channel: system.Channel[tuple[result: platform.MessageBoxResult,
      err: ref CatchableError]]
  channel.open()
  let reply = addr channel
  discard postMain(proc() =
    let dialogs = backend().dialogs()
    if dialogs == nil:
      let failure: ref CatchableError = newException(IOError,
        "mynim: document dialogs are unavailable")
      deliver(reply[], (platform.MessageBoxResult(),
        failure))
    else:
      dialogs.showMessageBox(if win == nil: nil else: win.native,
        platform.MessageBoxOptions(`type`: "warning",
          message: "Save changes to " & name & "?",
          buttons: @["Save", "Don't Save", "Cancel"], defaultId: 0,
          cancelId: 2),
        proc(value: platform.MessageBoxResult; err: ref CatchableError) =
          deliver(reply[], (value, err)))
  )
  let answer = await(channel)
  channel.close()
  if answer.err != nil:
    return
  var save = false
  var shouldDiscard = false
  case answer.result.response
  of 0:
    save = true
  of 1:
    shouldDiscard = true
  else:
    discard
  if save:
    let err = doc.saveDocument()
    if err != nil:
      stderr.writeLine("mynim: documents: " & err.msg)
      return
  if save or shouldDiscard:
    discard postMain(proc() =
      doc.mu.acquire()
      doc.closing = false
      doc.discarded = shouldDiscard
      let target = doc.window
      doc.mu.release()
      if target != nil:
        if shouldDiscard: target.destroy() else: target.close())
  else:
    doc.mu.acquire()
    doc.closing = false
    doc.mu.release()

proc attachDocument(doc: DocBase; win: Window) =
  var state: DocumentState
  doc.mu.acquire()
  doc.window = win
  state = doc.stateLocked()
  doc.mu.release()
  win.setTitle(documentTitle(state.name))
  win.setRepresentedFile(state.path)
  win.setDocumentEdited(state.edited)
  discard win.onFocus(proc() = refreshDocumentMenus())
  discard win.onBlur(proc() = refreshDocumentMenus())
  discard win.onClose(proc(event: var CloseEvent) =
    if event.defaultPrevented():
      return
    var ask = false
    doc.mu.acquire()
    if doc.edited and not doc.closing:
      doc.closing = true
      ask = true
    doc.mu.release()
    if ask:
      event.preventDefault()
      goAsync(proc() = askSaveBeforeClose(doc)))
  discard win.onClosed(proc() =
    doc.mu.acquire()
    doc.closed = true
    doc.window = nil
    doc.mu.release()
    doc.kind.mu.acquire()
    let index = doc.kind.docs.find(doc)
    if index >= 0:
      doc.kind.docs.delete(index)
    doc.kind.mu.release()
    refreshDocumentMenus())

proc showDocument(doc: DocBase) =
  doc.kind.mu.acquire()
  doc.kind.docs.add doc
  doc.kind.mu.release()
  try:
    let win = onMainValue(proc(): Window = doc.makeWindow())
    if win == nil:
      raise newException(ValueError, "mynim: DocumentsOptions.window returned nil")
    attachDocument(doc, win)
    win.show()
    refreshDocumentMenus()
  except CatchableError:
    doc.kind.mu.acquire()
    let index = doc.kind.docs.find(doc)
    if index >= 0:
      doc.kind.docs.delete(index)
    doc.kind.mu.release()
    raise

proc save*[T](doc: Document[T]): ref CatchableError
proc saveToPath[T](doc: Document[T]; path: string;
    checkConflict: bool): ref CatchableError
proc duplicate*[T](doc: Document[T]): Document[T]
proc revert*[T](doc: Document[T]): ref CatchableError
proc chooseOpen(parent: Window; filters: seq[platform.FileFilter]):
    tuple[paths: seq[string], err: ref CatchableError]
proc filters(k: DocKind): seq[platform.FileFilter]

proc makeDocument[T](ds: Documents[T]; content: T; untitledName: string):
    Document[T] =
  result = Document[T]()
  result.ds = ds
  result.kind = ds.kind
  result.name = untitledName
  result.content = content
  result.saved = content
  result.savedKnown = true
  result.mu.initLock()
  result.onState.mu.initLock()
  result.onReload.mu.initLock()
  let doc = result
  result.makeWindow = proc(): Window = ds.opts.window(doc)
  result.saveDocument = proc(): ref CatchableError = doc.save()
  result.saveAsDocument = proc(): ref CatchableError =
    doc.saveToPath("", false)
  result.duplicateDocument = proc(): DocBase = doc.duplicate()
  result.revertDocument = proc(): ref CatchableError = doc.revert()

proc nextUntitled(k: DocKind): int =
  var used = initHashSet[int]()
  for doc in k.docList():
    doc.mu.acquire()
    if doc.path == "" and doc.name.startsWith("Untitled "):
      try: used.incl parseInt(doc.name[9 .. ^1])
      except ValueError: discard
    doc.mu.release()
  result = 1
  while result in used:
    inc result

proc newUntitled(k: DocKind): DocBase =
  let name = "Untitled " & $k.nextUntitled()
  result = k.createUntitled(name)
  result.kind = k
  result.showDocument()

proc stampOf(path: string): DocumentFileStamp
proc fileWritable(path: string): bool

proc openInKind(k: DocKind; path: string): tuple[doc: DocBase,
    err: ref CatchableError] =
  try:
    let absolute = absolutePath(path)
    let existing = findDocument(absolute)
    if existing != nil:
      let win = existing.windowOf()
      if win != nil:
        win.show()
        win.focus()
      return (existing, nil)
    if dirExists(absolute):
      return (nil, newException(IOError, "mynim: " & absolute & " is a directory"))
    let opened = k.readDocument(absolute)
    if opened.err != nil:
      return opened
    opened.doc.stamp = stampOf(absolute)
    opened.doc.stampKnown = true
    opened.doc.readOnly = not fileWritable(absolute)
    opened.doc.path = absolute
    opened.doc.name = ""
    opened.doc.savedAt = opened.doc.changes
    opened.doc.showDocument()
    addRecent(absolute)
    return opened
  except CatchableError as err:
    (nil, err)

proc handles(k: DocKind; path: string): bool =
  let extension = path.extractFilename().splitFile().ext.strip(chars = {'.'}).toLowerAscii()
  for kind in k.types:
    for candidate in kind.extensions:
      if extension == candidate.toLowerAscii():
        return true

proc stampOf(path: string): DocumentFileStamp =
  let info = getFileInfo(path)
  DocumentFileStamp(modified: info.lastWriteTime, size: int64(info.size),
    id: info.id)

proc fileWritable(path: string): bool =
  let candidate = if fileExists(path): path else: path.parentDir()
  if candidate == "":
    return false
  try:
    let permissions = getFileInfo(candidate).permissions
    permissions * {fpUserWrite, fpGroupWrite, fpOthersWrite} != {}
  except CatchableError:
    false

proc openDocumentFile(path: string)

proc registerDocumentKind(k: DocKind) =
  documentsRegistry.mu.acquire()
  let first = documentsRegistry.kinds.len == 0
  documentsRegistry.kinds.add k
  documentsRegistry.mu.release()
  if not first:
    return
  discard app.onOpenFile(openDocumentFile)
  discard app.onQuit(proc() =
    documentsRegistry.mu.acquire()
    documentsRegistry.launched = false
    documentsRegistry.pending.setLen(0)
    documentsRegistry.mu.release())
  whenLaunched(proc() =
    documentsRegistry.mu.acquire()
    documentsRegistry.launched = true
    let pending = documentsRegistry.pending
    documentsRegistry.pending.setLen(0)
    documentsRegistry.mu.release()
    goAsync(proc() =
      for path in pending:
        openDocumentPath(path)
      let kind = defaultDocKind()
      if kind != nil and not kind.noUntitled and allDocuments().len == 0:
        discard kind.newUntitled()))

proc newDocuments*[T](opts: DocumentsOptions[T]): Documents[T] =
  ## Creates a typed document controller. Call it before `app.run`.
  if opts.types.len == 0 or opts.types[0].extensions.len == 0:
    raise newException(ValueError, "mynim: newDocuments needs a file type with an extension")
  if opts.read == nil or opts.write == nil or opts.window == nil:
    raise newException(ValueError, "mynim: newDocuments needs read, write, and window callbacks")
  for fileType in opts.types:
    for extension in fileType.extensions:
      if extension == "" or extension.contains({'/', '\\', '.'}):
        raise newException(ValueError, "mynim: invalid document extension " & extension)
  result = Documents[T]()
  result.opts = opts
  result.kind = DocKind(types: opts.types, noUntitled: opts.noUntitled)
  result.kind.mu.initLock()
  let ds = result
  result.kind.createUntitled = proc(name: string): DocBase =
    let content = if opts.new == nil: default(T) else: opts.new()
    makeDocument(ds, content, name)
  result.kind.readDocument = proc(path: string): tuple[doc: DocBase,
      err: ref CatchableError] =
    try:
      let stream = newStringStream(readFile(path))
      (makeDocument(ds, opts.read(stream), ""), nil)
    except CatchableError as err:
      (nil, err)
  registerDocumentKind(result.kind)

proc new*[T](ds: Documents[T]): Document[T] =
  ## Creates and shows an untitled document.
  needsApp("documents.new")
  cast[Document[T]](ds.kind.newUntitled())

proc open*[T](ds: Documents[T]; path: string): tuple[doc: Document[T],
    err: ref CatchableError] =
  ## Opens a file, focusing its existing window when already open.
  needsApp("documents.open")
  let opened = ds.kind.openInKind(path)
  (cast[Document[T]](opened.doc), opened.err)

proc openDialog*[T](ds: Documents[T]): tuple[documents: seq[Document[T]],
    err: ref CatchableError] =
  ## Asks for files accepted by this controller, then opens them.
  needsApp("documents.openDialog")
  let selected = chooseOpen(focusedWindow(), ds.kind.filters())
  if selected.err != nil:
    return (@[], selected.err)
  for path in selected.paths:
    let opened = ds.open(path)
    if opened.err != nil:
      result.err = opened.err
      return
    result.documents.add opened.doc

proc documents*[T](ds: Documents[T]): seq[Document[T]] =
  ## Returns open documents in creation order.
  for doc in ds.kind.docList():
    result.add cast[Document[T]](doc)

proc forWindow*[T](ds: Documents[T]; win: Window): Document[T] =
  ## Finds the document shown by a window, or nil.
  if win == nil:
    return nil
  for doc in ds.documents():
    if doc.window() == win:
      return doc

proc content*[T](doc: Document[T]): T =
  ## Returns the document content.
  doc.mu.acquire()
  result = doc.content
  doc.mu.release()

proc set*[T](doc: Document[T]; content: T) =
  ## Replaces the content and marks it edited unless it equals the saved value.
  doc.mu.acquire()
  doc.content = content
  inc doc.changes
  var edited = true
  if doc.ds.opts.equal != nil and doc.savedKnown:
    edited = not doc.ds.opts.equal(content, doc.saved)
  doc.mu.release()
  doc.changed(edited)

proc changed*[T](doc: Document[T]) =
  ## Marks mutable content as changed.
  doc.mu.acquire()
  inc doc.changes
  doc.mu.release()
  doc.changed(true)

proc setEdited*[T](doc: Document[T]; edited: bool) =
  ## Sets edit state for apps that maintain their own undo history.
  doc.mu.acquire()
  inc doc.changes
  if not edited:
    doc.saved = doc.content
    doc.savedKnown = true
    doc.savedAt = doc.changes
  doc.mu.release()
  doc.changed(edited)

proc onStateChange*[T](doc: Document[T]; fn: proc(state: DocumentState) {.closure.}):
    proc() {.closure.} =
  ## Calls `fn` on the UI thread when the document state changes.
  doc.onState.add(fn, false)

proc onReload*[T](doc: Document[T]; fn: proc() {.closure.}): proc() {.closure.} =
  ## Calls `fn` after `revert` replaces the content from disk.
  doc.onReload.add(fn, false)

proc writeAtomic(path, data: string): ref CatchableError =
  var file: File
  var temporary = ""
  var destination = path
  var permissions: set[FilePermission]
  var preservePermissions = false
  try:
    if fileExists(path):
      try:
        destination = expandSymlink(path)
      except OSError:
        discard
      try:
        permissions = getFilePermissions(destination)
        preservePermissions = true
      except OSError:
        discard
    (file, temporary) = createTempFile("." & destination.extractFilename() & ".",
      ".tmp", destination.parentDir())
    file.write(data)
    syncRecentFile(file)
    file.close()
    file = nil
    if preservePermissions:
      setFilePermissions(temporary, permissions)
    backend().replaceFile(destination, temporary)
    return nil
  except CatchableError as err:
    if file != nil:
      try: file.close()
      except CatchableError: discard
    if temporary != "" and fileExists(temporary):
      try: removeFile(temporary)
      except CatchableError: discard
    return err

proc chooseOpen(parent: Window; filters: seq[platform.FileFilter]):
    tuple[paths: seq[string], err: ref CatchableError] =
  var channel: system.Channel[tuple[paths: seq[string], err: ref CatchableError]]
  channel.open()
  let reply = addr channel
  discard postMain(proc() =
    let dialogs = backend().dialogs()
    if dialogs == nil:
      let failure: ref CatchableError = newException(IOError,
        "mynim: document dialogs are unavailable")
      deliver(reply[], (@[], failure))
    else:
      dialogs.showOpenDialog(if parent == nil: nil else: parent.native,
        platform.OpenDialogOptions(filters: filters, openFiles: true,
          multiple: true),
        proc(paths: seq[string]; err: ref CatchableError) =
          deliver(reply[], (paths, err)))
  )
  result = await(channel)
  channel.close()

proc chooseSave(parent: Window; path: string;
    filters: seq[platform.FileFilter]): tuple[path: string,
        err: ref CatchableError] =
  var channel: system.Channel[tuple[path: string, err: ref CatchableError]]
  channel.open()
  let reply = addr channel
  discard postMain(proc() =
    let dialogs = backend().dialogs()
    if dialogs == nil:
      let failure: ref CatchableError = newException(IOError,
        "mynim: document dialogs are unavailable")
      deliver(reply[], ("", failure))
    else:
      dialogs.showSaveDialog(if parent == nil: nil else: parent.native,
        platform.SaveDialogOptions(defaultPath: path, filters: filters),
        proc(path: string; err: ref CatchableError) =
          deliver(reply[], (path, err)))
  )
  result = await(channel)
  channel.close()

proc filters(k: DocKind): seq[platform.FileFilter] =
  for fileType in k.types:
    result.add platform.FileFilter(name: fileType.name,
      extensions: fileType.extensions)

proc saveToPath[T](doc: Document[T]; path: string;
    checkConflict: bool): ref CatchableError =
  var target = path
  if target == "":
    let picked = chooseSave(doc.window(), doc.path(), doc.ds.kind.filters())
    if picked.err != nil:
      return picked.err
    if picked.path == "":
      return ErrCanceled
    target = picked.path
  try:
    target = absolutePath(target)
    if checkConflict:
      doc.mu.acquire()
      let known = doc.stampKnown
      let previous = doc.stamp
      let deleted = doc.deleted
      doc.mu.release()
      if known and fileExists(target) and
          (stampOf(target) != previous or deleted):
        doc.mu.acquire()
        doc.conflict = true
        doc.deleted = false
        doc.mu.release()
        doc.notifyDocument()
        return ErrDocumentChanged
    var content: T
    var at: uint64
    let capture = proc(): tuple[content: T, at: uint64] =
      doc.mu.acquire()
      result.content = doc.content
      result.at = doc.changes
      doc.mu.release()
      if doc.ds.opts.snapshot != nil:
        result.content = doc.ds.opts.snapshot(result.content)
    let saved = if doc.ds.opts.snapshot != nil: onMainValue(capture) else: capture()
    content = saved.content
    at = saved.at
    let stream = newStringStream()
    doc.ds.opts.write(stream, content)
    stream.setPosition(0)
    let err = writeAtomic(target, stream.readAll())
    if err != nil:
      return err
    doc.mu.acquire()
    doc.path = target
    doc.readOnly = false
    doc.conflict = false
    doc.deleted = false
    doc.saved = content
    doc.savedKnown = true
    doc.savedAt = at
    doc.stamp = stampOf(target)
    doc.stampKnown = true
    doc.edited = doc.changes != at
    if doc.ds.opts.equal != nil and doc.edited:
      doc.edited = not doc.ds.opts.equal(doc.content, content)
    doc.mu.release()
    doc.notifyDocument()
    addRecent(target)
    nil
  except CatchableError as err:
    err

proc save*[T](doc: Document[T]): ref CatchableError =
  ## Saves to the current file, or asks where to save an untitled document.
  if doc.path() == "" or doc.isReadOnly():
    return doc.saveToPath("", false)
  doc.saveToPath(doc.path(), true)

proc saveAs*[T](doc: Document[T]; path = ""): ref CatchableError =
  ## Saves under `path`, or asks for a path when it is empty.
  doc.saveToPath(path, false)

proc saveAnyway*[T](doc: Document[T]): ref CatchableError =
  ## Saves to the current file even if its contents changed outside the app.
  if doc.path() == "":
    return doc.saveToPath("", false)
  doc.saveToPath(doc.path(), false)

proc revert*[T](doc: Document[T]): ref CatchableError =
  ## Re-reads the file and drops unsaved content.
  let path = doc.path()
  if path == "":
    return newException(IOError, "mynim: an untitled document has no file to revert")
  let loaded = doc.ds.kind.readDocument(path)
  if loaded.err != nil:
    return loaded.err
  let typed = cast[Document[T]](loaded.doc)
  let stamp = stampOf(path)
  let readOnly = not fileWritable(path)
  doc.mu.acquire()
  doc.content = typed.content
  doc.saved = typed.content
  doc.savedKnown = true
  inc doc.changes
  doc.savedAt = doc.changes
  doc.edited = false
  doc.conflict = false
  doc.deleted = false
  doc.stamp = stamp
  doc.stampKnown = true
  doc.readOnly = readOnly
  doc.mu.release()
  doc.notifyDocument()
  fire(doc.onReload)
  nil

proc close*[T](doc: Document[T]) =
  ## Closes the document's window, asking before discarding edited content.
  closeDocument(doc)

proc duplicate*[T](doc: Document[T]): Document[T] =
  ## Creates a new untitled document with the current content.
  needsApp("document.duplicate")
  var content = doc.content()
  if doc.ds.opts.snapshot != nil:
    let value = content
    content = onMainValue(proc(): T = doc.ds.opts.snapshot(value))
  let copy = makeDocument(doc.ds, content, "Untitled " & $doc.ds.kind.nextUntitled())
  copy.kind = doc.ds.kind
  copy.showDocument()

proc openDocumentPath(path: string) =
  var kind = defaultDocKind()
  for candidate in docKinds():
    if candidate.handles(path):
      kind = candidate
      break
  if kind == nil:
    fire1(app.onOpenFile, path)
    return
  let opened = kind.openInKind(path)
  if opened.err != nil:
    stderr.writeLine("mynim: could not open " & path & ": " & opened.err.msg)

proc openDocumentFile(path: string) =
  documentsRegistry.mu.acquire()
  if not documentsRegistry.launched:
    documentsRegistry.pending.add path
    documentsRegistry.mu.release()
    return
  documentsRegistry.mu.release()
  goAsync(proc() = openDocumentPath(path))

proc openDocumentsDialog() =
  var filters: seq[platform.FileFilter]
  for kind in docKinds():
    filters.add kind.filters()
  let selected = chooseOpen(focusedWindow(), filters)
  if selected.err != nil:
    return
  for path in selected.paths:
    openDocumentPath(path)

proc documentFor(win: Window): DocBase =
  if win == nil:
    return nil
  for doc in allDocuments():
    if doc.windowOf() == win:
      return doc

proc documentRole(role: MenuRole; win: Window) =
  let kind = defaultDocKind()
  if kind == nil:
    return
  if role == roleNew:
    goAsync(proc() = discard kind.newUntitled())
    return
  if role == roleOpen:
    goAsync(openDocumentsDialog)
    return
  var doc = documentFor(win)
  if doc == nil:
    doc = documentFor(focusedWindow())
  if doc == nil:
    return
  case role
  of roleSave:
    goAsync(proc() =
      let err = doc.saveDocument()
      if err != nil: stderr.writeLine("mynim: document save: " & err.msg))
  of roleSaveAs:
    goAsync(proc() =
      let err = doc.saveAsDocument()
      if err != nil: stderr.writeLine("mynim: document save: " & err.msg))
  of roleDuplicate:
    goAsync(proc() = discard doc.duplicateDocument())
  of roleRevert:
    goAsync(proc() =
      let err = doc.revertDocument()
      if err != nil: stderr.writeLine("mynim: document revert: " & err.msg))
  else:
    discard

proc walkDocumentItems(items: seq[MenuItem]; fn: proc(item: MenuItem) {.closure.}) =
  for item in items:
    fn(item)
    walkDocumentItems(item.submenu, fn)

proc refreshDocumentMenus() =
  if not app.isReady():
    return
  let doc = documentFor(focusedWindow())
  let enabled = doc != nil
  var menus = @[app.menu()]
  for win in allWindows():
    menus.add win.menu
  for menu in menus:
    if menu == nil:
      continue
    walkDocumentItems(menu.items(), proc(item: MenuItem) =
      case item.role
      of roleSave, roleSaveAs, roleDuplicate:
        item.setEnabled(enabled)
      of roleRevert:
        item.setEnabled(enabled and doc.editedOf() and doc.pathOf() != "")
      else:
        discard)
