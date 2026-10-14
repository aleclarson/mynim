## surface_drag.nim (surface_drag.go): OLE drag sources and data
## objects. The clipboard shares the IDataObject implementation, which
## serves a transfer.Data's representations as registered clipboard
## formats.

const
  tymedStream* = 4'u32
  dataEnumFormatEtc* = 8
  dataSetData* = 7
  dvFormatEtc* = 0x80040064'u32
  eNotImpl* = 0x80004001'u32
  sFalse* = 1'u
  dragDropDrop* = 0x40100'u
  dragDropCancel* = 0x40101'u
  dragDefaultCursors* = 0x40102'u
  dataSSameFormatEtc* = 0x40130'u
  oleEAdviseNotSupported* = 0x80040003'u

var
  iidIDataObject* = guid("0000010e-0000-0000-c000-000000000046")
  iidIDropSource* = guid("00000121-0000-0000-c000-000000000046")
  iidIEnumFormatEtc* = guid("00000103-0000-0000-c000-000000000046")
  iidIDragSourceHelper* = guid("de5bf786-477a-11d2-839d-00c04fd918d0")
  iidIDropTargetHelper* = guid("4657278b-411b-11d2-839a-00c04fd918d0")
  clsDragDropHelper* = guid("4657278a-411b-11d2-839a-00c04fd918d0")
  iidIUnknown* = guid("00000000-0000-0000-c000-000000000046")
  dragDataVtbl: array[12, uint]
  dragSourceVtbl: array[5, uint]
  formatEnumVtbl: array[7, uint]
  dragObjects*: Table[uint, dragDataEntry]
  dragSources: Table[uint, oleDragSourceEntry]
  formatEnums: Table[uint, formatEnumEntry]

proc validDataFormat*(f: formatEtc): bool
proc dataGlobal(b: seq[byte]): uint
proc nativeFormat*(f: uint16): formatEtc
proc newFormatEnum(formats: seq[formatEtc], n: int): uint
proc setTransferProviders*(d: dragDataEntry, data: Data,
  session: string)
proc newTransferData*(data: Data, session: string, clipboard: bool): uint
proc dragImage*(s: w32Surface, r: DragRequest, data: uint)
proc readDragStream*(stream: uint): tuple[b: seq[byte],
  err: ref CatchableError]

proc queryInterfaceTo(this, riid, out0: uint, want: GUID): uint =
  cast[ptr uint](cast[pointer](out0))[] = 0
  let iid = cast[ptr GUID](cast[pointer](riid))[]
  if iid != iidIUnknown and iid != want:
    return eNoInterface
  cast[ptr uint](cast[pointer](out0))[] = this
  addRef(this)
  sOK

proc dataNotImpl(this, a, b: uint): uint {.stdcall.} = eNotImpl

proc dataQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  queryInterfaceTo(this, riid, out0, iidIDataObject)

proc dataAddRef(this: uint): uint {.stdcall.} =
  let d = dragObjects[this]
  inc d.com.refs
  uint(d.com.refs)

proc dataRelease(this: uint): uint {.stdcall.} =
  let d = dragObjects[this]
  dec d.com.refs
  if d.com.refs == 0:
    dragObjects.del(this)
    for m in d.extra.values:
      var mm = m
      discard procReleaseStgMedium(cast[uint](addr mm))
    d.providers.clear()
    d.extra.clear()
    if not d.onRelease.isNil:
      let fn = d.onRelease
      d.onRelease = nil
      fn()
    dealloc(d.com)
    return 0
  uint(d.com.refs)

proc dataGetDataCb(this, format, medium: uint): uint {.stdcall.} =
  let d = dragObjects[this]
  let f = cast[ptr formatEtc](cast[pointer](format))[]
  cast[ptr stgMedium](cast[pointer](medium))[] = stgMedium()
  if not validDataFormat(f):
    return dvFormatEtc
  if f.format in d.extra:
    let m = d.extra[f.format]
    if (f.tymed and tymedHGlobal) == 0:
      return dvFormatEtc
    let h = procOleDuplicateData(m.handle, uint(f.format), 0)
    if h == 0:
      return eFail
    cast[ptr stgMedium](cast[pointer](medium))[] =
      stgMedium(tymed: tymedHGlobal, handle: h)
    return sOK
  let provider = d.providers.getOrDefault(f.format)
  if provider.isNil:
    return dvFormatEtc
  let (b, err) = provider()
  if not err.isNil:
    d.err = err
    return eFail
  if (f.tymed and tymedStream) != 0:
    let stream = memStream(b)
    if stream == 0:
      return eFail
    ## IDataObject::GetData transfers bytes from zero through the
    ## stream's current position. OLE uses that position as the
    ## length when rendering a stream onto the Win32 clipboard.
    if failed(comCall(stream, 5, 0, 2, 0)): ## IStream::Seek(0, END)
      release(stream)
      return eFail
    cast[ptr stgMedium](cast[pointer](medium))[] =
      stgMedium(tymed: tymedStream, handle: stream)
    return sOK
  let h = dataGlobal(b)
  if h == 0:
    return eFail
  cast[ptr stgMedium](cast[pointer](medium))[] =
    stgMedium(tymed: tymedHGlobal, handle: h)
  sOK

proc dataQueryGetDataCb(this, format: uint): uint {.stdcall.} =
  let d = dragObjects[this]
  let f = cast[ptr formatEtc](cast[pointer](format))[]
  if validDataFormat(f) and (f.format in d.providers or
      ((f.tymed and tymedHGlobal) != 0 and f.format in d.extra)):
    return sOK
  dvFormatEtc

proc dataSetFormatEtc(this, inF, outF: uint): uint {.stdcall.} =
  cast[ptr formatEtc](cast[pointer](outF))[] =
    cast[ptr formatEtc](cast[pointer](inF))[]
  cast[ptr formatEtc](cast[pointer](outF)).device = 0
  dataSSameFormatEtc

proc dataSetDataCb(this, format, medium, owned: uint): uint {.stdcall.} =
  let d = dragObjects[this]
  let f = cast[ptr formatEtc](cast[pointer](format))[]
  var m = cast[ptr stgMedium](cast[pointer](medium))[]
  if not validDataFormat(f) or m.tymed != tymedHGlobal:
    return dvFormatEtc
  if owned == 0:
    let h = procOleDuplicateData(m.handle, uint(f.format), 0)
    if h == 0:
      return eFail
    m = stgMedium(tymed: tymedHGlobal, handle: h)
  if f.format in d.extra:
    var old = d.extra[f.format]
    discard procReleaseStgMedium(cast[uint](addr old))
  d.extra[f.format] = m
  if f.format notin d.formats:
    d.formats.add f.format
  sOK

proc dataEnumFormatEtcCb(this, direction, out0: uint): uint {.stdcall.} =
  cast[ptr uint](cast[pointer](out0))[] = 0
  if direction != 1:
    return eNotImpl
  var formats: seq[formatEtc]
  let d = dragObjects[this]
  for f in d.formats:
    var format = nativeFormat(f)
    if f in d.providers:
      format.tymed = format.tymed or tymedStream
    formats.add format
  cast[ptr uint](cast[pointer](out0))[] = newFormatEnum(formats, 0)
  sOK

proc dataDAdvise(this, format, flags, sink, out0: uint): uint {.stdcall.} =
  oleEAdviseNotSupported

proc sourceQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  queryInterfaceTo(this, riid, out0, iidIDropSource)

proc sourceAddRef(this: uint): uint {.stdcall.} =
  let s = dragSources[this]
  inc s.com.refs
  uint(s.com.refs)

proc sourceRelease(this: uint): uint {.stdcall.} =
  let s = dragSources[this]
  dec s.com.refs
  if s.com.refs == 0:
    dragSources.del(this)
    dealloc(s.com)
    return 0
  uint(s.com.refs)

proc sourceQueryContinueDrag(this, escape, keys: uint): uint {.stdcall.} =
  if escape != 0 or dragSources[this].canceled:
    return dragDropCancel
  if (keys and 1) == 0:
    return dragDropDrop
  sOK

proc sourceGiveFeedback(this, effect: uint): uint {.stdcall.} =
  dragDefaultCursors

proc enumQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  queryInterfaceTo(this, riid, out0, iidIEnumFormatEtc)

proc enumAddRef(this: uint): uint {.stdcall.} =
  let e = formatEnums[this]
  inc e.com.refs
  uint(e.com.refs)

proc enumRelease(this: uint): uint {.stdcall.} =
  let e = formatEnums[this]
  dec e.com.refs
  if e.com.refs == 0:
    formatEnums.del(this)
    dealloc(e.com)
    return 0
  uint(e.com.refs)

proc enumNext(this, count, out0, fetched: uint): uint {.stdcall.} =
  let e = formatEnums[this]
  let n = min(int(count), e.formats.len - e.n)
  let dest = cast[ptr UncheckedArray[formatEtc]](cast[pointer](out0))
  for i in 0 ..< n:
    dest[i] = e.formats[e.n + i]
  e.n += n
  if fetched != 0:
    cast[ptr uint32](cast[pointer](fetched))[] = uint32(n)
  if n < int(count):
    return sFalse
  sOK

proc enumSkip(this, count: uint): uint {.stdcall.} =
  let e = formatEnums[this]
  let n = min(int(count), e.formats.len - e.n)
  e.n += n
  if n < int(count):
    return sFalse
  sOK

proc enumReset(this: uint): uint {.stdcall.} =
  formatEnums[this].n = 0
  sOK

proc enumClone(this, out0: uint): uint {.stdcall.} =
  let e = formatEnums[this]
  cast[ptr uint](cast[pointer](out0))[] = newFormatEnum(e.formats, e.n)
  sOK

proc initDataSource*() =
  dragDataVtbl = [
    cast[uint](dataQueryInterface),
    cast[uint](dataAddRef),
    cast[uint](dataRelease),
    cast[uint](dataGetDataCb),
    cast[uint](dataNotImpl), ## GetDataHere
    cast[uint](dataQueryGetDataCb),
    cast[uint](dataSetFormatEtc), ## GetCanonicalFormatEtc
    cast[uint](dataSetDataCb),
    cast[uint](dataEnumFormatEtcCb),
    cast[uint](dataDAdvise),
    cast[uint](dataNotImpl), ## DUnadvise
    cast[uint](dataNotImpl), ## EnumDAdvise
  ]
  dragSourceVtbl = [
    cast[uint](sourceQueryInterface),
    cast[uint](sourceAddRef),
    cast[uint](sourceRelease),
    cast[uint](sourceQueryContinueDrag),
    cast[uint](sourceGiveFeedback),
  ]
  formatEnumVtbl = [
    cast[uint](enumQueryInterface),
    cast[uint](enumAddRef),
    cast[uint](enumRelease),
    cast[uint](enumNext),
    cast[uint](enumSkip),
    cast[uint](enumReset),
    cast[uint](enumClone),
  ]

proc newFormatEnum(formats: seq[formatEtc], n: int): uint =
  let com = cast[ptr formatEnumCom](alloc0(sizeof(formatEnumCom)))
  com.vtbl = addr formatEnumVtbl
  com.refs = 1
  let p = cast[uint](com)
  formatEnums[p] = formatEnumEntry(com: com, formats: formats, n: n)
  p

proc nativeFormat*(f: uint16): formatEtc =
  formatEtc(format: f, aspect: dvaspectContent, index: -1,
    tymed: tymedHGlobal)

proc validDataFormat*(f: formatEtc): bool =
  f.aspect == dvaspectContent and f.index == -1 and
    (f.tymed and (tymedHGlobal or tymedStream)) != 0

proc dataGlobal(b: seq[byte]): uint =
  let h = procGlobalAlloc(gmemMoveable or 0x40,
    uint(max(b.len, 1)))
  if h == 0:
    return 0
  let p = procGlobalLock(h)
  if p == 0:
    discard procGlobalFree(h)
    return 0
  if b.len > 0:
    copyMem(cast[pointer](p), unsafeAddr b[0], b.len)
  discard procGlobalUnlock(h)
  h

proc newDragData(r: DragRequest): uint =
  newTransferData(r.data, r.session, false)

proc newTransferData*(data: Data, session: string,
    clipboard: bool): uint =
  let com = cast[ptr dragDataCom](alloc0(sizeof(dragDataCom)))
  com.vtbl = addr dragDataVtbl
  com.refs = 1
  let p = cast[uint](com)
  let d = dragDataEntry(com: com,
    providers: initTable[uint16, dataProvider](),
    extra: initTable[uint16, stgMedium](), clipboard: clipboard)
  dragObjects[p] = d
  setTransferProviders(d, data, session)
  p

proc setTransferProviders*(d: dragDataEntry, data: Data,
    session: string) =
  d.providers.clear()
  d.formats = @[]
  template add(f: uint16, provider: dataProvider) =
    if f notin d.formats:
      d.formats.add f
    d.providers[f] = provider
  for f in data.formats:
    let ff = f
    add uint16(registerClipboardFormat($ff)), (proc(): tuple[b: seq[byte], err: ref CatchableError] = (let t = data.read(ff); (t.data, t.err)))
    if d.clipboard:
      ## HGLOBAL allocations can include padding after
      ## OleFlushClipboard. Keep the byte length as a separate,
      ## optional interoperability hint; the actual format still
      ## contains unwrapped standard bytes.
      add uint16(registerClipboardFormat(clipboardLengthPrefix & $ff)),
        (proc(): tuple[b: seq[byte], err: ref CatchableError] =
          let (b, err) = data.read(ff)
          if not err.isNil:
            return (@[], err)
          var length = newSeq[byte](8)
          for i in 0 ..< 8:
            length[i] = byte(uint(b.len) shr (8 * i))
          (length, nil))
    case $ff
    of $transfer.Text:
      add cfUnicodeText, (proc(): tuple[b: seq[byte], err: ref CatchableError] =
        let (b, e) = data.read(transfer.Text)
        (utf16Bytes(b.bytesToString), e))
    of $transfer.HTML:
      add uint16(cfHTML), (proc(): tuple[b: seq[byte], err: ref CatchableError] =
        let (b, e) = data.read(transfer.HTML)
        (htmlData(b.bytesToString), e))
    of $transfer.PNG:
      add uint16(cfPNG), (proc(): tuple[b: seq[byte], err: ref CatchableError] =
        (let t = data.read(transfer.PNG); (t.data, t.err)))
      if d.clipboard:
        add cfDIB, (proc(): tuple[b: seq[byte], err: ref CatchableError] =
          let (b, err) = data.read(transfer.PNG)
          if not err.isNil:
            return (@[], err)
          let (img, derr) = pngDecode(b)
          if not derr.isNil:
            return (@[], derr)
          (imageToDIB(img), nil))
    of $transfer.URIList:
      add uint16(registerClipboardFormat("UniformResourceLocatorW")),
        (proc(): tuple[b: seq[byte], err: ref CatchableError] =
          let (urls, err) = data.urls()
          if not err.isNil or urls.len == 0:
            return (@[], errFormat())
          (utf16Bytes(urls[0]), nil))
    of $transfer.FileList:
      add cfHDrop, (proc(): tuple[b: seq[byte], err: ref CatchableError] =
        let (paths, err) = data.files()
        if not err.isNil:
          return (@[], err)
        var b = newSeq[byte](20)
        b[0] = 20 ## DROPFILES.pFiles
        b[16] = 1 ## fWide
        for p in paths:
          b.add utf16Bytes(p)
        b.add 0; b.add 0
        (b, nil))
    else: discard
  if session != "":
    add uint16(registerClipboardFormat($DragSessionFormat)),
      (proc(): tuple[b: seq[byte], err: ref CatchableError] =
        (cast[seq[byte]](session), nil))

method setDropFormats*(s: w32Surface, formats: seq[Format]) = discard
  ## OLE enumerates the offered IDataObject.

method startDataDrag*(s: w32Surface, r: DragRequest) =
  dropOnceDo()
  let data = newDragData(r)
  let com = cast[ptr oleDragSourceCom](alloc0(sizeof(oleDragSourceCom)))
  com.vtbl = addr dragSourceVtbl
  com.refs = 1
  let p = cast[uint](com)
  dragSources[p] = oleDragSourceEntry(com: com)
  s.dragSource = dragSources[p]
  defer:
    s.dragSource = nil
    release(p)
    release(data)
  if r.preview.len > 0:
    s.dragImage(r, data)
  ## OLE owns capture during its modal tracking loop.
  discard procReleaseCapture()
  var effect: uint32
  let hr = procDoDragDrop(data, p, uint(r.operations),
    cast[uint](addr effect))
  var res = Result(operation: Operation(effect) and
    (transfer.Copy or transfer.Move))
  if hr != dragDropDrop:
    res.operation = transfer.None
    res.canceled = hr == dragDropCancel or hr == sOK
  if failed(hr):
    res.err = hresultError("DoDragDrop", hr)
  if data in dragObjects and not dragObjects[data].err.isNil:
    res.operation = transfer.None
    res.canceled = false
    res.err = dragObjects[data].err
  r.done(res)

method cancelDataDrag*(s: w32Surface) =
  if not s.dragSource.isNil:
    s.dragSource.canceled = true
    discard procPostMessageW(s.hwnd, wmMouseMove, 0, 0)

proc dragHelper(iid: ptr GUID): uint =
  discard procCoCreateInstance(cast[uint](addr clsDragDropHelper), 0,
    1, cast[uint](iid), cast[uint](addr result))

## bitmapInfoHeader is BITMAPINFOHEADER.
type bitmapInfoHeader* = object
  size*: uint32
  width*, height*: int32
  planes*, bitCount*: uint16
  compression*, sizeImage*: uint32
  xPelsPerMeter*, yPelsPerMeter*: int32
  clrUsed*, clrImportant*: uint32

type shDragImage = object
  sizeDrag, offset: w32Point
  bitmap: uint
  key: uint32

proc dragImage*(s: w32Surface, r: DragRequest, data: uint) =
  let helper = dragHelper(addr iidIDragSourceHelper)
  if helper == 0:
    return
  defer: release(helper)
  let scale = s.dpi() / 96
  let w = max(int(r.width.float64 * scale), 1)
  let h = max(int(r.height.float64 * scale), 1)
  var bi = bitmapInfoHeader(width: int32(w), height: -int32(h),
    planes: 1, bitCount: 32)
  bi.size = uint32(sizeof(bi))
  var bits: uint
  let bmp = procCreateDIBSection(0, cast[uint](addr bi), 0,
    cast[uint](addr bits), 0, 0)
  if bmp == 0:
    return
  defer: discard procDeleteObject(bmp)
  let pix = cast[ptr UncheckedArray[byte]](cast[pointer](bits))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (min(int(y.float64 / scale), r.height - 1) * r.width +
        min(int(x.float64 / scale), r.width - 1)) * 4
      copyMem(addr pix[(y * w + x) * 4], unsafeAddr r.preview[i], 4)
  var image = shDragImage(
    sizeDrag: w32Point(x: int32(w), y: int32(h)),
    offset: w32Point(x: int32(r.hotX.float64 * scale),
      y: int32(r.hotY.float64 * scale)),
    bitmap: bmp, key: 0xFFFFFFFF'u32)
  discard comCall(helper, 3, cast[uint](addr image), data)

## oleDataBytes reads format f of a data object.
proc oleDataBytes*(data: uint, f: uint16): tuple[b: seq[byte],
    err: ref CatchableError] =
  var format = nativeFormat(f)
  var m: stgMedium
  ## A stream preserves exact binary lengths, including trailing
  ## NULs. HGLOBAL may contain allocator padding. Prefer streams
  ## where offered.
  format.tymed = tymedStream
  if not failed(comCall(data, dataGetData, cast[uint](addr format),
      cast[uint](addr m))):
    defer: discard procReleaseStgMedium(cast[uint](addr m))
    if m.tymed != tymedStream or m.handle == 0:
      return (@[], errFormat())
    return readDragStream(m.handle)
  format.tymed = tymedHGlobal
  if failed(comCall(data, dataGetData, cast[uint](addr format),
      cast[uint](addr m))):
    return (@[], errFormat())
  defer: discard procReleaseStgMedium(cast[uint](addr m))
  if m.tymed != tymedHGlobal or m.handle == 0:
    return (@[], errFormat())
  let p = procGlobalLock(m.handle)
  if p == 0:
    return (@[], newException(CatchableError,
      "mynim: cannot lock drag data"))
  defer: discard procGlobalUnlock(m.handle)
  let n = procGlobalSize(m.handle)
  if n > 64 shl 20:
    return (@[], newException(CatchableError,
      "mynim: drag representation exceeds 64 MiB"))
  var out0 = newSeq[byte](int(n))
  if n > 0:
    copyMem(addr out0[0], cast[pointer](p), int(n))
  (out0, nil)

proc readDragStream*(stream: uint): tuple[b: seq[byte],
    err: ref CatchableError] =
  ## GetData leaves the cursor at the end of the transferred bytes.
  if failed(comCall(stream, 5, 0, 0, 0)): ## IStream::Seek(0, SET)
    return (@[], newException(CatchableError,
      "mynim: cannot seek drag stream"))
  var out0: seq[byte]
  var buf = newSeq[byte](64 shl 10)
  while true:
    var n: uint32
    let hr = comCall(stream, 3, cast[uint](addr buf[0]), uint(buf.len),
      cast[uint](addr n))
    if failed(hr) or n > uint32(buf.len):
      return (@[], newException(CatchableError,
        "mynim: cannot read drag stream"))
    if out0.len + int(n) > 64 shl 20:
      return (@[], newException(CatchableError,
        "mynim: drag representation exceeds 64 MiB"))
    out0.add buf.toOpenArray(0, int(n) - 1)
    if n == 0 or hr == sFalse:
      return (out0, nil)

proc oleText*(b: seq[byte]): string =
  var u = newSeq[uint16](b.len div 2)
  for n in 0 ..< u.len:
    u[n] = uint16(b[n * 2]) or uint16(b[n * 2 + 1]) shl 8
  u16str(u)

proc oleRegisteredFormatName*(f: uint16): string =
  var buf: array[256, uint16]
  let n = procGetClipboardFormatNameW(uint(f), cast[uint](addr buf[0]),
    256)
  if n == 0:
    return ""
  u16str(buf.toOpenArray(0, int(n) - 1))

proc oleFormat*(f: uint16): Format =
  if f == cfUnicodeText:
    return transfer.Text
  if f == cfHDrop:
    return transfer.FileList
  if f == uint16(cfHTML):
    return transfer.HTML
  if f == uint16(cfPNG):
    return transfer.PNG
  let name = oleRegisteredFormatName(f)
  if name == "UniformResourceLocatorW":
    return transfer.URIList
  if name == "Rich Text Format":
    ## RichEdit's, which WordPad and Word copy.
    return "text/rtf"
  Format(name)

proc oleOffer*(data: uint, allowed: uint32, keys: uint):
    tuple[drag: DataDragEvent, formats: Table[Format, uint16]] =
  let d = DataDragEvent(offer: Offer(
    operations: Operation(allowed) and
      (transfer.Copy or transfer.Move)))
  if (keys and 8) != 0:
    d.offer.suggested = transfer.Copy
  elif (keys and 4) != 0:
    d.offer.suggested = transfer.Move
  var formats = initTable[Format, uint16]()
  template add(f: uint16) =
    let canonical = oleFormat(f)
    if canonical != "" and
        not canonical.startsWith(clipboardLengthPrefix) and
        not canonical.contains({'\x00', '\r', '\n'}):
      if canonical == DragSessionFormat:
        let (b, err) = oleDataBytes(data, f)
        if err.isNil:
          d.session = b.bytesToString
        while d.session.len > 0 and d.session[^1] == '\x00':
          d.session.setLen(d.session.len - 1)
      else:
        if canonical notin d.offer.formats:
          d.offer.formats.add canonical
        formats[canonical] = f
        if canonical == transfer.FileList:
          d.hasFiles = true
          formats[transfer.URIList] = f
          if transfer.URIList notin d.offer.formats:
            d.offer.formats.add transfer.URIList
  var enum0: uint
  if comCall(data, dataEnumFormatEtc, 1, cast[uint](addr enum0)) ==
      sOK and enum0 != 0:
    defer: release(enum0)
    for n in 0 ..< 1024:
      var f: formatEtc
      if comCall(enum0, 3, 1, cast[uint](addr f), 0) != sOK:
        break
      if f.device != 0:
        discard procCoTaskMemFree(f.device)
      if validDataFormat(f):
        add(f.format)
  ## Some sources do not enumerate. Query common formats too.
  for f in [uint16(cfUnicodeText), cfHDrop, uint16(cfHTML), uint16(cfPNG),
      uint16(registerClipboardFormat("UniformResourceLocatorW")),
      uint16(registerClipboardFormat($DragSessionFormat))]:
    var format = nativeFormat(f)
    if comCall(data, dataQueryGetData, cast[uint](addr format)) == sOK:
      add(f)
  (d, formats)
