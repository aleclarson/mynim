## compositor.nim (compositor.go): DirectComposition for windows
## without a redirection bitmap. A window with a material behind it
## has none (window.noRedirect), which hides what GDI and
## UpdateLayeredWindow draw in it and in its child windows, the
## controls of a hidden title bar among them. Those show through
## DirectComposition instead: a surface of premultiplied BGRA on a
## layered window without a redirection bitmap either, which blends
## over the webview as a layered window does. Native UI drawn in
## memory shows the same way on its surface's window; drawn on the
## GPU, through the renderer's swap chain, on a device of its own
## (d3d11.newComposed).
##
## The windows share a Direct3D 11 device and a DirectComposition
## device. When the GPU device is removed (a driver update, a GPU
## reset), which its removed event tells, or a draw finds the device
## invalid, both go, and every window's controls draw again with new
## ones. Controls that could not draw try again on a timer of the
## application window, later after each failure in a row.

var procDCompositionCreateDevice*: proc(a0, a1,
    a2: uint): uint {.stdcall.}

var
  guidIDXGIDevice* = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c")
  guidID3D11Device4* = guid("8992ab71-02e6-4b8d-ba48-b056dcda42c4")
  guidID3D11Texture2D* = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c")
  guidIDCompositionDevice* = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3")

## Vtable indices, from d3d11.h, d3d11_4.h and dcomp.h.
const
  d3dCtxUpdateSubresource* = 48 ## ID3D11DeviceContext
  d3dDevRegisterDeviceRemovedEvent* = 65 ## ID3D11Device4
  d3dDevUnregisterDeviceRemoved* = 66
  dcompDevCommit* = 3 ## IDCompositionDevice
  dcompDevCreateTargetForHwnd* = 6
  dcompDevCreateVisual* = 7
  dcompDevCreateSurface* = 8
  dcompDevCheckDeviceState* = 26
  dcompTargetSetRoot* = 3 ## IDCompositionTarget
  dcompVisualSetContent* = 15 ## IDCompositionVisual, whose overloads take a slot each
  dcompSurfaceBeginDraw* = 3 ## IDCompositionSurface
  dcompSurfaceEndDraw* = 4

  dxgiFormatB8G8R8A8* = 87'u
  dxgiAlphaPremultiplied* = 1'u

  infinite* = 0xFFFFFFFF'u32

## Forward declarations of procs defined below or in other files.
proc newComposition*(): tuple[c: composition, err: ref CatchableError]
proc free*(c: composition)
proc watch*(c: composition, appHwnd: uint)
proc backoff*(fails: int): Duration
proc loseComposition*(b: WinBackend, err: ref CatchableError)
proc draw*(c: compositor, dev: composition,
  px: ptr UncheckedArray[uint32], w, h: int32): ref CatchableError
proc composeLater*(b: WinBackend, at: MonoTime)

proc bindCompositor*() =
  if procDCompositionCreateDevice.isNil:
    let dcomp = systemDLL("dcomp.dll")
    if dcomp != 0:
      procDCompositionCreateDevice = cast[typeof(
        procDCompositionCreateDevice)](
        cast[pointer](procGetProcAddress(dcomp,
          cast[uint](cstring("DCompositionCreateDevice")))))

## compositionFor returns the device, made on first use, or nil when
## it cannot be made; after a failure it tries again at compRetry at
## the soonest, a second later, then longer after each failure in a
## row.
proc compositionFor*(b: WinBackend): composition =
  if not b.comp.isNil:
    return b.comp
  if getMonoTime() < b.compRetry:
    return nil
  let (c, err) = newComposition()
  if not err.isNil:
    when defined(mygoLog):
      stderr.writeLine("mynim: no DirectComposition: " & err.msg)
    b.compRetry = getMonoTime() + backoff(b.compFails)
    inc b.compFails
    return nil
  if c.software:
    when defined(mygoLog):
      stderr.writeLine(
        "mynim: DirectComposition draws with WARP, without the GPU")
  c.watch(b.appHwnd)
  b.comp = c
  c

proc newComposition*(): tuple[c: composition,
    err: ref CatchableError] =
  let c = composition()
  let (d3d, ctx, software, derr) = newDevice()
  if derr != "":
    return (nil, newException(CatchableError, "mynim: " & derr))
  c.d3d = d3d
  c.ctx = ctx
  c.software = software
  bindCompositor()
  if procDCompositionCreateDevice.isNil:
    c.free()
    return (nil, newException(CatchableError,
      "mynim: no DCompositionCreateDevice"))
  let dxgi = queryInterface(c.d3d, addr guidIDXGIDevice)
  if dxgi == 0:
    c.free()
    ## E_NOINTERFACE
    return (nil, hresultError("querying the DXGI device",
      0x80004002'u))
  let hr = procDCompositionCreateDevice(dxgi,
    cast[uint](addr guidIDCompositionDevice),
    cast[uint](addr c.dcomp))
  release(dxgi)
  if failed(hr):
    c.free()
    return (nil, hresultError("DCompositionCreateDevice", hr))
  (c, nil)

## backoff is how long to wait before trying again after fails
## failures in a row: a second, doubling up to a minute.
proc backoff*(fails: int): Duration =
  min(initDuration(seconds = int64(1 shl min(fails, 6))),
    initDuration(minutes = 1))

proc watchWait(a: tuple[event, appHwnd: uint]) =
  ## The DLL procs touch no GC memory.
  {.cast(gcsafe).}:
    discard procWaitForSingleObject(a.event, infinite)
    postMessage(a.appHwnd, wmAppDeviceRemoved, a.event, 0)

## watch has a thread wait for the GPU device to be removed and tell
## the application window (deviceRemoved). free signals the event
## too, which ends the thread; the main thread closes it.
proc watch*(c: composition, appHwnd: uint) =
  let dev = queryInterface(c.d3d, addr guidID3D11Device4)
  if dev == 0:
    return
  defer: release(dev)
  ## auto-reset, not signaled
  let event = procCreateEventW(0, 0, 0, 0)
  if event == 0:
    return
  if failed(comCall(dev, d3dDevRegisterDeviceRemovedEvent, event,
      cast[uint](addr c.cookie))):
    discard procCloseHandle(event)
    return
  c.removed = event
  ## The wait must not capture the ref c, which ARC would touch off
  ## the main thread: only the event and the window go.
  var th: Thread[tuple[event, appHwnd: uint]]
  createThread(th, watchWait, (event, appHwnd))

## deviceRemoved handles the message of a thread of watch, whose
## event was signaled: by the GPU device, gone, or by free.
proc deviceRemoved*(b: WinBackend, event: uint) =
  if not b.comp.isNil and b.comp.removed == event:
    b.loseComposition(newException(CatchableError,
      "mynim: the GPU device was removed"))
  discard procCloseHandle(event)

## lost reports whether the DirectComposition device is no longer
## valid, as when its GPU device was removed.
proc lost*(c: composition): bool =
  var valid: int32
  if failed(comCall(c.dcomp, dcompDevCheckDeviceState,
      cast[uint](addr valid))):
    return true
  valid == 0

proc free*(c: composition) =
  if c.removed != 0:
    let dev = queryInterface(c.d3d, addr guidID3D11Device4)
    if dev != 0:
      discard comCall(dev, d3dDevUnregisterDeviceRemoved,
        uint(c.cookie))
      release(dev)
    discard procSetEvent(c.removed) ## ends the thread of watch
    c.removed = 0
  for p in [addr c.dcomp, addr c.ctx, addr c.d3d]:
    if p[] != 0:
      release(p[])
      p[] = 0

## loseComposition drops the device after it failed, as when the GPU
## was reset, and what every window made with it. The controls draw
## again with a new device at once, or later when it fails again in
## a row.
proc loseComposition*(b: WinBackend, err: ref CatchableError) =
  when defined(mygoLog):
    stderr.writeLine(
      "mynim: DirectComposition failed, starting over: " & err.msg)
  for hwnd, c in b.captions:
    if hwnd == c.buttons and not c.comp.isNil:
      c.comp.free()
  for s in b.surfaces.values:
    if not s.comp.isNil:
      s.comp.free()
  if not b.comp.isNil:
    b.comp.free()
    b.comp = nil
  b.compRetry = getMonoTime()
  if b.compFails > 0:
    b.compRetry = b.compRetry + backoff(b.compFails - 1)
  inc b.compFails
  b.composeLater(b.compRetry)

## composeLater has the controls that could not draw draw again at
## the given time, or at an earlier one already set.
proc composeLater*(b: WinBackend, at: MonoTime) =
  if b.composeAt != MonoTime() and at >= b.composeAt:
    return
  b.composeAt = at
  let ms = max((at.ticks - getMonoTime().ticks +
    999_999) div 1_000_000, 0)
  discard procSetTimer(b.appHwnd, timerCompose, uint(ms), 0)

## recompose draws again, on timerCompose, the controls and the
## frames drawn in memory that do not show through the device: it
## was lost, or they could not draw.
proc recompose*(b: WinBackend) =
  discard procKillTimer(b.appHwnd, timerCompose)
  b.composeAt = MonoTime()
  for hwnd, c in b.captions:
    if hwnd != c.buttons or c.comp.isNil or
        not c.comp.dev.isNil:
      continue
    if getMonoTime() < c.comp.retry:
      b.composeLater(c.comp.retry)
      continue
    c.paint()
  ## Frames drawn in memory that could not show draw again.
  for s in b.surfaces.values:
    if s.comp.isNil or not s.comp.dev.isNil:
      continue
    if getMonoTime() < s.comp.retry:
      b.composeLater(s.comp.retry)
      continue
    s.requestFrame()

## newCompositor makes the compositor of the window hwnd.
proc newCompositor*(b: WinBackend, hwnd: uint): compositor =
  compositor(b: b, hwnd: hwnd)

## pixels returns room for n pixels.
proc pixels*(c: compositor, n: int): ptr UncheckedArray[uint32] =
  if c.px.len < n:
    c.px = newSeq[uint32](n)
  cast[ptr UncheckedArray[uint32]](addr c.px[0])

## show puts px, top-down rows of premultiplied BGRA w wide, on the
## window. When it cannot, the window draws again later (recompose);
## a device found invalid gives way to a new one (loseComposition).
proc show*(c: compositor, px: ptr UncheckedArray[uint32],
    w, h: int32) =
  if w <= 0 or h <= 0:
    return
  let b = c.b
  let dev = b.compositionFor()
  if dev.isNil:
    b.composeLater(b.compRetry)
    return
  let err = c.draw(dev, px, w, h)
  if err.isNil:
    b.compFails = 0
    c.fails = 0
    return
  c.free()
  if dev.lost():
    b.loseComposition(err)
    return
  ## The device is fine: this window alone tries again.
  when defined(mygoLog):
    stderr.writeLine(
      "mynim: cannot show a window's pixels through " &
      "DirectComposition: " & err.msg)
  c.retry = getMonoTime() + backoff(c.fails)
  inc c.fails
  b.composeLater(c.retry)

proc draw*(c: compositor, dev: composition,
    px: ptr UncheckedArray[uint32], w,
    h: int32): ref CatchableError =
  if c.dev != dev:
    c.free()
    var hr = comCall(dev.dcomp, dcompDevCreateTargetForHwnd, c.hwnd,
      1, cast[uint](addr c.target))
    if failed(hr):
      return hresultError(
        "IDCompositionDevice::CreateTargetForHwnd", hr)
    hr = comCall(dev.dcomp, dcompDevCreateVisual,
      cast[uint](addr c.visual))
    if failed(hr):
      return hresultError("IDCompositionDevice::CreateVisual", hr)
    hr = comCall(c.target, dcompTargetSetRoot, c.visual)
    if failed(hr):
      return hresultError("IDCompositionTarget::SetRoot", hr)
    c.dev = dev
  if c.surface == 0 or w != c.w or h != c.h:
    release(c.surface)
    c.surface = 0
    var hr = comCall(dev.dcomp, dcompDevCreateSurface, uint(uint32(w)),
      uint(uint32(h)), dxgiFormatB8G8R8A8, dxgiAlphaPremultiplied,
      cast[uint](addr c.surface))
    if failed(hr):
      return hresultError("IDCompositionDevice::CreateSurface", hr)
    c.w = w
    c.h = h
    hr = comCall(c.visual, dcompVisualSetContent, c.surface)
    if failed(hr):
      return hresultError("IDCompositionVisual::SetContent", hr)
  var tex: uint
  var offset: w32Point
  var hr = comCall(c.surface, dcompSurfaceBeginDraw, 0,
    cast[uint](addr guidID3D11Texture2D), cast[uint](addr tex),
    cast[uint](addr offset))
  if failed(hr):
    return hresultError("IDCompositionSurface::BeginDraw", hr)
  ## The surface can be part of an atlas: draw at the offset given.
  var box = [uint32(offset.x), uint32(offset.y), 0'u32,
    uint32(offset.x + w), uint32(offset.y + h), 1]
  discard comCall(dev.ctx, d3dCtxUpdateSubresource, tex, 0,
    cast[uint](addr box), cast[uint](addr px[0]), uint(uint32(w) * 4),
    0)
  release(tex)
  hr = comCall(c.surface, dcompSurfaceEndDraw)
  if failed(hr):
    return hresultError("IDCompositionSurface::EndDraw", hr)
  hr = comCall(dev.dcomp, dcompDevCommit)
  if failed(hr):
    return hresultError("IDCompositionDevice::Commit", hr)
  nil

proc free*(c: compositor) =
  for p in [addr c.surface, addr c.visual, addr c.target]:
    if p[] != 0:
      release(p[])
      p[] = 0
  c.dev = nil
  c.w = 0
  c.h = 0
