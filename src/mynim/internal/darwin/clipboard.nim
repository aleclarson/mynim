## clipboard.go: transfer.Data on NSPasteboard, with a data provider so
## the data can be lazy.

## macType and macFormat map transfer formats to pasteboard UTIs and
## back, for the clipboard and drags. MIME types the system does not
## know get a dev.mynim.mime. type of their hex.
var
  macDragTypes* = initTable[Format, string]()
  macDragFormats* = initTable[string, Format]()

proc containsAnyChar(s: string): bool =
  for c in s:
    if c in {'\x00', '\r', '\n'}:
      return true
  false

proc macType*(f: Format): string =
  case f
  of transfer.Text: return utString
  of transfer.HTML: return utHTML
  of transfer.PNG: return utPNG
  of transfer.FileList: return "public.file-url"
  of transfer.URIList:
    ## public.url carries one URL. Keep the full URI-list bytes in a
    ## separate type and offer public.url as an interoperable fallback.
    return "dev.mynim.uri-list"
  else:
    discard
  if macDragTypes.hasKey(f):
    return macDragTypes[f]
  var t = ""
  let cls = objcGetClass("UTType")
  if not cls.isNil:
    let ut = send(cls, "typeWithMIMEType:", argu(nsString($f)))
    if not ut.isNil:
      t = goString(send(ut, "identifier"))
  if t == "":
    t = "dev.mynim.mime." & toHex($f)
  macDragTypes[f] = t
  macDragFormats[t] = f
  t

proc macFormat*(t: string): Format =
  case t
  of utString, "public.plain-text", "NSStringPboardType":
    return transfer.Text
  of utHTML:
    return transfer.HTML
  of utPNG:
    return transfer.PNG
  of "public.file-url":
    return transfer.FileList
  of "public.url", "dev.mynim.uri-list":
    return transfer.URIList
  else:
    discard
  if macDragFormats.hasKey(t):
    return macDragFormats[t]
  if t.startsWith("dev.mynim.mime."):
    let h = t["dev.mynim.mime.".len .. ^1]
    try:
      let b = h.parseHexStr
      if b.len > 0:
        return Format(b)
    except ValueError:
      discard
  let cls = objcGetClass("UTType")
  if not cls.isNil:
    let ut = send(cls, "typeWithIdentifier:", argu(nsString(t)))
    if not ut.isNil:
      let mime = goString(send(ut, "preferredMIMEType"))
      if mime != "":
        return Format(mime)
  Format(t)

var clipboardClassRegistered = false

## macClipboardFormat: file-list representation can contain several
## URLs. Keep its complete bytes alongside AppKit's single-file URL
## interoperability representation.
proc macClipboardFormat(name: string): Format =
  if name == "public.utf16-plain-text" or
      name == "public.utf16-external-plain-text":
    return transfer.Text
  if name == "dev.mynim.file-list" or name == "NSFilenamesPboardType":
    return transfer.FileList
  macFormat(name)

proc registerClipboardClass() =
  if clipboardClassRegistered:
    return
  clipboardClassRegistered = true
  discard classDef("MyGoClipboardProvider", "NSObject",
    @["NSPasteboardItemDataProvider"], @[
    methodDef("pasteboard:item:provideDataForType:",
      cast[pointer](proc(self: id, cmd: SEL, board, item, typ: id)
          {.cdecl.} =
        let s = macClipboardProviders.getOrDefault(self)
        if s == nil:
          return
        let name = goString(typ)
        let f = macClipboardFormat(name)
        if not s.items.hasKey(item):
          return
        let it = s.items[item]
        var (b, err) = it.read(f)
        if err != nil:
          return
        if name == "public.url" or name == "public.file-url":
          b = cast[seq[byte]](
            ($cast[ptr UncheckedArray[char]](
              if b.len > 0: unsafeAddr b[0] else: nil))
            .split("\n")[0].strip())
        discard send(item, "setData:forType:", argu(nsData(b)),
                     argu(typ))),
      "v@:@@@@"),
    methodDef("pasteboardFinishedWithDataProvider:",
      cast[pointer](proc(self: id, cmd: SEL, board: id) {.cdecl.} =
        let s = macClipboardProviders.getOrDefault(self)
        if s != nil:
          s.release()),
      "v@:@@"),
  ])

proc release*(s: macClipboardSource) =
  if s.obj.isNil:
    return
  macClipboardProviders.del(s.obj)
  if macClipboard == s:
    macClipboard = nil
  # AppKit may still be in a callback on self; its own references are
  # independent of our +1. Drop all Nim closures before notifying the
  # core.
  discard autorelease(s.obj)
  s.obj = nil
  s.data = Data()
  s.items.clear()
  if s.released != nil:
    let fn = s.released
    s.released = nil
    fn()

proc currentMacClipboard(): macClipboardSource =
  let s = macClipboard
  if s != nil and sendInt(pasteboard(), "changeCount") != s.change:
    s.release()
    return nil
  s

proc macClipboardTypes(item: transfer.Item): seq[string] =
  for f in item.formats:
    result.add macType(f)
    if f == transfer.URIList:
      result.add "public.url"
    if f == transfer.FileList:
      result.add "dev.mynim.file-list"

method writeData*(c: clipboardImpl, data: Data, released: proc()) =
  var err: ref CatchableError = nil
  withPool(proc() =
    registerClipboardClass()
    if data.formats.len == 0:
      c.clear()
      if released != nil:
        released()
      return
    let s = macClipboardSource(data: data, released: released)
    s.obj = send(send(`class`("MyGoClipboardProvider"), "alloc"), "init")
    macClipboardProviders[s.obj] = s
    var items: seq[id]
    for item in data.items:
      let pb = autorelease(send(send(`class`("NSPasteboardItem"), "alloc"),
                                "init"))
      s.items[pb] = item
      var types: seq[id]
      for typ in macClipboardTypes(item):
        types.add nsString(typ)
      discard send(pb, "setDataProvider:forTypes:", argu(s.obj),
                   argu(nsArray(types)))
      items.add pb
    let board = pasteboard()
    discard send(board, "clearContents")
    if macClipboard != nil:
      macClipboard.release()
    if not sendBool(board, "writeObjects:", argu(nsArray(items))):
      s.released = nil
      s.release()
      err = newException(IOError, "mynim: cannot write pasteboard items")
      return
    s.change = sendInt(board, "changeCount")
    if not s.obj.isNil:
      macClipboard = s)
  if err != nil:
    raise err

method formats*(c: clipboardImpl): seq[Format] =
  var res: seq[Format]
  withPool(proc() =
    let s = currentMacClipboard()
    if s != nil:
      res = s.data.formats
      return
    for typ in arrayItems(send(pasteboard(), "types")):
      let name = goString(typ)
      var f = macClipboardFormat(name)
      if name == utTIFF:
        f = transfer.PNG
      if $f == "" or containsAnyChar($f) or
          f == DragSessionFormat:
        continue
      if f notin res:
        res.add f
      if f == transfer.FileList and transfer.URIList notin res:
        res.add transfer.URIList)
  res

proc macClipboardReadItem(item: id,
    formats: seq[Format]): tuple[reps: seq[Representation],
                                 err: ref CatchableError]

method readData*(c: clipboardImpl, formats: seq[Format]):
    tuple[d: Data, err: ref CatchableError] =
  var result0: Data
  var err: ref CatchableError = nil
  var fmts = formats
  withPool(proc() =
    let board = pasteboard()
    let change = sendInt(board, "changeCount")
    if fmts.len == 0:
      fmts = c.formats
      if fmts.len == 0:
        return
    let s = currentMacClipboard()
    if s != nil:
      let (d, e) = s.data.materialize(fmts)
      result0 = d
      err = e
    else:
      var items: seq[transfer.Item]
      for item in arrayItems(send(board, "pasteboardItems")):
        let (reps, e) = macClipboardReadItem(item, fmts)
        if e != nil:
          err = e
          return
        if reps.len != 0:
          items.add newItem(reps)
      result0 = newData(items)
      if result0.formats.len == 0:
        err = errFormat()
    if sendInt(board, "changeCount") != change:
      result0 = Data()
      err = errClipboardChanged())
  (result0, err)

proc macClipboardReadItem(item: id,
    formats: seq[Format]): tuple[reps: seq[Representation],
                                 err: ref CatchableError] =
  var available = initTable[Format, seq[string]]()
  for typ in arrayItems(send(item, "types")):
    let name = goString(typ)
    var f = macClipboardFormat(name)
    if name == utTIFF:
      f = transfer.PNG
    if $f == "" or f == DragSessionFormat or
        containsAnyChar($f):
      continue
    available.mgetOrPut(f, @[]).add name
    if f == transfer.FileList:
      available.mgetOrPut(transfer.URIList, @[]).add name
  var reps: seq[Representation]
  for n, f in formats:
    if f in formats[0 ..< n]:
      continue
    let names = available.getOrDefault(f)
    ## Put full serialized URI/file lists before single URL fallbacks.
    var preferred = @[macType(f)]
    if f == transfer.FileList:
      preferred = @["dev.mynim.file-list", macType(f)]
    if f == transfer.URIList:
      preferred = @[macType(f), "dev.mynim.file-list"]
    var ordered: seq[string]
    for name in preferred & names:
      if name in names and name notin ordered:
        ordered.add name
    var b: seq[byte]
    var found = false
    for name in ordered:
      let typ = nsString(name)
      if name == "NSFilenamesPboardType":
        var paths: seq[string]
        for value in arrayItems(send(item, "propertyListForType:",
                                     argu(typ))):
          paths.add goString(value)
        let (files, ferr) = fileData(paths)
        if ferr != nil:
          return (@[], ferr)
        let (d, derr) = files.read(f)
        if derr != nil:
          continue
        b = d
        found = true
        break
      let value = send(item, "dataForType:", argu(typ))
      if value.isNil:
        continue
      if sendInt(value, "length") > 64 shl 20:
        return (@[], newException(IOError,
          "mynim: clipboard representation exceeds 64 MiB"))
      b = goBytes(value)
      if name == "public.file-url":
        b = filePathURLBytes(b)
      if f == transfer.Text and name != utString:
        ## AppKit decodes legacy/UTF-16 text into an NSString.
        b = cast[seq[byte]](goString(send(item, "stringForType:",
                                          argu(typ))))
      if f == transfer.PNG and name == utTIFF:
        let rep = send(`class`("NSBitmapImageRep"), "imageRepWithData:",
                       argu(value))
        if rep.isNil:
          return (@[], newException(IOError,
            "mynim: cannot convert clipboard image"))
        b = goBytes(send(rep, "representationUsingType:properties:",
          argu(4), argu(send(`class`("NSDictionary"), "dictionary"))))
      found = true
      break
    if found:
      reps.add bytes(f, b)
  (reps, nil)

method flush*(c: clipboardImpl) =
  var err: ref CatchableError = nil
  withPool(proc() =
    let s = currentMacClipboard()
    if s == nil:
      return
    let (d, e) = s.data.materialize(s.data.formats)
    if e != nil:
      err = e
      return
    if currentMacClipboard() != s:
      err = errClipboardChanged()
      return
    var items: seq[id]
    for item in d.items:
      let pb = autorelease(send(send(`class`("NSPasteboardItem"), "alloc"),
                                "init"))
      for name in macClipboardTypes(item):
        let (b, _) = item.read(macClipboardFormat(name))
        var bb = b
        if name == "public.url" or name == "public.file-url":
          bb = cast[seq[byte]](
            bytesToString(b).split("\n")[0].strip())
        discard send(pb, "setData:forType:", argu(nsData(bb)),
                     argu(nsString(name)))
      items.add pb
    let board = pasteboard()
    discard send(board, "clearContents")
    if not sendBool(board, "writeObjects:", argu(nsArray(items))):
      err = newException(IOError, "mynim: cannot persist pasteboard items")
    s.release())
  if err != nil:
    raise err

method close*(c: clipboardImpl) =
  withPool(proc() =
    let s = currentMacClipboard()
    if s != nil:
      discard send(pasteboard(), "clearContents")
      s.release())
