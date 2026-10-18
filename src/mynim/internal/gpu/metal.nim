## metal draws scenes with Metal into a CAMetalLayer, called through the
## Objective-C runtime like the rest of the macOS backend. Every op of a
## scene is an instanced quad drawn by one shader (shader.metal, compiled
## ahead of time into shader.metallib), from the instances package gpu
## builds; clips are scissor rectangles, with the innermost rounded clip
## computed in the shader, as in package d3d11.

import std/[hashes, os, osproc, strutils, syncio, tables, tempfiles, times]
import ../gpu, ../scene, ../darwin
import ../../image

const
  shaderSource = staticRead("metal/shader.metal")
  effectTemplate = staticRead("metal/effect.metal")
  ## shaderLibrary is shader.metal compiled by Xcode's metal tools,
  ## which compileLibrary runs; shaderLibrarySum is its source's
  ## SHA-256.
  shaderLibrary = staticRead("metal/shader.metallib")
  shaderLibrarySum =
    "8be731906ebe8e150b13fccc88d9a3b03294e6ffdc1246be06fee616cca343cb"

proc effectSource*(src: string): string =
  ## The source of an effect's library: shader.metal with EFFECT
  ## defined, the head of effect.metal, the effect's shader (see
  ## scene.Effect), and the tail, which draws its instances with it
  ## (effect_ps). Effects compile it ahead of time with compileLibrary.
  let cut = effectTemplate.find("\n// effect\n")
  "#define EFFECT\n" & shaderSource & "\n" &
    effectTemplate[0 ..< cut] & "\n" & src & "\n" &
    effectTemplate[cut + "\n// effect\n".len .. ^1]

type
  ## Metal and Core Graphics structs passed by value.
  mtlRegion = object
    x, y, z, w, h, d: uint
  mtlScissorRect = object
    x, y, w, h: uint
  mtlClearColor = object
    r, g, b, a: float64

const
  pixelFormatR8Unorm = 10'u
  pixelFormatRGBA8Unorm = 70'u
  pixelFormatBGRA8Unorm = 80'u
  ## pixelFormatRGBA16Float holds the components of wide colors, which
  ## leave 0 to 1.
  pixelFormatRGBA16Float = 115'u

  usageShaderRead = 1'u
  usageRenderTarget = 4'u
  storageManaged = 1'u

  loadActionDontCare = 0'u
  loadActionLoad = 1'u
  loadActionClear = 2'u
  storeActionStore = 1'u
  primitiveTriStrip = 4'u
  blendZero = 0'u
  blendOne = 1'u
  blendOneMinusSrc1Color = 16'u
  blendOneMinusSrc1A = 18'u
  filterLinear = 1'u
  statusError = 5
  layerWidthSizable = 1'u shl 1
  layerHeightSizable = 1'u shl 4

  libMetal = "/System/Library/Frameworks/Metal.framework/Metal"
  libQuartz = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore"
  libSystem = "/usr/lib/libSystem.B.dylib"

## Typed objc_msgSend variants for the Metal structs and pointers.
proc msgReplaceRegion(obj: id, s: SEL, r: mtlRegion, level: uint,
                      bytes: pointer, bytesPerRow: uint)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgGetBytes(obj: id, s: SEL, bytes: pointer, bytesPerRow: uint,
                 r: mtlRegion, level: uint)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetScissor(obj: id, s: SEL, r: mtlScissorRect)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetClearColor(obj: id, s: SEL, c: mtlClearColor)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

## cfTimerContext is CFRunLoopTimerContext.
type cfTimerContext = object
  version: clong
  info: pointer
  retain, release, copyDescription: pointer

var
  loaded: bool
  errLoad: ref CatchableError

  createDevice: proc(): id {.cdecl.}
  srgb, extendedSRGB: id
  cgColorSpaceCreateWithName: proc(name: id): id {.cdecl.}
  commonModes: pointer

  dispatchDataCreate: proc(buf: pointer, size: uint, queue: pointer,
                           destructor: pointer): id {.cdecl.}
  dispatchRelease: proc(obj: pointer) {.cdecl.}

  # Timers that trim the drawables of renderers drawing nothing for a
  # while (see trim), by the handle in their info.
  cfAbsoluteTimeGetCurrent: proc(): cdouble {.cdecl.}
  cfRunLoopTimerCreate: proc(alloc: pointer, fireDate, interval: cdouble,
      flags: uint64, order: clong,
      callout: proc(timer, info: pointer) {.cdecl.},
      ctx: ptr cfTimerContext): id {.cdecl.}
  cfRunLoopTimerSetNextFireDate: proc(timer: id, date: cdouble) {.cdecl.}
  cfRunLoopAddTimer: proc(rl, timer, mode: pointer) {.cdecl.}
  cfRunLoopGetMainL: proc(): pointer {.cdecl.}
  cfReleaseL: proc(obj: pointer) {.cdecl.}
  cfRunLoopTimerInvalidate: proc(timer: id) {.cdecl.}

type
  texture = object
    tex: id
    w, h: int
    gen, ver: uint64
    lastFrame: uint64

  ## drawState is what drawing scenes into a target keeps from frame to
  ## frame: a frame's, and each canvas's.
  drawState = object
    b: gpu.Builder
    instBuf: id
    instCap: int

  ## effectPipe is the pipeline of an effect, or why it has none.
  effectPipe = object
    pipe: id
    err: ref CatchableError

  ## canvasTexture is the texture a canvas (scene.newCanvas) is drawn
  ## into, and what drawing it keeps, for as long as the canvas lives:
  ## what it holds is drawn once, not again when shown. Go keeps a weak
  ## pointer to the canvas to forget dead ones; this port keeps the
  ## image and drops the texture once no frame has drawn it for a
  ## while, which has the same effect.
  canvasTexture = object
    tex: id
    w, h: int
    gen, ver: uint64
    lastFrame: uint64
    d: drawState
    canvas: scene.Image

  ## formatState is what a renderer draws into targets of a pixel
  ## format with.
  formatState = object
    format: uint
    pipeline: id
    ## holePipe draws holes (scene.opHole), taking their coverage away.
    holePipe: id
    ## downPipe and blurPipe draw the passes computing the backdrops of
    ## effects, into the textures of backdrop, the second only along
    ## rows.
    downPipe, blurPipe: id
    backdrop: array[2, texture]
    ## effects are the pipelines of the effects drawn, made as first
    ## drawn.
    effects: Table[ref scene.Effect, ref effectPipe]

  Renderer* = ref object
    ## Draws scenes into a CAMetalLayer it adds to a view's layer.
    device, queue, sampler: id
    ## formats has what draws into BGRA8 targets, as frames do, and
    ## into RGBA16Float ones, as frames showing colors outside the sRGB
    ## gamut do (setWide), made for the first of those; cur is that of
    ## the target drawn into.
    formats: array[2, formatState]
    cur: ptr formatState
    ## wide tells that frames show the colors of scenes outside the
    ## sRGB gamut, and layerWide that the layer's drawables hold them;
    ## wideErr is why they cannot.
    wide, layerWide: bool
    wideErr: ref CatchableError
    ## layer is the CAMetalLayer in superlayer, the view's.
    layer, superlayer: id
    w, h: int
    bounds: NSRect
    scale: float64

    ## synced tells that the layer presents with the Core Animation
    ## transaction, and holes that the last frame had holes (web views
    ## under it). waited tells that the last frame, presented as soon
    ## as drawn, waited for its drawable; behind that the last render
    ## drew nothing to catch up with the display, and skippedAt when
    ## one last did.
    synced, holes, waited, behind: bool
    skippedAt: float64

    mask, color: texture
    empty: id ## a texture to bind where there is none
    images: Table[uint64, ref texture]
    ## canvases are the textures canvases are drawn into.
    canvases: Table[uint64, ref canvasTexture]
    blurred: seq[texture]
    used: int
    blurTmp: array[2, texture]
    frame: uint64
    ## last is the command buffer of the last frame, which the next
    ## waits for before it changes what the GPU reads.
    last: id
    err: ref CatchableError
    checked: bool

    ## lastRender is when the last frame drew; trimTimer trims the
    ## drawables once none has for a while, armed until it fires, and
    ## trimmed is whether it did.
    lastRender: float64
    trimTimer: id
    trimHandle: uint
    trimArmed, trimmed: bool

    ## ds is the frames' drawing state.
    ds: drawState

var
  trimTimers: Table[uint, Renderer]
  lastTrimHandle: uint

proc hash(e: ref scene.Effect): Hash = hash(cast[int](e))

proc dataSym[T](h: pointer; name: string): T =
  ## An exported data symbol, as a data constant of a framework is.
  cast[ptr T](mustDlsym(h, name))[]

proc rel(o: var id) =
  if not o.isNil:
    release(o)
    o = nil

proc release(d: var drawState) =
  rel(d.instBuf)
  d.instCap = 0
  d.b.release()

proc orId(a, b: id): id = (if not a.isNil: a else: b)

proc sameRect(a, b: NSRect): bool =
  a.origin.x == b.origin.x and a.origin.y == b.origin.y and
    a.size.width == b.size.width and a.size.height == b.size.height

## describe returns the description of an NSError.
proc describe(err: id): string =
  if err.isNil:
    return "unknown error"
  let p = send(send(err, "localizedDescription"), "UTF8String")
  if p.isNil:
    return "unknown error"
  result = $cast[cstring](p)

## need reports which of the methods obj lacks, so that a renderer
## fails rather than crash on a system without them.
proc need(obj: id, what: string, methods: varargs[string]) =
  if obj.isNil:
    raise newException(ValueError, "metal: no " & what)
  for m in methods:
    if not respondsTo(obj, m):
      raise newException(ValueError, "metal: " & what & " has no " & m)

proc trimIfIdle(r: Renderer)

proc trimCallback(timer, info: pointer) {.cdecl.} =
  let r = trimTimers.getOrDefault(cast[uint](info))
  if r != nil:
    r.trimIfIdle()

proc load() =
  ## Loads the libraries and their symbols once; failures are sticky.
  if loaded:
    if not errLoad.isNil:
      raise errLoad
    return
  loaded = true
  try:
    let metal = mustDlopen(libMetal)
    discard mustDlopen(libQuartz) # CAMetalLayer
    let cg = mustDlopen(libCG)
    let system = mustDlopen(libSystem)
    let cf = mustDlopen(libCF)
    createDevice = cast[typeof createDevice](
      mustDlsym(metal, "MTLCreateSystemDefaultDevice"))
    cgColorSpaceCreateWithName = cast[typeof cgColorSpaceCreateWithName](
      mustDlsym(cg, "CGColorSpaceCreateWithName"))
    dispatchDataCreate = cast[typeof dispatchDataCreate](
      mustDlsym(system, "dispatch_data_create"))
    dispatchRelease = cast[typeof dispatchRelease](
      mustDlsym(system, "dispatch_release"))
    cfAbsoluteTimeGetCurrent = cast[typeof cfAbsoluteTimeGetCurrent](
      mustDlsym(cf, "CFAbsoluteTimeGetCurrent"))
    cfRunLoopTimerCreate = cast[typeof cfRunLoopTimerCreate](
      mustDlsym(cf, "CFRunLoopTimerCreate"))
    cfRunLoopTimerSetNextFireDate =
      cast[typeof cfRunLoopTimerSetNextFireDate](
        mustDlsym(cf, "CFRunLoopTimerSetNextFireDate"))
    cfRunLoopAddTimer = cast[typeof cfRunLoopAddTimer](
      mustDlsym(cf, "CFRunLoopAddTimer"))
    cfRunLoopTimerInvalidate = cast[typeof cfRunLoopTimerInvalidate](
      mustDlsym(cf, "CFRunLoopTimerInvalidate"))
    commonModes = dataSym[pointer](cf, "kCFRunLoopCommonModes")
    cfRunLoopGetMainL = cast[typeof cfRunLoopGetMainL](
      mustDlsym(cf, "CFRunLoopGetMain"))
    cfReleaseL = cast[typeof cfReleaseL](mustDlsym(cf, "CFRelease"))
    srgb = cgColorSpaceCreateWithName(dataSym[id](
      cg, "kCGColorSpaceSRGB"))
    extendedSRGB = cgColorSpaceCreateWithName(dataSym[id](
      cg, "kCGColorSpaceExtendedSRGB"))
  except CatchableError as e:
    errLoad = e
    raise

proc waitLast(r: Renderer) =
  ## Waits for the GPU to finish the last frame, so that this one can
  ## change the buffers and textures it read.
  if r.last.isNil:
    return
  discard send(r.last, "waitUntilCompleted")
  if cast[int](send(r.last, "status")) == statusError and r.err.isNil:
    r.err = newException(ValueError,
      "metal: a frame failed: " & describe(send(r.last, "error")))
  rel(r.last)

proc newTexture(r: Renderer; w, h: int; format, usage: uint;
                pix: openArray[byte], stride: int): id =
  ## An owned w×h texture holding pix, rows of stride bytes, when
  ## given.
  let desc = send(`class`("MTLTextureDescriptor"),
    "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
    format, w.uint, h.uint, 0)
  if desc.isNil:
    return nil
  discard send(desc, "setUsage:", usage)
  if (usage and usageRenderTarget) != 0:
    discard send(desc, "setStorageMode:", storageManaged)
  result = send(r.device, "newTextureWithDescriptor:", desc)
  if not result.isNil and pix.len > 0:
    msgReplaceRegion(result,
      sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
      mtlRegion(w: w.uint, h: h.uint, d: 1), 0,
      addr pix[0], stride.uint)

proc initGPU(r: Renderer) =
  ## Makes what only drawing on the GPU needs. A window presenting CPU
  ## frames needs the device and layer alone: neither a command queue
  ## nor shaders, samplers and textures.
  if not r.queue.isNil:
    return
  var queue = send(r.device, "newCommandQueue")
  if queue.isNil:
    raise newException(ValueError, "metal: no command queue")
  defer: rel(queue)
  var sd = send(send(`class`("MTLSamplerDescriptor"), "alloc"), "init")
  defer: rel(sd)
  discard send(sd, "setMinFilter:", filterLinear)
  discard send(sd, "setMagFilter:", filterLinear)
  var sampler = send(r.device, "newSamplerStateWithDescriptor:", sd)
  defer: rel(sampler)
  var empty = r.newTexture(1, 1, pixelFormatRGBA8Unorm, usageShaderRead,
                           [byte 0, 0, 0, 0], 4)
  defer: rel(empty)
  if empty.isNil or sampler.isNil:
    raise newException(ValueError, "metal: cannot create a texture")
  r.queue = queue
  r.sampler = sampler
  r.empty = empty
  queue = nil
  sampler = nil
  empty = nil

proc newPipeline(r: Renderer; lib: id, fs: string, format: uint;
                 hole: bool): id =
  ## A pipeline drawing instances with the vertex function vs and the
  ## fragment function fs of lib, blending premultiplied colors over
  ## what is drawn, or for hole, taking their coverage away.
  var vsFn = send(lib, "newFunctionWithName:", nsString("vs"))
  defer: rel(vsFn)
  var fsFn = send(lib, "newFunctionWithName:", nsString(fs))
  defer: rel(fsFn)
  if vsFn.isNil or fsFn.isNil:
    raise newException(ValueError,
                       "metal: the shader has no vs or " & fs)
  var desc = send(send(`class`("MTLRenderPipelineDescriptor"), "alloc"),
                  "init")
  defer: rel(desc)
  discard send(desc, "setVertexFunction:", vsFn)
  discard send(desc, "setFragmentFunction:", fsFn)
  let ca = send(send(desc, "colorAttachments"),
                "objectAtIndexedSubscript:", 0)
  discard send(ca, "setPixelFormat:", format)
  # Premultiplied colors over what is drawn.
  let src = if hole: blendZero else: blendOne
  discard send(ca, "setBlendingEnabled:", 1)
  discard send(ca, "setSourceRGBBlendFactor:", src)
  # Dual-source blending: the shader's second color is the source's
  # alpha of each channel.
  discard send(ca, "setDestinationRGBBlendFactor:",
               blendOneMinusSrc1Color)
  discard send(ca, "setSourceAlphaBlendFactor:", src)
  discard send(ca, "setDestinationAlphaBlendFactor:", blendOneMinusSrc1A)
  var errObj: id
  result = send(r.device,
    "newRenderPipelineStateWithDescriptor:error:", desc,
    argu(addr errObj))
  if result.isNil:
    raise newException(ValueError, "metal: cannot create the " & fs &
      " pipeline: " & describe(errObj))

proc passPipeline(r: Renderer; lib: id, name: string, format: uint): id =
  ## A pipeline of a pass computing backdrops, which draws the fragment
  ## function name of lib over its target, unblended.
  var vs = send(lib, "newFunctionWithName:", nsString("passVS"))
  defer: rel(vs)
  var fs = send(lib, "newFunctionWithName:", nsString(name))
  defer: rel(fs)
  if vs.isNil or fs.isNil:
    raise newException(ValueError,
                       "metal: the shader has no passVS or " & name)
  var desc = send(send(`class`("MTLRenderPipelineDescriptor"), "alloc"),
                  "init")
  defer: rel(desc)
  discard send(desc, "setVertexFunction:", vs)
  discard send(desc, "setFragmentFunction:", fs)
  let ca = send(send(desc, "colorAttachments"),
                "objectAtIndexedSubscript:", 0)
  discard send(ca, "setPixelFormat:", format)
  var errObj: id
  result = send(r.device,
    "newRenderPipelineStateWithDescriptor:error:", desc,
    argu(addr errObj))
  if result.isNil:
    raise newException(ValueError, "metal: cannot create the " & name &
      " pipeline: " & describe(errObj))

proc libraryFromData(r: Renderer; code: openArray[byte]): id =
  ## A library loaded from the code of one, or nil when Metal cannot
  ## load it.
  if dispatchDataCreate.isNil or code.len == 0 or
      not respondsTo(r.device, "newLibraryWithData:error:"):
    return nil
  # Without a destructor, dispatch_data_create copies the bytes.
  let data = dispatchDataCreate(addr code[0], code.len.uint, nil, nil)
  if data.isNil:
    return nil
  defer: dispatchRelease(data)
  var errObj: id
  result = send(r.device, "newLibraryWithData:error:", data,
                argu(addr errObj))

proc compiledLibrary(r: Renderer): id =
  ## The library compiled from the shader ahead of time, or nil when
  ## it was compiled from another shader.metal (the shader was not
  ## regenerated since it changed) or Metal cannot load it.
  if gpu.sourceSum(shaderSource) != shaderLibrarySum:
    return nil
  result = r.libraryFromData(
    shaderLibrary.toOpenArrayByte(0, shaderLibrary.len - 1))

proc makePipelines(r: Renderer; f: ptr formatState) =
  ## Makes the pipelines of f's format, or none.
  var errObj: id
  var lib = r.compiledLibrary()
  if lib.isNil:
    lib = send(r.device, "newLibraryWithSource:options:error:",
               nsString(shaderSource), 0, argu(addr errObj))
  if lib.isNil:
    raise newException(ValueError,
      "metal: cannot compile the shader: " & describe(errObj))
  defer: rel(lib)
  try:
    f.pipeline = r.newPipeline(lib, "ps", f.format, false)
    f.holePipe = r.newPipeline(lib, "ps", f.format, true)
    f.downPipe = r.passPipeline(lib, "down", f.format)
    f.blurPipe = r.passPipeline(lib, "blur", f.format)
  except CatchableError:
    rel(f.pipeline)
    rel(f.holePipe)
    rel(f.downPipe)
    rel(f.blurPipe)
    raise

proc setWide*(r: Renderer; on: bool): bool =
  ## setWide has the frames drawn from now on show the colors of
  ## scenes outside the sRGB gamut (scene.Scene.wide), into drawables
  ## of RGBA16Float in the extended sRGB color space, which keeps
  ## components beyond 0 to 1 and which the system shows in the
  ## display's gamut, or their nearest sRGB colors, into drawables of
  ## BGRA8, as without; and reports whether they do. The pipelines
  ## drawing the wide colors are made the first time.
  let f = addr r.formats[1]
  if on and f.pipeline.isNil and r.wideErr.isNil:
    if extendedSRGB.isNil:
      r.wideErr = newException(ValueError,
        "metal: no extended sRGB color space")
    else:
      try:
        withPool(proc() = r.makePipelines(f))
      except CatchableError as e:
        r.wideErr = e
    if not r.wideErr.isNil:
      stderr.writeLine(r.wideErr.msg &
        ": drawing the nearest sRGB colors")
  r.wide = on and r.wideErr.isNil
  result = r.wide

proc setLayerWide(r: Renderer; on: bool): bool =
  ## Has the layer's drawables hold the colors outside the sRGB gamut,
  ## or not, and reports whether that changed: the system makes
  ## others, which hold no frame drawn in memory.
  if r.layerWide == on or r.layer.isNil:
    return false
  var format = pixelFormatBGRA8Unorm
  var space = srgb
  if on:
    format = pixelFormatRGBA16Float
    space = extendedSRGB
  let tx = `class`("CATransaction")
  discard send(tx, "begin")
  discard send(tx, "setDisableActions:", 1)
  discard send(r.layer, "setPixelFormat:", format)
  discard send(r.layer, "setColorspace:", space)
  discard send(tx, "commit")
  r.layerWide = on
  result = true

proc effectPipeline(r: Renderer; e: ref scene.Effect): id =
  ## The pipeline of e: from the library e compiled ahead of time,
  ## unless it was compiled from another source, as when the
  ## renderer's head or tail changed since, which it then compiles. It
  ## is nil for an effect that does not compile, which draws nothing.
  let f = r.cur
  let cached = f.effects.getOrDefault(e)
  if cached != nil:
    return cached.pipe
  let pe = new(effectPipe)
  f.effects[e] = pe
  let src = effectSource(e.metal.source)
  var lib: id
  if e.metal.compiled.len > 0 and
      e.metal.sum == gpu.sourceSum(src):
    lib = r.libraryFromData(e.metal.compiled)
  if lib.isNil:
    var errObj: id
    lib = send(r.device, "newLibraryWithSource:options:error:",
               nsString(src), 0, argu(addr errObj))
    if lib.isNil:
      pe.err = newException(ValueError, "metal: cannot compile the " &
        "effect " & e.name & ": " & describe(errObj))
  if not lib.isNil:
    try:
      pe.pipe = r.newPipeline(lib, "effect_ps", f.format, false)
    except CatchableError as ex:
      pe.err = ex
    rel(lib)
  if not pe.err.isNil and r.err.isNil:
    # Shown once, as frames go on without the effect.
    stderr.writeLine(pe.err.msg)
  result = pe.pipe

proc syncAtlas(r: Renderer; t: var texture; a: scene.Atlas;
               format: uint) =
  ## Uploads what changed in an atlas since the texture had it.
  if a.isNil:
    return
  if t.tex.isNil or t.gen != a.generation() or t.w != a.w or
      t.h != a.h:
    rel(t.tex)
    t.tex = r.newTexture(a.w, a.h, format, usageShaderRead, a.pix,
                         a.w * a.bpp)
    if t.tex.isNil:
      raise newException(ValueError,
                         "metal: cannot create an atlas texture")
    t.w = a.w
    t.h = a.h
    t.gen = a.generation()
    t.ver = a.version
    return
  var (rects, full) = a.changes(t.gen, t.ver)
  if full:
    rects = @[image.rect(0, 0, a.w, a.h)]
  for rc in rects:
    let off = (rc.min.y * a.w + rc.min.x) * a.bpp
    let region = mtlRegion(x: rc.min.x.uint, y: rc.min.y.uint,
                           w: (rc.max.x - rc.min.x).uint,
                           h: (rc.max.y - rc.min.y).uint, d: 1)
    msgReplaceRegion(t.tex,
      sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
      region, 0, addr a.pix[off], (a.w * a.bpp).uint)
  t.ver = a.version

proc imageTexture(r: Renderer; img: scene.Image): uint =
  ## The texture of an image, uploading it when new or changed.
  if not img.scene.isNil:
    # A canvas, drawn before the scene showing it.
    let c = r.canvases.getOrDefault(img.id)
    return if c == nil: 0 else: cast[uint](c.tex)
  var t = r.images.getOrDefault(img.id)
  if t == nil:
    let tex = r.newTexture(img.w, img.h, pixelFormatRGBA8Unorm,
                           usageShaderRead, img.pix, img.w * 4)
    if tex.isNil:
      return 0
    new(t)
    t[] = texture(tex: tex, w: img.w, h: img.h, ver: img.version)
    r.images[img.id] = t
  elif t.w != img.w or t.h != img.h:
    let tex = r.newTexture(img.w, img.h, pixelFormatRGBA8Unorm,
                           usageShaderRead, img.pix, img.w * 4)
    if tex.isNil:
      return 0
    rel(t.tex)
    t.tex = tex
    t.w = img.w
    t.h = img.h
    t.ver = img.version
  elif t.ver != img.version:
    msgReplaceRegion(t.tex,
      sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
      mtlRegion(w: img.w.uint, h: img.h.uint, d: 1), 0,
      addr img.pix[0], (img.w * 4).uint)
    t.ver = img.version
  t.lastFrame = r.frame
  result = cast[uint](t.tex)

proc beginRender(r: Renderer; cb, target: id; load: uint; s: scene.Scene;
             b: var gpu.Builder): id =
  ## Starts encoding the drawing of s into target, which it clears or
  ## keeps (load), with the state the instances draw with.
  let rpd = send(`class`("MTLRenderPassDescriptor"),
               "renderPassDescriptor")
  let ca = send(send(rpd, "colorAttachments"),
                "objectAtIndexedSubscript:", 0)
  discard send(ca, "setTexture:", target)
  discard send(ca, "setLoadAction:", load)
  discard send(ca, "setStoreAction:", storeActionStore)
  let c = s.clear.premul(1)
  msgSetClearColor(ca, sel("setClearColor:"),
    mtlClearColor(r: c[0].float64, g: c[1].float64, b: c[2].float64,
                  a: c[3].float64))
  result = send(cb, "renderCommandEncoderWithDescriptor:", rpd)
  if not r.checked:
    need(result, "render encoder", "setRenderPipelineState:",
      "setVertexBytes:length:atIndex:",
      "setVertexBuffer:offset:atIndex:",
      "setFragmentBuffer:offset:atIndex:",
      "setFragmentBytes:length:atIndex:",
      "setFragmentTexture:atIndex:", "setFragmentSamplerState:atIndex:",
      "setScissorRect:",
      "drawPrimitives:vertexStart:vertexCount:instanceCount:",
      "endEncoding")
    r.checked = true
  discard send(result, "setRenderPipelineState:", r.cur.pipeline)
  # The frame's size, and whether its target keeps colors outside the
  # sRGB gamut.
  var globals = [s.width.float32, s.height.float32, 0f, 0f]
  if b.wide:
    globals[2] = 1
  discard send(result, "setVertexBytes:length:atIndex:",
               argu(addr globals[0]), sizeof(globals).uint, 1)
  discard send(result, "setFragmentBytes:length:atIndex:",
               argu(addr globals[0]), sizeof(globals).uint, 1)
  discard send(result, "setFragmentSamplerState:atIndex:", r.sampler)
  discard send(result, "setFragmentTexture:atIndex:",
               orId(r.mask.tex, r.empty))
  discard send(result, "setFragmentTexture:atIndex:",
               orId(r.color.tex, r.empty))
  discard send(result, "setFragmentTexture:atIndex:", r.empty)
  discard send(result, "setFragmentTexture:atIndex:", r.empty)

proc passDraw(r: Renderer; cb, pipe, src, dst: id; w, h: int;
            p: gpu.Pass) =
  ## Encodes drawing the w×h texels at the start of dst with pipe,
  ## which reads src.
  let rpd = send(`class`("MTLRenderPassDescriptor"),
               "renderPassDescriptor")
  let ca = send(send(rpd, "colorAttachments"),
                "objectAtIndexedSubscript:", 0)
  discard send(ca, "setTexture:", dst)
  discard send(ca, "setLoadAction:", loadActionDontCare)
  discard send(ca, "setStoreAction:", storeActionStore)
  let enc = send(cb, "renderCommandEncoderWithDescriptor:", rpd)
  discard send(enc, "setRenderPipelineState:", pipe)
  discard send(enc, "setFragmentTexture:atIndex:", src)
  var pv = p
  discard send(enc, "setFragmentBytes:length:atIndex:",
               argu(addr pv), sizeof(gpu.Pass).uint, 0)
  msgSetScissor(enc, sel("setScissorRect:"),
                mtlScissorRect(x: 0, y: 0, w: w.uint, h: h.uint))
  discard send(enc,
    "drawPrimitives:vertexStart:vertexCount:instanceCount:",
    primitiveTriStrip, 0, 4, 1)
  discard send(enc, "endEncoding")

proc readBackdrop(r: Renderer; cb, target: id; bk: scene.Backdrop) =
  ## Encodes the passes computing the backdrop bk of what target
  ## holds, into r.cur.backdrop[0].
  let f = r.cur
  let (w, h) = bk.size()
  r.passDraw(cb, f.downPipe, target, f.backdrop[0].tex, w, h,
           gpu.downPass(bk, [0'i32, 0]))
  if bk.radius == 0:
    return
  r.passDraw(cb, f.blurPipe, f.backdrop[0].tex, f.backdrop[1].tex, w, h,
           gpu.blurPass(bk, [1'i32, 0]))
  r.passDraw(cb, f.blurPipe, f.backdrop[1].tex, f.backdrop[0].tex, w, h,
           gpu.blurPass(bk, [0'i32, 1]))

proc blurImage(r: Renderer; cb: id; img: scene.Image;
               bk: scene.Backdrop): uint =
  ## Encodes an image blur into reusable BGRA8 textures.
  let src = cast[id](r.imageTexture(img))
  let (w, h) = bk.size()
  if src.isNil or w <= 0 or h <= 0:
    return 0
  let f = addr r.formats[0]
  if f.downPipe.isNil:
    try:
      r.makePipelines(f)
    except CatchableError:
      return 0
  for i in 0 ..< r.blurTmp.len:
    let t = addr r.blurTmp[i]
    if t.w < w or t.h < h:
      rel(t.tex)
      let nw = max(w, t.w)
      let nh = max(h, t.h)
      t.tex = r.newTexture(nw, nh, pixelFormatBGRA8Unorm,
        usageRenderTarget or usageShaderRead, [], 0)
      if t.tex.isNil:
        t[] = texture()
        return 0
      t.w = nw
      t.h = nh
  if r.used == r.blurred.len:
    r.blurred.add(texture())
  let blurredTarget = addr r.blurred[r.used]
  inc r.used
  if blurredTarget[].tex.isNil or blurredTarget[].w != w or
      blurredTarget[].h != h:
    rel(blurredTarget[].tex)
    blurredTarget[].tex = r.newTexture(w, h, pixelFormatBGRA8Unorm,
      usageRenderTarget or usageShaderRead, [], 0)
    if blurredTarget[].tex.isNil:
      blurredTarget[] = texture()
      return 0
    blurredTarget[].w = w
    blurredTarget[].h = h
  var p = gpu.imageDownPass(bk)
  if bk.radius == 0:
    r.passDraw(cb, f.downPipe, src, blurredTarget[].tex, w, h, p)
    return cast[uint](blurredTarget[].tex)
  r.passDraw(cb, f.downPipe, src, r.blurTmp[0].tex, w, h, p)
  p = gpu.imageBlurPass(bk, [1'i32, 0])
  r.passDraw(cb, f.blurPipe, r.blurTmp[0].tex, r.blurTmp[1].tex, w, h, p)
  p = gpu.imageBlurPass(bk, [0'i32, 1])
  r.passDraw(cb, f.blurPipe, r.blurTmp[1].tex, blurredTarget[].tex, w, h, p)
  cast[uint](blurredTarget[].tex)

proc fitBackdrop(r: Renderer; b: var gpu.Builder) =
  ## Makes the textures of backdrops as large as the scene built
  ## needs.
  let f = r.cur
  var (w, h) = b.backdropSize()
  if w == 0 or (f.backdrop[0].w >= w and f.backdrop[0].h >= h):
    return
  # Somewhat larger, so that a pane growing does not make them again
  # every frame.
  w = max(w + w div 4, f.backdrop[0].w)
  h = max(h + h div 4, f.backdrop[0].h)
  for i in 0 ..< f.backdrop.len:
    rel(f.backdrop[i].tex)
    f.backdrop[i].tex = r.newTexture(w, h, f.format,
      usageRenderTarget or usageShaderRead, [], 0)
    if f.backdrop[i].tex.isNil:
      f.backdrop[i].w = 0
      f.backdrop[i].h = 0
      raise newException(ValueError,
                         "metal: cannot create a backdrop texture")
    f.backdrop[i].w = w
    f.backdrop[i].h = h

proc drawInto(r: Renderer; cb: id; s: scene.Scene; target: id;
              d: var drawState) =
  ## Encodes drawing s into target with d, in the format r.cur is.
  d.b.blurredImage = proc(i: scene.Image; bk: scene.Backdrop): uint =
    r.blurImage(cb, i, bk)
  let built = d.b.build(s, proc(i: scene.Image): uint =
    r.imageTexture(i))
  if d.b.instances.len > d.instCap:
    rel(d.instBuf)
    let capacity = max(d.b.instances.len * 3 div 2, 1024)
    d.instBuf = send(r.device, "newBufferWithLength:options:",
                     (capacity * gpu.instanceSize).uint, 0) # shared
    if d.instBuf.isNil:
      d.instCap = 0
      raise newException(ValueError,
                         "metal: cannot create the instance buffer")
    d.instCap = capacity
  if d.b.instances.len > 0:
    copyMem(send(d.instBuf, "contents"), addr d.b.instances[0],
            d.b.instances.len * gpu.instanceSize)

  r.fitBackdrop(d.b)
  var enc = r.beginRender(cb, target, loadActionClear, built, d.b)
  var bound = r.empty
  var pipe = r.cur.pipeline
  for b in d.b.batches:
    # Metal requires scissor rectangles within the target.
    var sc = b.scissor
    sc.left = max(sc.left, 0)
    sc.top = max(sc.top, 0)
    sc.right = min(sc.right, built.width.int32)
    sc.bottom = min(sc.bottom, built.height.int32)
    if b.count == 0 or sc.empty():
      continue
    var want = r.cur.pipeline
    if b.effect != nil:
      want = r.effectPipeline(b.effect)
      if want.isNil:
        continue
    elif b.hole:
      want = r.cur.holePipe
    if b.backdrop != 0:
      # The effect shows what is drawn so far.
      discard send(enc, "endEncoding")
      r.readBackdrop(cb, target, d.b.backdrops[b.backdrop - 1])
      enc = r.beginRender(cb, target, loadActionLoad, built, d.b)
      discard send(enc, "setFragmentTexture:atIndex:",
                   r.cur.backdrop[0].tex, 3)
      bound = r.empty
      pipe = r.cur.pipeline
    if want != pipe:
      pipe = want
      discard send(enc, "setRenderPipelineState:", pipe)
    if b.image != 0 and b.image != cast[uint](bound):
      bound = cast[id](b.image)
      discard send(enc, "setFragmentTexture:atIndex:", bound, 2)
    discard send(enc, "setFragmentTexture:atIndex:",
                 orId(cast[id](b.clipMask), r.empty), 4)
    let offset = (b.start * gpu.instanceSize).uint
    discard send(enc, "setVertexBuffer:offset:atIndex:",
                 d.instBuf, offset, 0)
    discard send(enc, "setFragmentBuffer:offset:atIndex:",
                 d.instBuf, offset, 0)
    msgSetScissor(enc, sel("setScissorRect:"),
      mtlScissorRect(x: sc.left.uint, y: sc.top.uint,
                     w: (sc.right - sc.left).uint,
                     h: (sc.bottom - sc.top).uint))
    discard send(enc,
      "drawPrimitives:vertexStart:vertexCount:instanceCount:",
      primitiveTriStrip, 0, 4, b.count.uint)
  discard send(enc, "endEncoding")

proc drawCanvas(r: Renderer; cb: id; c: scene.Image) =
  ## Draws a canvas into its texture, unless it holds its version
  ## already.
  var t = r.canvases.getOrDefault(c.id)
  if t == nil:
    new(t)
    t.canvas = c
    r.canvases[c.id] = t
  t.lastFrame = r.frame
  if not t.tex.isNil and t.w == c.w and t.h == c.h and
      t.ver == c.version:
    return
  if t.tex.isNil or t.w != c.w or t.h != c.h:
    rel(t.tex)
    t.tex = r.newTexture(c.w, c.h, pixelFormatBGRA8Unorm,
      usageRenderTarget or usageShaderRead, [], 0)
    if t.tex.isNil:
      raise newException(ValueError,
                         "metal: cannot create a canvas's texture")
    t.w = c.w
    t.h = c.h
  # In BGRA8, in sRGB, whatever the frame's format.
  let saved = r.cur
  defer: r.cur = saved
  r.cur = addr r.formats[0]
  if r.cur.pipeline.isNil:
    r.makePipelines(r.cur)
  let cs = c.scene
  cs.width = c.w
  cs.height = c.h
  t.d.b.wide = false
  r.drawInto(cb, cs, t.tex, t.d)
  t.ver = c.version

proc encode(r: Renderer; s: scene.Scene; target: id): id =
  ## Encodes drawing s into target, returning the autoreleased
  ## command buffer, not yet committed.
  r.initGPU()
  if r.cur.pipeline.isNil:
    r.makePipelines(r.cur)
  inc r.frame
  r.used = 0
  r.syncAtlas(r.mask, s.maskAtlas, pixelFormatR8Unorm)
  r.syncAtlas(r.color, s.colorAtlas, pixelFormatRGBA8Unorm)
  let cb = send(r.queue, "commandBuffer")
  if not r.checked:
    need(cb, "command buffer",
      "renderCommandEncoderWithDescriptor:", "commit",
      "presentDrawable:", "waitUntilScheduled", "waitUntilCompleted",
      "status", "blitCommandEncoder")
  # Canvases first, into textures of their own, which the frame
  # samples.
  var firstErr: ref CatchableError
  s.eachCanvas(proc(c: scene.Image) =
    if firstErr.isNil:
      try:
        r.drawCanvas(cb, c)
      except CatchableError as e:
        firstErr = e)
  if not firstErr.isNil:
    raise firstErr
  r.ds.b.wide = r.cur.format == pixelFormatRGBA16Float
  r.drawInto(cb, s, target, r.ds)
  result = cb

## hasHoles reports whether s has holes (scene.opHole), where it shows
## web views under it.
proc hasHoles(s: scene.Scene): bool =
  for op in s.ops:
    if op.kind == opHole:
      return true
  return false

proc releaseTextures(r: Renderer) =
  ## Frees what the GPU's frames use, once the window is idle. The
  ## next frame makes them again, uploading the atlases whole.
  rel(r.mask.tex)
  rel(r.color.tex)
  var gone: seq[uint64]
  for key, t in r.images.pairs:
    rel(t.tex)
    gone.add key
  for key in gone:
    r.images.del(key)
  gone.setLen(0)
  for key, t in r.canvases.pairs:
    rel(t.tex)
    t.d.release()
    gone.add key
  for key in gone:
    r.canvases.del(key)
  for i in 0 ..< r.blurred.len:
    rel(r.blurred[i].tex)
  r.blurred.setLen(0)
  r.used = 0
  for i in 0 ..< r.blurTmp.len:
    rel(r.blurTmp[i].tex)
    r.blurTmp[i] = texture()
  rel(r.ds.instBuf)
  r.ds.instCap = 0
  for i in 0 ..< r.formats.len:
    for j in 0 ..< r.formats[i].backdrop.len:
      rel(r.formats[i].backdrop[j].tex)
      r.formats[i].backdrop[j] = texture()
  r.ds.b.release()
  r.ds.b = gpu.Builder()

## trimAfter is how long a window draws nothing before its spare
## drawables go: about when the Metal driver frees its own memory of
## frames.
const trimAfter = 2.0

proc armTrim(r: Renderer) =
  ## Has the renderer's timer trim the drawables once it draws
  ## nothing for trimAfter.
  if r.trimArmed:
    return
  if r.trimTimer.isNil:
    inc lastTrimHandle
    r.trimHandle = lastTrimHandle
    var ctx = cfTimerContext(info: cast[pointer](r.trimHandle))
    # Its first fire date comes below; it repeats only in theory.
    r.trimTimer = cfRunLoopTimerCreate(nil,
      cfAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
      trimCallback, addr ctx)
    if r.trimTimer.isNil:
      return
    trimTimers[r.trimHandle] = r
    cfRunLoopAddTimer(cfRunLoopGetMainL(), r.trimTimer, commonModes)
  cfRunLoopTimerSetNextFireDate(r.trimTimer,
    cfAbsoluteTimeGetCurrent() + trimAfter)
  r.trimArmed = true

proc trim(r: Renderer) =
  ## Gives back the drawables the layer does not show. Shrinking them
  ## frees those, and Core Animation keeps showing the last frame; the
  ## next makes them again at full size.
  if r.layer.isNil or r.trimmed:
    return
  withPool(proc() =
    r.waitLast()
    r.releaseTextures()
    let tx = `class`("CATransaction")
    discard send(tx, "begin")
    discard send(tx, "setDisableActions:", 1)
    msgSetSize(r.layer, sel("setDrawableSize:"),
               NSSize(width: 1, height: 1))
    discard send(tx, "commit"))
  r.trimmed = true

proc trimIfIdle(r: Renderer) =
  ## Trims the drawables if the window drew nothing for trimAfter,
  ## and waits for that time otherwise.
  let wait = trimAfter - (epochTime() - r.lastRender)
  if wait > 0:
    cfRunLoopTimerSetNextFireDate(r.trimTimer,
      cfAbsoluteTimeGetCurrent() + wait)
    return
  r.trimArmed = false
  cfRunLoopTimerSetNextFireDate(r.trimTimer,
    cfAbsoluteTimeGetCurrent() + 1e9)
  r.trim()

proc fit(r: Renderer; w, h: int; scale: float64): bool =
  ## Sizes the layer and its drawables for frames of w×h pixels at
  ## scale, and as its view, and reports whether they changed.
  let bounds = msgRect(r.superlayer, sel("bounds"))
  if w == r.w and h == r.h and scale == r.scale and
      sameRect(bounds, r.bounds) and not r.trimmed:
    return false
  # Without animating the change, as layers do by default.
  let tx = `class`("CATransaction")
  discard send(tx, "begin")
  discard send(tx, "setDisableActions:", 1)
  msgSetRect(r.layer, sel("setFrame:"), bounds)
  msgSetFloat(r.layer, sel("setContentsScale:"), scale)
  msgSetSize(r.layer, sel("setDrawableSize:"),
             NSSize(width: w.float64, height: h.float64))
  discard send(tx, "commit")
  r.w = w
  r.h = h
  r.scale = scale
  r.bounds = bounds
  r.trimmed = false
  result = true

## behindAfter is how long a frame presented as soon as drawn waits
## for its drawable before the next skips a refresh (behind), at most
## once a second: a drawable frees within a millisecond or so while
## frames show at the refresh after they present.
const behindAfter = 0.004

proc renderIn(r: Renderer; s: scene.Scene) =
  r.waitLast()
  if not r.err.isNil:
    raise r.err
  var scale = s.scale.float64
  if scale <= 0:
    scale = 1
  r.cur = addr r.formats[0]
  if r.wide:
    r.cur = addr r.formats[1]
  var changed = r.setLayerWide(r.wide)
  changed = r.fit(s.width, s.height, scale) or changed
  # A frame changing the layer, or showing web views, which move with
  # the window's other changes, presents with the Core Animation
  # transaction, so that they show together, as during a live resize.
  # Others present as soon as the GPU has them, sparing a commit of
  # the transaction for each.
  let holes = hasHoles(s)
  let sync = changed or holes or r.holes
  r.holes = holes
  let now = epochTime()
  r.behind = not sync and r.waited and now - r.lastRender < 0.05 and
    now - r.skippedAt > 1
  r.waited = false
  if r.behind:
    # The last frame waited for a drawable, as the display held both
    # until its next refresh: the frames following it would wait as
    # long, most of each refresh, blocking the main thread. Drawing
    # none for a refresh catches up.
    r.skippedAt = now
    return
  if sync != r.synced:
    discard send(r.layer, "setPresentsWithTransaction:",
                 (if sync: 1 else: 0).uint)
    r.synced = sync
  let drawable = send(r.layer, "nextDrawable")
  if drawable.isNil:
    return # none came within a second: skip the frame
  r.waited = not sync and epochTime() - now > behindAfter
  let texture = send(drawable, "texture")
  let cb = r.encode(s, texture)
  if sync:
    discard send(cb, "commit")
    discard send(cb, "waitUntilScheduled")
    discard send(drawable, "present")
  else:
    discard send(cb, "presentDrawable:", drawable)
    discard send(cb, "commit")
  r.last = retain(cb)
  r.lastRender = epochTime()
  r.armTrim()
  # Forget the textures of images no frame drew for a while, and
  # those of canvases gone.
  if r.frame mod 120 == 0:
    var gone: seq[uint64]
    for key, t in r.images.pairs:
      if r.frame - t.lastFrame > 240:
        rel(t.tex)
        gone.add key
    for key in gone:
      r.images.del(key)
    gone.setLen(0)
    for key, t in r.canvases.pairs:
      if t.canvas.isNil or r.frame - t.lastFrame > 240:
        rel(t.tex)
        t.d.release()
        gone.add key
    for key in gone:
      r.canvases.del(key)

proc render*(r: Renderer; s: scene.Scene) =
  ## Draws s into the layer and presents it.
  if s.width <= 0 or s.height <= 0 or r.layer.isNil:
    return
  withPool(proc() = r.renderIn(s))

proc behind*(r: Renderer): bool =
  ## Whether the last render drew nothing, to catch up with the
  ## display: the window draws the frame again at the next refresh.
  r.behind

proc renderOffscreen(r: Renderer; s: scene.Scene): seq[byte] =
  ## Draws s into a texture of its own and returns its premultiplied
  ## BGRA rows, for tests.
  var pix: seq[byte]
  withPool(proc() =
    r.waitLast()
    r.cur = addr r.formats[0]
    var tex = r.newTexture(s.width, s.height, pixelFormatBGRA8Unorm,
      usageRenderTarget or usageShaderRead, [], 0)
    if tex.isNil:
      raise newException(ValueError, "metal: cannot create a target")
    defer: rel(tex)
    let cb = r.encode(s, tex)
    let blit = send(cb, "blitCommandEncoder")
    discard send(blit, "synchronizeResource:", tex)
    discard send(blit, "endEncoding")
    discard send(cb, "commit")
    discard send(cb, "waitUntilCompleted")
    if cast[int](send(cb, "status")) == statusError:
      raise newException(ValueError, "metal: the frame failed: " &
        describe(send(cb, "error")))
    pix = newSeq[byte](s.width * s.height * 4)
    msgGetBytes(tex, sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:"),
      addr pix[0], (s.width * 4).uint,
      mtlRegion(w: s.width.uint, h: s.height.uint, d: 1), 0))
  result = pix

proc release*(r: Renderer) =
  ## Frees the renderer's GPU objects and takes its layer out.
  r.ds.b.release()
  if not r.trimTimer.isNil:
    cfRunLoopTimerInvalidate(r.trimTimer)
    cfReleaseL(r.trimTimer)
    trimTimers.del(r.trimHandle)
    r.trimTimer = nil
  withPool(proc() =
    r.waitLast()
    if not r.layer.isNil:
      let tx = `class`("CATransaction")
      discard send(tx, "begin")
      discard send(tx, "setDisableActions:", 1)
      discard send(r.layer, "removeFromSuperlayer")
      discard send(tx, "commit")
      rel(r.layer)
    r.releaseTextures()
    rel(r.empty)
    rel(r.sampler)
    for i in 0 ..< r.formats.len:
      let f = addr r.formats[i]
      rel(f.pipeline)
      rel(f.holePipe)
      rel(f.downPipe)
      rel(f.blurPipe)
      for _, p in f.effects.pairs:
        rel(p.pipe)
    rel(r.queue)
    rel(r.device))

proc initRenderer(r: Renderer) =
  r.device = createDevice() # owned: NS_RETURNS_RETAINED
  need(r.device, "Metal device", "newCommandQueue",
    "newLibraryWithSource:options:error:",
    "newRenderPipelineStateWithDescriptor:error:",
    "newSamplerStateWithDescriptor:", "newTextureWithDescriptor:",
    "newBufferWithLength:options:")

proc makeRenderer(): Renderer =
  ## A renderer without a layer, for new and tests.
  load()
  result = Renderer(images: initTable[uint64, ref texture]())
  result.formats[0].format = pixelFormatBGRA8Unorm
  result.formats[1].format = pixelFormatRGBA16Float
  result.cur = addr result.formats[0]
  let r = result
  try:
    withPool(proc() = r.initRenderer())
  except CatchableError:
    r.release()
    raise

proc new*(layer: uint): Renderer =
  ## A renderer drawing into a CAMetalLayer that it adds to layer, the
  ## layer of a view, and sizes as it.
  if layer == 0:
    raise newException(ValueError, "metal: no layer")
  result = makeRenderer()
  let r = result
  try:
    withPool(proc() =
      if `class`("CAMetalLayer").isNil:
        raise newException(ValueError, "metal: no CAMetalLayer")
      var ml = send(send(`class`("CAMetalLayer"), "alloc"), "init")
      defer: rel(ml)
      need(ml, "CAMetalLayer", "setDevice:", "setPixelFormat:",
        "setFramebufferOnly:", "setPresentsWithTransaction:",
        "setColorspace:", "setDrawableSize:", "setContentsScale:",
        "setFrame:", "setAutoresizingMask:", "nextDrawable")
      discard send(ml, "setDevice:", r.device)
      discard send(ml, "setPixelFormat:", pixelFormatBGRA8Unorm)
      # Effects read their backdrops from the drawable, which their
      # passes sample then.
      discard send(ml, "setFramebufferOnly:", 0)
      # Frames wait for the last to finish, so two drawables do,
      # rather than the three Core Animation makes otherwise while a
      # window animates: one less frame of memory.
      if respondsTo(ml, "setMaximumDrawableCount:"):
        discard send(ml, "setMaximumDrawableCount:", 2)
      # The first frame shows with the window's other changes;
      # render decides for each frame.
      discard send(ml, "setPresentsWithTransaction:", 1)
      r.synced = true
      discard send(ml, "setColorspace:", srgb)
      discard send(ml, "setOpaque:", 0)
      discard send(ml, "setAutoresizingMask:",
                   layerWidthSizable or layerHeightSizable)
      discard send(cast[id](layer), "addSublayer:", ml)
      r.layer = ml
      r.superlayer = cast[id](layer)
      ml = nil)
  except CatchableError:
    r.release()
    raise

proc renderOffscreen*(s: scene.Scene): seq[byte] =
  ## Draws s with a renderer of its own into a texture, without a
  ## layer, and returns its premultiplied BGRA rows: for tests, as
  ## packages drawing effects have.
  let r = makeRenderer()
  defer: r.release()
  result = r.renderOffscreen(s)

proc compileLibrary*(src: string): seq[byte] =
  ## Compiles Metal Shading Language into a Metal library with
  ## Xcode's metal tools, for code compiled ahead of time:
  ## regeneration runs it, for the renderer's shader
  ## (shader.metallib) and effects' (effectSource).
  let dir = createTempDir("metal", "")
  defer: removeDir(dir)
  let inp = dir / "shader.metal"
  let air = dir / "shader.air"
  let lib = dir / "shader.metallib"
  writeFile(inp, src)
  # macOS 12 is the oldest MyGo runs on.
  for args in [
    @["-sdk", "macosx", "metal", "-c", inp, "-o", air,
      "-mmacosx-version-min=12.0"],
    @["-sdk", "macosx", "metallib", air, "-o", lib]]:
    let cmd = "xcrun " & args.join(" ")
    let (outp, code) = execCmdEx(cmd)
    if code != 0:
      raise newException(ValueError, "metal: " & args[2] & ": " &
        strip(outp))
  let b = readFile(lib)
  result = newSeq[byte](b.len)
  copyMem(addr result[0], addr b[0], b.len)
