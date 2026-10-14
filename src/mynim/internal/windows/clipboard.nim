## clipboard.nim (clipboard.go + system.go's clipboard): the OLE
## clipboard shares the IDataObject implementation of drags
## (surface_drag.nim). The private clipboard data of mynim itself is
## tracked so reads of its own representations return them exactly.

type winClipboardSource = ref object
  obj: uint
  data: Data
  released: proc()

var winClipboard: winClipboardSource

proc release(s: winClipboardSource) =
  if winClipboard == s:
    winClipboard = nil
  s.data = Data()
  if not s.released.isNil:
    let fn = s.released
    s.released = nil
    fn()

proc currentWinClipboard(): winClipboardSource =
  let s = winClipboard
  if not s.isNil:
    if procOleIsCurrentClipboard(s.obj) != sOK:
      winClipboard = nil
      return nil
  s

## open opens the clipboard, retrying while another program holds it.
proc open(c: w32Clipboard): bool =
  for i in 0 ..< 10:
    if procOpenClipboard(c.b.appHwnd) != 0:
      return true
    sleep(10)
  false

proc closeClipboard() = discard procCloseClipboard()

## clipboardData copies the clipboard data of a format.
method readText*(c: w32Clipboard): string =
  if not c.open():
    return ""
  defer: closeClipboard()
  let data = clipboardData(cfUnicodeText)
  var u = newSeq[uint16](data.len div 2)
  for i in 0 ..< u.len:
    u[i] = uint16(data[2 * i]) or uint16(data[2 * i + 1]) shl 8
  ## utf16Decode drops the terminating NUL.
  while u.len > 0 and u[^1] == 0:
    u.setLen(u.len - 1)
  u16str(u)

method writeText*(c: w32Clipboard, text: string) =
  discard c.writeData(textData(text), nil)

## htmlOffset finds the byte offset a CF_HTML header field names.
method readHTML*(c: w32Clipboard): string =
  if not c.open():
    return ""
  defer: closeClipboard()
  var data = clipboardData(cfHTML).bytesToString
  while data.len > 0 and data[^1] == '\x00':
    data.setLen(data.len - 1)
  let start = htmlOffset(data, "StartFragment:")
  let `end` = htmlOffset(data, "EndFragment:")
  if start < 0 or `end` < start or `end` > data.len:
    return ""
  data[start ..< `end`]

method writeHTML*(c: w32Clipboard, markup: string) =
  discard c.writeData(newData(newItem(bytes(transfer.HTML, markup),
    bytes(transfer.Text, markup))), nil)

## htmlData is shared by clipboard and drag representations.
method readImage*(c: w32Clipboard): seq[byte] =
  if not c.open():
    return @[]
  defer: closeClipboard()
  let data = clipboardData(cfPNG)
  if data.len > 0:
    return data
  let img = dibToImage(clipboardData(cfDIB))
  if img.isNil:
    return @[]
  pngEncode(img)

method writeImage*(c: w32Clipboard, data: seq[byte]) =
  let (_, err) = pngDecode(data)
  if not err.isNil:
    raise err
  discard c.writeData(newData(newItem(bytes(transfer.PNG, data))), nil)

## dibToImage decodes an uncompressed 24 or 32-bit device independent
## bitmap.
method clear*(c: w32Clipboard) =
  discard c.writeData(Data(), nil)

method availableFormats*(c: w32Clipboard): seq[string] =
  for f in c.formats:
    result.add $f

## writeData puts a transfer on the clipboard through OLE.
method writeData*(c: w32Clipboard, data: Data, released: proc()) =
  ## One OLE initialization/vtable per process, shared with native
  ## drags.
  dropOnceDo()
  if data.formats.len == 0:
    let hr = procOleSetClipboard(0)
    if failed(hr):
      raise hresultError("OleSetClipboard", hr)
    if not released.isNil:
      released()
    return
  for f in data.formats:
    if privateClipboardFormat(f):
      raise newException(CatchableError,
        "mynim: clipboard cannot contain native ownership metadata")
    if registerClipboardFormat($f) == 0 or
        registerClipboardFormat(clipboardLengthPrefix & $f) == 0:
      raise newException(CatchableError,
        "mynim: cannot register clipboard format")
  let obj = newTransferData(data, "", true)
  defer: release(obj)
  let hr = procOleSetClipboard(obj)
  if failed(hr):
    raise hresultError("OleSetClipboard", hr)
  let s = winClipboardSource(obj: obj, data: data, released: released)
  winClipboard = s
  dragObjects[obj].onRelease = proc() = s.release()

## clipboardFormats enumerates the open clipboard without rendering
## data. A stable OpenClipboard lock covers discovery and every
## selected read.
proc clipboardFormats(): tuple[offered: seq[Format],
    nativeFormats: Table[Format, uint16]] =
  var offered: seq[Format]
  var nativeFormats = initTable[Format, uint16]()
  template add(id: uint16) =
    var f = oleFormat(id)
    if id == cfDIB or id == cfDIBV5:
      f = transfer.PNG
    if f != "" and not privateClipboardFormat(f) and
        not ($f).anyOfIt(it in {'\x00', '\r', '\n'}):
      if f notin offered:
        offered.add f
      if nativeFormats.getOrDefault(f) == 0 or
          oleRegisteredFormatName(id) == $f:
        nativeFormats[f] = id
      if f == transfer.FileList:
        if nativeFormats.getOrDefault(transfer.URIList) == 0:
          nativeFormats[transfer.URIList] = id
        if transfer.URIList notin offered:
          offered.add transfer.URIList
  var f: uint
  while true:
    f = procEnumClipboardFormats(f)
    if f == 0:
      break
    add(uint16(f))
  ## Windows synthesizes Unicode text and DIBs for older clipboard
  ## owners.
  for id in [cfUnicodeText'u16, cfDIB]:
    if procIsClipboardFormatAvailable(uint(id)) != 0:
      add(id)
  (offered, nativeFormats)

method formats*(c: w32Clipboard): seq[Format] =
  let s = currentWinClipboard()
  if not s.isNil:
    return s.data.formats
  if not c.open():
    return @[]
  defer: closeClipboard()
  clipboardFormats().offered

proc clipboardBytes(format: uint16): tuple[b: seq[byte],
    err: ref CatchableError] =
  let h = procGetClipboardData(uint(format))
  if h == 0:
    return (@[], errFormat())
  let n = procGlobalSize(h)
  if n > 64 shl 20:
    return (@[], newException(CatchableError,
      "mynim: clipboard representation exceeds 64 MiB"))
  let p = procGlobalLock(h)
  if p == 0:
    return (@[], newException(CatchableError,
      "mynim: cannot lock clipboard data"))
  defer: discard procGlobalUnlock(h)
  var out0 = newSeq[byte](int(n))
  if n > 0:
    copyMem(addr out0[0], cast[pointer](p), int(n))
  (out0, nil)

method readData*(c: w32Clipboard, formats: seq[Format]):
    tuple[data: Data, err: ref CatchableError] =
  var formats = formats
  let s = currentWinClipboard()
  if not s.isNil:
    if formats.len == 0:
      formats = s.data.formats
    let (d, err) = s.data.materialize(formats)
    if currentWinClipboard() != s:
      return (Data(), errClipboardChanged())
    return (d, err)
  ## The lock also prevents mixing different owners while delayed
  ## data is rendered. Sequence numbers cannot do this: Windows
  ## increments them for ordinary delayed rendering, as well as for
  ## ownership changes.
  if not c.open():
    return (Data(), newException(CatchableError,
      "mynim: the clipboard is busy"))
  defer: closeClipboard()
  let (offered, nativeFormats) = clipboardFormats()
  if formats.len == 0:
    formats = offered
    if formats.len == 0:
      return (Data(), nil)
  var reps: seq[Representation]
  for n, f in formats:
    let id = nativeFormats.getOrDefault(f)
    if id == 0 or f in formats[0 ..< n]:
      continue
    var b: seq[byte]
    if id == cfHDrop:
      let h = procGetClipboardData(uint(id))
      if h == 0:
        return (Data(), errFormat())
      let (files, e) = fileData(droppedHDropPaths(h))
      if not e.isNil:
        return (Data(), e)
      let (bb, e2) = files.read(f)
      if not e2.isNil:
        return (Data(), e2)
      b = bb
    else:
      let (bb, err) = clipboardBytes(id)
      if not err.isNil:
        return (Data(), err)
      b = bb
      if id == cfUnicodeText:
        b = cast[seq[byte]](oleText(b))
      elif id == uint16(cfHTML):
        let s2 = b.bytesToString
        let start = htmlOffset(s2, "StartFragment:")
        let `end` = htmlOffset(s2, "EndFragment:")
        if start < 0 or `end` < start or `end` > b.len:
          return (Data(), newException(CatchableError,
            "mynim: invalid CF_HTML clipboard data"))
        b = b[start ..< `end`]
      elif id == cfDIB or id == cfDIBV5:
        let img = dibToImage(b)
        if img.isNil:
          return (Data(), newException(CatchableError,
            "mynim: cannot convert clipboard bitmap"))
        b = pngEncode(img)
      elif oleRegisteredFormatName(id) == "UniformResourceLocatorW":
        b = cast[seq[byte]](oleText(b))
      ## Plain registered payloads stay interoperable. The optional
      ## length hint restores empty/trailing-NUL custom bytes
      ## exactly.
      if oleRegisteredFormatName(id) == $f:
        let lengthID = uint16(registerClipboardFormat(
          clipboardLengthPrefix & $f))
        if procIsClipboardFormatAvailable(uint(lengthID)) != 0:
          let (length, e) = clipboardBytes(lengthID)
          if e.isNil and length.len >= 8:
            var n2: uint
            for i in 0 ..< 8:
              n2 = n2 or uint(length[i]) shl (8 * i)
            if n2 <= uint(b.len):
              b = b[0 ..< int(n2)]
    reps.add bytes(f, b)
  if reps.len == 0:
    return (Data(), errFormat())
  (newData(newItem(reps)), nil)

method flush*(c: w32Clipboard) =
  let s = currentWinClipboard()
  if s.isNil:
    return
  ## Keep the object alive while OLE relinquishes its reference.
  addRef(s.obj)
  defer: release(s.obj)
  let (d, err) = s.data.materialize(s.data.formats)
  if not err.isNil:
    raise err
  if currentWinClipboard() != s:
    raise errClipboardChanged()
  let obj = dragObjects[s.obj]
  ## Validate native conversions (notably PNG -> DIB) before native
  ## flush, so an encoding error cannot remove the source's delayed
  ## representations.
  for provider in obj.providers.values:
    let (_, e) = provider()
    if not e.isNil:
      raise e
  setTransferProviders(obj, d, "")
  s.data = d
  let hr = procOleFlushClipboard()
  if failed(hr):
    raise hresultError("OleFlushClipboard", hr)
  obj.onRelease = nil
  s.release()

method close*(c: w32Clipboard) =
  if not currentWinClipboard().isNil:
    c.clear()
  ## Remote COM references may outlive clipboard ownership. Native
  ## tracking has ended; remove their Nim provider closures before
  ## the app stops.
  for _, d in dragObjects:
    if d.clipboard:
      d.providers.clear()
      if not d.onRelease.isNil:
        let fn = d.onRelease
        d.onRelease = nil
        fn()
