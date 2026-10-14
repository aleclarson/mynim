## clipboard.go — clipboard writes with lazy providers and their
## release hooks.

## errClipboardReentrant means a provider tried to access the
## clipboard.
proc errClipboardReentrant(): ref CatchableError =
  newException(ValueError,
    "mynim: clipboard access from a clipboard provider")

## errClipboardChanged means ownership changed while a read was in
## progress.
proc errClipboardChanged*(): ref PlatformError =
  platform.errClipboardChanged()

## errClipboardPersistence means the desktop cannot store clipboard
## data after the owning application exits.
proc errClipboardPersistence*(): ref PlatformError =
  platform.errClipboardPersistence()

proc clipboardProvider(it: Item; fm: Format):
    proc(): tuple[data: seq[byte], err: ref CatchableError] {.closure.} =
  ## The lazy representation guarding reentry: a provider must not read
  ## or replace the clipboard while the system requests it.
  proc(): tuple[data: seq[byte], err: ref CatchableError] {.closure.} =
    clipboardProviding = true
    try:
      result = it.read(fm)
    finally:
      clipboardProviding = false

# Clipboard state is main-thread only. User release hooks are deferred
# until native callbacks unwind, including callbacks made during write
# itself.
type ClipboardLifetime = ref object
  armed, released, notified: bool
  onRelease: proc() {.closure.}

proc queueClipboardRelease(fn: proc() {.closure.}) =
  if not postMain(fn):
    # Native shutdown can end a nested operation before it unwinds.
    # The loop can no longer deliver hooks, but their resources still
    # need cleanup. Clipboard methods already reject stopped-loop work.
    fn()

proc release(l: ClipboardLifetime) =
  l.released = true
  if l.armed and not l.notified:
    l.notified = true
    let fn = l.onRelease
    if fn != nil:
      l.onRelease = nil
      if clipboardOperations != 0:
        clipboardReleases.add fn
      else:
        queueClipboardRelease(fn)

# Native reads/storage may pump nested event loops (notably GTK store).
# Release hooks wait for the complete outer clipboard operation, so a
# hook replacing the clipboard cannot interfere with an unfinished
# native flush.
proc withClipboardOperation(fn: proc() {.closure.}) =
  inc clipboardOperations
  try:
    fn()
  finally:
    dec clipboardOperations
    if clipboardOperations == 0:
      let pending = clipboardReleases
      clipboardReleases.setLen(0)
      for release in pending:
        queueClipboardRelease(release)

proc clipboardNativeValue[T](fn: proc(): T {.closure.}): T =
  onMainValue(proc(): T =
    if not clipboardProviding and not clipboardStopped:
      withClipboardOperation(proc() = result = fn()))

template clipboardOnMain(errVar, body: untyped) =
  ## Runs body on the main thread inside a clipboard operation;
  ## errVar holds a raised error or nil.
  errVar = errLoopStopped
  onMain(proc() =
    if clipboardStopped: return
    withClipboardOperation(proc() =
      try:
        body
        errVar = nil
      except CatchableError as e:
        errVar = e))

proc write*(c: ClipboardModule; data: Data; options: openArray[ClipboardOptions]): ref CatchableError =
  ## Replaces the clipboard with items offering alternative serialized
  ## representations. It takes a fresh provider snapshot without
  ## invoking any providers. Providers run on the main thread at most
  ## once per write; errors and panics are cached. Native receivers can
  ## request them until ownership ends, even after the source window
  ## closes. Keep captured resources alive until onRelease; prepare
  ## expensive data beforehand on a thread.
  ##
  ## Empty data clears the clipboard. At most one options value is
  ## allowed. It is safe from any thread. Nim values from Drag(value)
  ## are never copied to the clipboard; offer an explicit encoding with
  ## transfer.bytes or lazy.
  needsApp("clipboard.write")
  if options.len > 1:
    raiseAssert("mynim: clipboard.write accepts at most one options value")
  if dragSessionFormat in data.formats():
    return newException(ValueError,
      "mynim: clipboard cannot contain a process-local drag session")
  var opts: ClipboardOptions
  if options.len == 1:
    opts = options[0]
  var err: ref CatchableError
  clipboardOnMain(err):
    if clipboardProviding:
      raise errClipboardReentrant()
    let l = ClipboardLifetime(onRelease: opts.onRelease)
    # Guard native provider reentry without changing the shared data
    # model. read below also materializes this snapshot on the main
    # thread.
    var items: seq[Item]
    for item in data.snapshot().items():
      if item.formats().len == 0:
        continue
      var reps: seq[Representation]
      for f in item.formats():
        let it = item
        let fm = f
        reps.add lazy(fm, clipboardProvider(it, fm))
      items.add newItem(reps)
    var werr: ref CatchableError
    try:
      backend().clipboard().writeData(newData(items),
        proc() = l.release())
    except CatchableError as e:
      werr = e
    if werr != nil:
      l.onRelease = nil
      raise werr
    l.armed = true
    if l.released:
      l.release()
  err

proc write*(c: ClipboardModule; data: Data) =
  discard c.write(data, [])

proc read*(c: ClipboardModule; formats: varargs[Format]):
    tuple[data: Data, err: ref CatchableError] =
  ## Copies the requested representations from the current clipboard.
  ## With no formats it reads all advertised representations; an empty
  ## clipboard returns empty data. Explicit formats select alternatives
  ## without invoking other providers; no matching representation is
  ## transfer's errFormat. The returned data has no native providers
  ## and is safe to keep, read from any thread, or offer in a later
  ## drag. Ownership changes during a native read return an error,
  ## rather than mixing contents from different owners.
  needsApp("clipboard.read")
  var data = Data()
  var err: ref CatchableError
  clipboardOnMain(err):
    if clipboardProviding:
      raise errClipboardReentrant()
    let fmts = @formats
    try:
      let (d, e) = backend().clipboard().readData(fmts)
      data = d
      if e != nil: raise e
    except CatchableError as e2:
      raise e2
  (data, err)

proc formats*(c: ClipboardModule): seq[Format] =
  ## Discovers portable format names without requesting provider data.
  ## Use transfer.preferredFormat to negotiate in receiver preference
  ## order.
  needsApp("clipboard.formats")
  clipboardNativeValue(proc(): seq[Format] =
    backend().clipboard().formats())

proc readFormat*(c: ClipboardModule; format: Format):
    tuple[data: seq[byte], err: ref CatchableError] =
  ## Copies one representation, coalescing text/file items as
  ## data.read does.
  needsApp("clipboard.readFormat")
  let (d, err) = c.read(format)
  if err != nil:
    return (@[], err)
  d.read(format)

proc readFiles*(c: ClipboardModule): tuple[paths: seq[string], err: ref CatchableError] =
  ## Local paths from the clipboard's file/URI list. Remote URLs are
  ## ignored. No file is opened, created, moved or deleted.
  needsApp("clipboard.readFiles")
  let (d, err) = c.read(transfer.FileList, transfer.URIList)
  if err != nil:
    return (@[], err)
  d.files()

proc writeFiles*(c: ClipboardModule; paths: varargs[string]): ref CatchableError =
  ## Copies absolute paths to the clipboard as native file URLs/lists.
  needsApp("clipboard.writeFiles")
  let (d, err) = transfer.fileData(paths)
  if err != nil:
    return err
  c.write(d, [])

proc flush*(c: ClipboardModule): ref CatchableError =
  ## Requests all representations of MyNim's current clipboard and
  ## hands them to native storage, releasing lazy-provider resources on
  ## success. Provider errors leave ownership intact. It does nothing
  ## to another app's clipboard. app quitting calls it automatically,
  ## on a best-effort basis. Linux persistence requires a clipboard
  ## manager; without one flush returns errClipboardPersistence after
  ## materializing providers.
  needsApp("clipboard.flush")
  var err: ref CatchableError
  clipboardOnMain(err):
    if clipboardProviding:
      raise errClipboardReentrant()
    try:
      backend().clipboard().flush()
    except CatchableError as e:
      raise e
  err
