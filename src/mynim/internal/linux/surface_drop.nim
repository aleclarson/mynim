## surface_drop.nim: drag and drop of data on surfaces. Selection data
## arrives asynchronously. Only accepted formats are read after drop,
## before acknowledging the negotiated effect.

var
  gtkDragDestSet: proc(w: pointer, flags: int32, targets: pointer,
    nTargets, actions: int32) {.cdecl.}
  gtkDragGetData: proc(w, context, target: pointer,
    time: uint32) {.cdecl.}
  gtkDragFinish: proc(context: pointer, ok, del: bool,
    time: uint32) {.cdecl.}
  gdkDragStatus: proc(context: pointer, action: int32,
    time: uint32) {.cdecl.}
  gtkTargetListNew: proc(targets: pointer, n: uint32): pointer {.cdecl.}
  gtkTargetListUnref: proc(l: pointer) {.cdecl.}
  gtkDragBeginCoordinates: proc(w, list: pointer, actions: int32,
    button: int32, event: pointer, x, y: int32): pointer {.cdecl.}
  gtkDragCancel: proc(context: pointer) {.cdecl.}
  gtkDragSetIconPixbuf: proc(context, pixbuf: pointer, hotX,
    hotY: int32) {.cdecl.}
  gtkDragGetSourceWidget: proc(context: pointer): pointer {.cdecl.}
  gdkDragContextTargets: proc(context: pointer): pointer {.cdecl.}
  gdkDragContextActions: proc(context: pointer): int32 {.cdecl.}
  gdkDragContextSuggested: proc(context: pointer): int32 {.cdecl.}
  gdkDragContextSelected: proc(context: pointer): int32 {.cdecl.}
  cbSurfaceDragMotion, cbSurfaceDragLeave, cbSurfaceDragDrop,
    cbSurfaceDragData: pointer
  cbSurfaceDragGet, cbSurfaceDragEnd, cbSurfaceDragFailed,
    cbSurfaceDragDelete: pointer
  gtkDataSources: Table[pointer, gtkSurface]

const
  gdkActionCopy = 1'i32 shl 1
  gdkActionMove = 1'i32 shl 2

proc gtkOperations(o: Operation): int32 =
  var n: int32
  if (o and Copy) != 0:
    n = n or gdkActionCopy
  if (o and Move) != 0:
    n = n or gdkActionMove
  n

proc goGTKOperations(n: int32): Operation =
  var o: Operation
  if (n and gdkActionCopy) != 0:
    o = o or Copy
  if (n and gdkActionMove) != 0:
    o = o or Move
  o

proc gtkFormat(t: string): Format =
  if t == "UTF8_STRING" or t == "text/plain;charset=utf-8":
    return Text
  Format(t)

proc gtkOffer(context: pointer):
    tuple[d: DataDragEvent, targets: Table[Format, pointer]] =
  let d = DataDragEvent(offer: Offer(
    operations: goGTKOperations(gdkDragContextActions(context)),
    suggested: goGTKOperations(gdkDragContextSuggested(context))))
  var targets = initTable[Format, pointer]()
  var l = gdkDragContextTargets(context)
  while not l.isNil:
    let atom = field[pointer](l, 0)
    let f = gtkFormat(takeStr(gdkAtomName(atom)))
    if f != platform.DragSessionFormat:
      if f notin d.offer.formats:
        d.offer.formats.add f
      targets[f] = atom
      if f == URIList:
        d.hasFiles = true
          # Existing GTK file drops also advertise URI lists.
        if FileList notin d.offer.formats:
          d.offer.formats.add FileList
        targets[FileList] = atom
    l = field[pointer](l, 8)
  let src = gtkDataSources.getOrDefault(gtkDragGetSourceWidget(context))
  if src != nil and src.dragRequest != nil:
    d.session = src.dragRequest.session
  (d, targets)

proc cstr(s: string): cstring =
  ## cstr is cs on heap memory the entry keeps: the targets of a drag
  ## live past gtkTargets, as Go's cs' copies do.
  let p = cast[ptr UncheckedArray[byte]](alloc0(s.len + 1))
  copyMem(p, unsafeAddr s[0], s.len)
  cast[cstring](p)

proc gtkTargets(formats: seq[Format]): seq[gtkTargetEntry] =
  var names: seq[string]
  for f in formats:
    var name = string(f)
    if f == FileList:
      name = string(URIList)
    if name notin names:
      names.add name
    if f == Text:
      names.add "UTF8_STRING"
      names.add "text/plain;charset=utf-8"
  result = newSeq[gtkTargetEntry](names.len)
  for n, name in names:
    result[n] = gtkTargetEntry(target: cstr(name), info: uint32(n))

proc loadDrops*() =
  mustBind(libGTK, cast[ptr pointer](addr gtkDragDestSet),
    "gtk_drag_dest_set")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragGetData),
    "gtk_drag_get_data")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragFinish),
    "gtk_drag_finish")
  mustBind(libGDK, cast[ptr pointer](addr gdkDragStatus),
    "gdk_drag_status")
  mustBind(libGTK, cast[ptr pointer](addr gtkTargetListNew),
    "gtk_target_list_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkTargetListUnref),
    "gtk_target_list_unref")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragBeginCoordinates),
    "gtk_drag_begin_with_coordinates")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragCancel),
    "gtk_drag_cancel")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragSetIconPixbuf),
    "gtk_drag_set_icon_pixbuf")
  mustBind(libGTK, cast[ptr pointer](addr gtkDragGetSourceWidget),
    "gtk_drag_get_source_widget")
  mustBind(libGDK, cast[ptr pointer](addr gdkDragContextTargets),
    "gdk_drag_context_list_targets")
  mustBind(libGDK, cast[ptr pointer](addr gdkDragContextActions),
    "gdk_drag_context_get_actions")
  mustBind(libGDK, cast[ptr pointer](addr gdkDragContextSuggested),
    "gdk_drag_context_get_suggested_action")
  mustBind(libGDK, cast[ptr pointer](addr gdkDragContextSelected),
    "gdk_drag_context_get_selected_action")
  cbSurfaceDragMotion = cast[pointer](
    proc(widget, context: pointer, x, y: int32, time: uint32,
        data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      let (d, _) = gtkOffer(context)
      let taken = s.send(SurfaceEvent(kind: dataDragOver,
        x: float64(x), y: float64(y), drag: d))
      gdkDragStatus(context, gtkOperations(d.operation), time)
      taken)
  cbSurfaceDragLeave = cast[pointer](
    proc(widget, context: pointer, time: uint32,
        data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if not s.isNil:
        discard s.send(SurfaceEvent(kind: dataDragLeave,
          drag: DataDragEvent())))
  cbSurfaceDragDrop = cast[pointer](
    proc(widget, context: pointer, x, y: int32, time: uint32,
        data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil:
        return false
      let (d, targets) = gtkOffer(context)
      if not s.send(SurfaceEvent(kind: dataDragOver, x: float64(x),
          y: float64(y), drag: d)):
        return false
      if d.data.formats().len > 0:
        # A recognized local source preserves item boundaries and typed
        # values.
        let taken = s.send(SurfaceEvent(kind: dataDrop,
          x: float64(x), y: float64(y), drag: d))
        gtkDragFinish(context, taken,
          taken and d.operation == Move, time)
        return true
      s.cancelPendingDrop()
      var drop = gtkDataDrop(context: gObjectRef(context), event: d,
        x: float64(x), y: float64(y), time: time,
        pending: initTable[pointer, seq[Format]]())
      for f in d.formats:
        let atom = targets.getOrDefault(f)
        if not atom.isNil:
          drop.pending.mgetOrPut(atom, @[]).add f
      if drop.pending.len == 0:
        gtkDragFinish(context, false, false, time)
        gObjectUnref(drop.context)
        return true
      s.dataDrop = drop
      for atom in drop.pending.keys:
        gtkDragGetData(widget, context, atom, time)
      true)
  cbSurfaceDragData = cast[pointer](
    proc(widget, context: pointer, x, y: int32, sel: pointer,
        info, time: uint32, data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil or s.dataDrop.isNil or
          s.dataDrop.context != context:
        return
      let drop = s.dataDrop
      let atom = gtkSelectionDataTarget(sel)
      if not drop.pending.hasKey(atom):
        return
      let formats = drop.pending[atom]
      drop.pending.del(atom)
      let n = gtkSelectionDataGetLength(sel)
      let p = gtkSelectionDataGetData(sel)
      if n < 0 or n > 64 shl 20 or (n > 0 and p.isNil):
        drop.failed = true
      else:
        var buf: seq[byte]
        if n > 0:
          let pb = cast[ptr UncheckedArray[byte]](p)
          buf = newSeq[byte](n)
          copyMem(addr buf[0], pb, n)
        for f in formats:
          if f == FileList:
            let (files, _) = newData(newItem(bytes(URIList,
              buf))).files()
            if files.len == 0:
              continue
          drop.reps.add bytes(f, buf)
      if drop.pending.len != 0:
        return
      s.dataDrop = nil
      var taken = false
      if not drop.failed:
        drop.event.data = newData(newItem(drop.reps))
        taken = s.send(SurfaceEvent(kind: dataDrop, x: drop.x,
          y: drop.y, drag: drop.event))
      gtkDragFinish(context, taken,
        taken and drop.event.operation == Move, drop.time)
      gObjectUnref(drop.context))
  cbSurfaceDragGet = cast[pointer](
    proc(widget, context, sel: pointer, info, time: uint32,
        data: pointer) {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil or s.dragRequest.isNil:
        return
      let r = s.dragRequest
      let atom = gtkSelectionDataTarget(sel)
      let f = gtkFormat(takeStr(gdkAtomName(atom)))
      var buf: seq[byte]
      var err: ref CatchableError
      if f == platform.DragSessionFormat:
        buf = cast[seq[byte]](r.session)
      else:
        (buf, err) = r.data.read(f)
      if not err.isNil:
        s.dragError = err
        return
      if buf.len == 0:
        buf = @[0'u8]
        gtkSelectionDataSet(sel, atom, 8, addr buf[0], 0)
      else:
        gtkSelectionDataSet(sel, atom, 8, addr buf[0], int32(buf.len)))
  cbSurfaceDragFailed = cast[pointer](
    proc(widget, context: pointer, res: int32,
        data: pointer): bool {.cdecl.} =
      var s = theBackend.surfaceOf(data)
      if s.isNil:
        s = gtkDataSources.getOrDefault(widget)
      if s != nil and s.dragRequest != nil:
        # GTK_NO_TARGET=1 and USER_CANCELLED=2 are normal no-drop
        # results. gtk_drag_cancel can also abort with a generic
        # error; our explicit cancellation must remain a
        # cancellation.
        let explicit = s.dragCanceled
        let canceled = explicit or res == 1 or res == 2
        s.dragCanceled = true
        if not canceled and res > 2:
          s.dragError = newException(CatchableError,
            "mynim: GTK drag failed")
        # An explicit cancel (including destruction) must release the
        # tracker immediately, without a snap-back animation holding
        # the input grab after the app reports cancellation.
        return explicit
      false)
  cbSurfaceDragEnd = cast[pointer](
    proc(widget, context, data: pointer) {.cdecl.} =
      var s = theBackend.surfaceOf(data)
      if s.isNil:
        s = gtkDataSources.getOrDefault(widget)
      if s.isNil or s.dragRequest.isNil:
        return
      let r = s.dragRequest
      var op = goGTKOperations(gdkDragContextSelected(context))
      if s.dragCanceled or not s.dragError.isNil:
        op = None
      gtkDataSources.del(widget)
      s.dragRequest = nil
      s.dragContext = nil
      if not s.lastPointer.isNil:
        gdkEventFree(s.lastPointer)
        s.lastPointer = nil
      r.done(Result(operation: op,
        canceled: op == None and s.dragError.isNil,
        err: s.dragError)))
  # The app's done callback owns removal after a successful move.
  cbSurfaceDragDelete = cast[pointer](
    proc(widget, context, data: pointer) {.cdecl.} = discard)

method setDropFormats*(s: gtkSurface, formats: seq[Format]) =
  let targets = gtkTargets(formats)
  if targets.len != 0:
    gtkDragDestSet(s.area, 0, addr targets[0], int32(targets.len),
      gdkActionCopy or gdkActionMove)

proc acceptFileDrops*(s: gtkSurface, data: pointer) =
  s.setDropFormats(@[URIList])
  discard connect(s.area, "drag-motion", cbSurfaceDragMotion, data)
  discard connect(s.area, "drag-leave", cbSurfaceDragLeave, data)
  discard connect(s.area, "drag-drop", cbSurfaceDragDrop, data)
  discard connect(s.area, "drag-data-received", cbSurfaceDragData,
    data)
  discard connect(s.area, "drag-data-get", cbSurfaceDragGet, data)
  discard connect(s.area, "drag-end", cbSurfaceDragEnd, data)
  discard connect(s.area, "drag-failed", cbSurfaceDragFailed, data)
  discard connect(s.area, "drag-data-delete", cbSurfaceDragDelete,
    data)

method startDataDrag*(s: gtkSurface, r: DragRequest) =
  if s.dragRequest != nil or s.lastPointer.isNil:
    r.done(Result(err: newException(CatchableError,
      "mynim: GTK drag needs a pointer gesture")))
    return
  var r = r
  let targets = gtkTargets(r.data.formats() &
    @[platform.DragSessionFormat])
  let list = gtkTargetListNew(addr targets[0], uint32(targets.len))
  defer: gtkTargetListUnref(list)
  s.dragRequest = new(DragRequest)
  s.dragRequest[] = r
  s.dragError = nil
  s.dragCanceled = false
  gtkDataSources[s.area] = s
  s.dragContext = gtkDragBeginCoordinates(s.area, list,
    gtkOperations(r.operations), 1, s.lastPointer, int32(r.x),
    int32(r.y))
  if s.dragContext.isNil:
    gtkDataSources.del(s.area)
    s.dragRequest = nil
    r.done(Result(err: newException(CatchableError,
      "mynim: GTK failed to start drag")))
    return
  if r.preview.len > 0:
    var pix = r.preview
    var i = 0
    while i < pix.len:
      swap(pix[i], pix[i + 2])
      i += 4
    let png = pngEncode(RgbaImage(pix: pix, stride: r.width * 4,
      rect: rect(0, 0, r.width, r.height)))
    let (pb, err) = pixbufFromPNG(png)
    if err.isNil:
      gtkDragSetIconPixbuf(s.dragContext, pb, int32(r.hotX),
        int32(r.hotY))
      gObjectUnref(pb)

method cancelDataDrag*(s: gtkSurface) =
  if not s.dragContext.isNil:
    s.dragCanceled = true
    gtkDragCancel(s.dragContext)

proc cancelPendingDrop*(s: gtkSurface) =
  if not s.dataDrop.isNil:
    let d = s.dataDrop
    s.dataDrop = nil
    gtkDragFinish(d.context, false, false, d.time)
    gObjectUnref(d.context)

proc fileDragOver*(s: gtkSurface, x, y: float64): bool =
  s.send(SurfaceEvent(kind: fileDragOver, x: x, y: y))

proc dropFiles*(s: gtkSurface, x, y: float64, paths: seq[string]): bool =
  s.send(SurfaceEvent(kind: fileDrop, x: x, y: y, files: paths))

proc selectionPaths*(sel: pointer): seq[string] =
  let uris = gtkSelectionDataGetUris(sel)
  if uris.isNil:
    return @[]
  defer: gStrfreev(uris)
  var i = 0
  while true:
    let uri = field[pointer](uris, uint(i * 8))
    if uri.isNil:
      break
    let p = takeStr(gFilenameFromURI(goStr(uri), nil, nil))
    if p != "":
      result.add p
    inc i
