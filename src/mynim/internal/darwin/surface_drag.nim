## surface_drag.go: NSDraggingSource and NSPasteboardItemDataProvider
## implementations for native drag-and-drop, and drop handling.

proc dragPoint*(s: macSurface, info: id): tuple[x, y: float64]
proc eventMods*(ev: id): platform.Modifiers

proc macOperations(o: transfer.Operation): uint
proc pasteboardItems(src: macDataSource): seq[id]
proc finish(src: macDataSource, operation: uint)
proc nativeDataEvent(s: macSurface, info: id,
                     kind: SurfaceEventKind): bool

proc registerDataDragClasses*() =
  discard classDef("MyNimDragSource", "NSObject", @["NSDraggingSource"], @[
    methodDef("draggingSession:sourceOperationMaskForDraggingContext:",
      cast[pointer](proc(self: id, cmd: SEL, session: id,
                         context: int): uint {.cdecl.} =
        let src = macDragSources.getOrDefault(self)
        if src != nil:
          return macOperations(src.r.operations)
        0), "Q@:@q"),
    methodDef("draggingSession:endedAtPoint:operation:",
      cast[pointer](proc(self: id, cmd: SEL, session: id,
                         point: NSPoint, operation: uint) {.cdecl.} =
        let src = macDragSources.getOrDefault(self)
        if src != nil:
          src.finish(operation)), "v@:@{CGPoint=dd}Q"),
  ])
  discard classDef("MyNimDragProvider", "NSObject",
    @["NSPasteboardItemDataProvider"], @[
    methodDef("pasteboard:item:provideDataForType:",
      cast[pointer](proc(self: id, cmd: SEL, board, item,
                         typ: id) {.cdecl.} =
        let p = macDragProviders.getOrDefault(self)
        if p == nil:
          return
        let name = goString(typ)
        var b: seq[byte]
        var err: ref CatchableError
        if name == macType(DragSessionFormat):
          b = cast[seq[byte]](p.src.r.session)
        else:
          let f = macFormat(name)
          (b, err) = p.item.read(f)
          if f == transfer.FileList or name == "public.url":
            b = cast[seq[byte]](strip(cast[string](b).split('\n')[0]))
        if err != nil:
          p.src.err = err
          return
        discard send(item, "setData:forType:", argu(nsData(b)),
             argu(typ))), "v@:@@@"),
  ])

proc macOperations(o: transfer.Operation): uint =
  if (o and transfer.Copy) != 0:
    result = result or 1
  if (o and transfer.Move) != 0:
    result = result or 16

proc goOperations(n: uint): transfer.Operation =
  if (n and 1) != 0:
    result = result or transfer.Copy
  if (n and 16) != 0:
    result = result or transfer.Move

method setDropFormats*(s: macSurface, formats: seq[transfer.Format]) =
  var types: seq[id]
  for f in formats:
    types.add(nsString(macType(f)))
  if transfer.URIList in formats:
    types.add(nsString("public.url"))
  discard send(s.view, "registerForDraggedTypes:", argu(nsArray(types)))

method startDataDrag*(s: macSurface, r: DragRequest) =
  if s.w.closed or s.w.lastMouseDown == nil:
    r.done(transfer.Result(err: newException(ValueError,
      "mynim: native drag needs a pointer gesture")))
    return
  withPool(proc() =
    let src = macDataSource(r: r, s: s,
      obj: send(send(`class`("MyNimDragSource"), "alloc"), "init"))
    macDragSources[src.obj] = src
    s.dataDrag = src
    var img = send(`class`("NSImage"), "imageNamed:",
                   argu(nsString("NSMultipleDocuments")))
    var width = r.width
    var height = r.height
    if r.preview.len > 0:
      var pix = r.preview
      var i = 0
      while i < pix.len:
        swap(pix[i], pix[i + 2])
        i += 4
      let b = pngEncode(RgbaImage(pix: pix, stride: 4 * width,
        rect: image.Rectangle(max: image.Point(x: width, y: height))))
      img = autorelease(send(send(`class`("NSImage"), "alloc"),
        "initWithData:", argu(nsData(b))))
    else:
      width = 32
      height = 32
    var x = r.x
    var y = r.y
    if x < 0 or y < 0:
      let p = msgPointFromView(s.view, sel("convertPoint:fromView:"),
        msgPoint(s.w.lastMouseDown, sel("locationInWindow")), nil)
      x = p.x
      y = p.y
    var dragging: seq[id]
    var n = 0
    for pb in src.pasteboardItems():
      let di = autorelease(send(send(`class`("NSDraggingItem"), "alloc"),
        "initWithPasteboardWriter:", argu(pb)))
      let frame = NSRect(origin: NSPoint(
          x: x - float64(r.hotX) + float64(n * 3),
          y: y - float64(r.hotY) + float64(n * 3)),
        size: NSSize(width: float64(width), height: float64(height)))
      msgDraggingFrame(di, sel("setDraggingFrame:contents:"), frame, img)
      dragging.add(di)
      inc n
    src.session = retain(send(s.view,
      "beginDraggingSessionWithItems:event:source:",
      argu(nsArray(dragging)), argu(s.w.lastMouseDown), argu(src.obj)))
    if src.session == nil:
      src.err = newException(ValueError,
        "mynim: AppKit failed to start drag")
      src.finish(0)
      return
    discard send(src.session,
      "setAnimatesToStartingPositionsOnCancelOrFail:", argu(1)))

proc pasteboardItems(src: macDataSource): seq[id] =
  for item in src.r.data.items():
    let pb = autorelease(send(send(`class`("NSPasteboardItem"), "alloc"),
      "init"))
    let provider = send(send(`class`("MyNimDragProvider"), "alloc"),
      "init")
    macDragProviders[provider] = macDataProvider(src: src, item: item)
    src.providers.add(provider)
    var types: seq[id]
    for f in item.formats():
      types.add(nsString(macType(f)))
      if f == transfer.URIList:
        types.add(nsString("public.url"))
    types.add(nsString(macType(DragSessionFormat)))
    discard send(pb, "setDataProvider:forTypes:", argu(provider),
         argu(nsArray(types)))
    result.add(pb)

proc finish(src: macDataSource, operation: uint) =
  macDragSources.del(src.obj)
  if src.s.dataDrag == src:
    src.s.dataDrag = nil
  for p in src.providers:
    macDragProviders.del(p)
    release(p)
  release(src.session)
  # The callback still uses self. Autorelease after AppKit returns.
  discard autorelease(src.obj)
  var op = goOperations(operation)
  if src.err != nil:
    op = transfer.None
  let done = src.r.done
  src.r = DragRequest()
  done(transfer.Result(operation: op,
    canceled: op == transfer.None and src.err == nil, err: src.err))

method cancelDataDrag*(s: macSurface) =
  if s.dataDrag == nil:
    return
  # NSDraggingSession has no public cancel method. Posting Escape to
  # AppKit's tracking loop cancels through its normal keyboard path.
  withPool(proc() =
    let ev = msgDragKeyEvent(`class`("NSEvent"),
      sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
      10, NSPoint(), 0, 0, sendInt(s.w.win, "windowNumber"), nil,
      nsString("\x1b"), nsString("\x1b"), false, 53)
    discard send(s.w.b.app, "postEvent:atStart:", argu(ev), argu(1)))

proc nativeDataEvent(s: macSurface, info: id,
                     kind: SurfaceEventKind): bool =
  s.dragOperation = transfer.None
  let pb = send(info, "draggingPasteboard")
  let d = platform.DataDragEvent(offer: transfer.Offer(
    operations: goOperations(cast[uint](send(info,
      "draggingSourceOperationMask")))))
  d.session = goString(send(pb, "stringForType:",
    argu(nsString(macType(DragSessionFormat)))))
  let items = arrayItems(send(pb, "pasteboardItems"))
  for item in items:
    for t in arrayItems(send(item, "types")):
      let f = macFormat(goString(t))
      if f == DragSessionFormat:
        continue
      if f notin d.offer.formats:
        d.offer.formats.add(f)
      if f == transfer.FileList:
        d.hasFiles = true
        if transfer.URIList notin d.offer.formats:
          d.offer.formats.add(transfer.URIList)
  let mods = eventMods(send(s.w.b.app, "currentEvent"))
  if (mods and platform.modAlt) != 0:
    d.offer.suggested = transfer.Copy
  elif (mods and platform.modSuper) != 0:
    d.offer.suggested = transfer.Move
  let (x, y) = s.dragPoint(info)
  if kind == dataDragLeave:
    return s.send(platform.SurfaceEvent(kind: kind, drag: d))
  if not s.send(platform.SurfaceEvent(kind: dataDragOver, x: x, y: y,
      drag: d)):
    return false
  s.dragOperation = d.operation
  if kind == dataDragOver:
    return true
  # The native pasteboard is only read after the content accepted
  # formats.
  var dataItems: seq[transfer.Item]
  for item in items:
    var reps: seq[transfer.Representation]
    for f in d.formats:
      var t = macType(f)
      var available = send(item, "dataForType:", argu(nsString(t)))
      if available == nil and f == transfer.URIList:
        available = send(item, "dataForType:",
                         argu(nsString("public.url")))
        if available == nil:
          t = "public.file-url"
          available = send(item, "dataForType:", argu(nsString(t)))
      if available != nil:
        var b = goBytes(available)
        if t == "public.file-url":
          b = filePathURLBytes(b)
        reps.add(transfer.bytes(f, b))
    if reps.len > 0:
      dataItems.add(transfer.newItem(reps))
  d.data = transfer.newData(dataItems)
  s.send(platform.SurfaceEvent(kind: dataDrop, x: x, y: y, drag: d))

proc nativeDataOperation(s: macSurface, info: id): uint =
  if not s.nativeDataEvent(info, dataDragOver):
    return 0
  macOperations(s.dragOperation)
