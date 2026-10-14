## glprobe.nim: surfaces draw with OpenGL only where it runs on a GPU. A
## software renderer, such as Mesa's llvmpipe in virtual machines and in
## WSL, redraws the whole window on the CPU every frame, many times the
## work of drawing in memory, which redraws what changed; and once a
## window has a GL context, GTK composites the window with OpenGL, so
## the choice is made before: with a context GDK makes for a window that
## never shows, as the surfaces' would be, as the first window of
## native UI is made.

var
  glProbeDeviceOnce, glProbeOnce: bool
  glProbeHasDevice, glProbeGPU: bool

proc gpuDevice*(): bool
proc gpuDeviceIn*(root, gallium: string): bool
proc softwareGL(renderer: string): bool
proc failed(gerr: pointer): string

## hasGPUDevice reports whether the system has a device OpenGL could
## draw on (gpuDevice), saying once when it has none.
proc hasGPUDevice*(): bool =
  if not glProbeDeviceOnce:
    glProbeDeviceOnce = true
    glProbeHasDevice = gpuDevice()
    if glProbeHasDevice:
      return true
    # Without a GPU device, GL draws on the CPU: the probe, whose
    # driver stays loaded, would cost memory to say so.
    if fileExists("/dev/dxg"):
      echo "mynim: native UI draws without the GPU: Mesa draws on the " &
        "CPU in WSL, unless GALLIUM_DRIVER=d3d12"
    else:
      echo "mynim: native UI draws without the GPU: there is none"
  glProbeHasDevice

## gdkWindowAttr is GdkWindowAttr, for gdk_window_new.
type gdkWindowAttr = object
  title: pointer
  eventMask: int32
  x, y, width, height: int32
  wclass: int32
  visual: pointer
  windowType: int32
  cursor: pointer
  wmclassName, wmclassClass: pointer
  overrideRedirect: int32
  typeHint: int32

## gdkGL holds GDK's functions of OpenGL contexts.
var
  gdkGLOnce, gdkGLOk: bool
  gdkGLCreateContext: proc(w: pointer, err: ptr pointer): pointer {.cdecl.}
  gdkGLRequireVersion: proc(c: pointer, major, minor: int32) {.cdecl.}
  gdkGLSetUseES: proc(c: pointer, use: int32) {.cdecl.}
  gdkGLRealize: proc(c: pointer, err: ptr pointer): bool {.cdecl.}

proc loadGDKGL*(): bool =
  if not gdkGLOnce:
    gdkGLOnce = true
    gdkGLOk =
      bindFunc(libGDK, cast[ptr pointer](addr gdkGLCreateContext),
        "gdk_window_create_gl_context") and
      bindFunc(libGDK, cast[ptr pointer](addr gdkGLRequireVersion),
        "gdk_gl_context_set_required_version") and
      bindFunc(libGDK, cast[ptr pointer](addr gdkGLRealize),
        "gdk_gl_context_realize")
    if not bindFunc(libGDK, cast[ptr pointer](addr gdkGLSetUseES),
        "gdk_gl_context_set_use_es"):
      gdkGLSetUseES = nil
  gdkGLOk

## glContext makes and realizes an OpenGL context for a GdkWindow, as the
## renderer draws with: OpenGL 3.3, else OpenGL ES 3.0, for GPUs with
## OpenGL ES alone and GDK_GL=gles. It returns the context, or the
## GError of the last try.
proc glContext*(win: pointer): tuple[ctx, gerr: pointer] =
  if not loadGDKGL():
    return (nil, nil)
  var gerr: pointer
  for es in [false, true]:
    if es and gdkGLSetUseES.isNil:
      break
    if not gerr.isNil:
      gErrorFree(gerr)
      gerr = nil
    let ctx = gdkGLCreateContext(win, addr gerr)
    if ctx.isNil:
      return (nil, gerr)
    if es:
      gdkGLSetUseES(ctx, 1)
      gdkGLRequireVersion(ctx, 3, 0)
    else:
      gdkGLRequireVersion(ctx, 3, 3)
    if gdkGLRealize(ctx, addr gerr):
      return (ctx, nil)
    gObjectUnref(ctx)
  (nil, gerr)

## probeGL makes an OpenGL context as a GtkGLArea would and returns the
## name of its renderer, or why there is none.
proc probeGL*(): tuple[renderer, failure: string] =
  var windowNew: proc(parent: pointer, attr: ptr gdkWindowAttr,
                      mask: int32): pointer {.cdecl.}
  var windowDestroy: proc(w: pointer) {.cdecl.}
  var makeCurrent: proc(c: pointer) {.cdecl.}
  var clearCurrent: proc() {.cdecl.}
  var haveSyms = loadGDKGL()
  haveSyms = bindFunc(libGDK, cast[ptr pointer](addr windowNew),
    "gdk_window_new") and haveSyms
  haveSyms = bindFunc(libGDK, cast[ptr pointer](addr windowDestroy),
    "gdk_window_destroy") and haveSyms
  haveSyms = bindFunc(libGDK, cast[ptr pointer](addr makeCurrent),
    "gdk_gl_context_make_current") and haveSyms
  haveSyms = bindFunc(libGDK, cast[ptr pointer](addr clearCurrent),
    "gdk_gl_context_clear_current") and haveSyms
  if not haveSyms:
    return ("", "GDK has no OpenGL")
  let epoxy = dlopen("libepoxy.so.0", RTLD_NOW or RTLD_GLOBAL)
  if epoxy.isNil:
    return ("", "no libepoxy")
  # libepoxy exports a pointer to each GL function.
  let sym = cast[ptr pointer](dlsym(epoxy, "epoxy_glGetString"))
  if sym.isNil or sym[].isNil:
    return ("", "no glGetString")
  let getString = cast[proc(name: uint32): pointer {.cdecl.}](sym[])

  const inputOutput = 0'i32
  const toplevel = 1'i32
  var attr = gdkWindowAttr(width: 1, height: 1, wclass: inputOutput,
    windowType: toplevel)
  let win = windowNew(nil, addr attr, 0)
  if win.isNil:
    return ("", "cannot make a window")
  defer:
    windowDestroy(win)
    gObjectUnref(win) # with the GL context GDK made for painting it
  let (ctx, gerr) = glContext(win)
  if ctx.isNil:
    return ("", failed(gerr))
  defer: gObjectUnref(ctx)
  makeCurrent(ctx)
  defer: clearCurrent()
  const glRenderer = 0x1F01'u32
  (goStr(getString(glRenderer)), "")

## failed describes a GError of GDK's OpenGL.
proc failed(gerr: pointer): string =
  let err = gErr(gerr)
  if not err.isNil:
    return err.msg
  "no OpenGL context"

## gpuGL reports whether GDK's OpenGL contexts draw on a GPU.
proc gpuGL*(): bool =
  if not glProbeOnce:
    glProbeOnce = true
    # MYGO_GPU=1 draws with OpenGL wherever GDK makes a context, on the
    # CPU too: tests of the GL surface run so without a GPU.
    if getEnv("MYGO_GPU") == "1":
      glProbeGPU = true
      return true
    if not hasGPUDevice():
      return false
    let (renderer, failure) = probeGL()
    if failure != "":
      echo "mynim: native UI draws without the GPU: " & failure
    elif softwareGL(renderer):
      echo "mynim: native UI draws without the GPU: OpenGL draws on " &
        "the CPU (" & renderer & ")"
    else:
      glProbeGPU = true
  glProbeGPU

proc softwareGL(renderer: string): bool =
  let r = renderer.toLower
  for s in ["llvmpipe", "softpipe", "swrast", "software rasterizer"]:
    if s in r: return true
  false

# displayOnly are DRM drivers that only show what the CPU drew.
var displayOnly = {
  "simpledrm": true, "simple-framebuffer": true, "bochs": true,
  "bochs-drm": true, "cirrus": true, "cirrus-qemu": true,
  "vboxvideo": true, "hyperv_drm": true, "ast": true, "mgag200": true,
  "udl": true, "vkms": true}.toTable

## gpuDevice reports whether the system has a device OpenGL could draw
## on: NVIDIA's, or a render node of a DRM driver with 3D. Mesa draws on
## the CPU, loading as much as the probe would for nothing, on
## display-only drivers, as virtual machines and servers have, and on
## WSL's device unless GALLIUM_DRIVER=d3d12 gives it the GPU.
proc gpuDevice*(): bool =
  gpuDeviceIn("/", getEnv("GALLIUM_DRIVER"))

proc gpuDeviceIn*(root, gallium: string): bool =
  if walkPattern(root / "dev" / "nvidia*").toSeq.len > 0:
    return true
  for node in walkPattern(root / "sys" / "class" / "drm" / "renderD*"):
    var driver: string
    try:
      driver = expandSymlink(node / "device" / "driver")
    except OSError:
      discard
    if driver == "" or not displayOnly.getOrDefault(driver.lastPathPart):
      return true # a GPU's, or one to probe
  if fileExists(root / "dev" / "dxg"):
    return gallium == "d3d12"
  false
