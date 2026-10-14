## gl.go + load_linux.go + load_js.go + present.go + offscreen.go +
## read.go — scenes drawn with OpenGL 3.3, OpenGL ES 3.0 or WebGL 2
## into the framebuffer bound when render is called: the one GTK's
## GtkGLArea binds while it emits its render signal, or a canvas's
## (package web). Every op of a scene is an instanced quad drawn by one
## shader (shader.glsl, compiled when the renderer starts), from the
## instances package gpu builds; clips are scissor rectangles, with the
## innermost rounded clip computed in the shader, as in packages d3d11
## and metal. GL functions come from libepoxy on Linux, which GTK
## resolves its own through, called without cgo, and from the current
## WebGL 2 context in browsers.

import std/[math, strutils, tables]
import ../gpu, ../scene, ../../image

when defined(emscripten):
  import ../web/js
else:
  import std/dynlib

const shaderSource = staticRead("gl/shader.glsl")
const effectSourceRaw = staticRead("gl/effect.glsl")

proc effectSource*(src: string): string =
  ## The source of an effect's fragment shader, after the version
  ## header: shader.glsl with EFFECT defined, the head of effect.glsl,
  ## the effect's shader (see scene.Effect), and the tail, which draws
  ## its instances with it.
  let idx = effectSourceRaw.find("\n// effect\n")
  let head = if idx >= 0: effectSourceRaw[0 ..< idx] else: effectSourceRaw
  let tail = if idx >= 0: effectSourceRaw[idx + len("\n// effect\n") .. ^1] else: ""
  "#define EFFECT\n" & shaderSource & "\n" & head & "\n" & src & "\n" & tail

## OpenGL enumerations.
const
  glTriangleStrip* = 0x0005'u32
  glBlend* = 0x0BE2'u32
  glScissorTest* = 0x0C11'u32
  glZero* = 0'u32
  glOne* = 1'u32
  glOneMinusSrcAlpha* = 0x0303'u32
  glOneMinusSrc1Color* = 0x88FA'u32
  glOneMinusSrc1Alpha* = 0x88FB'u32
  glColorBufferBit* = 0x4000'u32
  glArrayBuffer* = 0x8892'u32
  glStreamDraw* = 0x88E0'u32
  glFloat* = 0x1406'u32
  glUnsignedByte* = 0x1401'u32
  glTexture2D* = 0x0DE1'u32
  glTexture0* = 0x84C0'u32
  glTextureMinFilter* = 0x2801'u32
  glTextureMagFilter* = 0x2800'u32
  glTextureWrapS* = 0x2802'u32
  glTextureWrapT* = 0x2803'u32
  glLinear* = 0x2601'u32
  glClampToEdge* = 0x812F'u32
  glR8* = 0x8229'u32
  glRed* = 0x1903'u32
  glRGBA8* = 0x8058'u32
  glRGBA* = 0x1908'u32
  glUnpackAlignment* = 0x0CF5'u32
  glUnpackRowLength* = 0x0CF2'u32
  glVertexShader* = 0x8B31'u32
  glFragmentShader* = 0x8B30'u32
  glCompileStatus* = 0x8B81'u32
  glLinkStatus* = 0x8B82'u32
  glInfoLogLength* = 0x8B84'u32
  glMaxTextureSize* = 0x0D33'u32
  glVersion* = 0x1F02'u32
  glRenderer* = 0x1F01'u32
  glFramebuffer* = 0x8D40'u32
  glColorAttachment0* = 0x8CE0'u32
  glFramebufferDone* = 0x8CD5'u32
  glFramebufferBinding* = 0x8CA6'u32
  glPackAlignment* = 0x0D05'u32
  glReadFramebuffer* = 0x8CA8'u32
  glDrawFramebuffer* = 0x8CA9'u32
  glNearest* = 0x2600'u32
  glNoError* = 0'u32

when defined(emscripten):
  ## load_js.go — the WebGL 2 side.

  type Context* = ref object
    ## The WebGL 2 context of a canvas, which renderers draw with
    ## while it is current (makeCurrent), as a GL context on Linux.
    ## WebGL names its objects by JavaScript objects, GL by numbers:
    ## the package numbers them, and the functions GL's renderer calls
    ## take and return those numbers.
    v*: JsValue
    id*: uint
    ## dual tells that the context has WEBGL_blend_func_extended,
    ## enabled.
    dual*: bool
    ## The pixel store's unpacking, which uploads read pixels by.
    unpackAlign*, unpackRow*: int32
    ## scratch is a Uint8Array that bytes are copied into for WebGL to
    ## read, grown as needed.
    scratch*: JsValue
    size*: int

  var
    ## cur is the current context.
    cur*: Context
    ## objects are the WebGL objects by their numbers, which their
    ## property objectKey holds too; locations the uniform locations.
    objects: Table[uint32, JsValue]
    locations: seq[JsValue]
    lastName: uint32
    lastID: uint
    ## errLoad is load's error on Linux; the browser has nothing to
    ## load.
    errLoad: ref CatchableError

  ## objectKey is the property of a WebGL object holding its number.
  const objectKey = "__mynim"

  proc renew*(c: Context)

  proc newContext*(canvas: JsValue): tuple[c: Context, err: ref CatchableError] =
    ## The WebGL 2 context of canvas, which draws premultiplied colors
    ## without depth, stencil or antialiasing, as frames need: the
    ## renderer cuts shapes' edges itself. It fails where the browser
    ## has no WebGL 2, or will not make a context for the canvas.
    let attrs = jsObj()
    jsSet(attrs, "alpha", jsValueOf(true))
    jsSet(attrs, "premultipliedAlpha", jsValueOf(true))
    jsSet(attrs, "antialias", jsValueOf(false))
    jsSet(attrs, "depth", jsValueOf(false))
    jsSet(attrs, "stencil", jsValueOf(false))
    jsSet(attrs, "preserveDrawingBuffer", jsValueOf(false))
    jsSet(attrs, "powerPreference", jsValueOf("default"))
    let v = jsCall(canvas, "getContext", [jsValueOf("webgl2"), attrs])
    if jsIsNull(v) or jsIsUndefined(v):
      return (nil, newException(CatchableError,
        "gl: the browser has no WebGL 2"))
    let c = Context(v: v, unpackAlign: 4)
    c.renew()
    (c, nil)

  proc renew*(c: Context) =
    lastID += 1
    c.id = lastID
    c.dual = not jsIsNull(jsCall(c.v, "getExtension",
                                 [jsValueOf("WEBGL_blend_func_extended")]))
    c.unpackAlign = 4
    c.unpackRow = 0

  proc id*(c: Context): uint = c.id
    ## The context's number, which changes with renew.

  proc lost*(c: Context): bool =
    ## Whether the browser took the context away.
    jsBool(jsCall(c.v, "isContextLost", []))

  proc makeCurrent*(c: Context) =
    ## Makes c the context renderers draw with.
    cur = c

  proc load(): ref CatchableError =
    if cur.isNil:
      return newException(CatchableError, "gl: no WebGL context is current")
    nil

  proc currentContext(): uint =
    if cur.isNil: 0 else: cur.id

  proc contextVersion(): tuple[version: int32, es: bool] = (30'i32, true)

  proc hasExtension(name: string): bool =
    name == "GL_EXT_blend_func_extended" and cur.dual

  proc versionString(): string =
    jsString(jsCall(cur.v, "getParameter", [jsValueOf(int(glVersion))]))

  proc call(name: cstring, args: varargs[JsValue]): JsValue =
    jsCall(cur.v, name, args)

  ## name numbers a new WebGL object.
  proc name(v: JsValue): uint32 =
    if jsIsNull(v): return 0
    lastName += 1
    objects[lastName] = v
    jsSet(v, objectKey, jsValueOf(int(lastName)))
    lastName

  ## object returns the WebGL object of a number, null for 0.
  proc objectOf(n: uint32): JsValue =
    if n == 0: return jsNullV
    objects.getOrDefault(n, jsNullV)

  ## number returns the number of a WebGL object, 0 for null.
  proc number(v: JsValue): uint32 =
    if jsIsNull(v) or jsIsUndefined(v): return 0
    uint32(jsInt(jsGet(v, objectKey)))

  proc deleteObjects(fn: cstring, n: int32, names: ptr uint32) =
    for i in 0 ..< int(n):
      let k = cast[ptr uint32](cast[uint](names) + uint(i * sizeof(uint32)))[]
      if objects.hasKey(k):
        discard call(fn, objects[k])
        objects.del(k)

  proc genObjects(fn: cstring, n: int32, `out`: ptr uint32) =
    for i in 0 ..< int(n):
      cast[ptr uint32](cast[uint](`out`) + uint(i * sizeof(uint32)))[] =
        name(call(fn))

  ## jsBytes copies n bytes at p into the scratch array, for WebGL to
  ## read.
  proc jsBytes(p: pointer, n: int): JsValue =
    if cur.size < n:
      cur.size = max(n, max(2 * cur.size, 1 shl 16))
      cur.scratch = jsNew(jsGet(jsGlobal(), "Uint8Array"),
                          [jsValueOf(cur.size)])
    jsCopyToJS(cur.scratch, cast[ptr UncheckedArray[byte]](p).toOpenArray(0, n - 1))
    cur.scratch

  ## uploadSize returns how many bytes an upload of w×h pixels reads,
  ## with the pixel store's unpacking.
  proc uploadSize(w, h: int32, format: uint32): int =
    var bpp = 4'i32
    if format == glRed:
      bpp = 1
    var row = w
    if cur.unpackRow > 0:
      row = cur.unpackRow
    let a = cur.unpackAlign
    let stride = (row * bpp + a - 1) div a * a
    int((h - 1) * stride + w * bpp)

  proc setShaderSource(s: uint32, src: string) =
    discard call("shaderSource", objectOf(s), jsValueOf(src))

  proc shaderLog(s: uint32): string =
    jsString(call("getShaderInfoLog", objectOf(s)))
  proc programLog(p: uint32): string =
    jsString(call("getProgramInfoLog", objectOf(p)))

  proc glGetError(): uint32 = uint32(jsInt(call("getError")))

  proc glGetIntegerv(param: uint32, data: ptr int32) =
    let v = call("getParameter", jsValueOf(int(param)))
    case param
    of glFramebufferBinding:
      data[] = int32(number(v))
    else:
      data[] = int32(jsInt(v))

  proc glCreateShader(typ: uint32): uint32 =
    name(call("createShader", jsValueOf(int(typ))))
  proc glCompileShader(s: uint32) =
    discard call("compileShader", objectOf(s))
  proc glDeleteShader(s: uint32) =
    var s2 = s
    deleteObjects("deleteShader", 1, addr s2)

  proc glGetShaderiv(s, param: uint32, `out`: ptr int32) =
    `out`[] = int32(jsBool(call("getShaderParameter", objectOf(s),
                                jsValueOf(int(param)))))

  proc glCreateProgram(): uint32 = name(call("createProgram"))
  proc glAttachShader(program, s: uint32) =
    discard call("attachShader", objectOf(program), objectOf(s))
  proc glLinkProgram(program: uint32) =
    discard call("linkProgram", objectOf(program))
  proc glUseProgram(program: uint32) =
    discard call("useProgram", objectOf(program))
  proc glDeleteProgram(program: uint32) =
    var p2 = program
    deleteObjects("deleteProgram", 1, addr p2)
  proc glBindVertexArray(array: uint32) =
    discard call("bindVertexArray", objectOf(array))
  proc glBindBuffer(target, buffer: uint32) =
    discard call("bindBuffer", jsValueOf(int(target)), objectOf(buffer))

  proc glGetProgramiv(program, param: uint32, `out`: ptr int32) =
    `out`[] = int32(jsBool(call("getProgramParameter", objectOf(program),
                                jsValueOf(int(param)))))

  proc glGetUniformLocation(program: uint32, uniform: cstring): int32 =
    let v = call("getUniformLocation", objectOf(program), jsValueOf($uniform))
    if jsIsNull(v): return -1
    locations.add v
    int32(locations.len - 1)

  proc location(l: int32): JsValue =
    if l < 0 or int(l) >= locations.len: return jsNullV
    locations[l]

  proc glUniform1i(l, v: int32) =
    discard call("uniform1i", location(l), jsValueOf(int(v)))
  proc glUniform2f(l: int32, x, y: float32) =
    discard call("uniform2f", location(l), jsValueOf(float64(x)),
                 jsValueOf(float64(y)))
  proc glUniform1f(l: int32, v: float32) =
    discard call("uniform1f", location(l), jsValueOf(float64(v)))
  proc glUniform2i(l, x, y: int32) =
    discard call("uniform2i", location(l), jsValueOf(int(x)),
                 jsValueOf(int(y)))

  proc glCopyTexSubImage2D(target: uint32, level, xoff, yoff, x, y, w, h: int32) =
    discard call("copyTexSubImage2D", jsValueOf(int(target)),
                 jsValueOf(int(level)), jsValueOf(int(xoff)),
                 jsValueOf(int(yoff)), jsValueOf(int(x)), jsValueOf(int(y)),
                 jsValueOf(int(w)), jsValueOf(int(h)))

  proc glGenVertexArrays(n: int32, `out`: ptr uint32) =
    genObjects("createVertexArray", n, `out`)
  proc glDeleteVertexArrays(n: int32, arrays: ptr uint32) =
    deleteObjects("deleteVertexArray", n, arrays)
  proc glGenBuffers(n: int32, `out`: ptr uint32) =
    genObjects("createBuffer", n, `out`)
  proc glDeleteBuffers(n: int32, buffers: ptr uint32) =
    deleteObjects("deleteBuffer", n, buffers)
  proc glGenTextures(n: int32, `out`: ptr uint32) =
    genObjects("createTexture", n, `out`)
  proc glDeleteTextures(n: int32, textures: ptr uint32) =
    deleteObjects("deleteTexture", n, textures)
  proc glGenFramebuffers(n: int32, `out`: ptr uint32) =
    genObjects("createFramebuffer", n, `out`)
  proc glDeleteFramebuffers(n: int32, fbs: ptr uint32) =
    deleteObjects("deleteFramebuffer", n, fbs)

  proc glBufferData(target: uint32, size: int, data: pointer, usage: uint32) =
    discard call("bufferData", jsValueOf(int(target)),
                 jsValueOf(size), jsValueOf(int(usage)))
    discard jsBytes(data, size)

  proc glEnableVertexAttrib(index: uint32) =
    discard call("enableVertexAttribArray", jsValueOf(int(index)))
  proc glVertexAttribPointer(index: uint32, size: int32, typ: uint32,
                             normalized: bool, stride: int32, offset: uint) =
    discard call("vertexAttribPointer", jsValueOf(int(index)),
                 jsValueOf(int(size)), jsValueOf(int(typ)),
                 jsValueOf(normalized), jsValueOf(int(stride)),
                 jsValueOf(float64(offset)))
  proc glVertexAttribDivisor(index, divisor: uint32) =
    discard call("vertexAttribDivisor", jsValueOf(int(index)),
                 jsValueOf(int(divisor)))
  proc glBindTexture(target, texture: uint32) =
    discard call("bindTexture", jsValueOf(int(target)), objectOf(texture))
  proc glActiveTexture(unit: uint32) =
    discard call("activeTexture", jsValueOf(int(unit)))

  proc glTexImage2D(target: uint32, level, internalFormat, w, h, border: int32,
                    format, typ: uint32, pix: pointer) =
    if pix.isNil:
      discard call("texImage2D", jsValueOf(int(target)),
                   jsValueOf(int(level)), jsValueOf(int(internalFormat)),
                   jsValueOf(int(w)), jsValueOf(int(h)),
                   jsValueOf(int(border)), jsValueOf(int(format)),
                   jsValueOf(int(typ)), jsNullV)
    else:
      discard call("texImage2D", jsValueOf(int(target)),
                   jsValueOf(int(level)), jsValueOf(int(internalFormat)),
                   jsValueOf(int(w)), jsValueOf(int(h)),
                   jsValueOf(int(border)), jsValueOf(int(format)),
                   jsValueOf(int(typ)),
                   jsBytes(pix, uploadSize(w, h, format)))

  proc glTexSubImage2D(target: uint32, level, x, y, w, h: int32,
                       format, typ: uint32, pix: pointer) =
    discard call("texSubImage2D", jsValueOf(int(target)),
                 jsValueOf(int(level)), jsValueOf(int(x)),
                 jsValueOf(int(y)), jsValueOf(int(w)), jsValueOf(int(h)),
                 jsValueOf(int(format)), jsValueOf(int(typ)),
                 jsBytes(pix, uploadSize(w, h, format)))

  proc glTexParameteri(target, param: uint32, v: int32) =
    discard call("texParameteri", jsValueOf(int(target)),
                 jsValueOf(int(param)), jsValueOf(int(v)))

  proc glPixelStorei(param: uint32, v: int32) =
    if param == glUnpackAlignment:
      cur.unpackAlign = v
    elif param == glUnpackRowLength:
      cur.unpackRow = v
    discard call("pixelStorei", jsValueOf(int(param)), jsValueOf(int(v)))

  proc glViewport(x, y, w, h: int32) =
    discard call("viewport", jsValueOf(int(x)), jsValueOf(int(y)),
                 jsValueOf(int(w)), jsValueOf(int(h)))
  proc glScissor(x, y, w, h: int32) =
    discard call("scissor", jsValueOf(int(x)), jsValueOf(int(y)),
                 jsValueOf(int(w)), jsValueOf(int(h)))
  proc glEnable(capability: uint32) =
    discard call("enable", jsValueOf(int(capability)))
  proc glDisable(capability: uint32) =
    discard call("disable", jsValueOf(int(capability)))
  proc glBlendFunc(src, dst: uint32) =
    discard call("blendFunc", jsValueOf(int(src)), jsValueOf(int(dst)))
  proc glClearColor(r, g, b, a: float32) =
    discard call("clearColor", jsValueOf(float64(r)),
                 jsValueOf(float64(g)), jsValueOf(float64(b)),
                 jsValueOf(float64(a)))
  proc glClear(mask: uint32) =
    discard call("clear", jsValueOf(int(mask)))
  proc glBindFramebuffer(target, fb: uint32) =
    discard call("bindFramebuffer", jsValueOf(int(target)), objectOf(fb))
  proc glCheckFramebufferState(target: uint32): uint32 =
    uint32(jsInt(call("checkFramebufferStatus", jsValueOf(int(target)))))
  proc glBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha: uint32) =
    discard call("blendFuncSeparate", jsValueOf(int(srcRGB)),
                 jsValueOf(int(dstRGB)), jsValueOf(int(srcAlpha)),
                 jsValueOf(int(dstAlpha)))
  proc glDrawArraysInstanced(mode: uint32, first, count, instances: int32) =
    discard call("drawArraysInstanced", jsValueOf(int(mode)),
                 jsValueOf(int(first)), jsValueOf(int(count)),
                 jsValueOf(int(instances)))

  proc glReadPixels(x, y, w, h: int32, format, typ: uint32, pix: pointer) =
    discard call("readPixels", jsValueOf(int(x)), jsValueOf(int(y)),
                 jsValueOf(int(w)), jsValueOf(int(h)),
                 jsValueOf(int(format)), jsValueOf(int(typ)),
                 jsBytes(pix, 4 * w * h))

  proc glFramebufferTexture2D(target, attachment, texTarget, texture: uint32,
                              level: int32) =
    discard call("framebufferTexture2D", jsValueOf(int(target)),
                 jsValueOf(int(attachment)), jsValueOf(int(texTarget)),
                 objectOf(texture), jsValueOf(int(level)))

  proc glBlitFramebuffer(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1: int32,
                         mask, filter: uint32) =
    discard call("blitFramebuffer", jsValueOf(int(sx0)),
                 jsValueOf(int(sy0)), jsValueOf(int(sx1)),
                 jsValueOf(int(sy1)), jsValueOf(int(dx0)),
                 jsValueOf(int(dy0)), jsValueOf(int(dx1)),
                 jsValueOf(int(dy1)), jsValueOf(int(mask)),
                 jsValueOf(int(filter)))

else:
  ## load_linux.go — the functions of libepoxy this package calls.
  var
    loadDone = false
    errLoad: ref CatchableError

    epoxyGLVersion: proc(): int32 {.cdecl.}
    epoxyIsDesktopGL: proc(): bool {.cdecl.}
    epoxyHasExtension: proc(name: cstring): bool {.cdecl.}
    currentGDKContext: proc(): uint {.cdecl.}

    glGetString: proc(name: uint32): pointer {.cdecl.}
    glGetError: proc(): uint32 {.cdecl.}
    glGetIntegerv: proc(name: uint32, data: ptr int32) {.cdecl.}
    glCreateShader: proc(typ: uint32): uint32 {.cdecl.}
    glShaderSource: proc(shader: uint32, count: int32,
                         sources: ptr cstring, lengths: ptr int32) {.cdecl.}
    glCompileShader: proc(shader: uint32) {.cdecl.}
    glGetShaderiv: proc(shader, name: uint32, `out`: ptr int32) {.cdecl.}
    glGetShaderInfoLog: proc(shader: uint32, size: int32,
                             length: ptr int32, log: cstring) {.cdecl.}
    glDeleteShader: proc(shader: uint32) {.cdecl.}
    glCreateProgram: proc(): uint32 {.cdecl.}
    glAttachShader: proc(program, shader: uint32) {.cdecl.}
    glLinkProgram: proc(program: uint32) {.cdecl.}
    glGetProgramiv: proc(program, name: uint32, `out`: ptr int32) {.cdecl.}
    glGetProgramInfoLog: proc(program: uint32, size: int32,
                              length: ptr int32, log: cstring) {.cdecl.}
    glUseProgram: proc(program: uint32) {.cdecl.}
    glDeleteProgram: proc(program: uint32) {.cdecl.}
    glGetUniformLocation: proc(program: uint32, name: cstring): int32 {.cdecl.}
    glUniform1i: proc(location, v: int32) {.cdecl.}
    glUniform2f: proc(location: int32, x, y: float32) {.cdecl.}
    glUniform1f: proc(location: int32, v: float32) {.cdecl.}
    glUniform2i: proc(location, x, y: int32) {.cdecl.}
    glCopyTexSubImage2D: proc(target: uint32, level, xoff, yoff, x, y,
                              w, h: int32) {.cdecl.}
    glGenVertexArrays: proc(n: int32, `out`: ptr uint32) {.cdecl.}
    glBindVertexArray: proc(array: uint32) {.cdecl.}
    glDeleteVertexArrays: proc(n: int32, arrays: ptr uint32) {.cdecl.}
    glGenBuffers: proc(n: int32, `out`: ptr uint32) {.cdecl.}
    glBindBuffer: proc(target, buffer: uint32) {.cdecl.}
    glBufferData: proc(target: uint32, size: int, data: pointer,
                       usage: uint32) {.cdecl.}
    glDeleteBuffers: proc(n: int32, buffers: ptr uint32) {.cdecl.}
    glEnableVertexAttrib: proc(index: uint32) {.cdecl.}
    glVertexAttribPointer: proc(index: uint32, size: int32, typ: uint32,
                                normalized: bool, stride: int32,
                                offset: uint) {.cdecl.}
    glVertexAttribDivisor: proc(index, divisor: uint32) {.cdecl.}
    glGenTextures: proc(n: int32, `out`: ptr uint32) {.cdecl.}
    glBindTexture: proc(target, texture: uint32) {.cdecl.}
    glActiveTexture: proc(unit: uint32) {.cdecl.}
    glTexImage2D: proc(target: uint32, level, internalFormat, w, h,
                       border: int32, format, typ: uint32,
                       pix: pointer) {.cdecl.}
    glTexSubImage2D: proc(target: uint32, level, x, y, w, h: int32,
                          format, typ: uint32, pix: pointer) {.cdecl.}
    glTexParameteri: proc(target, name: uint32, v: int32) {.cdecl.}
    glDeleteTextures: proc(n: int32, textures: ptr uint32) {.cdecl.}
    glPixelStorei: proc(name: uint32, v: int32) {.cdecl.}
    glViewport: proc(x, y, w, h: int32) {.cdecl.}
    glScissor: proc(x, y, w, h: int32) {.cdecl.}
    glEnable: proc(cap: uint32) {.cdecl.}
    glDisable: proc(cap: uint32) {.cdecl.}
    glBlendFunc: proc(src, dst: uint32) {.cdecl.}
    glBlendFuncSeparate: proc(srcRGB, dstRGB, srcAlpha, dstAlpha: uint32) {.cdecl.}
    glClearColor: proc(r, g, b, a: float32) {.cdecl.}
    glClear: proc(mask: uint32) {.cdecl.}
    glDrawArraysInstanced: proc(mode: uint32, first, count,
                                instances: int32) {.cdecl.}
    glReadPixels: proc(x, y, w, h: int32, format, typ: uint32,
                       pix: pointer) {.cdecl.}
    glGenFramebuffers: proc(n: int32, `out`: ptr uint32) {.cdecl.}
    glBindFramebuffer: proc(target, fb: uint32) {.cdecl.}
    glFramebufferTexture2D: proc(target, attachment, texTarget,
                                 texture: uint32, level: int32) {.cdecl.}
    glCheckFramebufferState: proc(target: uint32): uint32 {.cdecl.}
    glDeleteFramebuffers: proc(n: int32, fbs: ptr uint32) {.cdecl.}
    glBlitFramebuffer: proc(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1: int32,
                            mask, filter: uint32) {.cdecl.}

  proc load(): ref CatchableError =
    if loadDone:
      return errLoad
    loadDone = true
    let lib = loadLib("libepoxy.so.0", globalSymbols = true)
    if lib.isNil:
      errLoad = newException(CatchableError, "gl: cannot load libepoxy")
      return errLoad
    var missing: seq[string]
    let fn = proc(f: ptr pointer, name: cstring) =
      let sym = lib.symAddr(name)
      if sym.isNil:
        missing.add $name
      else:
        f[] = sym
    # libepoxy exports a pointer for each GL function, to a stub that
    # finds the function of the current context when first called.
    let glBind = proc(f: ptr pointer, name: cstring) =
      let sym = lib.symAddr("epoxy_" & $name)
      if sym.isNil:
        missing.add $name
      else:
        f[] = cast[ptr pointer](sym)[]
    fn(cast[ptr pointer](addr epoxyGLVersion), "epoxy_gl_version")
    fn(cast[ptr pointer](addr epoxyIsDesktopGL), "epoxy_is_desktop_gl")
    fn(cast[ptr pointer](addr epoxyHasExtension), "epoxy_has_gl_extension")
    glBind(cast[ptr pointer](addr glGetString), "glGetString")
    glBind(cast[ptr pointer](addr glGetError), "glGetError")
    glBind(cast[ptr pointer](addr glGetIntegerv), "glGetIntegerv")
    glBind(cast[ptr pointer](addr glCreateShader), "glCreateShader")
    glBind(cast[ptr pointer](addr glShaderSource), "glShaderSource")
    glBind(cast[ptr pointer](addr glCompileShader), "glCompileShader")
    glBind(cast[ptr pointer](addr glGetShaderiv), "glGetShaderiv")
    glBind(cast[ptr pointer](addr glGetShaderInfoLog), "glGetShaderInfoLog")
    glBind(cast[ptr pointer](addr glDeleteShader), "glDeleteShader")
    glBind(cast[ptr pointer](addr glCreateProgram), "glCreateProgram")
    glBind(cast[ptr pointer](addr glAttachShader), "glAttachShader")
    glBind(cast[ptr pointer](addr glLinkProgram), "glLinkProgram")
    glBind(cast[ptr pointer](addr glGetProgramiv), "glGetProgramiv")
    glBind(cast[ptr pointer](addr glGetProgramInfoLog), "glGetProgramInfoLog")
    glBind(cast[ptr pointer](addr glUseProgram), "glUseProgram")
    glBind(cast[ptr pointer](addr glDeleteProgram), "glDeleteProgram")
    glBind(cast[ptr pointer](addr glGetUniformLocation), "glGetUniformLocation")
    glBind(cast[ptr pointer](addr glUniform1i), "glUniform1i")
    glBind(cast[ptr pointer](addr glUniform2f), "glUniform2f")
    glBind(cast[ptr pointer](addr glUniform1f), "glUniform1f")
    glBind(cast[ptr pointer](addr glUniform2i), "glUniform2i")
    glBind(cast[ptr pointer](addr glCopyTexSubImage2D), "glCopyTexSubImage2D")
    glBind(cast[ptr pointer](addr glGenVertexArrays), "glGenVertexArrays")
    glBind(cast[ptr pointer](addr glBindVertexArray), "glBindVertexArray")
    glBind(cast[ptr pointer](addr glDeleteVertexArrays), "glDeleteVertexArrays")
    glBind(cast[ptr pointer](addr glGenBuffers), "glGenBuffers")
    glBind(cast[ptr pointer](addr glBindBuffer), "glBindBuffer")
    glBind(cast[ptr pointer](addr glBufferData), "glBufferData")
    glBind(cast[ptr pointer](addr glDeleteBuffers), "glDeleteBuffers")
    glBind(cast[ptr pointer](addr glEnableVertexAttrib), "glEnableVertexAttribArray")
    glBind(cast[ptr pointer](addr glVertexAttribPointer), "glVertexAttribPointer")
    glBind(cast[ptr pointer](addr glVertexAttribDivisor), "glVertexAttribDivisor")
    glBind(cast[ptr pointer](addr glGenTextures), "glGenTextures")
    glBind(cast[ptr pointer](addr glBindTexture), "glBindTexture")
    glBind(cast[ptr pointer](addr glActiveTexture), "glActiveTexture")
    glBind(cast[ptr pointer](addr glTexImage2D), "glTexImage2D")
    glBind(cast[ptr pointer](addr glTexSubImage2D), "glTexSubImage2D")
    glBind(cast[ptr pointer](addr glTexParameteri), "glTexParameteri")
    glBind(cast[ptr pointer](addr glDeleteTextures), "glDeleteTextures")
    glBind(cast[ptr pointer](addr glPixelStorei), "glPixelStorei")
    glBind(cast[ptr pointer](addr glViewport), "glViewport")
    glBind(cast[ptr pointer](addr glScissor), "glScissor")
    glBind(cast[ptr pointer](addr glEnable), "glEnable")
    glBind(cast[ptr pointer](addr glDisable), "glDisable")
    glBind(cast[ptr pointer](addr glBlendFunc), "glBlendFunc")
    glBind(cast[ptr pointer](addr glBlendFuncSeparate), "glBlendFuncSeparate")
    glBind(cast[ptr pointer](addr glClearColor), "glClearColor")
    glBind(cast[ptr pointer](addr glClear), "glClear")
    glBind(cast[ptr pointer](addr glDrawArraysInstanced), "glDrawArraysInstanced")
    glBind(cast[ptr pointer](addr glReadPixels), "glReadPixels")
    glBind(cast[ptr pointer](addr glGenFramebuffers), "glGenFramebuffers")
    glBind(cast[ptr pointer](addr glBindFramebuffer), "glBindFramebuffer")
    glBind(cast[ptr pointer](addr glFramebufferTexture2D), "glFramebufferTexture2D")
    glBind(cast[ptr pointer](addr glCheckFramebufferState), "glCheckFramebufferStatus")
    glBind(cast[ptr pointer](addr glDeleteFramebuffers), "glDeleteFramebuffers")
    glBind(cast[ptr pointer](addr glBlitFramebuffer), "glBlitFramebuffer")
    if missing.len > 0:
      errLoad = newException(CatchableError,
        "gl: libepoxy lacks " & missing.join(", "))
      return errLoad
    # GDK is loaded in apps, where its context tells when GTK realized
    # the area again; tests make contexts of their own.
    let selfLib = loadLib("", globalSymbols = true)
    if not selfLib.isNil:
      let sym = selfLib.symAddr("gdk_gl_context_get_current")
      if not sym.isNil:
        cast[ptr pointer](addr currentGDKContext)[] = sym
    nil

  proc currentContext(): uint =
    if currentGDKContext.isNil: 0 else: currentGDKContext()

  proc goString(p: pointer): string =
    if p.isNil: "" else: $(cast[cstring](p))

  proc contextVersion(): tuple[version: int32, es: bool] =
    (epoxyGLVersion(), not epoxyIsDesktopGL())

  proc hasExtension(name: string): bool =
    epoxyHasExtension(cstring(name))

  proc versionString(): string = goString(glGetString(glVersion))

  proc setShaderSource(s: uint32, src: string) =
    var cs = cstring(src & "\0")
    glShaderSource(s, 1, addr cs, nil)

  proc infoLog(obj: uint32,
               get: proc(a, b: uint32, o: ptr int32) {.cdecl.},
               read: proc(a: uint32, b: int32, c: ptr int32,
                          d: cstring) {.cdecl.}): string =
    var n: int32
    get(obj, glInfoLogLength, addr n)
    if n <= 1:
      return "no log"
    var buf = newString(int(n))
    read(obj, n, nil, cstring(buf))
    buf.setLen(int(n) - 1)
    buf.strip()

  proc shaderLog(s: uint32): string =
    infoLog(s, glGetShaderiv, glGetShaderInfoLog)
  proc programLog(p: uint32): string =
    infoLog(p, glGetProgramiv, glGetProgramInfoLog)

# --- gl.go — the renderer ---

type
  texture = object
    tex: uint32
    w, h: int
    gen, ver: uint64
    lastFrame: uint64

  ## canvasTexture is the texture a canvas (scene.newCanvas) is drawn
  ## into, through its framebuffer, and what drawing it keeps, for as
  ## long as the canvas lives. Its rows go up, as GL's: images showing
  ## it flip it.
  canvasTexture = ref object
    tex: uint32
    w, h: int
    gen, ver: uint64
    lastFrame: uint64
    fb: uint32
    b: gpu.Builder
    canvas: scene.Image

  ## Renderer draws scenes into the framebuffer bound when render is
  ## called, with the GL context that was current when new was called.
  ## All its methods must be called with that context current.
  Renderer* = ref object
    context: uint ## GDK's, to tell when the area's context changes
    es: bool
    ## dual tells that the context blends with a second color from the
    ## shader (OpenGL 3.3, or GLES with EXT_blend_func_extended).
    dual: bool
    maxSize: int
    program: uint32
    vao, buf: uint32
    uSize: int32
    mask: texture
    color: texture
    empty: uint32 ## a texture to bind where there is none
    images: Table[uint64, texture]
    frame: uint64
    ## canvases are the textures canvases are drawn into, and canvasTex
    ## the names of those textures.
    canvases: Table[uint64, canvasTexture]
    canvasTex: Table[uint32, bool]

    ## The passes computing the backdrops of effects: down and blur are
    ## their programs, with their uniforms' locations, drawn with
    ## passVAO; grab holds the area of the frame read, and backdrop the
    ## textures they draw into, through backdropFB, the second only
    ## along rows.
    down, blur: passProgram
    passVAO: uint32
    grab: texture
    backdrop: array[2, texture]
    backdropFB: array[2, uint32]
    ## header is what the shaders start with; effects are the programs
    ## of the effects drawn, made as first drawn.
    header: string
    effects: Table[scene.Effect, effectProgram]

    b: gpu.Builder

  ## effectProgram is the program of an effect and the location of its
  ## uSize, or why it has none.
  effectProgram = ref object
    program: uint32
    uSize: int32
    err: ref CatchableError

  ## passProgram is the program of a pass computing backdrops and its
  ## uniforms' locations.
  passProgram = object
    program: uint32
    origin, limit, shift, dir, down, rad, sigma: int32


proc `or`(a, b: uint32): uint32 =
  if a != 0: a else: b

proc compile(kind: uint32, src: string):
    tuple[s: uint32, err: ref CatchableError] =
  let s = glCreateShader(kind)
  setShaderSource(s, src)
  glCompileShader(s)
  var ok: int32
  glGetShaderiv(s, glCompileStatus, addr ok)
  if ok == 0:
    let log = shaderLog(s)
    glDeleteShader(s)
    return (0, newException(CatchableError,
      "gl: cannot compile the shader: " & log))
  (s, nil)

## attributes is the number of float4s in a gpu.Instance.
const attributes = gpu.instanceSize div 16

proc link(vertex, fragment: string):
    tuple[p: uint32, err: ref CatchableError] =
  ## Compiles a vertex and a fragment shader and links them.
  let (vs, e1) = compile(glVertexShader, vertex)
  if not e1.isNil: return (0, e1)
  defer: glDeleteShader(vs)
  let (fs, e2) = compile(glFragmentShader, fragment)
  if not e2.isNil: return (0, e2)
  defer: glDeleteShader(fs)
  let program = glCreateProgram()
  glAttachShader(program, vs)
  glAttachShader(program, fs)
  glLinkProgram(program)
  var ok: int32
  glGetProgramiv(program, glLinkStatus, addr ok)
  if ok == 0:
    let e = newException(CatchableError,
      "gl: cannot link the shader: " & programLog(program))
    glDeleteProgram(program)
    return (0, e)
  (program, nil)

proc passLink(header, name: string):
    tuple[p: passProgram, err: ref CatchableError] =
  ## Compiles and links the program of a pass computing backdrops, the
  ## part of the shader defining name.
  let (vs, e1) = compile(glVertexShader,
    header & "#define PASS_VERTEX\n" & shaderSource)
  if not e1.isNil: return (passProgram(), e1)
  defer: glDeleteShader(vs)
  let (fs, e2) = compile(glFragmentShader,
    header & "#define " & name & "\n" & shaderSource)
  if not e2.isNil: return (passProgram(), e2)
  defer: glDeleteShader(fs)
  var p = passProgram(program: glCreateProgram())
  glAttachShader(p.program, vs)
  glAttachShader(p.program, fs)
  glLinkProgram(p.program)
  var ok: int32
  glGetProgramiv(p.program, glLinkStatus, addr ok)
  if ok == 0:
    let e = newException(CatchableError,
      "gl: cannot link the " & name & " pass: " & programLog(p.program))
    glDeleteProgram(p.program)
    return (passProgram(), e)
  glUseProgram(p.program)
  glUniform1i(glGetUniformLocation(p.program, "uSrc"), 0)
  p.origin = glGetUniformLocation(p.program, "uOrigin")
  p.limit = glGetUniformLocation(p.program, "uLimit")
  p.shift = glGetUniformLocation(p.program, "uShift")
  p.dir = glGetUniformLocation(p.program, "uDir")
  p.down = glGetUniformLocation(p.program, "uDown")
  p.rad = glGetUniformLocation(p.program, "uRadius")
  p.sigma = glGetUniformLocation(p.program, "uSigma")
  glUseProgram(0)
  (p, nil)


## unpack sets the layout of the pixels uploads read: rows of stride
## bytes.
proc unpack(stride: int, internal: int32) =
  var bpp = 4
  if internal == int32(glR8):
    bpp = 1
  glPixelStorei(glUnpackAlignment, 1)
  glPixelStorei(glUnpackRowLength, int32(stride div bpp))

proc unpackReset() =
  glPixelStorei(glUnpackAlignment, 4)
  glPixelStorei(glUnpackRowLength, 0)

proc newTexture(internal: int32, format: uint32, w, h: int,
                pix: openArray[byte], stride: int): uint32 =
  glGenTextures(1, addr result)
  glBindTexture(glTexture2D, result)
  glTexParameteri(glTexture2D, glTextureMinFilter, int32(glLinear))
  glTexParameteri(glTexture2D, glTextureMagFilter, int32(glLinear))
  glTexParameteri(glTexture2D, glTextureWrapS, int32(glClampToEdge))
  glTexParameteri(glTexture2D, glTextureWrapT, int32(glClampToEdge))
  var data: pointer
  if pix.len > 0:
    data = unsafeAddr pix[0]
    unpack(stride, internal)
  glTexImage2D(glTexture2D, 0, internal, int32(w), int32(h), 0, format,
               glUnsignedByte, data)
  unpackReset()


## set uses the program with the uniforms of p.
proc `set`(pp: passProgram, p: gpu.Pass) =
  glUseProgram(pp.program)
  glUniform2i(pp.origin, p.origin[0], p.origin[1])
  glUniform2i(pp.limit, p.limit[0], p.limit[1])
  glUniform2i(pp.shift, p.shift[0], p.shift[1])
  glUniform2i(pp.dir, p.dir[0], p.dir[1])
  glUniform1i(pp.down, p.down)
  glUniform1i(pp.rad, p.radius)
  glUniform1f(pp.sigma, p.sigma)

proc init(r: Renderer): ref CatchableError
proc forget(r: Renderer)
proc drawCanvases(r: Renderer, s: scene.Scene): ref CatchableError
proc drawCanvas(r: Renderer, c: scene.Image): ref CatchableError
proc fitBackdrop(r: Renderer, b: var gpu.Builder): ref CatchableError
proc readBackdrop(r: Renderer, fb: uint32, height: int, bk: scene.Backdrop)
proc `pass`(r: Renderer, i, w, h: int)
proc bindState(r: Renderer, s: scene.Scene)
proc blendFunc(r: Renderer, hole: bool)
proc draw(r: Renderer, s: scene.Scene): ref CatchableError
proc release*(r: Renderer)
proc drawSceneImpl(r: Renderer, s: scene.Scene, b: var gpu.Builder): ref CatchableError

proc newRenderer*(): tuple[r: Renderer, err: ref CatchableError] =
  ## A renderer for the current GL context.
  let e = load()
  if not e.isNil:
    return (nil, e)
  let r = Renderer(images: initTable[uint64, texture](),
                   context: currentContext())
  let err = r.init()
  if not err.isNil:
    r.release()
    return (nil, err)
  (r, nil)

## init creates the program, buffers and textures in the current
## context.
proc init(r: Renderer): ref CatchableError =
  let (version, es) = contextVersion()
  r.es = es
  if (r.es and version < 30) or (not r.es and version < 33):
    return newException(CatchableError,
      "gl: OpenGL " & $int(version div 10) & "." & $int(version mod 10) &
      " is too old (" & versionString() & ")")
  var size: int32
  glGetIntegerv(glMaxTextureSize, addr size)
  r.maxSize = int(size)
  r.dual = not r.es or hasExtension("GL_EXT_blend_func_extended")
  var header = "#version 330 core\n#define DUAL\n"
  if r.es:
    header = "#version 300 es\n"
    if r.dual:
      header &= "#extension GL_EXT_blend_func_extended : require\n#define DUAL\n"
    header &= "precision highp float;\nprecision highp int;\n"
  r.header = header
  var e: ref CatchableError
  let vs = compile(glVertexShader,
    header & "#define VERTEX\n" & shaderSource)
  if not vs.err.isNil: return vs.err
  defer: glDeleteShader(vs.s)
  let fs = compile(glFragmentShader,
    header & "#define FRAGMENT\n" & shaderSource)
  if not fs.err.isNil: return fs.err
  defer: glDeleteShader(fs.s)
  r.program = glCreateProgram()
  glAttachShader(r.program, vs.s)
  glAttachShader(r.program, fs.s)
  glLinkProgram(r.program)
  var ok: int32
  glGetProgramiv(r.program, glLinkStatus, addr ok)
  if ok == 0:
    return newException(CatchableError,
      "gl: cannot link the shader: " & programLog(r.program))
  glUseProgram(r.program)
  r.uSize = glGetUniformLocation(r.program, "uSize")
  glUniform1i(glGetUniformLocation(r.program, "uMask"), 0)
  glUniform1i(glGetUniformLocation(r.program, "uColor"), 1)
  glUniform1i(glGetUniformLocation(r.program, "uImage"), 2)
  glUniform1i(glGetUniformLocation(r.program, "uClipMask"), 4)
  glUseProgram(0)
  (r.down, e) = passLink(header, "DOWN")
  if not e.isNil: return e
  (r.blur, e) = passLink(header, "BLUR")
  if not e.isNil: return e
  glGenVertexArrays(1, addr r.passVAO)

  # The instance buffer feeds fourteen float4 attributes per instance;
  # draws point them at their batch's instances.
  glGenVertexArrays(1, addr r.vao)
  glGenBuffers(1, addr r.buf)
  glBindVertexArray(r.vao)
  glBindBuffer(glArrayBuffer, r.buf)
  for i in 0 ..< uint32(attributes):
    glEnableVertexAttrib(i)
    glVertexAttribDivisor(i, 1)
  glBindVertexArray(0)
  glBindBuffer(glArrayBuffer, 0)

  r.empty = newTexture(int32(glRGBA8), glRGBA, 1, 1,
                       [byte 0, 0, 0, 0], 4)
  let err = glGetError()
  if err != glNoError:
    return newException(CatchableError,
      "gl: setting up failed (error " & toHex(int(err)) & ")")
  nil

## effectProgram returns the program of e, compiled the first time from
## its GLSL, which drivers keep compiled; its program is 0 for an effect
## that does not compile, which draws nothing.
proc effectProgramOf(r: Renderer, e: ref scene.Effect): effectProgram =
  let p0 = r.effects.getOrDefault(e[], nil)
  if not p0.isNil:
    return p0
  let p = effectProgram()
  if r.effects.len == 0:
    r.effects = initTable[scene.Effect, effectProgram]()
  r.effects[e[]] = p
  (p.program, p.err) = link(r.header & "#define VERTEX\n" & shaderSource,
                            r.header & effectSource(e[].glsl))
  if not p.err.isNil:
    p.err = newException(CatchableError,
      "gl: the effect " & e[].name & ": " & p.err.msg)
    stderr.writeLine(p.err.msg)
    return p
  glUseProgram(p.program)
  p.uSize = glGetUniformLocation(p.program, "uSize")
  glUniform1i(glGetUniformLocation(p.program, "uBackdrop"), 3)
  glUniform1i(glGetUniformLocation(p.program, "uClipMask"), 4)
  p

proc syncAtlas(r: Renderer, t: var texture, a: scene.Atlas,
               internal: int32, format: uint32): ref CatchableError =
  if a.isNil:
    return nil
  if a.w > r.maxSize or a.h > r.maxSize:
    return newException(CatchableError,
      "gl: a " & $a.w & "×" & $a.h &
      " atlas is larger than textures can be")
  if t.tex == 0 or t.gen != a.generation() or t.w != a.w or t.h != a.h:
    if t.tex != 0:
      glDeleteTextures(1, addr t.tex)
    t.tex = newTexture(internal, format, a.w, a.h, a.pix, a.w * a.bpp)
    t.w = a.w
    t.h = a.h
    t.gen = a.generation()
    t.ver = a.version
    return nil
  let (rects0, full) = a.changes(t.gen, t.ver)
  var rects = rects0
  if full:
    rects = @[image.rect(0, 0, a.w, a.h)]
  if rects.len > 0:
    glBindTexture(glTexture2D, t.tex)
    unpack(a.w * a.bpp, internal)
    for rc in rects:
      let src = a.pix[(rc.min.y * a.w + rc.min.x) * a.bpp]
      glTexSubImage2D(glTexture2D, 0, int32(rc.min.x), int32(rc.min.y),
                      int32(rc.dx), int32(rc.dy), format, glUnsignedByte,
                      unsafeAddr src)
    unpackReset()
  t.ver = a.version
  nil

proc imageTexture(r: Renderer, img: scene.Image): uint =
  if img.w > r.maxSize or img.h > r.maxSize:
    return 0
  if not img.scene.isNil:
    # A canvas, drawn before the scene showing it.
    let c = r.canvases.getOrDefault(img.id, nil)
    if not c.isNil:
      return uint(c.tex)
    return 0
  var t = r.images.getOrDefault(img.id)
  var found = r.images.hasKey(img.id)
  if not found:
    t = texture(tex: newTexture(int32(glRGBA8), glRGBA, img.w, img.h,
                                img.pix, img.w * 4),
                w: img.w, h: img.h, ver: img.version)
  elif t.w != img.w or t.h != img.h:
    glDeleteTextures(1, addr t.tex)
    t.tex = newTexture(int32(glRGBA8), glRGBA, img.w, img.h,
                       img.pix, img.w * 4)
    t.w = img.w
    t.h = img.h
    t.ver = img.version
  elif t.ver != img.version:
    glBindTexture(glTexture2D, t.tex)
    unpack(img.w * 4, int32(glRGBA8))
    glTexSubImage2D(glTexture2D, 0, 0, 0, int32(img.w), int32(img.h),
                    glRGBA, glUnsignedByte, unsafeAddr img.pix[0])
    unpackReset()
    t.ver = img.version
  t.lastFrame = r.frame
  r.images[img.id] = t
  uint(t.tex)

## render draws s into the bound framebuffer, which is
## s.width×s.height device pixels.
proc render*(r: Renderer, s: scene.Scene): ref CatchableError =
  if s.width <= 0 or s.height <= 0:
    return nil
  let c = currentContext()
  if c != r.context:
    # GTK realized the area again, with a new context: the old one
    # took the objects with it.
    r.forget()
    r.context = c
    let e = r.init()
    if not e.isNil:
      return e
  let e = r.draw(s)
  if not e.isNil:
    return e
  let err = glGetError()
  if err != glNoError:
    return newException(CatchableError,
      "gl: drawing failed (error " & toHex(int(err)) & ")")
  nil

proc draw(r: Renderer, s: scene.Scene): ref CatchableError =
  r.frame += 1
  glActiveTexture(glTexture0)
  var e = r.syncAtlas(r.mask, s.maskAtlas, int32(glR8), glRed)
  if not e.isNil: return e
  e = r.syncAtlas(r.color, s.colorAtlas, int32(glRGBA8), glRGBA)
  if not e.isNil: return e
  e = r.drawCanvases(s)
  if not e.isNil: return e
  e = r.drawSceneImpl(s, r.b)
  if not e.isNil: return e
  if r.frame mod 120 == 0:
    var dead: seq[uint64]
    for key, t in r.images:
      if r.frame - t.lastFrame > 240:
        glDeleteTextures(1, unsafeAddr t.tex)
        dead.add key
    for k in dead:
      r.images.del(k)
    # Go keeps a weak pointer to the canvas to drop its texture once
    # collected; Nim has no weak references under ARC, so canvases'
    # textures live while the renderer does.
  nil

## drawCanvases draws the canvases s draws anew or shows into their
## textures, unless they hold their versions already, leaving the
## framebuffer bound as it was.
proc drawCanvases(r: Renderer, s: scene.Scene): ref CatchableError =
  var outer: int32
  glGetIntegerv(glFramebufferBinding, addr outer)
  defer: glBindFramebuffer(glFramebuffer, uint32(outer))
  var err: ref CatchableError
  s.eachCanvas(proc(c: scene.Image) =
    if err.isNil:
      err = r.drawCanvas(c))
  err

proc drawCanvas(r: Renderer, c: scene.Image): ref CatchableError =
  if c.w > r.maxSize or c.h > r.maxSize:
    return nil
  if r.canvases.len == 0:
    r.canvases = initTable[uint64, canvasTexture]()
    r.canvasTex = initTable[uint32, bool]()
  var t = r.canvases.getOrDefault(c.id)
  if t.isNil:
    t = canvasTexture(canvas: c)
    r.canvases[c.id] = t
  if t.tex != 0 and t.w == c.w and t.h == c.h and t.ver == c.version:
    return nil
  if t.tex == 0 or t.w != c.w or t.h != c.h:
    if t.tex != 0:
      r.canvasTex.del(t.tex)
      glDeleteTextures(1, addr t.tex)
    t.tex = newTexture(int32(glRGBA8), glRGBA, c.w, c.h, [], 0)
    t.w = c.w
    t.h = c.h
    r.canvasTex[t.tex] = true
    if t.fb == 0:
      glGenFramebuffers(1, addr t.fb)
    glBindFramebuffer(glFramebuffer, t.fb)
    glFramebufferTexture2D(glFramebuffer, glColorAttachment0,
                           glTexture2D, t.tex, 0)
    if glCheckFramebufferState(glFramebuffer) != glFramebufferDone:
      return newException(CatchableError,
        "gl: cannot draw into a " & $c.w & "×" & $c.h & " canvas")
  glBindFramebuffer(glFramebuffer, t.fb)
  let cs = c.scene
  cs.width = c.w
  cs.height = c.h
  let e = r.drawSceneImpl(cs, t.b)
  if not e.isNil:
    return e
  t.ver = c.version
  nil

proc deleteCanvas(r: Renderer, t: canvasTexture) =
  r.canvasTex.del(t.tex)
  if t.tex != 0:
    glDeleteTextures(1, addr t.tex)
  if t.fb != 0:
    glDeleteFramebuffers(1, addr t.fb)
  t.b.release()

## drawScene draws s into the framebuffer bound, with b.
proc drawSceneImpl(r: Renderer, s: scene.Scene,
               b: var gpu.Builder): ref CatchableError =
  let s = b.build(s, proc(i: scene.Image): uint = r.imageTexture(i))
  # Canvases' rows go up, as GL's: images showing them sample them
  # flipped, which their source rectangles may be (scene.opImage).
  if r.canvasTex.len > 0:
    for bt in b.batches:
      if bt.image == 0 or not r.canvasTex.getOrDefault(uint32(bt.image)):
        continue
      for i in bt.start ..< bt.start + bt.count:
        if b.instances[i].params[0] == 4:
          b.instances[i].uv[1] = 1 - b.instances[i].uv[1]
          b.instances[i].uv[3] = 1 - b.instances[i].uv[3]
  var e = r.fitBackdrop(b)
  if not e.isNil:
    return e
  # The framebuffer drawn into, GTK's, which the passes computing
  # backdrops leave for their own.
  var fb: int32
  glGetIntegerv(glFramebufferBinding, addr fb)

  glViewport(0, 0, int32(s.width), int32(s.height))
  glDisable(glScissorTest)
  let c = s.clear.premul(1)
  glClearColor(c[0], c[1], c[2], c[3])
  glClear(glColorBufferBit)
  if b.instances.len == 0:
    return nil
  glBindBuffer(glArrayBuffer, r.buf)
  glBufferData(glArrayBuffer, b.instances.len * gpu.instanceSize,
               unsafeAddr b.instances[0], glStreamDraw)
  r.bindState(s)
  var bound = uint(r.empty)
  var program = r.program
  var hole = false
  for bt in b.batches:
    var sc = bt.scissor
    sc.left = max(sc.left, 0)
    sc.top = max(sc.top, 0)
    sc.right = min(sc.right, int32(s.width))
    sc.bottom = min(sc.bottom, int32(s.height))
    if bt.count == 0 or sc.empty():
      continue
    var want = r.program
    if not bt.effect.isNil:
      let p = r.effectProgramOf(bt.effect)
      if p.program == 0:
        continue
      want = p.program
    if bt.backdrop != 0:
      # The effect shows what is drawn so far.
      r.readBackdrop(uint32(fb), s.height, b.backdrops[bt.backdrop - 1])
      glBindFramebuffer(glFramebuffer, uint32(fb))
      glViewport(0, 0, int32(s.width), int32(s.height))
      r.bindState(s)
      glActiveTexture(glTexture0 + 3)
      glBindTexture(glTexture2D, r.backdrop[0].tex)
      glActiveTexture(glTexture0 + 2)
      bound = uint(r.empty)
      program = r.program
      hole = false
    if bt.hole != hole:
      hole = bt.hole
      r.blendFunc(hole)
    if want != program:
      program = want
      glUseProgram(program)
      if not bt.effect.isNil:
        glUniform2f(r.effects[bt.effect[]].uSize,
                    float32(s.width), float32(s.height))
    if bt.image != 0 and uint(bt.image) != bound:
      bound = uint(bt.image)
      glBindTexture(glTexture2D, uint32(bound)) # unit 2 is active
    glActiveTexture(glTexture0 + 4)
    glBindTexture(glTexture2D, `or`(uint32(bt.clipMask), r.empty))
    glActiveTexture(glTexture0 + 2)
    # Instances draw from the batch's first: without base instances in
    # OpenGL ES 3.0, the attributes start there.
    let offset = uint(bt.start * gpu.instanceSize)
    for i in 0 ..< uint32(attributes):
      glVertexAttribPointer(i, 4, glFloat, false,
                            int32(gpu.instanceSize), offset + uint(i) * 16)
    # GL's scissor rectangles start at the bottom.
    glScissor(sc.left, int32(s.height) - sc.bottom,
              sc.right - sc.left, sc.bottom - sc.top)
    glDrawArraysInstanced(glTriangleStrip, 0, 4, int32(bt.count))
  # Leave the state as GTK, which draws the area with the same
  # context, expects it.
  glDisable(glScissorTest)
  glDisable(glBlend)
  for unit in 0 ..< 5:
    glActiveTexture(glTexture0 + uint32(unit))
    glBindTexture(glTexture2D, 0)
  glActiveTexture(glTexture0)
  glBindBuffer(glArrayBuffer, 0)
  glBindVertexArray(0)
  glUseProgram(0)
  nil

## bindState sets the state the instances of s draw with, leaving
## texture unit 2, the images', active.
proc bindState(r: Renderer, s: scene.Scene) =
  glUseProgram(r.program)
  glUniform2f(r.uSize, float32(s.width), float32(s.height))
  glBindVertexArray(r.vao)
  glBindBuffer(glArrayBuffer, r.buf)
  for unit, tex in [`or`(r.mask.tex, r.empty), `or`(r.color.tex, r.empty),
                    r.empty, r.empty, r.empty]:
    glActiveTexture(glTexture0 + uint32(unit))
    glBindTexture(glTexture2D, tex)
  glActiveTexture(glTexture0 + 2)
  glEnable(glBlend)
  r.blendFunc(false)
  glEnable(glScissorTest)

## blendFunc blends premultiplied colors over what is drawn, or for
## hole, takes their coverage away (scene.opHole).
proc blendFunc(r: Renderer, hole: bool) =
  var src = glOne
  if hole:
    src = glZero
  if r.dual:
    glBlendFuncSeparate(src, glOneMinusSrc1Color, src,
                        glOneMinusSrc1Alpha)
  else:
    glBlendFunc(src, glOneMinusSrcAlpha)

## readBackdrop computes the backdrop bk of what the framebuffer fb
## holds, a frame height pixels high, into r.backdrop[0]: it copies the
## area into grab, whose rows go up as GL's, averages its squares and
## blurs them.
proc readBackdrop(r: Renderer, fb: uint32, height: int,
                  bk: scene.Backdrop) =
  let (w, h) = bk.size()
  glDisable(glBlend)
  glBindFramebuffer(glFramebuffer, fb)
  glActiveTexture(glTexture0)
  glBindTexture(glTexture2D, r.grab.tex)
  glCopyTexSubImage2D(glTexture2D, 0, 0, 0, int32(bk.area.min.x),
                      int32(height - bk.area.max.y),
                      int32(bk.area.dx), int32(bk.area.dy))
  glBindVertexArray(r.passVAO)
  # Rows go up in grab: the frame's row y is its row Max.Y-1-y.
  r.down.`set`(gpu.downPass(bk, [int32(bk.area.min.x),
                                 int32(bk.area.max.y - 1)]))
  r.`pass`(0, w, h)
  if bk.radius > 0:
    r.blur.`set`(gpu.blurPass(bk, [int32 1, 0]))
    glBindTexture(glTexture2D, r.backdrop[0].tex)
    r.`pass`(1, w, h)
    r.blur.`set`(gpu.blurPass(bk, [int32 0, 1]))
    glBindTexture(glTexture2D, r.backdrop[1].tex)
    r.`pass`(0, w, h)

## pass draws the program in use into the w×h texels at the start of
## r.backdrop[i], reading the texture bound to unit 0.
proc `pass`(r: Renderer, i, w, h: int) =
  glBindFramebuffer(glFramebuffer, r.backdropFB[i])
  glViewport(0, 0, int32(r.backdrop[i].w), int32(r.backdrop[i].h))
  glScissor(0, 0, int32(w), int32(h))
  glDrawArraysInstanced(glTriangleStrip, 0, 4, 1)

## fitBackdrop makes the textures of backdrops as large as the scene
## built needs, and the texture the area read is copied to.
proc fitBackdrop(r: Renderer, b: var gpu.Builder): ref CatchableError =
  let (w0, h0) = b.backdropSize()
  var aw, ah = 0
  for bk in b.backdrops:
    aw = max(aw, bk.area.dx)
    ah = max(ah, bk.area.dy)
  if aw > r.grab.w or ah > r.grab.h:
    # Somewhat larger, so that a pane growing does not make it again
    # every frame.
    aw = min(max(aw + aw div 4, r.grab.w), r.maxSize)
    ah = min(max(ah + ah div 4, r.grab.h), r.maxSize)
    if r.grab.tex != 0:
      glDeleteTextures(1, addr r.grab.tex)
    r.grab = texture(tex: newTexture(int32(glRGBA8), glRGBA, aw, ah,
                                   [], 0),
                     w: aw, h: ah)
  var w = w0
  var h = h0
  if w <= r.backdrop[0].w and h <= r.backdrop[0].h:
    return nil
  w = min(max(w + w div 4, r.backdrop[0].w), r.maxSize)
  h = min(max(h + h div 4, r.backdrop[0].h), r.maxSize)
  for i in 0 ..< 2:
    var t = addr r.backdrop[i]
    if t.tex != 0:
      glDeleteTextures(1, addr t.tex)
    t[] = texture(tex: newTexture(int32(glRGBA8), glRGBA, w, h, [], 0),
                  w: w, h: h)
    if r.backdropFB[i] == 0:
      glGenFramebuffers(1, addr r.backdropFB[i])
    var fb: int32
    glGetIntegerv(glFramebufferBinding, addr fb)
    glBindFramebuffer(glFramebuffer, r.backdropFB[i])
    glFramebufferTexture2D(glFramebuffer, glColorAttachment0,
                           glTexture2D, t.tex, 0)
    let done = glCheckFramebufferState(glFramebuffer) == glFramebufferDone
    glBindFramebuffer(glFramebuffer, uint32(fb))
    if not done:
      return newException(CatchableError,
        "gl: cannot draw into a " & $w & "×" & $h & " backdrop texture")
  nil

## forget drops the objects of a context that is gone.
proc forget(r: Renderer) =
  r.program = 0
  r.vao = 0
  r.buf = 0
  r.empty = 0
  r.down = passProgram()
  r.blur = passProgram()
  r.passVAO = 0
  r.effects.clear()
  r.grab = texture()
  r.backdrop = [texture(), texture()]
  r.backdropFB = [0'u32, 0]
  r.mask = texture()
  r.color = texture()
  r.images.clear()
  for t in r.canvases.values:
    t.b.release()
  r.canvases.clear()
  r.canvasTex.clear()

## release deletes the renderer's objects when its context is current,
## and otherwise leaves them to the context, which deletes them with
## itself.
proc release*(r: Renderer) =
  r.b.release()
  if not errLoad.isNil or currentContext() != r.context:
    r.forget()
    return
  for t in r.images.mvalues:
    glDeleteTextures(1, addr t.tex)
  for t in r.canvases.values:
    r.deleteCanvas(t)
  for tex in [addr r.mask.tex, addr r.color.tex, addr r.empty,
              addr r.grab.tex, addr r.backdrop[0].tex,
              addr r.backdrop[1].tex]:
    if tex[] != 0:
      glDeleteTextures(1, tex)
  for i in 0 ..< 2:
    if r.backdropFB[i] != 0:
      glDeleteFramebuffers(1, addr r.backdropFB[i])
  for p in r.effects.values:
    if p.program != 0:
      glDeleteProgram(p.program)
  for p in [r.down.program, r.blur.program]:
    if p != 0:
      glDeleteProgram(p)
  if r.passVAO != 0:
    glDeleteVertexArrays(1, addr r.passVAO)
  if r.buf != 0:
    glDeleteBuffers(1, addr r.buf)
  if r.vao != 0:
    glDeleteVertexArrays(1, addr r.vao)
  if r.program != 0:
    glDeleteProgram(r.program)
  r.forget()

# --- present.go ---

type Presenter* = ref object
  ## Shows frames drawn in memory in the bound framebuffer: what a
  ## GtkGLArea shows when its content draws on the CPU after all, as
  ## when the GL renderer fails. GTK shows only what OpenGL draws into
  ## a GtkGLArea.
  context: uint
  tex, fb: uint32
  w, h: int
  rgba: seq[byte]

## present copies premultiplied BGRA rows of stride bytes, width×height
## pixels, into the bound framebuffer, which is that size. The context
## current must be the one of the last call, or a new one.
proc present*(p: Presenter, pix: openArray[byte], stride,
              width, height: int): ref CatchableError =
  let e = load()
  if not e.isNil:
    return e
  if width <= 0 or height <= 0 or
      pix.len < stride * (height - 1) + 4 * width:
    return nil
  let c = currentContext()
  if c != p.context:
    # A new context: the old one took the texture with it.
    p.context = c
    p.tex = 0
    p.fb = 0
    p.w = 0
    p.h = 0
  # GL reads RGBA; frames in memory are BGRA.
  let n = 4 * width * height
  if p.rgba.len < n:
    p.rgba = newSeq[byte](n)
  for y in 0 ..< height:
    for x in 0 ..< 4 * width:
      let s = y * stride + x
      let d = 4 * width * y + x
      if x mod 4 == 0:
        p.rgba[d] = pix[s + 2]
      elif x mod 4 == 2:
        p.rgba[d] = pix[s - 2]
      else:
        p.rgba[d] = pix[s]
  var target: int32
  glGetIntegerv(glFramebufferBinding, addr target)
  if p.tex == 0 or p.w != width or p.h != height:
    if p.tex != 0:
      glDeleteTextures(1, addr p.tex)
    p.tex = newTexture(int32(glRGBA8), glRGBA, width, height, [], 0)
    if p.fb == 0:
      glGenFramebuffers(1, addr p.fb)
    glBindFramebuffer(glReadFramebuffer, p.fb)
    glFramebufferTexture2D(glReadFramebuffer, glColorAttachment0,
                           glTexture2D, p.tex, 0)
    p.w = width
    p.h = height
  glActiveTexture(glTexture0)
  glBindTexture(glTexture2D, p.tex)
  unpack(4 * width, int32(glRGBA8))
  glTexSubImage2D(glTexture2D, 0, 0, 0, int32(width), int32(height),
                  glRGBA, glUnsignedByte, unsafeAddr p.rgba[0])
  unpackReset()
  glBindTexture(glTexture2D, 0)
  glBindFramebuffer(glReadFramebuffer, p.fb)
  glBindFramebuffer(glDrawFramebuffer, uint32(target))
  glDisable(glScissorTest)
  # Rows go down in memory and up in GL: the copy flips them.
  glBlitFramebuffer(0, 0, int32(width), int32(height), 0,
                    int32(height), int32(width), 0,
                    glColorBufferBit, glNearest)
  glBindFramebuffer(glFramebuffer, uint32(target))
  let err = glGetError()
  if err != glNoError:
    return newException(CatchableError,
      "gl: presenting a frame failed (error " & toHex(int(err)) & ")")
  nil

# --- read.go ---

proc readFramebuffer*(width, height: int):
    tuple[pix: seq[byte], err: ref CatchableError] =
  ## The pixels of the bound framebuffer, width×height, as the CPU
  ## renderer draws them: premultiplied BGRA rows from the top. Tests
  ## compare them.
  let e = load()
  if not e.isNil:
    return (@[], e)
  if width <= 0 or height <= 0:
    return (@[], nil)
  var pix = newSeq[byte](4 * width * height)
  glPixelStorei(glPackAlignment, 1)
  glReadPixels(0, 0, int32(width), int32(height), glRGBA,
               glUnsignedByte, unsafeAddr pix[0])
  glPixelStorei(glPackAlignment, 4)
  let ge = glGetError()
  if ge != glNoError:
    return (@[], newException(CatchableError,
      "gl: reading the framebuffer failed (error " & toHex(int(ge)) & ")"))
  # GL's rows go up, and its bytes are RGBA.
  var `out` = newSeq[byte](pix.len)
  for y in 0 ..< height:
    for x in 0 ..< 4 * width:
      let s = 4 * width * (height - 1 - y) + x
      let d = 4 * width * y + x
      if x mod 4 == 0:
        `out`[d] = pix[s + 2]
      elif x mod 4 == 2:
        `out`[d] = pix[s - 2]
      else:
        `out`[d] = pix[s]
  (`out`, nil)

when not defined(emscripten):
  # --- offscreen.go (linux only) ---

  const
    eglPlatformSurfaceless = 0x31DD'i32 # EGL_PLATFORM_SURFACELESS_MESA
    eglNone = 0x3038'i32
    eglRenderableType = 0x3040'i32
    eglOpenGLBit = 0x0008'i32
    eglSurfaceType = 0x3033'i32
    eglPbufferBit = 0x0001'i32
    eglOpenGLAPI = 0x30A2'u32
    eglOpenGLESAPI = 0x30A0'u32
    eglOpenGLES3Bit = 0x0040'i32 # EGL_OPENGL_ES3_BIT_KHR
    eglContextMajorVersion = 0x3098'i32
    eglContextMinorVersion = 0x30FB'i32
    eglContextProfileMask = 0x30FD'i32
    eglContextCoreProfileBit = 0x1'i32

  type Offscreen* = ref object
    ## A GL context without a window, current on the thread that made
    ## it, which must stay locked to it, with a framebuffer bound: for
    ## drawing scenes in tests, as packages drawing effects do. EGL
    ## makes it with Mesa's surfaceless platform, which draws with
    ## llvmpipe without a GPU.
    display, context: uint
    fb, tex: uint32
    w, h: int
    undoAll: proc()
    r: Renderer

  proc newOffscreen*(es: bool, w, h: int):
      tuple[o: Offscreen, err: ref CatchableError] =
    ## An OpenGL 3.3 context, or with es an OpenGL ES 3.0 one, current
    ## on the calling thread, and a bound framebuffer of w×h pixels.
    let lib = loadLib("libEGL.so.1", globalSymbols = true)
    if lib.isNil:
      return (nil, newException(CatchableError, "gl: no EGL"))
    var
      getPlatformDisplay: proc(platform: uint32, native: uint,
                               attribs: pointer): uint {.cdecl.}
      initialize: proc(display: uint, major, minor: ptr int32): uint32 {.cdecl.}
      bindAPI: proc(api: uint32): uint32 {.cdecl.}
      chooseConfig: proc(display: uint, attribs: ptr int32,
                         configs: ptr uint, size: int32,
                         n: ptr int32): uint32 {.cdecl.}
      createContext: proc(display, config, share: uint,
                          attribs: ptr int32): uint {.cdecl.}
      makeCurrent: proc(display, draw, read, context: uint): uint32 {.cdecl.}
      destroyContext: proc(display, context: uint): uint32 {.cdecl.}
      terminate: proc(display: uint): uint32 {.cdecl.}
    template eglBind(f: untyped, name: string) =
      let sym = lib.symAddr(name)
      if sym.isNil:
        return (nil, newException(CatchableError,
          "gl: EGL has no " & name))
      cast[ptr pointer](addr f)[] = sym
    eglBind(getPlatformDisplay, "eglGetPlatformDisplay")
    eglBind(initialize, "eglInitialize")
    eglBind(bindAPI, "eglBindAPI")
    eglBind(chooseConfig, "eglChooseConfig")
    eglBind(createContext, "eglCreateContext")
    eglBind(makeCurrent, "eglMakeCurrent")
    eglBind(destroyContext, "eglDestroyContext")
    eglBind(terminate, "eglTerminate")
    let o = Offscreen(w: w, h: h)
    var undo: seq[proc()]
    o.undoAll = proc() =
      for i in countdown(undo.len - 1, 0):
        undo[i]()
    var failed = true
    defer:
      if failed:
        o.undoAll()
    let display = getPlatformDisplay(uint32(eglPlatformSurfaceless), 0,
                                     nil)
    if display == 0 or initialize(display, nil, nil) == 0:
      return (nil, newException(CatchableError,
        "gl: no surfaceless EGL display"))
    undo.add proc() = discard terminate(display)
    var api = eglOpenGLAPI
    var bit = eglOpenGLBit
    var contextAttribs: seq[int32] =
      @[eglContextMajorVersion, 3'i32, eglContextMinorVersion, 3'i32,
        eglContextProfileMask, eglContextCoreProfileBit, eglNone]
    if es:
      api = eglOpenGLESAPI
      bit = eglOpenGLES3Bit
      contextAttribs = @[eglContextMajorVersion, 3'i32,
                         eglContextMinorVersion, 0'i32, eglNone]
    discard bindAPI(api)
    # Configurations are for windows unless asked otherwise.
    var configAttribs = @[eglRenderableType, bit, eglSurfaceType,
                         eglPbufferBit, eglNone]
    var config: uint
    var n: int32
    if chooseConfig(display, addr configAttribs[0], addr config, 1,
                    addr n) == 0 or n == 0:
      return (nil, newException(CatchableError,
        "gl: no EGL configuration for the API"))
    let context = createContext(display, config, 0,
                                addr contextAttribs[0])
    if context == 0:
      return (nil, newException(CatchableError,
        "gl: no context of the version"))
    undo.add proc() =
      discard makeCurrent(display, 0, 0, 0)
      discard destroyContext(display, context)
    if makeCurrent(display, 0, 0, context) == 0:
      return (nil, newException(CatchableError,
        "gl: cannot make the context current without a surface"))
    let le = load()
    if not le.isNil:
      return (nil, le)
    o.tex = newTexture(int32(glRGBA8), glRGBA, w, h, [], 0)
    glGenFramebuffers(1, addr o.fb)
    glBindFramebuffer(glFramebuffer, o.fb)
    glFramebufferTexture2D(glFramebuffer, glColorAttachment0,
                           glTexture2D, o.tex, 0)
    o.display = display
    o.context = context
    undo.add proc() =
      if not o.r.isNil:
        o.r.release()
      glBindFramebuffer(glFramebuffer, 0)
      glDeleteFramebuffers(1, unsafeAddr o.fb)
      glDeleteTextures(1, unsafeAddr o.tex)
    if glCheckFramebufferState(glFramebuffer) != glFramebufferDone:
      return (nil, newException(CatchableError,
        "gl: framebuffer incomplete"))
    failed = false
    (o, nil)

  ## info names the context's version and renderer.
  proc info*(o: Offscreen): string =
    goString(glGetString(glVersion)) & ", " &
      goString(glGetString(glRenderer))

  ## render draws s, which must be as large as the framebuffer, with a
  ## renderer of its own, and returns its pixels as the CPU renderer
  ## draws them: premultiplied BGRA rows from the top.
  proc render*(o: Offscreen, s: scene.Scene):
      tuple[pix: seq[byte], err: ref CatchableError] =
    if o.r.isNil:
      let (r, e) = newRenderer()
      if not e.isNil:
        return (@[], e)
      o.r = r
    let e = o.r.render(s)
    if not e.isNil:
      return (@[], e)
    readFramebuffer(o.w, o.h)

  ## release deletes the context and what it holds.
  proc release*(o: Offscreen) = o.undoAll()
