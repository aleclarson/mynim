## surface.nim (surface.go): the child window of a window that shows
## content mynim draws itself. Renderers draw into it with a swap
## chain, or the backend copies frames drawn in memory onto it.

const surfaceClass* = "MyGoSurface"

var
  surfaceClassRegistered = false
  surfaceCursors = initTable[Cursor, uint]()
  surfaceWheelLines = 0
  surfaceWheelLinesQueried = false

const
  wmPaint* = 0x000F'u32
  wmKillFocus* = 0x0008'u32
  wmSetCursor* = 0x0020'u32
  wmGetDlgCode* = 0x0087'u32
  wmKeyDown* = 0x0100'u32
  wmKeyUp* = 0x0101'u32
  wmChar* = 0x0102'u32
  wmSysKeyDown* = 0x0104'u32
  wmSysKeyUp* = 0x0105'u32
  wmSysChar* = 0x0106'u32
  wmImeStartComp* = 0x010D'u32
  wmImeEndComp* = 0x010E'u32
  wmImeComposition* = 0x010F'u32
  wmLButtonDown* = 0x0201'u32
  wmLButtonDblClk* = 0x0203'u32
  wmRButtonDown* = 0x0204'u32
  wmRButtonDblClk* = 0x0206'u32
  wmMButtonDown* = 0x0207'u32
  wmMButtonUp* = 0x0208'u32
  wmMButtonDblClk* = 0x0209'u32
  wmMouseWheel* = 0x020A'u32
  wmMouseHWheel* = 0x020E'u32
  wmXButtonDown* = 0x020B'u32
  wmXButtonUp* = 0x020C'u32
  wmXButtonDblClk* = 0x020D'u32
  wmAppCommand* = 0x0319'u32
  wmCaptureChanged* = 0x0215'u32
  wmImeSetContext* = 0x0281'u32
  wmImeChar* = 0x0286'u32
  wmGetObject* = 0x003D'u32
  wmImeRequest* = 0x0288'u32
  dlgcWantAllKeys* = 0x0004'u32
  dlgcWantChars* = 0x0080'u32
  iscShowUICompWindow* = 0x80000000'u32
  gcsCompStr* = 0x0008'u32
  gcsCursorPos* = 0x0080'u32
  gcsResultStr* = 0x0800'u32
  cfsPoint* = 0x0002'u32
  cfsExclude* = 0x0080'u32
  iaceDefault* = 0x0010'u32
  niCompositionStr* = 0x0015'u32
  cpsComplete* = 0x0001'u32
  cpsCancel* = 0x0004'u32
  spiGetWheelScrollLns* = 0x0068'u32
  tmeLeaveFlag* = 0x0002'u32

type
  paintStruct* = object
    hdc*: uint
    erase*: int32
    paint*: w32Rect
    restore*, incUpdate*: int32
    reserved*: array[32, byte]

  compositionForm* = object
    style*: uint32
    pos*: w32Point
    area*: w32Rect

  candidateForm* = object
    index*, style*: uint32
    pos*: w32Point
    area*: w32Rect

  trackMouseEvent* = object
    size*, flags*: uint32
    track*, hoverTime*: uint

## Forward declarations for procs of files included later.
proc composed*(s: w32Surface, ev: SurfaceEvent)
proc imeRequest*(s: w32Surface, wp, lp: uint): uint
proc getObject*(s: w32Surface, wp,
  lp: uint): tuple[r: uint, ok: bool]
proc destroyAccess*(s: w32Surface)
proc forwardMouse*(s: w32Surface, m: uint32, wp, lp: uint): bool
proc mouseLeft*(s: w32Surface)
proc webCursor*(s: w32Surface): bool
proc placeEmbedded*(w: w32Window)
proc commit*(l: webLayer)
proc free*(l: webLayer)
proc viaComposition*(s: w32Surface): bool
proc cursorHandle*(c: Cursor): uint
proc placeIME*(s: w32Surface)
proc wheelLines*(): int
proc imeString*(himc, which: uint): string
proc runeLen*(u: openArray[uint16]): int
proc vkKey*(vk: uint): Key
proc keyAndPosition*(vk, lp: uint, `release`: bool,
  modifiers: platform.Modifiers): tuple[k, physical: Key, ok: bool]
proc freeComp*(s: w32Surface)
proc free*(c: compositor)
proc pixels*(c: compositor, n: int): ptr UncheckedArray[uint32]
proc show*(c: compositor, px: ptr UncheckedArray[uint32],
  w, h: int32)
proc newCompositor*(b: WinBackend, hwnd: uint): compositor

proc registerSurfaceClass*() =
  if surfaceClassRegistered:
    return
  surfaceClassRegistered = true
  var wc = wndClassEx(wndProc: wndProcCallback,
    instance: instance(), className: u16(surfaceClass))
  wc.size = uint32(sizeof(wc))
  discard procRegisterClassExW(cast[uint](addr wc))

proc newSurface*(w: w32Window): w32Surface =
  registerSurfaceClass()
  let s = w32Surface(b: w.b, w: w)
  s.hwnd = createWindow(0, surfaceClass, "",
    wsChild or wsVisible or wsClipSiblings, 0, 0, 0, 0, w.hwnd)
  if s.hwnd == 0:
    return nil
  w.b.surfaces[s.hwnd] = s
  ## Input methods only come to text inputs.
  discard procImmAssociateContextEx(s.hwnd, 0, 0)
  s.acceptFileDrops()
  s.fit()
  s

## fit makes the surface fill the client area of its window.
proc fit*(s: w32Surface) =
  var r: w32Rect
  discard procGetClientRect(s.w.hwnd, cast[uint](addr r))
  discard procSetWindowPos(s.hwnd, 0, 0, 0,
    uint(uint32(r.right - r.left)), uint(uint32(r.bottom - r.top)),
    swpNoZOrder or swpNoActivate)

proc dpi*(s: w32Surface): int = dpiOf(s.w.hwnd)

proc toDIP*(s: w32Surface, v: int32): float64 =
  float64(v) * 96 / float64(s.dpi())

## native returns the surface's window, which a GPU renderer is about
## to draw into: in a window without a redirection bitmap, it
## composes the window from then on, and the frames drawn in memory
## let go of it.
method native*(s: w32Surface): SurfaceNative =
  s.freeComp()
  SurfaceNative(hwnd: s.hwnd, composed: s.viaComposition())

## viaComposition reports whether the frames show through
## DirectComposition: in a window without a redirection bitmap, and
## over web views.
proc viaComposition*(s: w32Surface): bool =
  s.w.noRedirect or not s.layer.isNil

## showsMaterial reports whether the window shows its material behind
## the content: it has one, and no redirection bitmap to cover it.
method showsMaterial*(s: w32Surface): bool =
  s.w.noRedirect and s.w.vibrancy != ""

proc freeComp*(s: w32Surface) =
  if not s.comp.isNil:
    s.comp.free()
    s.comp = nil

method size*(s: w32Surface): tuple[width, height, scale: float64] =
  var r: w32Rect
  discard procGetClientRect(s.hwnd, cast[uint](addr r))
  (s.toDIP(r.right - r.left), s.toDIP(r.bottom - r.top),
    float64(s.dpi()) / 96)

method requestFrame*(s: w32Surface) =
  discard procInvalidateRectW(s.hwnd, 0, 0)

## refreshRate returns the refresh rate of the monitor showing the
## window, in its current display mode.
method refreshRate*(s: w32Surface): float64 =
  let mi = monitorInfo(s.w.monitor())
  var dm: devMode
  dm.size = uint16(sizeof(dm))
  if procEnumDisplaySettingsW(cast[uint](addr mi.device[0]),
      enumCurrentSettings, cast[uint](addr dm)) == 0:
    return 0
  if dm.displayFrequency <= 1:
    return 0 ## the hardware's default rate, unknown
  float64(dm.displayFrequency)

method presentPixels*(s: w32Surface, pix: seq[byte], stride,
    width, height: int) =
  if pix.len < stride * height or width == 0 or height == 0:
    return
  if s.viaComposition():
    ## GDI draws nothing in a window without a redirection bitmap,
    ## and would draw under the web views: the frame shows through
    ## DirectComposition, with its alpha.
    if s.comp.isNil:
      s.comp = newCompositor(s.w.b, s.hwnd)
    let px = s.comp.pixels(width * height)
    for y in 0 ..< height:
      let src = cast[ptr UncheckedArray[uint32]](
        cast[pointer](addr pix[y * stride]))
      for x in 0 ..< width:
        px[y * width + x] = src[x]
    s.comp.show(px, int32(width), int32(height))
    return
  var dc = s.paintDC
  var got = false
  if dc == 0:
    dc = procGetDC(s.hwnd)
    got = true
  if got:
    defer: discard procReleaseDC(s.hwnd, dc)
  var bi = bitmapInfoHeader(width: int32(stride div 4),
    height: -int32(height), planes: 1, bitCount: 32)
  bi.size = uint32(sizeof(bi))
  discard procSetDIBitsToDevice(dc, 0, 0, uint(uint32(width)),
    uint(uint32(height)), 0, 0, 0, uint(uint32(height)),
    cast[uint](addr pix[0]), cast[uint](addr bi), 0)

method setCursor*(s: w32Surface, c: Cursor) =
  s.cursor = c
  var pt: w32Point
  discard procGetCursorPos(cast[uint](addr pt))
  discard procScreenToClient(s.hwnd, cast[uint](addr pt))
  var r: w32Rect
  discard procGetClientRect(s.hwnd, cast[uint](addr r))
  if pt.x >= r.left and pt.y >= r.top and pt.x < r.right and
      pt.y < r.bottom:
    discard procSetCursor(cursorHandle(c))

proc cursorHandle*(c: Cursor): uint =
  if surfaceCursors.hasKey(c):
    return surfaceCursors[c]
  const ids = [
    (cursorDefault, 32512'u), (cursorPointer, 32649'u),
    (cursorText, 32513'u), (cursorMove, 32646'u),
    (cursorResizeEW, 32644'u), (cursorResizeNS, 32645'u),
    (cursorResizeNWSE, 32642'u), (cursorResizeNESW, 32643'u),
    (cursorNotAllowed, 32648'u), (cursorCrosshair, 32515'u),
    (cursorGrab, 32649'u), (cursorGrabbing, 32646'u),
    # Windows has no cursors of one direction, of columns and
    # rows, or for vertical text: those of both directions and
    # the I-beam.
    (cursorResizeN, 32645'u), (cursorResizeS, 32645'u),
    (cursorResizeE, 32644'u), (cursorResizeW, 32644'u),
    (cursorResizeColumn, 32644'u), (cursorResizeRow, 32645'u),
    (cursorVerticalText, 32513'u)]
  if c == cursorNone:
    surfaceCursors[c] = 0 ## SetCursor(NULL) hides it
    return 0
  var id = 32512'u
  for (k, v) in ids:
    if k == c:
      id = v
      break
  let h = procLoadCursorW(0, id)
  surfaceCursors[c] = h
  h

method setTextInput*(s: w32Surface, t: TextInputState) =
  let active = t.active
  let caret = t.caret
  if s.input.active and s.input.client != t.client:
    s.clientComposition.reset()
    let himc = procImmGetContext(s.hwnd)
    if himc != 0:
      discard procImmNotifyIME(himc, niCompositionStr, cpsCancel, 0)
      discard procImmReleaseContext(s.hwnd, himc)
    s.reconvert = nil
  s.input = t
  if active != s.ime:
    s.ime = active
    if active:
      discard procImmAssociateContextEx(s.hwnd, 0, iaceDefault)
    else:
      s.reconvert = nil
      let himc = procImmGetContext(s.hwnd)
      if himc != 0:
        discard procImmNotifyIME(himc, niCompositionStr,
          cpsComplete, 0)
        discard procImmReleaseContext(s.hwnd, himc)
      discard procImmAssociateContextEx(s.hwnd, 0, 0)
  s.caret = caret
  if active:
    s.placeIME()

## placeIME puts the input method's composition and candidate
## windows at the caret.
proc placeIME*(s: w32Surface) =
  let himc = procImmGetContext(s.hwnd)
  if himc == 0:
    return
  defer: discard procImmReleaseContext(s.hwnd, himc)
  let dpi = s.dpi()
  let x = toPx(int(s.caret.x), dpi)
  let y = toPx(int(s.caret.y), dpi)
  let h = toPx(int(s.caret.h + 0.5), dpi)
  var cf = compositionForm(style: cfsPoint,
    pos: w32Point(x: x, y: y))
  discard procImmSetCompositionWnd(himc, cast[uint](addr cf))
  var cand = candidateForm(style: cfsExclude,
    pos: w32Point(x: x, y: y + h),
    area: w32Rect(left: x, top: y, right: x + 1, bottom: y + h))
  discard procImmSetCandidateWindow(himc, cast[uint](addr cand))

proc send*(s: w32Surface, ev: SurfaceEvent): bool =
  if ev.kind == pointerDown or ev.kind == surfaceBlur:
    s.clientComposition.reset()
  if s.w.closed:
    return false
  s.w.h.surfaceEvent(ev)

## modifierKey is whether the virtual key vk is Shift, Ctrl, Alt or a
## Windows key.
proc modifierKey*(vk: uint): bool =
  vk == uint(vkShift) or vk == uint(vkControl) or
    vk == uint(vkMenu) or vk == uint(vkLWin) or
    vk == uint(vkRWin) or (vk >= 0xA0'u and vk <= 0xA5'u)

proc mods*(): platform.Modifiers =
  var m: platform.Modifiers = 0
  proc down(vk: uint): bool =
    (procGetKeyState(vk) and 0x8000) != 0
  if down(vkShift):
    m = m or modShift
  if down(vkControl):
    m = m or modCtrl
  if down(vkMenu):
    m = m or modAlt
  if down(vkLWin) or down(vkRWin):
    m = m or modSuper
  m

proc pointer*(s: w32Surface, kind: SurfaceEventKind, lp: uint,
    button: int) =
  let x = int16(loword(lp))
  let y = int16(hiword(lp))
  discard s.send(SurfaceEvent(kind: kind,
    x: s.toDIP(int32(x)), y: s.toDIP(int32(y)), button: button,
    mods: mods()))

proc message*(s: w32Surface, hwnd: uint, m: uint32, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  case m
  of wmMouseMove, wmLButtonDown, wmLButtonDblClk, wmRButtonDown,
      wmRButtonDblClk, wmRButtonUp, wmMButtonDown, wmMButtonDblClk,
      wmMButtonUp, wmXButtonDown, wmXButtonDblClk, wmXButtonUp,
      wmMouseWheel, wmMouseHWheel:
    if s.forwardMouse(m, wp, lp):
      ## the web view under the pointer takes it
      return (0'u, true)
  of wmTimer:
    if wp == timerWebView:
      discard procKillTimer(hwnd, timerWebView)
      for v in s.w.webViews:
        if v.controller == 0 and v.webViewErr.isNil:
          v.createWebView()
      return (0'u, true)
  else:
    discard
  case m
  of wmPaint:
    var ps: paintStruct
    let dc = procBeginPaint(hwnd, cast[uint](addr ps))
    s.paintDC = dc
    discard s.send(SurfaceEvent(kind: surfaceFrame))
    s.paintDC = 0
    discard procEndPaint(hwnd, cast[uint](addr ps))
    return (0'u, true)
  of wmEraseBkgnd:
    return (1'u, true)
  of wmSize:
    if not s.layer.isNil:
      ## The web views keep their place in DIPs, in other pixels
      ## after a change of DPI.
      for v in s.w.webViews:
        v.placeEmbedded()
      s.layer.commit()
    discard s.send(SurfaceEvent(kind: surfaceResize))
    ## Draw at once, so the content follows the window while it is
    ## resized.
    discard procRedrawWindow(hwnd, 0, 0,
      rdwInvalidate or rdwUpdateNow)
    return (0'u, true)
  of wmMouseMove:
    if not s.tracking:
      var tme = trackMouseEvent(flags: tmeLeaveFlag, track: hwnd)
      tme.size = uint32(sizeof(tme))
      discard procTrackMouseEvent(cast[uint](addr tme))
      s.tracking = true
    s.pointer(pointerMove, lp, 0)
    return (0'u, true)
  of wmMouseLeave:
    s.tracking = false
    s.mouseLeft()
    discard s.send(SurfaceEvent(kind: pointerLeave))
    return (0'u, true)
  of wmLButtonDown, wmLButtonDblClk, wmRButtonDown, wmRButtonDblClk,
      wmMButtonDown, wmMButtonDblClk:
    var button = 0
    case m
    of wmRButtonDown, wmRButtonDblClk:
      button = 1
    of wmMButtonDown, wmMButtonDblClk:
      button = 2
    else:
      discard
    discard procSetFocus(hwnd)
    if s.buttons == 0:
      discard procSetCapture(hwnd)
    s.buttons = s.buttons or (1 shl button)
    s.pointer(pointerDown, lp, button)
    return (0'u, true)
  of wmLButtonUp, wmRButtonUp, wmMButtonUp:
    var button = 0
    case m
    of wmRButtonUp:
      button = 1
    of wmMButtonUp:
      button = 2
    else:
      discard
    s.buttons = s.buttons and not (1 shl button)
    if s.buttons == 0:
      discard procReleaseCapture()
    s.pointer(pointerUp, lp, button)
    if m == wmRButtonUp:
      ## WM_CONTEXTMENU
      return (0'u, false)
    return (0'u, true)
  of wmXButtonDown, wmXButtonDblClk, wmXButtonUp:
    ## The side buttons go back and forward, as keys do, as they are
    ## let go: Windows's apps go there then, as DefWindowProc sends
    ## WM_APPCOMMAND, which taking them leaves out.
    if m == wmXButtonUp:
      var k = keyBack
      if hiword(wp) == 2: ## XBUTTON2
        k = keyForward
      discard s.send(SurfaceEvent(kind: keyPressed, key: k,
        mods: mods()))
      discard s.send(SurfaceEvent(kind: keyReleased, key: k,
        mods: mods()))
    return (1'u, true)
  of wmAppCommand:
    ## Devices that send commands rather than keys or buttons.
    var k = keyUnknown
    case hiword(lp) and not 0xF000'u16
    of 1: ## APPCOMMAND_BROWSER_BACKWARD
      k = keyBack
    of 2: ## APPCOMMAND_BROWSER_FORWARD
      k = keyForward
    else:
      discard
    if k == keyUnknown:
      return (0'u, false)
    discard s.send(SurfaceEvent(kind: keyPressed, key: k,
      mods: mods()))
    discard s.send(SurfaceEvent(kind: keyReleased, key: k,
      mods: mods()))
    return (1'u, true)
  of wmCaptureChanged:
    s.buttons = 0
    if lp != hwnd:
      s.webCapture = nil
    return (0'u, true)
  of wmMouseWheel, wmMouseHWheel:
    var pt = w32Point(x: int32(int16(loword(lp))),
      y: int32(int16(hiword(lp))))
    discard procScreenToClient(hwnd, cast[uint](addr pt))
    let delta = float64(int16(hiword(wp)))
    let dist = delta / 120 * float64(wheelLines()) * 33
    var ev = SurfaceEvent(kind: pointerScroll,
      x: s.toDIP(pt.x), y: s.toDIP(pt.y), mods: mods(),
      precise: int(int(delta)) mod 120 != 0)
    if m == wmMouseWheel:
      ev.dy = -dist
    else:
      ev.dx = dist
    discard s.send(ev)
    return (0'u, true)
  of wmSetCursor:
    if loword(lp) == htClient:
      if s.webCursor():
        ## the page's
        return (1'u, true)
      discard procSetCursor(cursorHandle(s.cursor))
      return (1'u, true)
  of wmGetDlgCode:
    return (uint(dlgcWantAllKeys or dlgcWantChars), true)
  of wmSetFocus:
    discard s.send(SurfaceEvent(kind: surfaceFocus))
    return (0'u, true)
  of wmKillFocus:
    discard s.send(SurfaceEvent(kind: surfaceBlur))
    return (0'u, true)
  of wmKeyDown, wmSysKeyDown:
    s.clientComposition.reset()
    s.keyTaken = false
    let modifiers = mods()
    if modifierKey(wp):
      discard s.send(SurfaceEvent(kind: modifiersChanged,
        mods: modifiers))
    let (k, physical, ok) = keyAndPosition(wp, lp, false, modifiers)
    if ok:
      s.keyTaken = s.send(SurfaceEvent(kind: keyPressed, key: k,
        physicalKey: physical, mods: modifiers,
        `repeat`: (lp and (1'u shl 30)) != 0))
    ## Alt+F4, Alt+Space and F10 keep working.
    return (0'u, m == wmKeyDown)
  of wmKeyUp, wmSysKeyUp:
    let modifiers = mods()
    if modifierKey(wp):
      discard s.send(SurfaceEvent(kind: modifiersChanged,
        mods: modifiers))
    let (k, physical, ok) = keyAndPosition(wp, lp, true, modifiers)
    if ok:
      discard s.send(SurfaceEvent(kind: keyReleased, key: k,
        physicalKey: physical, mods: modifiers))
    return (0'u, m == wmKeyUp)
  of wmSysChar:
    if s.keyTaken:
      ## The content took Alt and the key, as a terminal does.
      return (0'u, true)
    ## Alt and a letter go to the window, which opens the menu of
    ## the letter: DefWindowProc would open the window's bar
    ## without it.
    if wp > uint(' '):
      discard procSendMessageW(s.w.hwnd, wmSysCommand, scKeyMenu, wp)
      return (0'u, true)
  of wmChar:
    let c = uint16(wp)
    if c >= 0xD800 and c < 0xDC00:
      s.high = c
      return (0'u, true)
    if c >= 0xDC00 and c < 0xE000 and s.high != 0:
      let r = Rune(((uint32(s.high) - 0xD800) shl 10) +
        (uint32(c) - 0xDC00) + 0x10000)
      s.high = 0
      discard s.send(SurfaceEvent(kind: textInput, text: $r))
      return (0'u, true)
    if c < 0x20 or c == 0x7F:
      ## control characters come as keys
      return (0'u, true)
    discard s.send(SurfaceEvent(kind: textInput,
      text: $Rune(c)))
    return (0'u, true)
  of wmImeSetContext:
    let r = procDefWindowProcW(hwnd, m, wp,
      lp and not uint(iscShowUICompWindow))
    return (r, true)
  of wmImeStartComp:
    s.placeIME()
    return (0'u, true)
  of wmImeComposition:
    let himc = procImmGetContext(hwnd)
    if himc == 0:
      return (0'u, true)
    if (lp and uint(gcsResultStr)) != 0:
      let text = imeString(himc, gcsResultStr)
      if text != "":
        s.composed(SurfaceEvent(kind: textInput, text: text))
    if (lp and uint(gcsCompStr)) != 0:
      let text = imeString(himc, gcsCompStr)
      let pos = procImmGetCompositionStrW(himc, gcsCursorPos, 0, 0)
      let units = utf16Units(text)
      let caret = runeLen(units[0 ..< min(int(pos), units.len)])
      s.composed(SurfaceEvent(kind: textComposition, text: text,
        caret: caret))
    discard procImmReleaseContext(hwnd, himc)
    s.placeIME()
    return (0'u, true)
  of wmImeEndComp:
    s.reconvert = nil
    let c = s.input.client
    if not c.isNil:
      s.clientComposition.`end`(c)
      return (0'u, true)
    discard s.send(SurfaceEvent(kind: textComposition))
    return (0'u, true)
  of wmImeChar:
    return (0'u, true)
  of wmImeRequest:
    return (s.imeRequest(wp, lp), true)
  of wmGetObject:
    let (r, ok) = s.getObject(wp, lp)
    return (r, ok)
  of wmDestroy:
    s.cancelDataDrag()
    s.destroyAccess()
    s.revokeFileDrops()
    s.freeComp()
    s.w.b.surfaces.del(hwnd)
    return (0'u, true)
  else:
    discard
  (0'u, false)

## runeLen is the number of runes a UTF-16 sequence decodes to.
proc runeLen*(u: openArray[uint16]): int =
  var i = 0
  while i < u.len:
    inc result
    let c = u[i]
    inc i
    if c >= 0xD800 and c < 0xDC00 and i < u.len and
        u[i] >= 0xDC00 and u[i] < 0xE000:
      inc i

## imeString reads a composition string of an input context.
proc imeString*(himc, which: uint): string =
  let n = procImmGetCompositionStrW(himc, which, 0, 0)
  if int32(n) <= 0:
    return ""
  var buf = newSeq[uint16](int(n) div 2)
  discard procImmGetCompositionStrW(himc, which,
    cast[uint](addr buf[0]), n)
  u16str(buf)

proc wheelLines*(): int =
  if not surfaceWheelLinesQueried:
    surfaceWheelLinesQueried = true
    var n: uint32
    if procSystemParametersInfoW(spiGetWheelScrollLns, 0,
        cast[uint](addr n), 0) != 0 and n > 0 and n < 100:
      surfaceWheelLines = int(n)
    else:
      surfaceWheelLines = 3
  surfaceWheelLines

## keyAndPosition returns the key of a WM_KEYDOWN or WM_KEYUP by
## virtual key, and by position (the scancode in lp). ok is false for
## a key to leave out: one whose virtual key is unmapped, unless a
## shortcut modifier is held and its position is a US key. Known
## virtual keys keep their meaning (Russian letters already use VK_A
## through VK_Z). A release is sent whatever the modifiers held now,
## so that a press sent as a chord is let go of even after Ctrl was.
proc keyAndPosition*(vk, lp: uint, `release`: bool,
    modifiers: platform.Modifiers): tuple[k, physical: Key, ok: bool] =
  let k = vkKey(vk)
  ## An input method (VK_PROCESSKEY) or injected Unicode text
  ## (VK_PACKET) keeps the key from the application: the scancode is
  ## not a shortcut.
  if vk == vkProcessKey or vk == vkPacket:
    return (k, keyUnknown, k != keyUnknown)
  var physical = keyUnknown
  ## Bit 24 is the extended flag: the keypad's slash shares the code
  ## of /.
  if (lp and (1'u shl 24)) == 0:
    physical = keyForScancode(uint16((lp shr 16) and 0xFF))
  if k == keyUnknown and
      not (`release` and physical != keyUnknown) and
      not keyByPosition(k, physical, modifiers):
    return (k, physical, false)
  (k, physical, true)

## vkKey maps a virtual key code to the key it stands for.
proc vkKey*(vk: uint): Key =
  if vk >= uint('A') and vk <= uint('Z'):
    return Key(int(keyA) + int(vk) - int('A'))
  if vk >= uint('0') and vk <= uint('9'):
    return Key(int(key0) + int(vk) - int('0'))
  if vk >= 0x60 and vk <= 0x69: ## the numeric keypad
    return Key(int(key0) + int(vk) - 0x60)
  if vk >= 0x70 and vk <= 0x7B:
    return Key(int(keyF1) + int(vk) - 0x70)
  case vk
  of 0x0D'u:
    keyEnter
  of 0x1B:
    keyEscape
  of 0x08:
    keyBackspace
  of 0x09:
    keyTab
  of 0x20:
    keySpace
  of 0x2E:
    keyDelete
  of 0x2D:
    keyInsert
  of 0x24:
    keyHome
  of 0x23:
    keyEnd
  of 0x21:
    keyPageUp
  of 0x22:
    keyPageDown
  of 0x25:
    keyLeft
  of 0x26:
    keyUp
  of 0x27:
    keyRight
  of 0x28:
    keyDown
  of 0xBD, 0x6D:
    keyMinus
  of 0xBB:
    keyEqual
  of 0xBC:
    keyComma
  of 0xBE, 0x6E:
    keyPeriod
  of 0xBF, 0x6F:
    keySlash
  of 0xBA:
    keySemicolon
  of 0xDE:
    keyQuote
  of 0xDB:
    keyBracketLeft
  of 0xDD:
    keyBracketRight
  of 0xDC:
    keyBackslash
  of 0xC0:
    keyBackquote
  of 0x5D:
    keyContextMenu
  of 0xA6: ## VK_BROWSER_BACK
    keyBack
  of 0xA7: ## VK_BROWSER_FORWARD
    keyForward
  else:
    keyUnknown

## surface returns the surface of a window created with
## WindowOptions.surface.
method surface*(w: w32Window): Surface =
  if w.surface.isNil:
    return nil
  w.surface
