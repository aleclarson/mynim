## clipboard.nim: the clipboard's data path. GTK serves clipboard
## contents through callbacks of a selection owner, so writeData keeps a
## source registered by a unique pointer until another app takes the
## selection or the source releases.

var
  gtkSelectionDataSet*: proc(sel, atom: pointer, format: int32,
                           data: pointer, length: int32) {.cdecl.}
  gtkSelectionDataTarget*: proc(sel: pointer): pointer {.cdecl.}
  gtkClipboardSetWithData*:
    proc(cb, targets: pointer, n: uint32, get, clear, data: pointer): bool {.cdecl.}
  gtkClipboardSetCanStore*: proc(cb, targets: pointer, n: int32) {.cdecl.}
  gtkClipboardStore*: proc(cb: pointer) {.cdecl.}
  gdkClipboardPersistence*: proc(d: pointer): bool {.cdecl.}
  cbClipboardGet*, cbClipboardClear*, cbClipboardOwner*: pointer
  clipboardConnected*: bool

proc gtkFormat*(t: string): Format ## surface_drop.nim
proc gtkTargets*(formats: seq[Format]): seq[gtkTargetEntry] ## surface_drop.nim

var
  gtkClipboardCurrent*: gtkClipboardSource
  clipboardID*: pointer
  clipboardGeneration*: uint64

proc clip*(): pointer =
  result = gtkClipboardGet(gdkAtomIntern(cs("CLIPBOARD"), false))
  if not clipboardConnected:
    discard connect(result, "owner-change", cbClipboardOwner, nil)
    clipboardConnected = true

proc releaseSource*(s: gtkClipboardSource) =
  let fn = s.released
  if not fn.isNil:
    s.released = nil
    fn()

proc cbClipboardGetFn(board, sel: pointer, info: uint32,
    data: pointer) {.cdecl.} =
  let s = gtkClipboardSources.getOrDefault(data)
  if s.isNil: return
  let atom = gtkSelectionDataTarget(sel)
  let f = gtkFormat(takeStr(gdkAtomName(atom)))
  var (b, err) = s.data.read(f)
  if isErrFormat(err) and f == URIList:
    (b, err) = s.data.read(FileList)
  if not err.isNil: return
  if b.len == 0:
    b = @[0'u8]
    gtkSelectionDataSet(sel, atom, 8, addr b[0], 0)
  else:
    gtkSelectionDataSet(sel, atom, 8, unsafeAddr b[0], int32(b.len))

proc cbClipboardClearFn(board, data: pointer) {.cdecl.} =
  let s = gtkClipboardSources.getOrDefault(data)
  if s.isNil: return
  gtkClipboardSources.del(data)
  if gtkClipboardCurrent == s:
    gtkClipboardCurrent = nil
  s.data = Data()
  s.releaseSource()

proc cbClipboardOwnerFn(board, event, data: pointer) {.cdecl.} =
  inc clipboardGeneration

proc initClipboardCallbacks*() =
  # Clipboard-only apps may never create a surface or initialize its
  # drag adapter. Bind the shared selection primitives independently of
  # it.
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataSet),
    "gtk_selection_data_set")
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataTarget),
    "gtk_selection_data_get_target")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardSetWithData),
    "gtk_clipboard_set_with_data")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardSetCanStore),
    "gtk_clipboard_set_can_store")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardStore),
    "gtk_clipboard_store")
  mustBind(libGDK, cast[ptr pointer](addr gdkClipboardPersistence),
    "gdk_display_supports_clipboard_persistence")
  cbClipboardGet = cast[pointer](cbClipboardGetFn)
  cbClipboardClear = cast[pointer](cbClipboardClearFn)
  cbClipboardOwner = cast[pointer](cbClipboardOwnerFn)

method writeData*(c: clipboardImpl, data: Data, released: proc()) =
  if data.formats.len == 0:
    c.clear()
    if not released.isNil:
      released()
    return
  clipboardID = cast[pointer](cast[uint](clipboardID) + 1)
  let s = gtkClipboardSource(id: clipboardID, data: data, released: released)
  gtkClipboardSources[s.id] = s
  var targets = gtkTargets(data.formats)
  if not gtkClipboardSetWithData(clip(), unsafeAddr targets[0],
      uint32(targets.len), cbClipboardGet, cbClipboardClear, s.id):
    gtkClipboardSources.del(s.id)
    raise newException(CatchableError,
      "mynim: cannot own the clipboard selection")
  gtkClipboardCurrent = s
  gtkClipboardSetCanStore(clip(), nil, 0)

proc clipboardTargets*(): tuple[formats: seq[Format],
                                targets: Table[Format, pointer]] =
  var atoms: pointer
  var n: int32
  var targets = initTable[Format, pointer]()
  if not gtkClipboardWaitForTargets(clip(), addr atoms, addr n) or
      atoms.isNil:
    return (@[], targets)
  defer: gFree(atoms)
  if n < 0 or n > 4096:
    return (@[], targets)
  var res: seq[Format]
  for i in 0 ..< int(n):
    let atom = field[pointer](atoms, uint(i) * sizeof(pointer).uint)
    let name = takeStr(gdkAtomName(atom))
    if name == "" or name.contains({'\x00', '\r', '\n'}):
      continue
    case name
    of "TARGETS", "MULTIPLE", "TIMESTAMP", "SAVE_TARGETS":
      continue
    else: discard
    let f = gtkFormat(name)
    if f == DragSessionFormat:
      continue
    if f notin res:
      res.add f
    # Prefer canonical MIME targets over aliases where both are offered.
    if targets.getOrDefault(f).isNil or name == $f:
      targets[f] = atom
    if f == URIList and targets.getOrDefault(FileList).isNil:
      targets[FileList] = atom
      if FileList notin res:
        res.add FileList
    if name.startsWith("image/") and PNG notin res:
      res.add PNG
  (res, targets)

method formats*(c: clipboardImpl): seq[Format] =
  let (formats, _) = clipboardTargets()
  let s = gtkClipboardCurrent
  if not s.isNil:
    return s.data.formats
  formats

method readData*(c: clipboardImpl, formats: seq[Format]):
    tuple[d: Data, err: ref CatchableError] =
  let generation = clipboardGeneration
  let (offered, targets) = clipboardTargets()
  if generation != clipboardGeneration:
    return (Data(), errClipboardChanged())
  var fmts = formats
  let s = gtkClipboardCurrent
  if not s.isNil:
    if fmts.len == 0:
      fmts = s.data.formats
    let (d, err) = s.data.materialize(fmts)
    if generation != clipboardGeneration or gtkClipboardCurrent != s:
      return (Data(), errClipboardChanged())
    return (d, err)
  if fmts.len == 0:
    fmts = offered
    if fmts.len == 0:
      return (Data(), nil)
  var reps: seq[Representation]
  for n, f in fmts:
    if f in fmts[0 ..< n] or f notin offered:
      continue
    var b: seq[byte]
    if f == PNG and targets.getOrDefault(f).isNil:
      b = c.readImage()
      if b.len == 0:
        return (Data(), newException(CatchableError,
          "mynim: cannot convert clipboard image"))
    else:
      let sd = gtkClipboardWaitForContents(clip(), targets[f])
      if sd.isNil:
        return (Data(), errFormat())
      let length = gtkSelectionDataGetLength(sd)
      let p = gtkSelectionDataGetData(sd)
      if length < 0 or length > 64 shl 20 or (length != 0 and p.isNil):
        gtkSelectionDataFree(sd)
        return (Data(), newException(CatchableError,
          "mynim: invalid or oversized clipboard representation"))
      let bytes = cast[ptr UncheckedArray[byte]](cast[ptr pointer](addr p)[])
      b = @(toOpenArray(bytes, 0, int(length) - 1))
      gtkSelectionDataFree(sd)
    if generation != clipboardGeneration:
      return (Data(), errClipboardChanged())
    reps.add bytes(f, b)
  if reps.len == 0:
    return (Data(), errFormat())
  (transfer.newData(newItem(reps)), nil)

method flush*(c: clipboardImpl) =
  let s = gtkClipboardCurrent
  if s.isNil: return
  let generation = clipboardGeneration
  let (d, err) = s.data.materialize(s.data.formats)
  if not err.isNil:
    raise err
  if gtkClipboardCurrent != s or generation != clipboardGeneration:
    raise errClipboardChanged()
  # GTK still serves eager bytes if no clipboard manager is available;
  # provider closures and their resources can be released in either case.
  s.data = d
  s.releaseSource()
  if not gdkClipboardPersistence(gdkDisplayGetDefault()):
    raise errClipboardPersistence()
  gtkClipboardStore(clip())

method close*(c: clipboardImpl) =
  if not gtkClipboardCurrent.isNil:
    c.clear()
