## surface_drop.nim (surface_drop.go): files dragged over native UI
## come through OLE drag and drop: the surface's window is a drop
## target, which tells the source whether the content takes the files
## where they are. Over the page of a web view that nothing the
## content painted covers, the page takes the drag instead, through
## its composition controller, as it would its own.

type
  dropTargetCom = object
    vtbl: ptr array[7, uint]
    refs: int32
  ## dropTarget is the IDropTarget of a surface.
  dropTargetEntry = ref object
    com: ptr dropTargetCom
    s*: w32Surface
    data*: uint
    helper*: uint
    drag*: DataDragEvent
    formats*: Table[Format, uint16]
    legacyLink*: bool
    # page is the web view whose page has the drag.
    page*: w32Window


var
  dropTargetVtbl: array[7, uint]
  dropTargets: Table[uint, dropTargetEntry]
  iidIDropTarget* = guid("00000122-0000-0000-c000-000000000046")

var hdropFormat* = formatEtc(format: cfHDrop, aspect: dvaspectContent,
  index: -1, tymed: tymedHGlobal)

proc enter*(t: dropTargetEntry, data: uint, allowed: uint32, keys: uint)
proc leave*(t: dropTargetEntry)
proc overPage*(t: dropTargetEntry, keys, pt, effect: uint): bool
proc leavePage*(t: dropTargetEntry): bool
proc over*(t: dropTargetEntry, keys, pt, effect: uint)
proc drop*(t: dropTargetEntry, data, pt, effect: uint)
proc helperEnter*(t: dropTargetEntry, data, pt, effect: uint)
proc pageAt*(t: dropTargetEntry, pt: uint): w32Window
proc screenDIP*(s: w32Surface, pt: uint): tuple[x, y: float64]
proc fileDragOver*(s: w32Surface, x, y: float64): bool
proc dropFiles*(s: w32Surface, x, y: float64, paths: seq[string]): bool
proc droppedPaths*(data: uint): seq[string]
proc droppedHDropPaths*(data: uint): seq[string]

const ## ICoreWebView2CompositionController3 methods (webview_embed)
  comp3DragEnter* = 12
  comp3DragOver* = 14
  comp3DragLeave* = 13
  comp3Drop* = 15

proc targetOf(this: uint): dropTargetEntry = dropTargets[this]

proc dropQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  let iid = cast[ptr GUID](cast[pointer](riid))[]
  if iid != iidIUnknown and iid != iidIDropTarget:
    cast[ptr uint](cast[pointer](out0))[] = 0
    return eNoInterface
  cast[ptr uint](cast[pointer](out0))[] = this
  inc targetOf(this).com.refs
  sOK

proc dropAddRef(this: uint): uint {.stdcall.} =
  let t = targetOf(this)
  inc t.com.refs
  uint(t.com.refs)

proc dropRelease(this: uint): uint {.stdcall.} =
  let t = targetOf(this)
  dec t.com.refs
  if t.com.refs == 0:
    t.leave()
    release(t.helper)
    dropTargets.del(this)
    dealloc(t.com)
    return 0
  uint(t.com.refs)

## DragEnter(data, keys, point, effect)
proc dropDragEnter(this, data, keys, pt, effect: uint): uint {.stdcall.} =
  let t = targetOf(this)
  let allowed = cast[ptr uint32](cast[pointer](effect))[]
  t.enter(data, allowed, keys)
  if not t.overPage(keys, pt, effect):
    t.over(keys, pt, effect)
  t.helperEnter(data, pt, effect)
  sOK

## DragOver(keys, point, effect)
proc dropDragOver(this, keys, pt, effect: uint): uint {.stdcall.} =
  let t = targetOf(this)
  if not t.overPage(keys, pt, effect):
    t.over(keys, pt, effect)
  if t.helper != 0:
    var p = w32Point(x: int32(uint32(pt)),
      y: int32(uint32(pt shr 32)))
    discard comCall(t.helper, 5, cast[uint](addr p),
      cast[uint](cast[ptr uint32](cast[pointer](effect))[]))
  sOK

## DragLeave()
proc dropDragLeave(this: uint): uint {.stdcall.} =
  let t = targetOf(this)
  if t.helper != 0:
    discard comCall(t.helper, 4)
  if not t.leavePage():
    discard t.s.send(SurfaceEvent(kind: dataDragLeave,
      drag: DataDragEvent()))
  t.leave()
  sOK

## Drop(data, keys, point, effect)
proc dropDrop(this, data, keys, pt, effect: uint): uint {.stdcall.} =
  let t = targetOf(this)
  if t.data != data:
    t.enter(data, cast[ptr uint32](cast[pointer](effect))[], keys)
  let v = t.pageAt(pt)
  if not v.isNil:
    if v != t.page:
      discard t.overPage(keys, pt, effect) ## enters it
    discard comCall(v.comp3, comp3Drop, data, keys, v.pagePoint(pt),
      effect)
    t.page = nil
  else:
    discard t.leavePage()
    t.over(keys, pt, effect)
    t.drop(data, pt, effect)
  if t.helper != 0:
    var p = w32Point(x: int32(uint32(pt)),
      y: int32(uint32(pt shr 32)))
    discard comCall(t.helper, 6, data, cast[uint](addr p),
      cast[uint](cast[ptr uint32](cast[pointer](effect))[]))
  t.leave()
  sOK

proc initDropTarget*() =
  discard procOleInitialize(0)
  initDataSource()
  dropTargetVtbl = [
    cast[uint](dropQueryInterface),
    cast[uint](dropAddRef),
    cast[uint](dropRelease),
    cast[uint](dropDragEnter),
    cast[uint](dropDragOver),
    cast[uint](dropDragLeave),
    cast[uint](dropDrop),
  ]

## acceptFileDrops makes the surface's window a drop target.
proc acceptFileDrops*(s: w32Surface) =
  dropOnceDo()
  let com = cast[ptr dropTargetCom](alloc0(sizeof(dropTargetCom)))
  com.vtbl = addr dropTargetVtbl
  com.refs = 1
  let p = cast[uint](com)
  dropTargets[p] = dropTargetEntry(com: com, s: s,
    helper: dragHelper(addr iidIDropTargetHelper))
  discard procRegisterDragDrop(s.hwnd, p) ## takes its own reference
  s.dropTarget = p

proc revokeFileDrops*(s: w32Surface) =
  if s.dropTarget != 0:
    discard procRevokeDragDrop(s.hwnd)
    release(s.dropTarget)
    s.dropTarget = 0

## overPage passes the drag at a point of the screen on to the page of
## the web view there, if one takes it, and reports whether one does:
## entering it, the content hears that the drag left, and leaving it,
## the page.
proc overPage*(t: dropTargetEntry, keys, pt, effect: uint): bool =
  let v = t.pageAt(pt)
  if v == t.page:
    if v.isNil:
      return false
    discard comCall(v.comp3, comp3DragOver, keys, v.pagePoint(pt),
      effect)
    return true
  if not t.leavePage():
    discard t.s.send(SurfaceEvent(kind: dataDragLeave,
      drag: DataDragEvent()))
  if v.isNil:
    return false
  t.page = v
  discard comCall(v.comp3, comp3DragEnter, t.data, keys,
    v.pagePoint(pt), effect)
  true

## pageAt returns the web view whose page takes a drag at a point of
## the screen, if one does.
proc pageAt*(t: dropTargetEntry, pt: uint): w32Window =
  if t.data == 0:
    return nil
  let (x, y) = t.s.screenDIP(pt)
  let v = t.s.webViewAt(x, y)
  if v.isNil or v.comp3 == 0: ## a runtime older than drags into pages
    return nil
  v

## leavePage tells the page that had the drag that it left, and
## reports whether one had it.
proc leavePage*(t: dropTargetEntry): bool =
  let v = t.page
  t.page = nil
  if v.isNil:
    return false
  if not v.closed and v.comp3 != 0:
    discard comCall(v.comp3, comp3DragLeave)
  true

## over answers whether the content takes the files dragged to a
## point of the screen, by the effect it lets the drop have.
proc over*(t: dropTargetEntry, keys, pt, effect: uint) =
  t.legacyLink = false
  let allowed = cast[ptr uint32](cast[pointer](effect))[]
  cast[ptr uint32](cast[pointer](effect))[] = dropEffectNone
  if t.drag.isNil:
    return
  let d = t.drag
  d.offer.operations = Operation(allowed) and
    (transfer.Copy or transfer.Move)
  d.offer.suggested = transfer.None
  if (keys and 8) != 0:
    d.offer.suggested = transfer.Copy
  elif (keys and 4) != 0:
    d.offer.suggested = transfer.Move
  let (x, y) = t.s.screenDIP(pt)
  if t.s.send(SurfaceEvent(kind: dataDragOver, x: x, y: y, drag: d)):
    cast[ptr uint32](cast[pointer](effect))[] = uint32(d.operation)
  elif d.hasFiles and (allowed and dropEffectLink) != 0 and
      (allowed and (dropEffectCopy or dropEffectMove)) == 0 and
      t.s.fileDragOver(x, y):
    ## Preserve the pre-existing file-only link fallback. Serialized
    ## destinations and new sources continue to negotiate copy/move.
    t.legacyLink = true
    cast[ptr uint32](cast[pointer](effect))[] = dropEffectLink

proc enter*(t: dropTargetEntry, data: uint, allowed: uint32,
    keys: uint) =
  t.leave()
  addRef(data)
  t.data = data
  let (d, f) = oleOffer(data, allowed, keys)
  t.drag = d
  t.formats = f

proc leave*(t: dropTargetEntry) =
  let data = t.data
  t.data = 0
  t.drag = nil
  t.formats.clear()
  release(data)

proc helperEnter*(t: dropTargetEntry, data, pt, effect: uint) =
  if t.helper == 0:
    return
  var p = w32Point(x: int32(uint32(pt)), y: int32(uint32(pt shr 32)))
  discard comCall(t.helper, 3, t.s.hwnd, data, cast[uint](addr p),
    cast[uint](cast[ptr uint32](cast[pointer](effect))[]))

proc drop*(t: dropTargetEntry, data, pt, effect: uint) =
  if t.legacyLink:
    cast[ptr uint32](cast[pointer](effect))[] = 0
    let (x, y) = t.s.screenDIP(pt)
    let paths = droppedPaths(data)
    if paths.len > 0 and t.s.dropFiles(x, y, paths):
      cast[ptr uint32](cast[pointer](effect))[] = dropEffectLink
    return
  let d = t.drag
  if d.isNil or cast[ptr uint32](cast[pointer](effect))[] == 0:
    return
  cast[ptr uint32](cast[pointer](effect))[] = 0
  var nativeFiles: seq[string]
  if d.data.formats.len == 0:
    var reps: seq[Representation]
    for f in d.formats:
      let id = t.formats.getOrDefault(f)
      if id == 0:
        return
      var b: seq[byte]
      if id == cfHDrop:
        if nativeFiles.len == 0:
          nativeFiles = droppedPaths(data)
        if nativeFiles.len == 0:
          return
        let (files, e) = fileData(nativeFiles)
        ## Legacy file-drop APIs deliver CF_HDROP paths as received.
        ## Their contract predates portable URL representations, so
        ## a path that cannot be encoded must still reach those
        ## listeners.
        if not e.isNil:
          continue
        let (bb, e2) = files.read(f)
        if not e2.isNil:
          continue
        b = bb
      else:
        let (buf, err) = oleDataBytes(data, id)
        if not err.isNil:
          return
        b = buf
        if id == cfUnicodeText:
          b = cast[seq[byte]](oleText(buf))
        elif id == uint16(cfHTML):
          let text = buf.bytesToString
          let start = htmlOffset(text, "StartFragment:")
          let `end` = htmlOffset(text, "EndFragment:")
          if start < 0 or `end` < start or `end` > text.len:
            return
          b = buf[start ..< `end`]
        elif id == uint16(registerClipboardFormat(
            "UniformResourceLocatorW")):
          b = cast[seq[byte]](oleText(buf))
      reps.add bytes(f, b)
    d.data = newData(newItem(reps))
  let (x, y) = t.s.screenDIP(pt)
  if t.s.send(SurfaceEvent(kind: dataDrop, x: x, y: y, drag: d,
      files: nativeFiles)):
    cast[ptr uint32](cast[pointer](effect))[] = uint32(d.operation)

## acceptEffect returns the effect of a drop the content takes, of
## those the source allows: never a move, which would delete the
## files.
proc acceptEffect*(allowed: uint32): uint32 =
  if (allowed and dropEffectCopy) != 0:
    return dropEffectCopy
  if (allowed and dropEffectLink) != 0:
    return dropEffectLink
  dropEffectNone

## screenDIP converts a POINTL of the screen, passed by value, to DIPs
## relative to the surface.
proc screenDIP*(s: w32Surface, pt: uint): tuple[x, y: float64] =
  var p = w32Point(x: int32(uint32(pt)), y: int32(uint32(pt shr 32)))
  discard procScreenToClient(s.hwnd, cast[uint](addr p))
  (s.toDIP(p.x), s.toDIP(p.y))

## fileDragOver reports whether the content takes files dragged to
## (x, y).
proc fileDragOver*(s: w32Surface, x, y: float64): bool =
  s.send(SurfaceEvent(kind: fileDragOver, x: x, y: y))

## dropFiles drops files at (x, y), and reports whether the content
## took them.
proc dropFiles*(s: w32Surface, x, y: float64, paths: seq[string]): bool =
  s.send(SurfaceEvent(kind: fileDrop, x: x, y: y, files: paths))

## droppedPaths returns the paths of the files of a data object.
proc droppedPaths*(data: uint): seq[string] =
  var format = hdropFormat
  var m: stgMedium
  if comCall(data, dataGetData, cast[uint](addr format),
      cast[uint](addr m)) != sOK:
    return @[]
  defer: discard procReleaseStgMedium(cast[uint](addr m))
  droppedHDropPaths(m.handle)

proc droppedHDropPaths*(handle: uint): seq[string] =
  let n = procDragQueryFileW(handle, 0xFFFFFFFF'u, 0, 0)
  var paths: seq[string]
  for i in 0 ..< n:
    let size = procDragQueryFileW(handle, i, 0, 0)
    var buf = newSeq[uint16](size + 1)
    discard procDragQueryFileW(handle, i, cast[uint](addr buf[0]),
      size + 1)
    let p = u16str(buf)
    if p != "":
      paths.add p
  paths
