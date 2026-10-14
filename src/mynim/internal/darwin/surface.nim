## surface.go: the surface of a window that shows content MyNim draws
## itself is a layer-backed view in place of the web view, inside the same
## content view, so that vibrancy, the traffic lights and a hidden title
## bar behave as with a page. It turns AppKit's events into surface
## events, is the text input client of input methods, and paces frames
## with a display link.

proc webViewAt*(s: macSurface, x, y: float64): macWindow
proc visibleSurface*(s: macSurface): bool
proc nsCursor(c: Cursor): id
proc noCursor(): id
proc applyCursor(s: macSurface)

var
  # cgColorSpaceSRGB is resolved lazily by loadSurface.
  cgColorSpaceSRGB*: pointer
  # caPass counts the passes of the main run loop, past Core Animation's
  # commit of each: frames drawn in the same pass go into the same
  # transaction.
  caPass*: uint64 = 1

const
  cfRunLoopBeforeWaiting = 1 shl 5
  cfRunLoopExit = 1 shl 7
  # caCommitOrder is the order of Core Animation's observer committing
  # the transaction of each pass of the run loop.
  caCommitOrder = 2000000

proc caPassTick(observer: pointer, activity: uint, info: pointer)
    {.cdecl.} =
  inc caPass

var surfaceOnce: bool

proc loadSurface*() =
  if surfaceOnce:
    return
  surfaceOnce = true
  cgColorSpaceSRGB = cgColorSpaceCreateWithName(kCGColorSpaceSRGB)
  # An observer after Core Animation's counts the transactions it
  # committed.
  let observer = cfRunLoopObserverCreate(nil,
    uint(cfRunLoopBeforeWaiting or cfRunLoopExit), true,
    caCommitOrder + 1, cast[pointer](caPassTick), nil)
  if observer != nil:
    cfRunLoopAddObserver(cfRunLoopGetMain(), observer,
                         kCFRunLoopCommonModes)

proc createSurface*(w: macWindow, content: NSRect) =
  loadSurface()
  let s = macSurface(w: w)
  s.view = msgInitRect(send(`class`("MyNimSurfaceView"), "alloc"),
    sel("initWithFrame:"), NSRect(size: content.size))
  discard send(s.view, "setWantsLayer:", argu(1))
  discard send(s.view, "setLayerContentsRedrawPolicy:", argu(2)) # on setNeedsDisplay
  discard send(s.view, "setAutoresizingMask:", argu(nsViewWidthHeightSizable))
  let layer = send(s.view, "layer")
  discard send(layer, "setContentsGravity:", argu(nsString("resize")))
  # Tracking for hover, inside the visible part of the view.
  const options = 0x01 or 0x02 or 0x04 or 0x40 or 0x200
    # entered/exited, moved, cursor update, active app, visible rect
  s.tracking = msgInitTracking(send(`class`("NSTrackingArea"), "alloc"),
    sel("initWithRect:options:owner:userInfo:"), NSRect(), uint(options),
    s.view, nil)
  discard send(s.view, "addTrackingArea:", argu(s.tracking))
  if respondsTo(s.view, "displayLinkWithTarget:selector:"):
    s.link = retain(send(s.view, "displayLinkWithTarget:selector:",
      argu(s.view), argu(sel("mynimTick:"))))
    discard send(s.link, "setPaused:", argu(1))
    discard send(s.link, "addToRunLoop:forMode:",
      argu(send(`class`("NSRunLoop"), "mainRunLoop")),
      argu(kCFRunLoopCommonModes))
  # Files dragged from other apps.
  discard send(s.view, "registerForDraggedTypes:",
    argu(nsArray(nsString("public.file-url"))))
  w.surface = s
  w.b.bySurface[s.view] = s

proc destroySurface*(s: macSurface) =
  s.cancelDataDrag()
  if s.link != nil:
    discard send(s.link, "invalidate")
    release(s.link)
    s.link = nil
  s.destroyAccess()
  discard send(s.view, "removeTrackingArea:", argu(s.tracking))
  release(s.tracking)
  s.w.b.bySurface.del(s.view)
  release(s.view)

## surface returns the surface of a window created with
## WindowOptions.surface.
method surface*(w: macWindow): Surface =
  if w.surface == nil:
    return nil
  w.surface

method native*(s: macSurface): SurfaceNative =
  SurfaceNative(view: cast[uint](s.view),
                layer: cast[uint](send(s.view, "layer")))

## showsMaterial reports whether the window has a material, whose effect
## view, behind the surface, shows where its frames are transparent.
method showsMaterial*(s: macSurface): bool =
  s.w.effect != nil or s.w.popover != nil

proc scale(s: macSurface): float64 =
  let f = msgFloat(s.w.win, sel("backingScaleFactor"))
  if f > 0: f else: 1

method size*(s: macSurface): tuple[width, height, scale: float64] =
  let b = msgRect(s.view, sel("bounds"))
  (b.size.width, b.size.height, s.scale())

proc refresh(s: macSurface): times.Duration

method requestFrame*(s: macSurface) =
  if s.w.closed:
    return
  if s.link != nil:
    if s.linkRunning:
      s.due = true
    elif getTime() - s.lastFrame > 2 * s.refresh() and s.visibleSurface():
      # After a pause, the frame draws at once, at the end of this pass
      # of the run loop, as AppKit's views do. A window out of sight
      # waits for the link, which ticks once it shows: AppKit draws the
      # views of hidden windows too.
      discard send(s.view, "setNeedsDisplay:", argu(1))
    else:
      # Frames that follow each other draw at the display's refreshes;
      # the link keeps running while they come, rather than pausing
      # after each, which costs a call to the window server.
      s.due = true
      s.linkRunning = true
      discard send(s.link, "setPaused:", argu(0))
    return
  if s.timing:
    return
  # One refresh after the last frame, or at once after a pause.
  let delay = s.refresh() - (getTime() - s.lastFrame)
  if delay <= times.DurationZero:
    discard send(s.view, "setNeedsDisplay:", argu(1))
    return
  s.timing = true
  withPool(proc() =
    let t = msgTimer(`class`("NSTimer"),
      sel("timerWithTimeInterval:target:selector:userInfo:repeats:"),
      delay.inNanoseconds().float64 / 1e9, s.view, sel("mynimTimer:"),
      nil, false)
    discard send(send(`class`("NSRunLoop"), "mainRunLoop"), "addTimer:forMode:",
      argu(t), argu(kCFRunLoopCommonModes)))

## presentsWithTransaction reports whether the GPU renderer's
## CAMetalLayer presents with Core Animation's transaction
## (internal/gpu/metal), as it does the frames that change it: the frame
## drawn last then takes a drawable until the transaction commits.
proc presentsWithTransaction(s: macSurface): bool =
  let sublayers = send(send(s.view, "layer"), "sublayers")
  let metalLayer = `class`("CAMetalLayer")
  for i in 0 ..< sendInt(sublayers, "count"):
    let l = send(sublayers, "objectAtIndex:", argu(i))
    if sendBool(l, "isKindOfClass:", argu(metalLayer)):
      return sendBool(l, "presentsWithTransaction")
  false

## occluded reports whether nothing of the window shows on screen:
## hidden, minimized, on another space or covered by other windows,
## which still get display link ticks.
method occluded*(s: macSurface): bool = not s.visibleSurface()

## visibleSurface reports whether some of the window shows on screen.
proc visibleSurface*(s: macSurface): bool =
  const occlusionStateVisible = 1 shl 1
  (sendInt(s.w.win, "occlusionState") and occlusionStateVisible) != 0

## refresh returns the time between two refreshes of the window's
## display.
proc refresh(s: macSurface): times.Duration =
  var fps = 60
  let r = int(s.refreshRate())
  if r > 0:
    fps = max(r, 30)
  initDuration(nanoseconds = 1_000_000_000 div fps)

method refreshRate*(s: macSurface): float64 =
  let screen = send(s.w.win, "screen")
  if screen != nil and respondsTo(screen, "maximumFramesPerSecond"):
    return float64(sendInt(screen, "maximumFramesPerSecond"))
  0

method wideGamut*(s: macSurface): bool =
  const displayGamutP3 = 2 # NSDisplayGamutP3
  let screen = send(s.w.win, "screen")
  screen != nil and respondsTo(screen, "canRepresentDisplayGamut:") and
    sendInt(screen, "canRepresentDisplayGamut:",
            argu(displayGamutP3)) != 0

method presentPixels*(s: macSurface, pix: openArray[byte],
                      stride, width, height: int) =
  if pix.len < stride * height or width == 0 or height == 0:
    return
  let data = cfDataCreate(nil, unsafeAddr pix[0], stride * height)
  let provider = cgDataProviderCreateWithCFData(data)
  const bitmapInfo = 2 or (2 shl 12)
    # premultiplied alpha first, 32-bit little endian: BGRA
  let img = cgImageCreate(uint(width), uint(height), 8, 32,
    uint(stride), cgColorSpaceSRGB, bitmapInfo, provider, nil, false, 0)
  let layer = send(s.view, "layer")
  msgSetFloat(layer, sel("setContentsScale:"), s.scale())
  discard send(layer, "setContents:", argu(img))
  cgImageRelease(img)
  cgDataProviderRelease(provider)
  cfRelease(data)

const cursorSelectors = {
  cursorDefault: "arrowCursor",
  cursorPointer: "pointingHandCursor",
  cursorText: "IBeamCursor",
  cursorMove: "openHandCursor",
  cursorResizeEW: "resizeLeftRightCursor",
  cursorResizeNS: "resizeUpDownCursor",
  cursorNotAllowed: "operationNotAllowedCursor",
  cursorCrosshair: "crosshairCursor",
  cursorGrab: "openHandCursor",
  cursorGrabbing: "closedHandCursor",
  cursorResizeN: "resizeUpCursor",
  cursorResizeE: "resizeRightCursor",
  cursorResizeS: "resizeDownCursor",
  cursorResizeW: "resizeLeftCursor",
  # macOS 15 has cursors for columns and rows.
  cursorResizeColumn: "columnResizeCursor",
  cursorResizeRow: "rowResizeCursor",
  cursorVerticalText: "IBeamCursorForVerticalLayout",
  cursorCopy: "dragCopyCursor",
  cursorAlias: "dragLinkCursor",
  cursorContextMenu: "contextualMenuCursor",
}

## cursorFallbacks are the cursors of older macOS for those it lacks.
const cursorFallbacks = {
  cursorResizeColumn: "resizeLeftRightCursor",
  cursorResizeRow: "resizeUpDownCursor",
}

## applyCursor sets the content's cursor, unless the pointer is over a
## web view, whose page sets its own.
proc applyCursor(s: macSurface) =
  if s.placed.len > 0:
    let p = msgPoint(`class`("NSEvent"), sel("mouseLocation"))
    let inWindow = msgRectToRect(s.w.win, sel("convertRectFromScreen:"),
      NSRect(origin: p))
    let local = msgPointFromView(s.view, sel("convertPoint:fromView:"),
      inWindow.origin, nil)
    if s.webViewAt(local.x, local.y) != nil:
      return
  discard send(nsCursor(s.cursor), "set")

## nsCursor returns the NSCursor of c. The diagonal resize cursors are
## the frame resize cursors of macOS 15, else AppKit's own older ones.
proc nsCursor(c: Cursor): id =
  let cls = `class`("NSCursor")
  if c == cursorResizeNWSE or c == cursorResizeNESW:
    var corner = 1 or 2
    var older = "_windowResizeNorthWestSouthEastCursor" # top left
    if c == cursorResizeNESW:
      corner = 1 or 8
      older = "_windowResizeNorthEastSouthWestCursor" # top right
    if respondsTo(cls, "frameResizeCursorFromPosition:inDirections:"):
      let cur = send(cls,
        "frameResizeCursorFromPosition:inDirections:", argu(corner),
        argu(1 or 2)) # inward and outward
      if cur != nil:
        return cur
    if respondsTo(cls, older):
      let cur = send(cls, older)
      if cur != nil:
        return cur
  if c == cursorNone:
    return noCursor()
  var name = ""
  for (k, v) in cursorSelectors:
    if k == c:
      name = v
      break
  if name == "":
    name = "arrowCursor"
  if not respondsTo(cls, name):
    name = ""
    for (k, v) in cursorFallbacks:
      if k == c:
        name = v
        break
    if name == "":
      name = "arrowCursor"
  discard send(cls, name)

var hiddenCursor: id

## noCursor returns a cursor of a transparent image, which hides the
## pointer while it is over the view, unlike NSCursor's hide, which
## hides it everywhere until unhidden.
proc noCursor(): id =
  if hiddenCursor == nil:
    # A PNG of one transparent pixel.
    let b = pngEncode(RgbaImage(pix: @[0'u8, 0, 0, 0], stride: 4,
      rect: image.Rectangle(max: image.Point(x: 1, y: 1))))
    withPool(proc() =
      let data = send(`class`("NSData"), "dataWithBytes:length:",
        argu(unsafeAddr b[0]), argu(b.len))
      let img = send(send(`class`("NSImage"), "alloc"),
        "initWithData:", argu(data))
      hiddenCursor = msgInitIDPoint(
        send(`class`("NSCursor"), "alloc"),
        sel("initWithImage:hotSpot:"), img, NSPoint())
      discard send(img, "release"))
  hiddenCursor

method setCursor*(s: macSurface, c: Cursor) =
  s.cursor = c
  if s.inside:
    s.applyCursor()

method setTextInput*(s: macSurface, t: TextInputState) =
  if s.input.client != t.client and s.input.active:
    s.marked = ""
    discard send(send(s.view, "inputContext"), "discardMarkedText")
  if s.input.active and not t.active and s.marked != "":
    s.marked = ""
    discard send(send(s.view, "inputContext"), "discardMarkedText")
  let moved = t.active != s.input.active or t.caret != s.input.caret
  s.input = t
  if t.active and moved:
    discard send(send(s.view, "inputContext"), "invalidateCharacterCoordinates")

## surfaceKeyChanged tells the content of a window that became or ceased
## to be the key window that its surface gained or lost the keyboard, as
## focus events do on the other platforms: AppKit tells views only when
## the first responder changes.
proc surfaceKeyChanged*(w: macWindow, key: bool) =
  let s = w.surface
  if s == nil or send(w.win, "firstResponder") != s.view:
    return
  let kind = if key: surfaceFocus else: surfaceBlur
  discard s.send(platform.SurfaceEvent(kind: kind))

proc eventMods*(ev: id): platform.Modifiers =
  let flags = cast[uint](send(ev, "modifierFlags"))
  var m: platform.Modifiers
  if (flags and (1 shl 17)) != 0:
    m = m or platform.modShift
  if (flags and (1 shl 18)) != 0:
    m = m or platform.modCtrl
  if (flags and (1 shl 19)) != 0:
    m = m or platform.modAlt
  if (flags and (1 shl 20)) != 0:
    m = m or platform.modSuper
  m

## location returns where a mouse event happened, in the view's flipped
## coordinates.
proc location*(s: macSurface, ev: id): tuple[x, y: float64] =
  let p = msgPointFromView(s.view, sel("convertPoint:fromView:"),
    msgPoint(ev, sel("locationInWindow")), nil)
  (p.x, p.y)

## sideButton sends a mouse's back or forward button pressed or released
## as keyBack or keyForward.
proc sideButton(s: macSurface, kind: SurfaceEventKind, back: bool,
                mods: platform.Modifiers) =
  let k = if back: keyBack else: keyForward
  case kind
  of pointerDown:
    discard s.send(platform.SurfaceEvent(kind: keyPressed, key: k,
      mods: mods))
  of pointerUp:
    discard s.send(platform.SurfaceEvent(kind: keyReleased, key: k,
      mods: mods))
  else: discard

proc mouse(s: macSurface, kind: SurfaceEventKind, ev: id, button: int) =
  let (x, y) = s.location(ev)
  discard s.send(platform.SurfaceEvent(kind: kind, x: x, y: y,
    button: button, clicks: sendInt(ev, "clickCount"),
    mods: eventMods(ev)))

## macKeys maps virtual key codes that do not type a character.
const macKeys = {
  0x24'u16: keyEnter, 0x4C: keyEnter, 0x30: keyTab, 0x31: keySpace,
  0x33: keyBackspace, 0x35: keyEscape, 0x75: keyDelete, 0x72: keyInsert,
  0x73: keyHome, 0x77: keyEnd, 0x74: keyPageUp, 0x79: keyPageDown,
  0x7B: keyLeft, 0x7C: keyRight, 0x7D: keyDown, 0x7E: keyUp,
  0x7A: keyF1, 0x78: keyF2, 0x63: keyF3, 0x76: keyF4,
  0x60: keyF5, 0x61: keyF6, 0x62: keyF7, 0x64: keyF8,
  0x65: keyF9, 0x6D: keyF10, 0x67: keyF11, 0x6F: keyF12,
  0x6E: keyContextMenu,
}

proc eventKey(ev: id): platform.Key =
  let code = uint16(sendInt(ev, "keyCode"))
  for (k, v) in macKeys:
    if k == code:
      return v
  let chars = goString(send(ev, "charactersIgnoringModifiers"))
  for r in chars.runes:
    return keyForRune(r.int32)
  keyUnknown

## ansiKeys maps virtual key codes (Carbon's kVK_ANSI_*) to the key at
## that position of an ANSI US keyboard.
const ansiKeys = {
  0x00'u16: keyA, 0x01: keyS, 0x02: keyD, 0x03: keyF,
  0x04: keyH, 0x05: keyG, 0x06: keyZ, 0x07: keyX,
  0x08: keyC, 0x09: keyV, 0x0B: keyB, 0x0C: keyQ,
  0x0D: keyW, 0x0E: keyE, 0x0F: keyR, 0x10: keyY,
  0x11: keyT, 0x1F: keyO, 0x20: keyU, 0x22: keyI,
  0x23: keyP, 0x25: keyL, 0x26: keyJ, 0x28: keyK,
  0x2D: keyN, 0x2E: keyM,
  0x12: key1, 0x13: key2, 0x14: key3, 0x15: key4,
  0x16: key6, 0x17: key5, 0x19: key9, 0x1A: key7,
  0x1C: key8, 0x1D: key0,
  0x18: keyEqual, 0x1B: keyMinus, 0x1E: keyBracketRight,
  0x21: keyBracketLeft, 0x27: keyQuote, 0x29: keySemicolon,
  0x2A: keyBackslash, 0x2B: keyComma, 0x2C: keySlash,
  0x2F: keyPeriod, 0x32: keyBackquote,
}

## keyAtCode returns the key a virtual key code stands for by position:
## the non-text keys of macKeys, then the ANSI US letter, digit and
## punctuation keys.
proc keyAtCode(code: uint16): platform.Key =
  for (k, v) in macKeys:
    if k == code:
      return v
  for (k, v) in ansiKeys:
    if k == code:
      return v
  keyUnknown

const
  macISOSectionCode = 0x0A'u16
  macANSIGraveCode = 0x32'u16
  macISOLayoutType = 0x49534F20'u32 # Carbon's kKeyboardISO ('ISO ')

proc keyAtCodeForLayout(code: uint16, layoutType: uint32): platform.Key =
  if layoutType == macISOLayoutType:
    # On ISO keyboards the key left of 1 is kVK_ISO_Section, while
    # kVK_ANSI_Grave is the extra key beside the left Shift.
    case code
    of macISOSectionCode:
      return keyBackquote
    of macANSIGraveCode:
      # No key for ISO's extra key in platform.Key.
      return keyUnknown
    else: discard
  keyAtCode(code)

## physicalKey returns the ANSI US key at the event's physical position,
## independent of the current input source. Only the grave key differs
## on ISO.
proc physicalKey(ev: id): platform.Key =
  let code = uint16(sendInt(ev, "keyCode"))
  if code != macISOSectionCode and code != macANSIGraveCode:
    return keyAtCode(code)
  var keyboardType: int16
  let cgEvent = send(ev, "CGEvent")
  if cgEvent != nil:
    keyboardType = int16(cgEventGetIntegerValueField(cgEvent, 10))
      # kCGKeyboardEventKeyboardType
  if keyboardType == 0: # Synthetic NSEvents can lack a keyboard type.
    keyboardType = int16(lmGetKbdType())
  keyAtCodeForLayout(code, kbGetLayoutType(keyboardType))

## stringOf returns the text of an NSString or NSAttributedString.
proc stringOf(obj: id): string =
  var obj = obj
  if obj == nil:
    return ""
  if respondsTo(obj, "string"):
    obj = send(obj, "string")
  goString(obj)

## utf16Len returns the length of s in UTF-16 code units, as NSRanges
## count.
proc utf16Len(s: string): int = units(toRunes(s))

## runesBefore converts a UTF-16 offset in s into a rune offset.
proc runesBefore(s: string, units: int): int =
  let runes = toRunes(s)
  var left = units
  for i, r in runes:
    if left <= 0:
      return i
    left -= utf16RuneLen(r)
  runes.len

## dragPoint returns where a drag is, in the view's coordinates.
proc dragPoint*(s: macSurface, info: id): tuple[x, y: float64] =
  let p = msgPointFromView(s.view, sel("convertPoint:fromView:"),
    msgPoint(info, sel("draggingLocation")), nil)
  (p.x, p.y)

proc registerSurfaceClass*() =
  registerDataDragClasses()
  proc mouseOf(kind: SurfaceEventKind,
               button: int): pointer =
    cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
      let s = theBackend.surfaceOf(self)
      if s == nil:
        return
      var btn = button
      if button == 2:
        let n = sendInt(ev, "buttonNumber")
        if n == 3 or n == 4:
          # The side buttons go back and forward, as keys do.
          s.sideButton(kind, n == 3, eventMods(ev))
          return
        btn = min(n, 2)
      elif button == 0 and kind == pointerDown:
        # A Control-click is a secondary click, until its release.
        s.ctrlClick = (eventMods(ev) and platform.modCtrl) != 0
      if button == 0 and s.ctrlClick:
        btn = 1
      if kind == pointerDown:
        if btn == 0:
          release(s.w.lastMouseDown)
          s.w.lastMouseDown = retain(ev)
        discard send(s.w.win, "makeFirstResponder:", argu(self))
      s.mouse(kind, ev, btn)
      if kind == pointerUp and button == 0:
        s.ctrlClick = false)
  proc commandOf(name: string): MethodDef =
    methodDef(name & ":",
      cast[pointer](proc(self: id, cmd: SEL, sender: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: surfaceCommand,
            text: name))), "v@:@")
  proc dragged(self: id, cmd: SEL, info: id): uint {.cdecl.} =
    let s = theBackend.surfaceOf(self)
    if s == nil:
      return 0
    s.nativeDataOperation(info)
  let methods = @[
    # Files dragged from other apps.
    methodDef("draggingEntered:", cast[pointer](dragged), "Q@:@"),
    methodDef("draggingUpdated:", cast[pointer](dragged), "Q@:@"),
    methodDef("draggingExited:",
      cast[pointer](proc(self: id, cmd: SEL, info: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.nativeDataEvent(info, dataDragLeave)), "v@:@"),
    methodDef("prepareForDragOperation:",
      cast[pointer](proc(self: id, cmd: SEL, info: id): bool {.cdecl.} =
        true), "B@:@"),
    methodDef("performDragOperation:",
      cast[pointer](proc(self: id, cmd: SEL, info: id): bool {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil:
          return false
        s.nativeDataEvent(info, dataDrop)), "B@:@"),
  ]
  discard classDef("MyNimSurfaceView", "NSView", @["NSTextInputClient"],
    methods & accessViewMethods() & @[
    methodDef("isFlipped",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    # The pointer goes through to the web views under the surface
    # where the content shows them (webview.nim).
    methodDef("hitTest:",
      cast[pointer](proc(self: id, cmd: SEL, p: NSPoint): id {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil and s.placed.len > 0:
          let local = msgPointFromView(self,
            sel("convertPoint:fromView:"), p, send(self, "superview"))
          if s.webViewAt(local.x, local.y) != nil:
            return nil
        sendSuperPoint(self, "MyNimSurfaceView", cmd, p)), "@@:{CGPoint=dd}"),
    methodDef("acceptsFirstResponder",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    methodDef("acceptsFirstMouse:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id): bool {.cdecl.} =
        true), "B@:@"),
    methodDef("mouseDownCanMoveWindow",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = false),
      "B@:"),
    methodDef("wantsUpdateLayer",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = true),
      "B@:"),
    methodDef("updateLayer",
      cast[pointer](proc(self: id, cmd: SEL) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil:
          return
        if s.framePass == caPass and send(self, "inLiveResize") == nil and
            (not s.resized or s.presentsWithTransaction()):
          # AppKit displays the view again before Core Animation
          # commits the frame drawn in this pass, as while the trackpad
          # scrolls. The next refresh draws it: as one just drew, not
          # at once; and after a frame presented with the transaction,
          # the frame would wait a second for a drawable, the layer's
          # two being taken until the commit. A frame for a new size
          # after one presented at once, as those of the display
          # link's ticks are, draws at once, or the layer would
          # stretch the last one meanwhile. A window that resizes, as
          # zooming animates it, displays the view for each of its
          # sizes within one pass of the run loop, committing each:
          # those frames draw at once too.
          s.lastFrame = getTime()
          s.requestFrame()
          return
        s.resized = false
        s.framePass = caPass
        s.lastFrame = getTime()
        discard s.send(platform.SurfaceEvent(kind: surfaceFrame))),
      "v@:"),
    methodDef("mynimTick:",
      cast[pointer](proc(self: id, cmd: SEL, link: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil or not s.due:
          # No frame was asked for since the last refresh.
          discard send(link, "setPaused:", argu(1))
          if s != nil:
            s.linkRunning = false
          return
        s.due = false
        if sendBool(send(self, "layer"), "needsDisplay"):
          # AppKit displays the view in this pass, as after a resize
          # (the view's needsDisplay tells nothing): the frame shows
          # with the window's changes then.
          return
        # The frame draws now, rather than when AppKit displays the
        # view, which would cost a pass of its display cycle and a
        # commit of Core Animation's transaction for each frame: the
        # renderer presents frames that change nothing else as soon as
        # drawn.
        s.resized = false
        s.framePass = caPass
        s.lastFrame = getTime()
        discard s.send(platform.SurfaceEvent(kind: surfaceFrame))),
      "v@:@"),
    methodDef("mynimTimer:",
      cast[pointer](proc(self: id, cmd: SEL, timer: id) {.cdecl.} =
        # A closed window's view lives until its timer fires.
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.timing = false
          discard send(self, "setNeedsDisplay:", argu(1))), "v@:@"),
    methodDef("setFrameSize:",
      cast[pointer](proc(self: id, cmd: SEL, size: NSSize) {.cdecl.} =
        sendSuperSize(self, "MyNimSurfaceView", cmd, size)
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.resized = true
          discard s.send(platform.SurfaceEvent(kind: surfaceResize))
          discard send(self, "setNeedsDisplay:", argu(1))), "v@:{CGSize=dd}"),
    methodDef("viewDidChangeBackingProperties",
      cast[pointer](proc(self: id, cmd: SEL) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.resized = true
          discard s.send(platform.SurfaceEvent(kind: surfaceResize))
          discard send(self, "setNeedsDisplay:", argu(1))), "v@:"),
    methodDef("becomeFirstResponder",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: surfaceFocus))
        true), "B@:"),
    methodDef("resignFirstResponder",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: surfaceBlur))
        true), "B@:"),
    methodDef("mouseDown:", mouseOf(pointerDown, 0), "v@:@"),
    methodDef("mouseUp:", mouseOf(pointerUp, 0), "v@:@"),
    methodDef("mouseDragged:", mouseOf(pointerMove, 0), "v@:@"),
    methodDef("rightMouseDown:", mouseOf(pointerDown, 1), "v@:@"),
    methodDef("rightMouseUp:", mouseOf(pointerUp, 1), "v@:@"),
    methodDef("rightMouseDragged:", mouseOf(pointerMove, 1), "v@:@"),
    methodDef("otherMouseDown:", mouseOf(pointerDown, 2), "v@:@"),
    methodDef("otherMouseUp:", mouseOf(pointerUp, 2), "v@:@"),
    methodDef("otherMouseDragged:", mouseOf(pointerMove, 2), "v@:@"),
    methodDef("mouseMoved:", mouseOf(pointerMove, 0), "v@:@"),
    methodDef("mouseEntered:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.inside = true
          s.applyCursor()), "v@:@"),
    methodDef("mouseExited:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.inside = false
          discard s.send(platform.SurfaceEvent(kind: pointerLeave))),
      "v@:@"),
    methodDef("cursorUpdate:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.applyCursor()), "v@:@"),
    methodDef("scrollWheel:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil:
          return
        let (x, y) = s.location(ev)
        var dx = msgFloat(ev, sel("scrollingDeltaX"))
        var dy = msgFloat(ev, sel("scrollingDeltaY"))
        let precise = sendBool(ev, "hasPreciseScrollingDeltas")
        if not precise:
          # A mouse wheel scrolls by lines: 40 DIPs, as in browsers.
          dx *= 40
          dy *= 40
        discard s.send(platform.SurfaceEvent(kind: pointerScroll,
          x: x, y: y, dx: -dx, dy: -dy, precise: precise,
          mods: eventMods(ev)))), "v@:@"),
    methodDef("keyDown:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil:
          return
        let mods = eventMods(ev)
        let ime = s.input.active and
          (mods and (platform.modSuper or platform.modCtrl)) == 0
        # A key typed while the input method composes is the input
        # method's alone, as Enter choosing a candidate or Escape
        # giving the composition up, as GTK's and IMM32's filtering
        # keeps them on Linux and Windows.
        if not ime or not s.hasMarkedText():
          discard s.send(platform.SurfaceEvent(kind: keyPressed,
            key: eventKey(ev), physicalKey: physicalKey(ev), mods: mods,
            repeat: sendBool(ev, "isARepeat")))
        # Input methods see the key while a text input has the focus;
        # they answer with insertText: or setMarkedText:.
        if ime:
          s.keyDown = true
          discard send(self, "interpretKeyEvents:", argu(nsArray(ev)))
          s.keyDown = false), "v@:@"),
    methodDef("keyUp:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: keyReleased,
            key: eventKey(ev), physicalKey: physicalKey(ev),
            mods: eventMods(ev)))), "v@:@"),
    methodDef("flagsChanged:",
      cast[pointer](proc(self: id, cmd: SEL, ev: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: modifiersChanged,
            mods: eventMods(ev)))), "v@:@"),
    commandOf("copy"), commandOf("cut"), commandOf("paste"),
    commandOf("selectAll"), commandOf("undo"), commandOf("redo"),
    commandOf("delete"),
    methodDef("pasteAsPlainText:",
      cast[pointer](proc(self: id, cmd: SEL, sender: id) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          discard s.send(platform.SurfaceEvent(kind: surfaceCommand,
            text: "pasteAndMatchStyle"))), "v@:@"),
    methodDef("validateMenuItem:",
      cast[pointer](proc(self: id, cmd: SEL, item: id): bool {.cdecl.} =
        true), "B@:@"),

    # NSTextInputClient
    methodDef("hasMarkedText",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        s != nil and s.hasMarkedText()), "B@:"),
    methodDef("markedRange",
      cast[pointer](proc(self: id, cmd: SEL): nsRange {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          return s.markedRange()
        nsRange(location: nsNotFound)), "{_NSRange=QQ}@:"),
    methodDef("selectedRange",
      cast[pointer](proc(self: id, cmd: SEL): nsRange {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          return s.selectedRange()
        nsRange(location: nsNotFound)), "{_NSRange=QQ}@:"),
    methodDef("setMarkedText:selectedRange:replacementRange:",
      cast[pointer](proc(self: id, cmd: SEL, text: id,
                         selected, replacement: nsRange) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.setMarkedText(stringOf(text), selected, replacement)),
      "v@:@@{_NSRange=QQ}{_NSRange=QQ}"),
    methodDef("unmarkText",
      cast[pointer](proc(self: id, cmd: SEL) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.unmarkText()), "v@:"),
    methodDef("validAttributesForMarkedText",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} = nsArray()),
      "@@:"),
    methodDef("attributedSubstringForProposedRange:actualRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange,
                         actual: ptr nsRange): id {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          var a: nsRange
          let res = s.substring(r, a, actual != nil)
          if actual != nil:
            actual[] = a
          return res
        nil), "@@:{_NSRange=QQ}^{_NSRange=QQ}"),
    methodDef("insertText:replacementRange:",
      cast[pointer](proc(self: id, cmd: SEL, text: id,
                         replacement: nsRange) {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil:
          s.insertText(stringOf(text), replacement)),
      "v@:@@{_NSRange=QQ}"),
    methodDef("characterIndexForPoint:",
      cast[pointer](proc(self: id, cmd: SEL, p: NSPoint): uint {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s != nil and s.input.client != nil:
          let window = msgRectToRect(s.w.win,
            sel("convertRectFromScreen:"), NSRect(origin: p))
          let local = msgConvertRectView(self,
            sel("convertRect:fromView:"), window, nil)
          let (index, ok) = s.input.client.indexForPoint(
            local.origin.x, local.origin.y)
          if ok:
            return uint(index)
        nsNotFound), "Q@:{CGPoint=dd}"),
    methodDef("firstRectForCharacterRange:actualRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange,
                         actual: ptr nsRange): NSRect {.cdecl.} =
        let s = theBackend.surfaceOf(self)
        if s == nil:
          return default(NSRect)
        var c = s.input.caret
        let client = s.input.client
        if client != nil:
          let rangeWanted = clientRange(r)
          if rangeWanted == nil:
            return default(NSRect)
          let (bounds, used, ok) = client.boundsForRange(rangeWanted[])
          if not ok:
            return default(NSRect)
          c = bounds
          if actual != nil:
            actual[] = nsRange(location: uint(used.start),
              length: uint(max(0, used.`end` - used.start)))
        let inWindow = msgConvertRectView(self,
          sel("convertRect:toView:"), NSRect(
            origin: NSPoint(x: c.x, y: c.y),
            size: NSSize(width: max(c.w, 1), height: c.h)), nil)
        msgRectToRect(s.w.win, sel("convertRectToScreen:"), inWindow)),
      "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}"),
    methodDef("doCommandBySelector:",
      cast[pointer](proc(self: id, cmd: SEL, c: SEL) {.cdecl.} = discard),
      "v@::"),
  ])
