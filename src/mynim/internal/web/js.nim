## js.nim: JavaScript interop for the emscripten wasm build, standing
## for Go's syscall/js. JS values are handles into a registry on the JS
## side (__myjs.vals); each operation crosses with emscripten's asm
## facility, which passes ints and doubles, so strings cross as
## UTF8ToString and by emscripten_run_script_string for the way back.
## Callbacks into wasm go through the function-pointer table: JS calls
## jsDispatch, which finds the Nim proc registered for the handle.

type
  JsValue* = distinct int32
    ## A handle of a JS value kept in __myjs.vals.
  JsType* = enum
    jsUndefined, jsNull, jsBoolean, jsNumber, jsStringT, jsSymbol,
    jsFunction, jsObject
  JsCallback* = proc(this: JsValue, args: seq[JsValue]): JsValue

const
  jsUndef* = JsValue(0)
  jsNullV* = JsValue(1)
  jsGlobalV* = JsValue(2)
  jsTrueV* = JsValue(3)
  jsFalseV* = JsValue(4)

proc asmInt(code: cstring, sig: cstring): cint
  {.varargs, importc: "emscripten_asm_const_int",
   header: "<emscripten.h>".}
proc asmDouble(code: cstring, sig: cstring): cdouble
  {.varargs, importc: "emscripten_asm_const_double",
   header: "<emscripten.h>".}
proc asmPtr(code: cstring, sig: cstring): pointer
  {.varargs, importc: "emscripten_asm_const_ptr",
   header: "<emscripten.h>".}
proc runScript(code: cstring)
  {.importc: "emscripten_run_script", header: "<emscripten.h>".}
proc runScriptString(code: cstring): cstring
  {.importc: "emscripten_run_script_string", header: "<emscripten.h>".}
proc emscriptenSleep(ms: cuint)
  {.importc: "emscripten_sleep", header: "<emscripten.h>".}
proc exitWithLiveRuntime()
  {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}
proc forceExit(status: cint)
  {.importc: "emscripten_force_exit", header: "<emscripten.h>".}
proc cfre(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const jsGlue = """
var M = globalThis.__myjs = {
  vals: [undefined, null, globalThis, true, false],
  free: [], args: [],
  keep: function(v) {
    var i = M.free.length ? M.free.pop() : M.vals.length;
    M.vals[i] = v; return i;
  },
  take: function() { var a = M.args; M.args = []; return a; },
  of: function(a) { for (var i = 0, r = []; i < a.length; i++) r.push(M.vals[a[i]]); return r; },
  typeof: function(v) {
    if (v === null) return 1;
    switch (typeof v) {
      case 'undefined': return 0; case 'boolean': return 2;
      case 'number': return 3; case 'string': return 4;
      case 'symbol': return 5; case 'function': return 6;
      default: return 7;
    }
  },
  stringOf: function(h) {
    var v = M.vals[h];
    return v === undefined ? 'undefined' : v === null ? 'null' : String(v);
  },
  fnOf: function(id) {
    var f = function() {
      M.args = [M.keep(this)];
      for (var i = 0; i < arguments.length; i++) M.args.push(M.keep(arguments[i]));
      var r = M.dispatchFn ? M.dispatchFn(id) : 0;
      return M.vals[r];
    };
    f.__myid = id;
    return M.keep(f);
  },
  cbOf: function(id) {
    // A function that ignores its arguments and wakes the callback,
    // for promise .then/.catch handlers passed event results.
    return M.fnOf(id);
  }
};
"""
## __myjs.dispatchFn is set from the wasm function table by jsInit.

var
  cbTable: Table[cint, JsCallback]
  cbHandle: Table[cint, JsValue] ## callback id -> its JS function handle
  cbNext: cint = 1
  jsInited: bool

proc hi(v: JsValue): cint = cast[cint](v)
  ## a value's handle, for asm arguments

proc `==`*(a, b: JsValue): bool {.borrow.}

proc jsDispatch(id: cint): cint {.exportc, cdecl.} =
  ## Routes a JS call of a jsFuncOf'd Nim proc.
  {.gcsafe.}:
    let fn = cbTable.getOrDefault(id)
    if fn.isNil:
      return 0
    let n = int(asmInt("return __myjs.args.length", ""))
    var args = newSeqOfCap[JsValue](n)
    for i in 0 ..< n:
      args.add JsValue(asmInt("return __myjs.args[$0]", "i", i.cint))
    let this = if args.len > 0: args[0] else: jsUndef
    cint(fn(this, args[1..^1]))

proc jsInit() =
  ## Installs __myjs and hands it the wasm dispatcher.
  if jsInited:
    return
  jsInited = true
  runScript(jsGlue)
  let idx = cint(cast[int](cast[pointer](jsDispatch)))
  discard asmInt(
    "var W = typeof wasmTable !== 'undefined' ? wasmTable : Module['wasmTable']; __myjs.dispatchFn = W.get($0);",
    "i", idx)

## --- reads and writes ---

proc jsGet*(h: JsValue, name: cstring): JsValue =
  JsValue(asmInt(
    "return __myjs.keep(__myjs.vals[$0][UTF8ToString($1)]);",
    "ii", hi(h), name))

proc jsGetIx*(h: JsValue, i: int): JsValue =
  JsValue(asmInt("return __myjs.keep(__myjs.vals[$0][$1]);",
                 "ii", hi(h), i.cint))

proc jsSet*(h: JsValue, name: cstring, v: JsValue) =
  discard asmInt("__myjs.vals[$0][UTF8ToString($1)] = __myjs.vals[$2];",
          "iii", hi(h), name, hi(v))

proc jsSetIx*(h: JsValue, i: int, v: JsValue) =
  discard asmInt("__myjs.vals[$0][$1] = __myjs.vals[$2];",
          "iii", hi(h), i.cint, hi(v))

proc jsPushArg*(v: JsValue) =
  discard asmInt("__myjs.args.push($0);", "i", hi(v))

proc jsCall*(h: JsValue, name: cstring, args: openArray[JsValue]): JsValue =
  ## h.name(args...) as a method of h.
  for a in args:
    jsPushArg(a)
  JsValue(asmInt(
    """var o = __myjs.vals[$0], f = o[UTF8ToString($1)];
       var a = __myjs.take();
       return __myjs.keep(f.apply(o, __myjs.of(a)));""",
    "ii", hi(h), name))

proc jsInvoke*(h: JsValue, args: openArray[JsValue]): JsValue =
  ## h(args...) as a bare function.
  for a in args:
    jsPushArg(a)
  JsValue(asmInt(
    """var a = __myjs.take();
       return __myjs.keep(__myjs.vals[$0].apply(undefined, __myjs.of(a)));""",
    "i", hi(h)))

proc jsNew*(h: JsValue, args: openArray[JsValue]): JsValue =
  ## new h(args...).
  for a in args:
    jsPushArg(a)
  JsValue(asmInt(
    """var a = __myjs.of(__myjs.take());
       var C = __myjs.vals[$0];
       return __myjs.keep(new (Function.prototype.bind.apply(C, [null].concat(a))));""",
    "i", hi(h)))

proc jsArrayOf*(vals: seq[JsValue]): JsValue =
  ## A JS array of the values, made through the arg stack.
  for v in vals:
    jsPushArg(v)
  JsValue(asmInt(
    "return __myjs.keep(__myjs.of(__myjs.take()));", ""))

proc jsObj*(): JsValue =
  JsValue(asmInt("return __myjs.keep({});", ""))

proc jsLen*(h: JsValue): int =
  int(asmInt("return __myjs.vals[$0].length|0;", "i", hi(h)))

proc jsType*(h: JsValue): JsType =
  JsType(asmInt("return __myjs.typeof(__myjs.vals[$0]);", "i", hi(h)))

proc jsBool*(h: JsValue): bool =
  asmInt("return __myjs.vals[$0] ? 1 : 0;", "i", hi(h)) != 0

proc jsInt*(h: JsValue): int =
  int(asmInt("return Math.trunc(__myjs.vals[$0]);", "i", hi(h)))

proc jsFloat*(h: JsValue): float64 =
  float64(asmDouble("return __myjs.vals[$0];", "i", hi(h)))

proc jsString*(h: JsValue): string =
  let p = runScriptString("__myjs.stringOf(" & $cast[int32](h) & ")")
  if p.isNil:
    return ""
  result = $p
  cfre(p)

proc jsIsUndefined*(h: JsValue): bool = jsType(h) == jsUndefined
proc jsIsNull*(h: JsValue): bool = jsType(h) == jsNull
proc jsEqual*(a, b: JsValue): bool =
  asmInt("return __myjs.vals[$0] === __myjs.vals[$1] ? 1 : 0;",
         "ii", hi(a), hi(b)) != 0

## --- value construction ---

proc jsValueOf*(s: string): JsValue =
  JsValue(asmInt("return __myjs.keep(UTF8ToString($0));", "i",
                 s.cstring))

proc jsValueOf*(v: bool): JsValue =
  if v: jsTrueV else: jsFalseV

proc jsValueOf*(v: int): JsValue =
  JsValue(asmInt("return __myjs.keep($0);", "i", v.cint))

proc jsValueOf*(v: float64): JsValue =
  JsValue(asmInt("return __myjs.keep($0);", "d", v.cdouble))

## --- callbacks and buffers ---

proc jsFuncOf*(fn: JsCallback): JsValue =
  ## A JS function calling fn, whose arguments reach it as handles.
  jsInit()
  let id = cbNext
  inc cbNext
  cbTable[id] = fn
  let h = JsValue(asmInt("return __myjs.fnOf($0);", "i", id))
  cbHandle[id] = h
  h

proc jsFuncRelease*(h: JsValue) =
  for id, hh in cbHandle.pairs:
    if hh == h:
      cbTable.del(id)
      cbHandle.del(id)
      break
  discard asmInt("delete __myjs.vals[$0]; __myjs.free.push($0);", "i", hi(h))

proc jsCopyToJS*(dst: JsValue, src: openArray[byte]) =
  ## Copy bytes into a JS Uint8Array (or ArrayBuffer view).
  if src.len == 0:
    return
  discard asmInt("__myjs.vals[$0].set(HEAPU8.subarray($1, $1 + $2));",
          "iii", hi(dst), cast[cint](cast[int](unsafeAddr src[0])),
          src.len.cint)

proc jsCopyFromJS*(dst: var openArray[byte], src: JsValue) =
  ## Copy a JS Uint8Array's bytes into wasm memory.
  if dst.len == 0:
    return
  discard asmInt("HEAPU8.set(__myjs.vals[$0], $1);",
          "ii", hi(src), cast[cint](cast[int](addr dst[0])))

proc jsGlobal*(): JsValue = jsGlobalV
