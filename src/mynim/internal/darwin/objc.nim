## objc.go: the Objective-C runtime, driven through direct FFI — Nim emits
## C, so the purego trampolines of the Go original are ordinary dynlib
## bindings here.

type
  id* = pointer
  SEL* = pointer

## NSPoint, NSSize and NSRect mirror the CoreGraphics structs (64-bit).
type
  NSPoint* = object
    x*, y*: float64
  NSSize* = object
    width*, height*: float64
  NSRect* = object
    origin*: NSPoint
    size*: NSSize

const
  libObjC* = "libobjc.A.dylib"
  libFoundation* =
    "/System/Library/Frameworks/Foundation.framework/Foundation"
  libCF* =
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
  libCG* =
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
  libAppKit* =
    "/System/Library/Frameworks/AppKit.framework/AppKit"
  libWebKit* =
    "/System/Library/Frameworks/WebKit.framework/WebKit"
  libCarbon* = "/System/Library/Frameworks/Carbon.framework/Carbon"
  libCoreServices* =
    "/System/Library/Frameworks/CoreServices.framework/CoreServices"
  libIOKit* = "/System/Library/Frameworks/IOKit.framework/IOKit"
  libUTI* =
    "/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers"
  libUserNotifications* =
    "/System/Library/Frameworks/UserNotifications.framework/UserNotifications"
  libServiceManagement* =
    "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement"
  libSystem* = "libSystem.B.dylib"

## Runtime entry points. objc_msgSend is variadic; it is bound once per
## arity for the integer/pointer arguments of `send`, and once per
## signature for arguments or results of other C types.

when defined(amd64):
  const msgStret = "objc_msgSend_stret"
else:
  # arm64 and others return big structs through the same entry point.
  const msgStret = "objc_msgSend"

proc msgSend0(o, s: pointer): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend1(o, s: pointer; a1: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend2(o, s: pointer; a1, a2: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend3(o, s: pointer; a1, a2, a3: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend4(o, s: pointer; a1, a2, a3, a4: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend5(o, s: pointer; a1, a2, a3, a4, a5: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend6(o, s: pointer; a1, a2, a3, a4, a5, a6: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend7(o, s: pointer; a1, a2, a3, a4, a5, a6, a7: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend8(o, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend9(o, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend10(o, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend11(o, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
               a11: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSend12(o, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10,
               a11, a12: uint): pointer
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

proc msgSuper0(sup, s: pointer): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper1(sup, s: pointer; a1: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper2(sup, s: pointer; a1, a2: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper3(sup, s: pointer; a1, a2, a3: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper4(sup, s: pointer; a1, a2, a3, a4: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper5(sup, s: pointer; a1, a2, a3, a4, a5: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper6(sup, s: pointer; a1, a2, a3, a4, a5, a6: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper7(sup, s: pointer; a1, a2, a3, a4, a5, a6, a7: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper8(sup, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper9(sup, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuper10(sup, s: pointer; a1, a2, a3, a4, a5, a6, a7, a8, a9,
                a10: uint): pointer
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}

## Typed variants of objc_msgSend for float and struct arguments.
proc msgRect*(obj: id, s: SEL): NSRect
  {.importc: msgStret, dynlib: libObjC, cdecl.}
proc msgSetRect*(obj: id, s: SEL, r: NSRect)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetRectBool*(obj: id, s: SEL, r: NSRect, b: bool)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgRectForRect*(obj: id, s: SEL, r: NSRect, style: uint): NSRect
  {.importc: msgStret, dynlib: libObjC, cdecl.}
proc msgRectToRect*(obj: id, s: SEL, r: NSRect): NSRect
  {.importc: msgStret, dynlib: libObjC, cdecl.}
proc msgFloat*(obj: id, s: SEL): float64
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetFloat*(obj: id, s: SEL, v: float64)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSize*(obj: id, s: SEL): NSSize
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetSize*(obj: id, s: SEL, sz: NSSize)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSuperSetSize*(sup: pointer, s: SEL, sz: NSSize)
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgSuperPoint*(sup: pointer, s: SEL, p: NSPoint): id
  {.importc: "objc_msgSendSuper", dynlib: libObjC, cdecl.}
proc msgPoint*(obj: id, s: SEL): NSPoint
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgSetPoint*(obj: id, s: SEL, p: NSPoint)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInitRect*(obj: id, s: SEL, r: NSRect): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInitRectID*(obj: id, s: SEL, r: NSRect, a: id): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgRectIDUint*(obj: id, s: SEL, r: NSRect, a: id, n: uint)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInitIDPoint*(obj: id, s: SEL, a: id, p: NSPoint): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInitWindow*(obj: id, s: SEL, r: NSRect, style, backing: uint,
                    deferFlag: bool): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgColor*(cls: id, s: SEL, r, g, b, a: float64): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgOtherEvent*(cls: id, s: SEL, typ: uint, loc: NSPoint, flags: uint,
                    ts: float64, wn: int, ctx: id, subtype: int16,
                    d1, d2: int): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgPopUpMenu*(menu: id, s: SEL, item: id, loc: NSPoint, view: id): bool
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgNextEvent*(app: id, s: SEL, mask: uint64, until, mode: id,
                   dequeue: bool): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgPointFromView*(obj: id, s: SEL, p: NSPoint, view: id): NSPoint
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgPointToPoint*(obj: id, s: SEL, p: NSPoint): NSPoint
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgConvertRectView*(obj: id, s: SEL, r: NSRect, view: id): NSRect
  {.importc: msgStret, dynlib: libObjC, cdecl.}
proc msgDateSince*(cls: id, s: SEL, seconds: float64): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgFloatID*(obj: id, s: SEL, v: float64): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgFloat2ID*(obj: id, s: SEL, a, b: float64): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgFontFamily*(obj: id, s: SEL, family: id, traits: uint, weight: int,
                    size: float64): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgMouseEvent*(cls: id, s: SEL, typ: uint, loc: NSPoint, flags: uint,
                    ts: float64, wn: int, ctx: id, eventNumber, clickCount: int,
                    pressure: float32): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgKeyEvent*(cls: id, s: SEL, typ: uint, loc: NSPoint, flags: uint,
                  ts: float64, wn: int, ctx: id, chars, charsIgnoring: id,
                  repeat: bool, keyCode: uint16): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgDrawImage*(obj: id, s: SEL, dst, src: NSRect, op: uint,
                   fraction: float64)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInitBitmap*(obj: id, s: SEL, planes: pointer, width, height,
                    bitsPerSample, samplesPerPixel: int, alpha, planar: bool,
                    colorSpace: id, bytesPerRow, bitsPerPixel: int): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

proc blockCopyRaw(b: pointer): pointer
  {.importc: "_Block_copy", dynlib: libObjC, cdecl.}
proc blockReleaseRaw(b: pointer)
  {.importc: "_Block_release", dynlib: libObjC, cdecl.}

## Functions on hot paths, called by address in Go; ordinary bindings here.
proc poolPush*(): pointer
  {.importc: "objc_autoreleasePoolPush", dynlib: libObjC, cdecl.}
proc poolPop*(pool: pointer)
  {.importc: "objc_autoreleasePoolPop", dynlib: libObjC, cdecl.}
proc pthreadMainNP*(): cint
  {.importc: "pthread_main_np", dynlib: libSystem, cdecl.}

proc selRegisterName(name: cstring): SEL
  {.importc: "sel_registerName", dynlib: libObjC, cdecl.}
proc objcGetClass(name: cstring): id
  {.importc: "objc_getClass", dynlib: libObjC, cdecl.}
proc classGetSuperclass(cls: id): id
  {.importc: "class_getSuperclass", dynlib: libObjC, cdecl.}
proc objcAllocateClassPair(super: id, name: cstring, extraBytes: csize_t): id
  {.importc: "objc_allocateClassPair", dynlib: libObjC, cdecl.}
proc objcRegisterClassPair(cls: id)
  {.importc: "objc_registerClassPair", dynlib: libObjC, cdecl.}
proc classAddMethod(cls: id, name: SEL, imp: pointer, types: cstring): bool
  {.importc: "class_addMethod", dynlib: libObjC, cdecl.}
proc classAddIvar(cls: id, name: cstring, size: csize_t, alignment: uint8,
                  types: cstring): bool
  {.importc: "class_addIvar", dynlib: libObjC, cdecl.}
proc classAddProtocol(cls: id, proto: pointer): bool
  {.importc: "class_addProtocol", dynlib: libObjC, cdecl.}
proc objcGetProtocol(name: cstring): pointer
  {.importc: "objc_getProtocol", dynlib: libObjC, cdecl.}
proc objectGetIvar(obj: id, ivar: pointer): id
  {.importc: "object_getIvar", dynlib: libObjC, cdecl.}
proc objectSetIvar(obj: id, ivar: pointer, v: id)
  {.importc: "object_setIvar", dynlib: libObjC, cdecl.}
proc classGetInstanceVariable(cls: id, name: cstring): pointer
  {.importc: "class_getInstanceVariable", dynlib: libObjC, cdecl.}

## dlopen'd frameworks' exported globals are read through dlsym.
proc dlopen(path: cstring, mode: cint): pointer
  {.importc: "dlopen", dynlib: "libdl.dylib".}
proc dlsym(handle: pointer, name: cstring): pointer
  {.importc: "dlsym", dynlib: "libdl.dylib".}

const rtldNow* = 2
const rtldGlobal* = 8
const rtldDefault* = cast[pointer](-2.int64)

proc mustDlopen*(path: string): pointer =
  result = dlopen(path, rtldNow or rtldGlobal)
  if result.isNil:
    raise newException(IOError, "mynim: cannot load " & path)

proc mustDlsym*(lib: pointer, name: string): pointer =
  result = dlsym(lib, name)
  if result.isNil:
    raise newException(IOError, "mynim: " & name)

proc deref[T](p: pointer): T =
  cast[ptr T](p)[]

var libFoundationH*, libCFH*, libCGH*, libAppKitH*, libWebKitH*,
    libCarbonH*, libCoreServicesH*, libIOKitH*: pointer

var loadedOnce: bool

## loadFrameworks opens the frameworks; the optional ones are loaded so
## their classes are registered. Essential handles serve constString.
proc loadFrameworks*() =
  if loadedOnce:
    return
  loadedOnce = true
  libFoundationH = mustDlopen(libFoundation)
  libCFH = mustDlopen(libCF)
  libCGH = mustDlopen(libCG)
  libAppKitH = mustDlopen(libAppKit)
  libWebKitH = mustDlopen(libWebKit)
  libCarbonH = mustDlopen(libCarbon)
  libCoreServicesH = mustDlopen(libCoreServices)
  libIOKitH = dlopen(libIOKit, rtldGlobal or rtldNow)
  discard dlopen(libUTI, rtldGlobal or rtldNow)
  discard dlopen(libUserNotifications, rtldGlobal or rtldNow)
  discard dlopen(libServiceManagement, rtldGlobal or rtldNow)

var selCache: Table[string, SEL]
var clsCache: Table[string, id]
var superCache: Table[string, id]

## sel returns the selector for name, cached.
proc sel*(name: string): SEL =
  result = selCache.getOrDefault(name)
  if result.isNil:
    result = selRegisterName(name)
    selCache[name] = result

## class returns the class object for name, cached. It panics for classes
## that do not exist since that is a programming error.
proc `class`*(name: string): id =
  result = clsCache.getOrDefault(name)
  if result.isNil:
    result = objcGetClass(name)
    if result.isNil:
      raise newException(ValueError,
                         "mynim: Objective-C class " & name & " not found")
    clsCache[name] = result

## hasClass reports whether a class exists (for APIs of newer macOS
## versions).
proc hasClass*(name: string): bool = not objcGetClass(name).isNil

## sendImpl sends a message whose arguments are integers or pointers,
## dispatched on arity.
proc sendImpl(obj: id, s: SEL, args: openArray[uint]): pointer =
  case args.len
  of 0: msgSend0(obj, s)
  of 1: msgSend1(obj, s, args[0])
  of 2: msgSend2(obj, s, args[0], args[1])
  of 3: msgSend3(obj, s, args[0], args[1], args[2])
  of 4: msgSend4(obj, s, args[0], args[1], args[2], args[3])
  of 5: msgSend5(obj, s, args[0], args[1], args[2], args[3], args[4])
  of 6: msgSend6(obj, s, args[0], args[1], args[2], args[3], args[4],
                 args[5])
  of 7: msgSend7(obj, s, args[0], args[1], args[2], args[3], args[4],
                 args[5], args[6])
  of 8: msgSend8(obj, s, args[0], args[1], args[2], args[3], args[4],
                 args[5], args[6], args[7])
  of 9: msgSend9(obj, s, args[0], args[1], args[2], args[3], args[4],
                 args[5], args[6], args[7], args[8])
  of 10: msgSend10(obj, s, args[0], args[1], args[2], args[3], args[4],
                   args[5], args[6], args[7], args[8], args[9])
  of 11: msgSend11(obj, s, args[0], args[1], args[2], args[3], args[4],
                   args[5], args[6], args[7], args[8], args[9], args[10])
  else: msgSend12(obj, s, args[0], args[1], args[2], args[3], args[4],
                  args[5], args[6], args[7], args[8], args[9], args[10],
                  args[11])

proc argu*(x: pointer): uint = cast[uint](x)
proc argu*(x: bool): uint = x.uint
proc argu*(x: SomeInteger): uint = x.uint

## send sends a message whose arguments are integers or pointers.
proc send*(obj: id, selector: string,
           args: varargs[uint, argu]): id {.inline.} =
  id sendImpl(obj, sel(selector), args)

## sendSel is send with a resolved selector.
proc sendSel*(obj: id, s: SEL,
              args: varargs[uint, argu]): id {.inline.} =
  id sendImpl(obj, s, args)

## sendBool sends a message returning BOOL.
proc sendBool*(obj: id, selector: string,
               args: varargs[uint, argu]): bool {.inline.} =
  (cast[uint](send(obj, selector, args)) and 0xff) != 0

## sendInt sends a message returning NSInteger.
proc sendInt*(obj: id, selector: string,
              args: varargs[uint, argu]): int {.inline.} =
  cast[int](send(obj, selector, args))

## objcSuper mirrors struct objc_super.
type objcSuper = object
  receiver: id
  superClass: id

## superclass returns the superclass of a class, cached: overrides call it
## as often as AppKit calls them, as setFrameSize: while a window resizes.
proc superclass(name: string): id =
  result = superCache.getOrDefault(name)
  if result.isNil:
    result = classGetSuperclass(`class`(name))
    superCache[name] = result

## superOf returns the struct objc_super that calls the superclass of
## className with self. The superclass is resolved from className rather
## than from the object's class, which the runtime may replace with a
## generated subclass (key-value observing does): resolving "super" from
## it would call the override again and recurse forever. Nim's stack does
## not move, so a local suffices.
proc superOf(self: id, className: string): ptr objcSuper =
  result = create(objcSuper)
  result.receiver = self
  result.superClass = superclass(className)

## sendSuper calls the superclass implementation of a method overridden in
## className (see superOf).
proc sendSuper*(self: id, className: string, s: SEL,
                args: varargs[uint, argu]): id =
  let sup = superOf(self, className)
  defer: dealloc(sup)
  let p = cast[pointer](sup)
  result = case args.len
    of 0: id msgSuper0(p, s)
    of 1: id msgSuper1(p, s, args[0])
    of 2: id msgSuper2(p, s, args[0], args[1])
    of 3: id msgSuper3(p, s, args[0], args[1], args[2])
    of 4: id msgSuper4(p, s, args[0], args[1], args[2], args[3])
    of 5: id msgSuper5(p, s, args[0], args[1], args[2], args[3], args[4])
    of 6: id msgSuper6(p, s, args[0], args[1], args[2], args[3], args[4],
                       args[5])
    of 7: id msgSuper7(p, s, args[0], args[1], args[2], args[3], args[4],
                       args[5], args[6])
    of 8: id msgSuper8(p, s, args[0], args[1], args[2], args[3], args[4],
                       args[5], args[6], args[7])
    of 9: id msgSuper9(p, s, args[0], args[1], args[2], args[3], args[4],
                       args[5], args[6], args[7], args[8])
    else: id msgSuper10(p, s, args[0], args[1], args[2], args[3], args[4],
                        args[5], args[6], args[7], args[8], args[9])

## sendSuperSize is sendSuper for a method taking an NSSize, which travels
## in floating-point registers and so cannot go through the integer
## arguments.
proc sendSuperSize*(self: id, className: string, s: SEL, size: NSSize) =
  let sup = superOf(self, className)
  defer: dealloc(sup)
  msgSuperSetSize(sup, s, size)

## sendSuperPoint is sendSuper for a method taking an NSPoint and
## returning an object, as hitTest:.
proc sendSuperPoint*(self: id, className: string, s: SEL, p: NSPoint): id =
  let sup = superOf(self, className)
  defer: dealloc(sup)
  msgSuperPoint(sup, s, p)

proc respondsTo*(obj: id, selector: string): bool =
  not obj.isNil and sendBool(obj, "respondsToSelector:", argu(sel(selector)))

proc retain*(obj: id): id =
  if obj.isNil: nil else: send(obj, "retain")

proc release*(obj: id) =
  if not obj.isNil:
    discard send(obj, "release")

proc autorelease*(obj: id): id =
  if obj.isNil: nil else: send(obj, "autorelease")

proc nsString*(s: string): id

## appKitString returns an NSString constant that AppKit exports, such as
## NSPrintJobSavingURL, whose value may differ from its name.
proc appKitString*(name: string): id =
  let p = dlsym(libAppKitH, name)
  if p.isNil: nsString(name) else: deref[id](p)

## constString reads an exported NSString constant such as
## NSPasteboardTypeString.
proc constString*(lib: pointer, name: string): id =
  let p = dlsym(lib, name)
  if p.isNil: nil else: deref[id](p)

## alloc creates an owned (+1) instance of a class with init.
proc alloc*(className: string): id =
  send(send(`class`(className), "alloc"), "init")

## withPool runs fn inside an autorelease pool. A pool belongs to the
## thread that pushed it.
proc withPool*(fn: proc()) =
  let pool = poolPush()
  defer: poolPop(pool)
  fn()

const nsUTF8StringEncoding* = 4

## nsString returns an autoreleased NSString.
proc nsString*(s: string): id =
  let str = send(send(`class`("NSString"), "alloc"),
                 "initWithBytes:length:encoding:",
                 argu(if s.len > 0: cast[pointer](s.cstring) else: nil),
                 argu(s.len), argu(nsUTF8StringEncoding))
  autorelease(str)

## goString copies an NSString into a Nim string.
proc goString*(str: id): string =
  if str.isNil:
    return ""
  let p = send(str, "UTF8String")
  if p.isNil:
    return ""
  let n = sendInt(str, "lengthOfBytesUsingEncoding:",
                  argu(nsUTF8StringEncoding))
  result = newString(n)
  if n > 0:
    copyMem(addr result[0], p, n)

## nsData returns an autoreleased NSData with a copy of b.
proc nsData*(b: openArray[byte]): id =
  send(`class`("NSData"), "dataWithBytes:length:",
       argu(if b.len > 0: cast[pointer](unsafeAddr b[0]) else: nil),
       argu(b.len))

## goBytes copies the contents of an NSData.
proc goBytes*(data: id): seq[byte] =
  if data.isNil:
    return @[]
  let n = sendInt(data, "length")
  if n == 0:
    return @[]
  let p = send(data, "bytes")
  result = newSeq[byte](n)
  copyMem(addr result[0], p, n)

proc nsURL*(s: string): id =
  send(`class`("NSURL"), "URLWithString:", argu(nsString(s)))

## filePathURLBytes resolves a file reference URL (file:///.file/id=…,
## which Finder puts on the pasteboard when it drags or copies files) to a
## file URL of its path. Other URLs come back unchanged.
proc filePathURLBytes*(b: openArray[byte]): seq[byte] =
  var s = newString(b.len)
  if b.len > 0:
    copyMem(addr s[0], unsafeAddr b[0], b.len)
  s = s.strip(chars = {'\0'}, trailing = true, leading = false)
  if not s.startsWith("file:///.file/"):
    return @b
  let u = nsURL(s)
  if u.isNil:
    return @b
  let p = send(u, "filePathURL")
  if not p.isNil:
    let r = goString(send(p, "absoluteString"))
    if r != "":
      return cast[seq[byte]](r)
  @b

proc fileURL*(path: string): id =
  send(`class`("NSURL"), "fileURLWithPath:", argu(nsString(path)))

## nsArray returns an autoreleased NSArray of objs.
proc nsArray*(objs: varargs[id]): id =
  let arr = send(`class`("NSMutableArray"), "arrayWithCapacity:",
                 argu(objs.len))
  for o in objs:
    discard send(arr, "addObject:", argu(o))
  arr

proc arrayItems*(arr: id): seq[id] =
  if arr.isNil:
    return @[]
  let n = sendInt(arr, "count")
  result = newSeq[id](n)
  for i in 0 ..< n:
    result[i] = send(arr, "objectAtIndex:", argu(i))

proc nsNumberInt*(v: int): id =
  send(`class`("NSNumber"), "numberWithLongLong:", argu(v))

proc nsBool*(v: bool): id =
  send(`class`("NSNumber"), "numberWithBool:", argu(v))

## Block literal ABI. A block is a literal {isa, flags, reserved, invoke,
## descriptor} followed by captured variables; here the one capture is a
## pointer to the Nim cell that holds the closure.

type
  BlockDesc = object
    reserved: culong
    size: culong
    copyHelper: pointer
    disposeHelper: pointer
    signature: cstring
  BlockLit = object
    isa: pointer
    flags: cint
    reserved: cint
    invoke: pointer
    desc: ptr BlockDesc
    ctx: pointer ## the cell: first a generic call, then the env ref

const
  blockHasCopyDispose = 1 shl 25
  blockHasSignature = 1 shl 30

var NSConcreteGlobalBlock {.importc: "_NSConcreteGlobalBlock",
                           dynlib: libSystem.}: pointer

## liveBlocks keeps block cells alive forever: blocks handed to Cocoa are
## never freed, like the scarce callbacks of the Go original.
var liveBlocks: seq[ref RootObj]

type
  ## A block that takes args A1..An as id-sized values and returns
  ## nothing; each Nim proc stored in a cell is a cdecl trampoline that
  ## reads this ctx.
  BlockCell*[F] = ref object of RootObj
    f*: F

proc blockCopy*(b: pointer): pointer = blockCopyRaw(b)
proc blockRelease*(b: pointer) = blockReleaseRaw(b)

template defBlock(name, sig, body) {.dirty.} = discard

## callBlock invokes an Objective-C block received from the system, such
## as a WebKit completion handler.
proc callBlock*(blk: pointer, args: openArray[uint]) =
  type Inv0 = proc(b: pointer): pointer {.cdecl.}
  type Inv1 = proc(b: pointer; a1: uint): pointer {.cdecl.}
  type Inv2 = proc(b: pointer; a1, a2: uint): pointer {.cdecl.}
  type Inv3 = proc(b: pointer; a1, a2, a3: uint): pointer {.cdecl.}
  let lit = cast[ptr BlockLit](blk)
  case args.len
  of 0: discard cast[Inv0](lit.invoke)(blk)
  of 1: discard cast[Inv1](lit.invoke)(blk, args[0])
  of 2: discard cast[Inv2](lit.invoke)(blk, args[0], args[1])
  else: discard cast[Inv3](lit.invoke)(blk, args[0], args[1], args[2])

## mkBlock allocates a block literal with the given invoke trampoline and
## signature; ctx is the cell the trampoline reads.
proc mkBlock(invoke: pointer, signature: cstring, cell: ref RootObj): pointer =
  let desc = cast[ptr BlockDesc](allocShared0(sizeof(BlockDesc)))
  desc.size = culong(sizeof(BlockLit))
  desc.signature = signature
  let lit = cast[ptr BlockLit](allocShared0(sizeof(BlockLit)))
  lit.isa = NSConcreteGlobalBlock
  lit.flags = blockHasCopyDispose or blockHasSignature
  lit.invoke = invoke
  lit.desc = desc
  lit.ctx = cast[pointer](cell)
  liveBlocks.add cell
  cast[pointer](lit)

## Block signatures used by AppKit and WebKit, with their type encodings.
## Each mkBlockN wraps a Nim closure in the matching trampoline.

proc trampBlockId(blk: ptr BlockLit; a: id) {.cdecl.} =
  cast[BlockCell[proc(a: id)]](blk.ctx).f(a)

proc mkBlockId*(f: proc(a: id)): pointer =
  ## a block of signature void (^)(id)
  mkBlock(cast[pointer](trampBlockId), "v@?@",
          BlockCell[proc(a: id)](f: f))

proc trampBlockIdId(blk: ptr BlockLit; a, b: id) {.cdecl.} =
  cast[BlockCell[proc(a, b: id)]](blk.ctx).f(a, b)

proc mkBlockIdId*(f: proc(a, b: id)): pointer =
  ## a block of signature void (^)(id, id)
  mkBlock(cast[pointer](trampBlockIdId), "v@?@@",
          BlockCell[proc(a, b: id)](f: f))

proc trampBlockIdIdId(blk: ptr BlockLit; a, b, c: id) {.cdecl.} =
  cast[BlockCell[proc(a, b, c: id)]](blk.ctx).f(a, b, c)

proc mkBlockIdIdId*(f: proc(a, b, c: id)): pointer =
  ## a block of signature void (^)(id, id, id)
  mkBlock(cast[pointer](trampBlockIdIdId), "v@?@@@",
          BlockCell[proc(a, b, c: id)](f: f))

proc trampBlockIdRetId(blk: ptr BlockLit; a: id): id {.cdecl.} =
  cast[BlockCell[proc(a: id): id]](blk.ctx).f(a)

proc mkBlockIdRetId*(f: proc(a: id): id): pointer =
  ## a block of signature id (^)(id)
  mkBlock(cast[pointer](trampBlockIdRetId), "@@?@",
          BlockCell[proc(a: id): id](f: f))

proc trampBlockBool(blk: ptr BlockLit; a: bool) {.cdecl.} =
  cast[BlockCell[proc(a: bool)]](blk.ctx).f(a)

proc mkBlockBool*(f: proc(a: bool)): pointer =
  ## a block of signature void (^)(BOOL)
  mkBlock(cast[pointer](trampBlockBool), "v@?B",
          BlockCell[proc(a: bool)](f: f))

proc trampBlockInt(blk: ptr BlockLit; a: clonglong) {.cdecl.} =
  cast[BlockCell[proc(a: clonglong)]](blk.ctx).f(a)

proc mkBlockInt*(f: proc(a: clonglong)): pointer =
  ## a block of signature void (^)(NSInteger)
  mkBlock(cast[pointer](trampBlockInt), "v@?q",
          BlockCell[proc(a: clonglong)](f: f))

proc trampBlockVoid(blk: ptr BlockLit) {.cdecl.} =
  cast[BlockCell[proc()]](blk.ctx).f()

proc mkBlockVoid*(f: proc()): pointer =
  ## a block of signature void (^)(void)
  mkBlock(cast[pointer](trampBlockVoid), "v@?",
          BlockCell[proc()](f: f))

proc trampBlockDouble(blk: ptr BlockLit; a: float64) {.cdecl.} =
  cast[BlockCell[proc(a: float64)]](blk.ctx).f(a)

proc mkBlockDouble*(f: proc(a: float64)): pointer =
  ## a block of signature void (^)(double)
  mkBlock(cast[pointer](trampBlockDouble), "v@?d",
          BlockCell[proc(a: float64)](f: f))

## nsError describes an NSError, preferring the JavaScript exception
## message WebKit attaches.
proc nsError*(err: id): ref CatchableError =
  if err.isNil:
    return nil
  let info = send(err, "userInfo")
  let msg = send(info, "objectForKey:",
                 argu(nsString("WKJavaScriptExceptionMessage")))
  if not msg.isNil:
    return newException(ValueError, goString(msg))
  newException(ValueError, goString(send(err, "localizedDescription")))

## A method registered on a new Objective-C class: Cmd is its selector
## and Fn a C function pointer of signature id(self, _cmd, args...).
type MethodDef* = object
  cmd*: SEL
  fn*: pointer
  types*: cstring

## methodDef builds a MethodDef; types is the ObjC type encoding.
proc methodDef*(selector: string, fn: pointer, types: cstring): MethodDef =
  MethodDef(cmd: sel(selector), fn: fn, types: types)

## classDef builds an Objective-C class once.
proc classDef*(name, super: string, protocols: seq[string],
               methods: seq[MethodDef]): id =
  loadFrameworks()
  var c = objcAllocateClassPair(`class`(super), name, 0)
  if c.isNil:
    # already registered
    return `class`(name)
  for p in protocols:
    let proto = objcGetProtocol(p)
    if not proto.isNil:
      discard classAddProtocol(c, proto)
  for m in methods:
    if not classAddMethod(c, m.cmd, m.fn, m.types):
      discard
  objcRegisterClassPair(c)
  clsCache[name] = c
  c

proc msgInitTracking*(obj: id, s: SEL, r: NSRect, options: uint,
                      owner, info: id): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgTimer*(cls: id, s: SEL, interval: float64, target: id,
               selector: SEL, info: id, repeats: bool): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgDraggingFrame*(obj: id, s: SEL, frame: NSRect, contents: id)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgDragKeyEvent*(cls: id, s: SEL, typ: uint, loc: NSPoint,
                      flags: uint, ts: float64, wn: int, ctx: id,
                      chars, charsIgnoring: id, isRepeat: bool,
                      code: uint16): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

## CoreGraphics / Carbon / CoreFoundation entry points the surface uses.
var kCGColorSpaceSRGB* {.importc: "kCGColorSpaceSRGB", dynlib: libCG.}: pointer
proc cgColorSpaceCreateWithName*(name: pointer): pointer
  {.importc: "CGColorSpaceCreateWithName", dynlib: libCG, cdecl.}
proc cgDataProviderCreateWithCFData*(data: pointer): pointer
  {.importc: "CGDataProviderCreateWithCFData", dynlib: libCG, cdecl.}
proc cgDataProviderRelease*(p: pointer)
  {.importc: "CGDataProviderRelease", dynlib: libCG, cdecl.}
proc cgImageCreate*(width, height, bitsPerComponent, bitsPerPixel,
                    bytesPerRow: uint, space: pointer, bitmapInfo: uint32,
                    provider, decode: pointer, shouldInterpolate: bool,
                    intent: int): pointer
  {.importc: "CGImageCreate", dynlib: libCG, cdecl.}
proc cgImageRelease*(img: pointer)
  {.importc: "CGImageRelease", dynlib: libCG, cdecl.}
proc cgEventGetIntegerValueField*(event: pointer, field: uint32): int64
  {.importc: "CGEventGetIntegerValueField", dynlib: libCG, cdecl.}
proc cfDataCreate*(alloc: pointer, bytes: pointer, len: int): pointer
  {.importc: "CFDataCreate", dynlib: libCF, cdecl.}
proc kbGetLayoutType*(keyboardType: int16): uint32
  {.importc: "KBGetLayoutType", dynlib: libCarbon, cdecl.}
proc lmGetKbdType*(): uint8
  {.importc: "LMGetKbdType", dynlib: libCarbon, cdecl.}

proc cfRunLoopObserverCreate*(alloc: pointer, activities: uint,
                              repeats: bool, order: int,
                              callout, ctx: pointer): pointer
  {.importc: "CFRunLoopObserverCreate", dynlib: libCF, cdecl.}
proc cfRunLoopAddObserver*(rl, observer, mode: pointer)
  {.importc: "CFRunLoopAddObserver", dynlib: libCF, cdecl.}

proc msgExitEvent*(cls: id, s: SEL, typ: uint, loc: NSPoint, flags: uint,
                   ts: float64, wn: int, ctx: id, en, tn: int,
                   data: pointer): id
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

proc cgEventSetIntegerValueField*(event: pointer, field: uint32,
                                  value: int64)
  {.importc: "CGEventSetIntegerValueField", dynlib: libCG, cdecl.}
proc tisCopyCurrentKeyboardInputSource*(): pointer
  {.importc: "TISCopyCurrentKeyboardInputSource", dynlib: libCarbon,
   cdecl.}
proc tisGetInputSourceProperty*(src, key: pointer): pointer
  {.importc: "TISGetInputSourceProperty", dynlib: libCarbon, cdecl.}
proc cfEqual*(a, b: pointer): bool
  {.importc: "CFEqual", dynlib: libCF, cdecl.}
var kTISPropertyInputSourceType* {.importc: "kTISPropertyInputSourceType",
    dynlib: libCarbon.}: pointer
var kTISTypeKeyboardLayout* {.importc: "kTISTypeKeyboardLayout",
    dynlib: libCarbon.}: pointer
