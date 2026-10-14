## com.nim (com.go): the COM layer the backend shares: calling methods
## through vtables, HRESULT errors, the single-method handler objects
## WebView2 callbacks want, and IStream helpers.

type
  comFn0 = proc(a0: uint): uint {.stdcall.}
  comFn1 = proc(a0, a1: uint): uint {.stdcall.}
  comFn2 = proc(a0, a1, a2: uint): uint {.stdcall.}
  comFn3 = proc(a0, a1, a2, a3: uint): uint {.stdcall.}
  comFn4 = proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
  comFn5 = proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
  comFn6 = proc(a0, a1, a2, a3, a4, a5, a6: uint): uint {.stdcall.}
  comFn7 = proc(a0, a1, a2, a3, a4, a5, a6, a7: uint): uint {.stdcall.}
  comFn8 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8: uint): uint {.stdcall.}
  comFn9 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9: uint): uint
    {.stdcall.}
  comFn10 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10: uint): uint
    {.stdcall.}
  comFn11 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11: uint):
    uint {.stdcall.}
  comFn12 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11,
    a12: uint): uint {.stdcall.}
  comFn13 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
    a13: uint): uint {.stdcall.}
  comFn14 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
    a13, a14: uint): uint {.stdcall.}
  comFn15 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
    a13, a14, a15: uint): uint {.stdcall.}

## comMethod returns method i of the COM interface obj.
proc comMethod(obj: uint, i: int): uint =
  let vtbl = cast[ptr UncheckedArray[uint]](cast[pointer](obj))[0]
  cast[ptr UncheckedArray[uint]](cast[pointer](vtbl))[i]

proc comCall*(obj: uint, i: int): uint =
  cast[comFn0](cast[pointer](comMethod(obj, i)))(obj)
proc comCall*(obj: uint, i: int, a1: uint): uint =
  cast[comFn1](cast[pointer](comMethod(obj, i)))(obj, a1)
proc comCall*(obj: uint, i: int, a1, a2: uint): uint =
  cast[comFn2](cast[pointer](comMethod(obj, i)))(obj, a1, a2)
proc comCall*(obj: uint, i: int, a1, a2, a3: uint): uint =
  cast[comFn3](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4: uint): uint =
  cast[comFn4](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5: uint): uint =
  cast[comFn5](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6: uint): uint =
  cast[comFn6](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7: uint): uint =
  cast[comFn7](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8: uint):
    uint =
  cast[comFn8](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8,
    a9: uint): uint =
  cast[comFn9](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9,
    a10: uint): uint =
  cast[comFn10](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
    a11: uint): uint =
  cast[comFn11](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10, a11)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
    a11, a12: uint): uint =
  cast[comFn12](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10, a11, a12)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
    a11, a12, a13: uint): uint =
  cast[comFn13](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10, a11, a12, a13)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
    a11, a12, a13, a14: uint): uint =
  cast[comFn14](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10, a11, a12, a13, a14)
proc comCall*(obj: uint, i: int, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
    a11, a12, a13, a14, a15: uint): uint =
  cast[comFn15](cast[pointer](comMethod(obj, i)))(obj, a1, a2, a3, a4, a5, a6, a7, a8,
    a9, a10, a11, a12, a13, a14, a15)

## comCallFloat calls method i of obj, which takes a double, as
## DirectWrite's methods do (dwrite.nim).
proc comCallFloat*(obj: uint, i: int, f: float64): uint =
  cast[proc(a0: uint, a1: float64): uint {.stdcall.}](
    cast[pointer](comMethod(obj, i)))(obj, f)

proc failed*(hr: uint): bool = int32(uint32(hr)) < 0

proc hresultError*(what: string, hr: uint): ref CatchableError =
  newException(CatchableError,
    "mynim: " & what & " failed (HRESULT " &
      toHex(uint32(hr), 8) & ")")

proc addRef*(obj: uint) =
  if obj != 0:
    discard comCall(obj, 1)

proc release*(obj: uint) =
  if obj != 0:
    discard comCall(obj, 2)

## queryInterface returns obj's implementation of iid, or 0.
proc queryInterface*(obj: uint, iid: ptr GUID): uint =
  if obj == 0:
    return 0
  var out0: uint
  if failed(comCall(obj, 0, cast[uint](iid),
      cast[uint](addr out0))):
    return 0
  out0

## Interfaces a COM object must not claim to implement blindly: callers
## would then marshal through it or treat it as free threaded.
var
  iidIMarshal* = guid("00000003-0000-0000-c000-000000000046")
  iidIAgileObject* = guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90")
  iidINoMarshal* = guid("ecc8691b-c1db-4dc0-855e-65f6c551af49")

## A handler is a COM object with a single method besides IUnknown, as
## the WebView2 event and completion handlers are. All handlers share
## one vtable, whose callbacks are created once; each object routes
## Invoke to its Nim function. Handlers stay reachable through the
## handlers table until COM releases its last reference.
type
  w32HandlerCom = object ## the memory COM sees
    vtbl: ptr array[4, uint]
    refs: int32
  w32Handler = ref object ## the GC-visible state
    com: ptr w32HandlerCom
    fn: proc(a, b: uint) {.closure.}

var
  handlerVtbl*: array[4, uint]
  handlersMu: Lock
  handlers: Table[uint, w32Handler]

proc handlerRef(this: uint, delta: int32): int32 =
  acquire(handlersMu)
  defer: release(handlersMu)
  let h = handlers.getOrDefault(this)
  if h.isNil:
    return 0
  h.com.refs += delta
  if h.com.refs <= 0:
    handlers.del(this)
    dealloc(h.com)
    return 0
  h.com.refs

proc handlerQueryInterface(this, riid, out0: uint): uint {.stdcall.} =
  let iid = cast[ptr GUID](cast[pointer](riid))[]
  if iid == iidIMarshal or iid == iidIAgileObject or iid == iidINoMarshal:
    cast[ptr uint](cast[pointer](out0))[] = 0
    return eNoInterface
  cast[ptr uint](cast[pointer](out0))[] = this
  discard handlerRef(this, 1)
  sOK

proc handlerAddRef(this: uint): uint {.stdcall.} =
  uint(handlerRef(this, 1))

proc handlerRelease(this: uint): uint {.stdcall.} =
  uint(handlerRef(this, -1))

proc handlerInvoke(this, a, b: uint): uint {.stdcall.} =
  acquire(handlersMu)
  let h = handlers.getOrDefault(this)
  release(handlersMu)
  if not h.isNil:
    h.fn(a, b)
  sOK

initLock(handlersMu)
handlerVtbl = [
  cast[uint](handlerQueryInterface),
  cast[uint](handlerAddRef),
  cast[uint](handlerRelease),
  cast[uint](handlerInvoke),
]

## newHandler creates a handler object holding one reference, which the
## caller releases once it has handed the object to COM.
proc newHandler*(fn: proc(a, b: uint) {.closure.}): uint =
  let com = cast[ptr w32HandlerCom](alloc0(sizeof(w32HandlerCom)))
  com.vtbl = addr handlerVtbl
  com.refs = 1
  let p = cast[uint](com)
  acquire(handlersMu)
  handlers[p] = w32Handler(com: com, fn: fn)
  release(handlersMu)
  p

## withHandler passes a new handler to call, which takes its own
## reference if it keeps the handler, and drops ours.
template withHandler*(fn: proc(a, b: uint) {.closure.},
    call: untyped): untyped =
  let h = newHandler(fn)
  let r = call(h)
  release(h)
  r

## IStream helpers.

## readStream reads an IStream to its end.
proc readStream*(stream: uint): seq[byte] =
  var buf = newSeq[byte](64 shl 10)
  while true:
    var n: uint32
    let hr = comCall(stream, 3, cast[uint](addr buf[0]), uint(buf.len),
      cast[uint](addr n)) ## ISequentialStream::Read
    result.add buf.toOpenArray(0, int(n) - 1)
    if failed(hr) or n == 0 or hr == 1: ## S_FALSE: end of stream
      return

## memStream returns a new IStream holding a copy of data.
proc memStream*(data: openArray[byte]): uint =
  var p: pointer
  if data.len > 0:
    p = unsafeAddr data[0]
  procSHCreateMemStream(cast[uint](p), uint(data.len))
