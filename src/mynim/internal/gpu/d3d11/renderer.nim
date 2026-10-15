## Direct3D 11 resources and scene renderer for Windows native UI.

import std/[dynlib, monotimes, sets, tables, times]
import ../../scene as scene
import ../../gpu as gpu
import ./[com, device, shader]
when defined(windows):
  import ../../windows/win32 as win32

type
  Guid = object
    data1: uint32
    data2, data3: uint16
    data4: array[8, byte]
  BufferDesc = object
    byteWidth, usage, bindFlags, cpuAccessFlags, miscFlags,
      structureByteStride: uint32
  SubresourceData = object
    sysMem: uint
    sysMemPitch, sysMemSlice: uint32
  Texture2DDesc = object
    width, height, mipLevels, arraySize, format: uint32
    sampleCount, sampleQuality: uint32
    usage, bindFlags, cpuAccessFlags, miscFlags: uint32
  InputElement = object
    semanticName: cstring
    semanticIndex, format, inputSlot, alignedByteOffset,
      inputSlotClass, instanceDataStepRate: uint32
  RenderTargetBlend = object
    blendEnable: int32
    srcBlend, destBlend, blendOp: uint32
    srcBlendAlpha, destBlendAlpha, blendOpAlpha: uint32
    writeMask: uint8
    pad: array[3, byte]
  BlendDesc = object
    alphaToCoverage, independentBlend: int32
    renderTarget: array[8, RenderTargetBlend]
  RasterizerDesc = object
    fillMode, cullMode: uint32
    frontCounterClockwise: int32
    depthBias: int32
    depthBiasClamp, slopeScaledDepthBias: float32
    depthClip, scissor, multisample, antialiasedLine: int32
  SamplerDesc = object
    filter, addressU, addressV, addressW: uint32
    mipLodBias: float32
    maxAnisotropy, comparisonFunc: uint32
    borderColor: array[4, float32]
    minLod, maxLod: float32
  Viewport = object
    x, y, width, height, minDepth, maxDepth: float32
  Box = object
    left, top, front, right, bottom, back: uint32
  Mapped = object
    data: uint
    rowPitch, depthPitch: uint32
  SwapChainDesc1 = object
    width, height, format: uint32
    stereo: int32
    sampleCount, sampleQuality, bufferUsage, bufferCount: uint32
    scaling, swapEffect, alphaMode, flags: uint32
  Texture = object
    tex, srv, rtv: uint
    width, height: int
    generation, version, lastFrame: uint64
  CanvasTexture = ref object
    texture: Texture
    builder: gpu.Builder
    version: uint64
    lastFrame: uint64
  Renderer* = ref object
    hwnd: uint
    device, context, factory, swapChain, swapChain2, rtv: uint
    dcomp, target, visual: uint
    width, height, bufferWidth, bufferHeight: int
    resizing: bool
    resizedAt: MonoTime
    warp: bool
    vs, ps, passVs, downPs, blurPs: uint
    layout, blend, holeBlend, raster, sampler: uint
    constantBuffer, passBuffer, instanceBuffer: uint
    instanceCapacity: int
    mask, color, grab: Texture
    backdrop: array[2, Texture]
    images: Table[uint64, Texture]
    canvases: Table[uint64, CanvasTexture]
    effects: Table[uint, tuple[effect: ref scene.Effect, shader: uint]]
    frame: uint64
    drawing: uint
    composed: bool
    builder: gpu.Builder

const
  iidDxgiDevice = Guid(data1: 0x54ec77fa, data2: 0x1377, data3: 0x44e6,
    data4: [0x8c'u8, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c])
  iidDxgiDevice1 = Guid(data1: 0x77db970f, data2: 0x6276, data3: 0x48ba,
    data4: [0xba'u8, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c])
  iidDxgiFactory2 = Guid(data1: 0x50c83a1c, data2: 0xe072, data3: 0x4c48,
    data4: [0x87'u8, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0])
  iidSwapChain2 = Guid(data1: 0xa8be2ac4'u32, data2: 0x199f, data3: 0x4946,
    data4: [0xb3'u8, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7])
  iidTexture2D = Guid(data1: 0x6f15aaf2, data2: 0xd208, data3: 0x4e89,
    data4: [0x9a'u8, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c])
  iidDCompositionDevice = Guid(data1: 0xc37ea93a'u32, data2: 0xe7aa, data3: 0x450d,
    data4: [0xb1'u8, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3])

  deviceCreateBuffer = 3
  deviceCreateTexture2D = 5
  deviceCreateShaderResourceView = 7
  deviceCreateRenderTargetView = 9
  deviceCreateInputLayout = 11
  deviceCreateVertexShader = 12
  deviceCreatePixelShader = 15
  deviceCreateBlendState = 20
  deviceCreateRasterizerState = 22
  deviceCreateSamplerState = 23

  contextViewGetResource = 7
  contextVsSetConstantBuffers = 7
  contextPsSetShaderResources = 8
  contextPsSetShader = 9
  contextPsSetSamplers = 10
  contextVsSetShader = 11
  contextMap = 14
  contextUnmap = 15
  contextPsSetConstantBuffers = 16
  contextIaSetInputLayout = 17
  contextIaSetVertexBuffers = 18
  contextDrawInstanced = 21
  contextIaSetPrimitiveTopology = 24
  contextOmSetRenderTargets = 33
  contextOmSetBlendState = 35
  contextRsSetState = 43
  contextRsSetViewports = 44
  contextRsSetScissorRects = 45
  contextCopySubresourceRegion = 46
  contextUpdateSubresource = 48
  contextClearRenderTargetView = 50
  contextClearState = 110
  contextFlush = 111
  dxgiDeviceGetAdapter = 7
  dxgiDeviceSetMaxLatency = 12
  dxgiGetParent = 6
  factoryMakeWindowAssociation = 8
  factoryCreateSwapChainForHwnd = 15
  factoryCreateSwapChainForComposition = 24
  swapChainPresent = 8
  swapChainGetBuffer = 9
  swapChainResizeBuffers = 13
  dcompCommit = 3
  dcompCreateTarget = 6
  dcompCreateVisual = 7
  dcompTargetSetRoot = 3
  dcompVisualSetContent = 15

  formatR32G32B32A32Float = 2'u32
  formatR8G8B8A8Unorm = 28'u32
  formatB8G8R8A8Unorm = 87'u32
  formatR8Unorm = 61'u32
  usageDefault = 0'u32
  usageDynamic = 2'u32
  bindVertexBuffer = 0x1'u32
  bindConstantBuffer = 0x4'u32
  bindShaderResource = 0x8'u32
  bindRenderTarget = 0x20'u32
  cpuAccessWrite = 0x10000'u32
  mapWriteDiscard = 4'u32
  topologyTriangleStrip = 5'u32

type DCompCreateDeviceProc = proc(dxgiDevice: uint; iid: pointer;
    compositionDevice: ptr uint): uint {.stdcall.}

when defined(windows):
  type DwmFlushProc = proc(): uint {.stdcall.}

const resizeSettleMilliseconds = 1000'u

var
  dcompLibrary: LibHandle
  procDCompCreateDevice: DCompCreateDeviceProc

when defined(windows):
  var
    dwmLibrary: LibHandle
    procDwmFlush: DwmFlushProc

when defined(windows):
  const settleTimer = 0x6d79'u

  proc resizeSettled(hwnd, msg, id, time: uint): uint
      {.stdcall, gcsafe.} =
    discard win32.procKillTimer(hwnd, id)
    discard win32.procInvalidateRectW(hwnd, 0, 0)
    0

  proc armResizeSettle(r: Renderer) =
    discard win32.procSetTimer(r.hwnd, settleTimer,
      resizeSettleMilliseconds, cast[uint](resizeSettled))

  proc flushDwm() =
    if procDwmFlush.isNil:
      dwmLibrary = loadLib(device.systemDir() & "\\dwmapi.dll")
      if dwmLibrary.isNil:
        return
      let address = symAddr(dwmLibrary, "DwmFlush")
      if address.isNil:
        unloadLib(dwmLibrary)
        dwmLibrary = nil
        return
      procDwmFlush = cast[DwmFlushProc](address)
    discard procDwmFlush()

template cAddress(value: untyped): uint = cast[uint](unsafeAddr value)
proc pointerValue(value: pointer): uint {.inline.} = cast[uint](value)
proc address[T](value: var T): uint {.inline.} = cast[uint](addr value)
proc hrError(action: string; hr: uint): string =
  "d3d11: " & action & " failed (HRESULT " & $uint32(hr) & ")"

proc init(r: Renderer): string
proc release*(r: Renderer)

proc new*(hwnd: uint; composed = false):
    tuple[renderer: Renderer, error: string] =
  ## Creates a D3D11 renderer for an opaque HWND, using WARP if no GPU exists.
  if hwnd == 0:
    return (nil, "d3d11: no window")
  let (dev, ctx, software, error) = device.newDevice()
  if error.len > 0:
    return (nil, error)
  result.renderer = Renderer(hwnd: hwnd, device: dev, context: ctx,
    composed: composed,
    warp: software, images: initTable[uint64, Texture](),
    canvases: initTable[uint64, CanvasTexture](),
    effects: initTable[uint, tuple[effect: ref scene.Effect, shader: uint]]())
  result.error = result.renderer.init()
  if result.error.len > 0:
    result.renderer.release()
    result.renderer = nil

proc init(r: Renderer): string =
  var dxgiDevice, adapter, dxgiDevice1: uint
  if com.failed(com.call(r.device, 0, cAddress(iidDxgiDevice),
      address(dxgiDevice))):
    return "d3d11: no DXGI device"
  defer: com.release(dxgiDevice)

  ## Keep one frame queued ahead of the display, not three, to reduce input
  ## latency while frames follow one another.
  if not com.failed(com.call(r.device, 0, cAddress(iidDxgiDevice1),
      address(dxgiDevice1))):
    discard com.call(dxgiDevice1, dxgiDeviceSetMaxLatency, 1)
    com.release(dxgiDevice1)
  if com.failed(com.call(dxgiDevice, dxgiDeviceGetAdapter,
      address(adapter))):
    return "d3d11: no adapter"
  defer: com.release(adapter)
  if com.failed(com.call(adapter, dxgiGetParent, cAddress(iidDxgiFactory2),
      address(r.factory))):
    return "d3d11: DXGI 1.2 is required"

  let (code, shaderError) = shader.shaderCode()
  if shaderError.len > 0:
    return shaderError
  for entry in [
      (code.vertex, deviceCreateVertexShader, "vertex"),
      (code.pixel, deviceCreatePixelShader, "pixel"),
      (code.passVertex, deviceCreateVertexShader, "pass vertex"),
      (code.down, deviceCreatePixelShader, "down"),
      (code.blur, deviceCreatePixelShader, "blur")]:
    if entry[0].len == 0:
      return "d3d11: missing " & entry[2] & " shader bytecode"
    var shaderHandle: uint
    let hr = com.call(r.device, entry[1],
      pointerValue(unsafeAddr entry[0][0]), uint(entry[0].len), 0,
      address(shaderHandle))
    if com.failed(hr):
      return "d3d11: cannot create the " & entry[2] & " shader"
    case entry[2]
    of "vertex": r.vs = shaderHandle
    of "pixel": r.ps = shaderHandle
    of "pass vertex": r.passVs = shaderHandle
    of "down": r.downPs = shaderHandle
    of "blur": r.blurPs = shaderHandle
    else: discard

  let names = ["RECT", "RADII", "INNER", "COLOR", "COLOR", "COLOR",
    "GRAD", "UV", "CLIP", "CLIPR", "PARAMS", "TRANSFORM", "TRANSFORM",
    "TRANSFORM"]
  let indices = [0'u32, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 1, 2]
  var nameStorage: array[14, string]
  var elements: array[14, InputElement]
  for i, name in names:
    nameStorage[i] = name & '\0'
    elements[i] = InputElement(
      semanticName: cast[cstring](addr nameStorage[i][0]),
      semanticIndex: indices[i], format: formatR32G32B32A32Float,
      alignedByteOffset: uint32(16 * i), inputSlotClass: 1,
      instanceDataStepRate: 1)
  let layoutHr = com.call(r.device, deviceCreateInputLayout,
    pointerValue(addr elements[0]), uint(elements.len),
    pointerValue(unsafeAddr code.vertex[0]), uint(code.vertex.len),
    address(r.layout))
  if com.failed(layoutHr):
    return "d3d11: cannot create the input layout"

  var blendDesc: BlendDesc
  blendDesc.renderTarget[0] = RenderTargetBlend(
    blendEnable: 1, srcBlend: 2, destBlend: 17, blendOp: 1,
    srcBlendAlpha: 2, destBlendAlpha: 19, blendOpAlpha: 1, writeMask: 0xf)
  if com.failed(com.call(r.device, deviceCreateBlendState,
      address(blendDesc), address(r.blend))):
    return "d3d11: cannot create the blend state"
  blendDesc.renderTarget[0].srcBlend = 1
  blendDesc.renderTarget[0].srcBlendAlpha = 1
  if com.failed(com.call(r.device, deviceCreateBlendState,
      address(blendDesc), address(r.holeBlend))):
    return "d3d11: cannot create the blend state of holes"

  let rasterDesc = RasterizerDesc(fillMode: 3, cullMode: 1,
    depthClip: 1, scissor: 1)
  if com.failed(com.call(r.device, deviceCreateRasterizerState,
      cAddress(rasterDesc), address(r.raster))):
    return "d3d11: cannot create the rasterizer state"
  let samplerDesc = SamplerDesc(filter: 0x15, addressU: 3,
    addressV: 3, addressW: 3, comparisonFunc: 1, maxLod: high(float32))
  if com.failed(com.call(r.device, deviceCreateSamplerState,
      cAddress(samplerDesc), address(r.sampler))):
    return "d3d11: cannot create the sampler"

  var buffer = BufferDesc(byteWidth: 16, usage: usageDefault,
    bindFlags: bindConstantBuffer)
  if com.failed(com.call(r.device, deviceCreateBuffer,
      address(buffer), 0, address(r.constantBuffer))):
    return "d3d11: cannot create the constant buffer"
  buffer.byteWidth = uint32(sizeof(gpu.Pass))
  if com.failed(com.call(r.device, deviceCreateBuffer,
      address(buffer), 0, address(r.passBuffer))):
    return "d3d11: cannot create the constant buffer of passes"

proc releaseTexture(t: var Texture) =
  com.release(t.rtv)
  com.release(t.srv)
  com.release(t.tex)
  t.width = 0
  t.height = 0

proc release*(r: Renderer) =
  ## Releases the renderer's D3D objects. Calling this more than once is safe.
  if r.isNil:
    return
  when defined(windows):
    discard win32.procKillTimer(r.hwnd, settleTimer)
  r.builder.release()
  if r.context != 0:
    discard com.call(r.context, contextClearState)
    discard com.call(r.context, contextFlush)
  for _, texture in r.images.mpairs:
    texture.releaseTexture()
  r.images.clear()
  for _, canvas in r.canvases.mpairs:
    if canvas != nil:
      canvas.builder.release()
      canvas.texture.releaseTexture()
  r.canvases.clear()
  r.mask.releaseTexture()
  r.color.releaseTexture()
  r.grab.releaseTexture()
  for i in 0 ..< r.backdrop.len:
    r.backdrop[i].releaseTexture()
  for _, effect in r.effects.mpairs:
    var shader = effect.shader
    com.release(shader)
  r.effects.clear()
  for handle in [addr r.visual, addr r.target, addr r.dcomp,
      addr r.rtv, addr r.swapChain2, addr r.swapChain,
      addr r.instanceBuffer, addr r.constantBuffer, addr r.passBuffer,
      addr r.sampler, addr r.raster, addr r.holeBlend, addr r.blend,
      addr r.layout, addr r.blurPs, addr r.downPs, addr r.passVs,
      addr r.ps, addr r.vs, addr r.factory, addr r.context, addr r.device]:
    com.release(handle[])
  r.width = 0
  r.height = 0

proc setSourceSize(r: Renderer; width, height: int): string =
  if r.swapChain2 == 0 or r.composed:
    return
  let hr = com.call(r.swapChain2, 29, uint(width), uint(height))
  if com.failed(hr):
    result = "d3d11: cannot set the swap chain source size (HRESULT " &
      $uint32(hr) & ")"

proc createComposedSwapChain(r: Renderer; desc: SwapChainDesc1): string

proc buffers(r: Renderer; width, height, bufferWidth, bufferHeight,
             count: int): string =
  com.release(r.rtv)
  if r.swapChain == 0:
    let desc = SwapChainDesc1(width: uint32(bufferWidth),
      height: uint32(bufferHeight),
      format: formatB8G8R8A8Unorm, sampleCount: 1, bufferUsage: 0x20,
      bufferCount: uint32(count), scaling: 0, swapEffect: 4)
    if r.composed:
      result = r.createComposedSwapChain(desc)
      if result.len > 0:
        return
    else:
      let hr = com.call(r.factory, factoryCreateSwapChainForHwnd,
        r.device, r.hwnd, cAddress(desc), 0, 0, address(r.swapChain))
      if com.failed(hr):
        return hrError("cannot create the swap chain", hr)
      const noAltEnter = 2'u
      discard com.call(r.factory, factoryMakeWindowAssociation,
        r.hwnd, noAltEnter)
    discard com.call(r.swapChain, 0, cAddress(iidSwapChain2),
      address(r.swapChain2))
  else:
    let hr = com.call(r.swapChain, swapChainResizeBuffers, uint(count),
      uint(bufferWidth), uint(bufferHeight), 0, 0)
    if com.failed(hr):
      return hrError("cannot resize the swap chain", hr)
  if (let error = r.setSourceSize(width, height); error.len > 0):
    return error

  var backBuffer: uint
  let getHr = com.call(r.swapChain, swapChainGetBuffer, 0,
    cAddress(iidTexture2D), address(backBuffer))
  if com.failed(getHr):
    return hrError("no swap-chain back buffer", getHr)
  defer: com.release(backBuffer)
  let targetHr = com.call(r.device, deviceCreateRenderTargetView,
    backBuffer, 0, address(r.rtv))
  if com.failed(targetHr):
    return hrError("cannot create the back-buffer render target", targetHr)
  r.width = width
  r.height = height
  r.bufferWidth = bufferWidth
  r.bufferHeight = bufferHeight

proc bindDComp(): bool =
  if procDCompCreateDevice != nil:
    return true
  dcompLibrary = loadLib(device.systemDir() & "\\dcomp.dll")
  if dcompLibrary.isNil:
    return false
  let address = symAddr(dcompLibrary, "DCompositionCreateDevice")
  if address.isNil:
    unloadLib(dcompLibrary)
    dcompLibrary = nil
    return false
  procDCompCreateDevice = cast[DCompCreateDeviceProc](address)
  true

proc createComposedSwapChain(r: Renderer; desc: SwapChainDesc1): string =
  if not bindDComp():
    return "d3d11: no DirectComposition"
  var dxgiDevice: uint
  let queryHr = com.call(r.device, 0, cAddress(iidDxgiDevice),
    address(dxgiDevice))
  if com.failed(queryHr):
    return "d3d11: no DXGI device for DirectComposition"
  let createHr = procDCompCreateDevice(dxgiDevice,
    cast[pointer](unsafeAddr iidDCompositionDevice), addr r.dcomp)
  com.release(dxgiDevice)
  if com.failed(createHr):
    return hrError("cannot create the DirectComposition device", createHr)

  var composedDesc = desc
  composedDesc.swapEffect = 3
  composedDesc.alphaMode = 1
  let swapHr = com.call(r.factory, factoryCreateSwapChainForComposition,
    r.device, cAddress(composedDesc), 0, address(r.swapChain))
  if com.failed(swapHr):
    return hrError("cannot create the composed swap chain", swapHr)
  let targetHr = com.call(r.dcomp, dcompCreateTarget, r.hwnd, 1,
    address(r.target))
  if com.failed(targetHr):
    return hrError("cannot create the composition target", targetHr)
  let visualHr = com.call(r.dcomp, dcompCreateVisual, address(r.visual))
  if com.failed(visualHr):
    return hrError("cannot create the composition visual", visualHr)
  let contentHr = com.call(r.visual, dcompVisualSetContent, r.swapChain)
  if com.failed(contentHr):
    return hrError("cannot set the composition visual content", contentHr)
  let rootHr = com.call(r.target, dcompTargetSetRoot, r.visual)
  if com.failed(rootHr):
    return hrError("cannot set the composition root", rootHr)
  let commitHr = com.call(r.dcomp, dcompCommit)
  if com.failed(commitHr):
    return hrError("cannot commit the composition", commitHr)

proc resize(r: Renderer; width, height: int): string =
  if width <= 0 or height <= 0:
    return
  if r.swapChain != 0 and width == r.width and height == r.height:
    if r.resizing and getMonoTime() - r.resizedAt >=
        initDuration(milliseconds = int64(resizeSettleMilliseconds div 2)):
      r.resizing = false
      return r.buffers(width, height, width, height, 2)
    return
  if r.swapChain == 0 or r.swapChain2 == 0:
    return r.buffers(width, height, width, height, 2)
  r.resizedAt = getMonoTime()
  when defined(windows):
    r.armResizeSettle()
  if r.resizing and width <= r.bufferWidth and height <= r.bufferHeight:
    if (let error = r.setSourceSize(width, height); error.len > 0):
      return error
    r.width = width
    r.height = height
    return
  r.resizing = true
  r.buffers(width, height, width + width div 4 + 64,
    height + height div 4 + 64, 3)

proc newTexture(r: Renderer; t: var Texture; width, height: int;
                format: uint32; pixels: openArray[byte]; bpp: int): string =
  t.releaseTexture()
  let desc = Texture2DDesc(width: uint32(width), height: uint32(height),
    mipLevels: 1, arraySize: 1, format: format, sampleCount: 1,
    usage: usageDefault, bindFlags: bindShaderResource)
  var initData: SubresourceData
  var initPtr = 0'u
  if pixels.len >= width * height * bpp and pixels.len > 0:
    initData = SubresourceData(sysMem: pointerValue(unsafeAddr pixels[0]),
      sysMemPitch: uint32(width * bpp))
    initPtr = address(initData)
  let textureHr = com.call(r.device, deviceCreateTexture2D,
    cAddress(desc), initPtr, address(t.tex))
  if com.failed(textureHr):
    return hrError("cannot create a " & $width & "x" & $height & " texture", textureHr)
  let viewHr = com.call(r.device, deviceCreateShaderResourceView,
    t.tex, 0, address(t.srv))
  if com.failed(viewHr):
    com.release(t.tex)
    return hrError("cannot create a texture view", viewHr)
  t.width = width
  t.height = height

proc newTarget(r: Renderer; t: var Texture; width, height: int;
               drawn: bool): string =
  t.releaseTexture()
  var desc = Texture2DDesc(width: uint32(width), height: uint32(height),
    mipLevels: 1, arraySize: 1, format: formatB8G8R8A8Unorm,
    sampleCount: 1, usage: usageDefault, bindFlags: bindShaderResource)
  if drawn:
    desc.bindFlags = desc.bindFlags or bindRenderTarget
  let textureHr = com.call(r.device, deviceCreateTexture2D,
    cAddress(desc), 0, address(t.tex))
  if com.failed(textureHr):
    return hrError("cannot create a " & $width & "x" & $height & " target", textureHr)
  let viewHr = com.call(r.device, deviceCreateShaderResourceView,
    t.tex, 0, address(t.srv))
  if com.failed(viewHr):
    t.releaseTexture()
    return hrError("cannot create a target view", viewHr)
  if drawn:
    let targetHr = com.call(r.device, deviceCreateRenderTargetView,
      t.tex, 0, address(t.rtv))
    if com.failed(targetHr):
      t.releaseTexture()
      return hrError("cannot create a target render view", targetHr)
  t.width = width
  t.height = height

proc fitBackdrop(r: Renderer; b: gpu.Builder): string =
  let (width, height) = b.backdropSize()
  var areaWidth, areaHeight: int
  for backdrop in b.backdrops:
    areaWidth = max(areaWidth,
      backdrop.area.max.x - backdrop.area.min.x)
    areaHeight = max(areaHeight,
      backdrop.area.max.y - backdrop.area.min.y)
  if areaWidth > r.grab.width or areaHeight > r.grab.height:
    result = r.newTarget(r.grab, max(areaWidth + areaWidth div 4,
      r.grab.width), max(areaHeight + areaHeight div 4, r.grab.height), false)
    if result.len > 0:
      return
  if width > r.backdrop[0].width or height > r.backdrop[0].height:
    let targetWidth = max(width + width div 4, r.backdrop[0].width)
    let targetHeight = max(height + height div 4, r.backdrop[0].height)
    for i in 0 ..< r.backdrop.len:
      result = r.newTarget(r.backdrop[i], targetWidth, targetHeight, true)
      if result.len > 0:
        return

proc pass(r: Renderer; pixelShader, source: uint; target: var Texture;
          width, height: int; constants: gpu.Pass) =
  let ctx = r.context
  discard com.call(ctx, contextUpdateSubresource, r.passBuffer, 0, 0,
    cAddress(constants), 0, 0)
  discard com.call(ctx, contextOmSetRenderTargets, 1, address(target.rtv), 0)
  let viewport = Viewport(width: float32(target.width),
    height: float32(target.height), maxDepth: 1)
  discard com.call(ctx, contextRsSetViewports, 1, cAddress(viewport))
  let scissor = gpu.Scissor(right: int32(width), bottom: int32(height))
  discard com.call(ctx, contextRsSetScissorRects, 1, cAddress(scissor))
  discard com.call(ctx, contextPsSetShader, pixelShader, 0, 0)
  var sourceView = source
  discard com.call(ctx, contextPsSetShaderResources, 4, 1,
    address(sourceView))
  discard com.call(ctx, contextDrawInstanced, 4, 1, 0, 0)
  sourceView = 0
  discard com.call(ctx, contextPsSetShaderResources, 4, 1,
    address(sourceView))

proc readBackdrop(r: Renderer; backdrop: scene.Backdrop): string =
  let ctx = r.context
  var none: array[5, uint]
  discard com.call(ctx, contextPsSetShaderResources, 0, uint(none.len),
    address(none[0]))
  var backBuffer: uint
  discard com.call(r.drawing, contextViewGetResource, address(backBuffer))
  if backBuffer == 0:
    return "d3d11: cannot read the drawing target for an effect"
  let box = Box(left: uint32(backdrop.area.min.x),
    top: uint32(backdrop.area.min.y), right: uint32(backdrop.area.max.x),
    bottom: uint32(backdrop.area.max.y), back: 1)
  discard com.call(ctx, contextCopySubresourceRegion, r.grab.tex,
    0, 0, 0, 0, backBuffer, 0, cAddress(box))
  com.release(backBuffer)
  discard com.call(ctx, contextOmSetBlendState, 0, 0, 0xffffffff'u)
  discard com.call(ctx, contextIaSetInputLayout, 0)
  discard com.call(ctx, contextVsSetShader, r.passVs, 0, 0)
  discard com.call(ctx, contextPsSetConstantBuffers, 1, 1,
    address(r.passBuffer))
  let (width, height) = backdrop.size()
  r.pass(r.downPs, r.grab.srv, r.backdrop[0], width, height,
    gpu.downPass(backdrop,
      [int32(backdrop.area.min.x), int32(backdrop.area.min.y)]))
  if backdrop.radius > 0:
    r.pass(r.blurPs, r.backdrop[0].srv, r.backdrop[1], width, height,
      gpu.blurPass(backdrop, [1'i32, 0]))
    r.pass(r.blurPs, r.backdrop[1].srv, r.backdrop[0], width, height,
      gpu.blurPass(backdrop, [0'i32, 1]))

proc syncAtlas(r: Renderer; t: var Texture; atlas: scene.Atlas;
               format: uint32): string =
  if atlas.isNil:
    return
  if t.tex == 0 or t.generation != atlas.generation() or
      t.width != atlas.w or t.height != atlas.h:
    result = r.newTexture(t, atlas.w, atlas.h, format, atlas.pix, atlas.bpp)
    if result.len == 0:
      t.generation = atlas.generation()
      t.version = atlas.version
    return
  let (rects, full) = atlas.changes(t.generation, t.version)
  if full and atlas.pix.len > 0:
    discard com.call(r.context, contextUpdateSubresource, t.tex, 0, 0,
      pointerValue(unsafeAddr atlas.pix[0]), uint(atlas.w * atlas.bpp), 0)
  for rect in rects:
    let box = Box(left: uint32(rect.min.x), top: uint32(rect.min.y),
      right: uint32(rect.max.x), bottom: uint32(rect.max.y), back: 1)
    let offset = (rect.min.y * atlas.w + rect.min.x) * atlas.bpp
    if offset >= 0 and offset < atlas.pix.len:
      discard com.call(r.context, contextUpdateSubresource, t.tex, 0,
        cAddress(box), pointerValue(unsafeAddr atlas.pix[offset]),
        uint(atlas.w * atlas.bpp), 0)
  t.version = atlas.version

proc imageView(r: Renderer; image: scene.Image): uint =
  if image.isNil:
    return 0
  if not image.scene.isNil:
    if r.canvases.hasKey(image.id):
      return r.canvases[image.id].texture.srv
    return 0
  if not r.images.hasKey(image.id):
    var t: Texture
    if r.newTexture(t, image.w, image.h, formatR8G8B8A8Unorm,
        image.pix, 4).len > 0:
      return 0
    t.version = image.version
    r.images[image.id] = t
  else:
    var t = r.images[image.id]
    if t.width != image.w or t.height != image.h:
      let error = r.newTexture(t, image.w, image.h,
        formatR8G8B8A8Unorm, image.pix, 4)
      if error.len > 0:
        r.images[image.id] = t
        return 0
      t.version = image.version
    elif t.version != image.version and image.pix.len > 0:
      discard com.call(r.context, contextUpdateSubresource, t.tex, 0, 0,
        pointerValue(unsafeAddr image.pix[0]), uint(image.w * 4), 0)
      t.version = image.version
    r.images[image.id] = t
  r.images[image.id].lastFrame = r.frame
  r.images[image.id].srv

proc drawCanvas(r: Renderer; canvas: scene.Image): string
proc drawScene(r: Renderer; s: scene.Scene; b: var gpu.Builder;
               target: uint): string

proc drawCanvas(r: Renderer; canvas: scene.Image): string =
  if r.canvases.hasKey(canvas.id):
    if r.canvases[canvas.id].isNil:
      r.canvases[canvas.id] = CanvasTexture()
  else:
    r.canvases[canvas.id] = CanvasTexture()
  let target = r.canvases[canvas.id]
  target.lastFrame = r.frame
  if target.texture.tex != 0 and target.texture.width == canvas.w and
      target.texture.height == canvas.h and target.version == canvas.version:
    return
  if target.texture.tex == 0 or target.texture.width != canvas.w or
      target.texture.height != canvas.h:
    result = r.newTarget(target.texture, canvas.w, canvas.h, true)
    if result.len > 0:
      return
  let canvasScene = canvas.scene
  canvasScene.width = canvas.w
  canvasScene.height = canvas.h
  result = r.drawScene(canvasScene, target.builder, target.texture.rtv)
  if result.len == 0:
    target.version = canvas.version

proc drawCanvases(r: Renderer; s: scene.Scene): string =
  var seen = initHashSet[scene.Image]()
  var drawError = ""
  proc visit(canvas: scene.Image) =
    if drawError.len > 0 or canvas.isNil or canvas.scene.isNil or canvas in seen:
      return
    seen.incl(canvas)
    for op in canvas.scene.ops:
      if op.kind == scene.opImage and not op.image.isNil and
          not op.image.scene.isNil:
        visit(op.image)
    if drawError.len == 0:
      drawError = r.drawCanvas(canvas)
  for canvas in s.canvases:
    visit(canvas)
  for op in s.ops:
    if op.kind == scene.opImage and not op.image.isNil and
        not op.image.scene.isNil:
      visit(op.image)
  result = drawError

proc effectShader(r: Renderer; effect: ref scene.Effect): uint =
  if effect.isNil:
    return 0
  let key = cast[uint](effect)
  if r.effects.hasKey(key):
    return r.effects[key].shader
  var bytecode: string
  var error = ""
  if effect.hlsl.compiled.len > 0 and
      effect.hlsl.sum == gpu.sourceSum(shader.effectSource(effect.hlsl.source)):
    bytecode = newString(effect.hlsl.compiled.len)
    copyMem(addr bytecode[0], unsafeAddr effect.hlsl.compiled[0], bytecode.len)
  else:
    (bytecode, error) = shader.compileEffect(effect.hlsl.source)
  var shaderHandle: uint
  if error.len == 0 and bytecode.len > 0:
    let hr = com.call(r.device, deviceCreatePixelShader,
      pointerValue(unsafeAddr bytecode[0]), uint(bytecode.len), 0,
      address(shaderHandle))
    if com.failed(hr):
      error = "d3d11: cannot create the pixel shader of effect " & effect.name
  elif error.len == 0:
    error = "d3d11: effect " & effect.name & " has no pixel shader"
  if error.len > 0:
    stderr.writeLine(error)
  r.effects[key] = (effect, shaderHandle)
  shaderHandle

proc bindState(r: Renderer; s: scene.Scene; backdrop: uint) =
  let ctx = r.context
  discard com.call(ctx, contextOmSetRenderTargets, 1, address(r.drawing), 0)
  let viewport = Viewport(width: float32(s.width), height: float32(s.height),
    maxDepth: 1)
  discard com.call(ctx, contextRsSetViewports, 1, cAddress(viewport))
  discard com.call(ctx, contextOmSetBlendState, r.blend, 0, 0xffffffff'u)
  discard com.call(ctx, contextIaSetInputLayout, r.layout)
  let stride = uint32(sizeof(gpu.Instance))
  var offset = 0'u32
  discard com.call(ctx, contextIaSetVertexBuffers, 0, 1,
    address(r.instanceBuffer), cAddress(stride), address(offset))
  discard com.call(ctx, contextVsSetShader, r.vs, 0, 0)
  discard com.call(ctx, contextVsSetConstantBuffers, 0, 1,
    address(r.constantBuffer))
  discard com.call(ctx, contextPsSetShader, r.ps, 0, 0)
  discard com.call(ctx, contextPsSetSamplers, 0, 1, address(r.sampler))
  var views = [r.mask.srv, r.color.srv, 0'u, backdrop]
  discard com.call(ctx, contextPsSetShaderResources, 0, uint(views.len),
    address(views[0]))

proc drawScene(r: Renderer; s: scene.Scene; b: var gpu.Builder;
               target: uint): string =
  r.drawing = target
  discard b.build(s, proc(image: scene.Image): uint = r.imageView(image))
  result = r.fitBackdrop(b)
  if result.len > 0:
    return

  let count = b.instances.len
  if count > 0:
    if count > r.instanceCapacity:
      com.release(r.instanceBuffer)
      let capacity = max(count * 3 div 2, 1024)
      let desc = BufferDesc(byteWidth: uint32(capacity * sizeof(gpu.Instance)),
        usage: usageDynamic, bindFlags: bindVertexBuffer,
        cpuAccessFlags: cpuAccessWrite)
      let hr = com.call(r.device, deviceCreateBuffer, cAddress(desc), 0,
        address(r.instanceBuffer))
      if com.failed(hr):
        r.instanceCapacity = 0
        return hrError("cannot create the instance buffer", hr)
      r.instanceCapacity = capacity
    var mapped: Mapped
    let mapHr = com.call(r.context, contextMap, r.instanceBuffer, 0,
      mapWriteDiscard, 0, address(mapped))
    if com.failed(mapHr):
      return hrError("cannot map the instance buffer", mapHr)
    copyMem(cast[pointer](mapped.data), unsafeAddr b.instances[0],
      count * sizeof(gpu.Instance))
    discard com.call(r.context, contextUnmap, r.instanceBuffer, 0)

  var globals = [float32(s.width), float32(s.height), 0'f32, 0'f32]
  discard com.call(r.context, contextUpdateSubresource,
    r.constantBuffer, 0, 0, address(globals[0]), 0, 0)
  discard com.call(r.context, contextOmSetRenderTargets, 1,
    address(r.drawing), 0)
  let clear = s.clear.premul(1)
  discard com.call(r.context, contextClearRenderTargetView,
    r.drawing, cAddress(clear[0]))
  discard com.call(r.context, contextRsSetState, r.raster)
  discard com.call(r.context, contextIaSetPrimitiveTopology,
    topologyTriangleStrip)
  r.bindState(s, 0)
  var boundImage = 0'u
  var pixelShader = r.ps
  var blendState = r.blend
  for batch in b.batches:
    if batch.count == 0:
      continue
    var wantedShader = r.ps
    if not batch.effect.isNil:
      wantedShader = r.effectShader(batch.effect)
      if wantedShader == 0:
        continue
    if batch.backdrop != 0:
      result = r.readBackdrop(b.backdrops[batch.backdrop - 1])
      if result.len > 0:
        return
      r.bindState(s, r.backdrop[0].srv)
      boundImage = 0
      pixelShader = r.ps
      blendState = r.blend
    if wantedShader != pixelShader:
      pixelShader = wantedShader
      discard com.call(r.context, contextPsSetShader, pixelShader, 0, 0)
    let wantedBlend = if batch.hole: r.holeBlend else: r.blend
    if wantedBlend != blendState:
      blendState = wantedBlend
      discard com.call(r.context, contextOmSetBlendState,
        blendState, 0, 0xffffffff'u)
    if batch.image != 0 and batch.image != boundImage:
      boundImage = batch.image
      discard com.call(r.context, contextPsSetShaderResources, 2, 1,
        address(boundImage))
    var mask = batch.clipMask
    discard com.call(r.context, contextPsSetShaderResources, 5, 1,
      address(mask))
    discard com.call(r.context, contextRsSetScissorRects, 1,
      cAddress(batch.scissor))
    discard com.call(r.context, contextDrawInstanced, 4,
      uint(batch.count), 0, uint(batch.start))

proc draw(r: Renderer; s: scene.Scene): string =
  inc r.frame
  result = r.resize(s.width, s.height)
  if result.len > 0:
    return
  result = r.syncAtlas(r.mask, s.maskAtlas, formatR8Unorm)
  if result.len > 0:
    return
  result = r.syncAtlas(r.color, s.colorAtlas, formatR8G8B8A8Unorm)
  if result.len > 0:
    return
  result = r.drawCanvases(s)
  if result.len > 0:
    return
  result = r.drawScene(s, r.builder, r.rtv)

proc present(r: Renderer; sync: uint): string =
  let hr = com.call(r.swapChain, swapChainPresent, sync, 0)
  if com.failed(hr):
    return hrError("present", hr)
  if r.frame mod 120 == 0:
    var removeImages: seq[uint64]
    for id, texture in r.images:
      if r.frame - texture.lastFrame > 240:
        removeImages.add(id)
    for id in removeImages:
      var texture = r.images[id]
      texture.releaseTexture()
      r.images.del(id)
    var removeCanvases: seq[uint64]
    for id, canvas in r.canvases:
      if canvas.isNil or r.frame - canvas.lastFrame > 240:
        removeCanvases.add(id)
    for id in removeCanvases:
      if r.canvases[id] != nil:
        r.canvases[id].builder.release()
        r.canvases[id].texture.releaseTexture()
      r.canvases.del(id)

proc render*(r: Renderer; s: scene.Scene): string =
  ## Draws a scene and presents the swap-chain back buffer.
  if r.isNil or s.isNil or s.width <= 0 or s.height <= 0:
    return
  let resized = r.swapChain != 0 and
    (s.width != r.width or s.height != r.height)
  result = r.draw(s)
  if result.len > 0:
    return
  result = r.present(if resized: 0'u else: 1'u)
  when defined(windows):
    if result.len == 0 and resized:
      flushDwm()
