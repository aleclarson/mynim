## coretext: Core Text lays out paragraphs on macOS: a typesetter finds
## the fonts, falls back to others for what a font lacks, shapes, and
## suggests line breaks, and Core Graphics rasterizes glyphs, in color
## for color fonts such as Apple Color Emoji, and the others with font
## smoothing, as AppKit draws text. The system font comes from NSFont,
## which knows its weights.
##
## The bindings are self-contained so the text package does not depend
## on the window backend, as in Go.

# Core Foundation, Core Text, Core Graphics and Objective-C.
const
  libCT = "/System/Library/Frameworks/CoreText.framework/CoreText"
  libCFs = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
  libCGs = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
  libAppKitP = "/System/Library/Frameworks/AppKit.framework/AppKit"
  libObjCP = "/usr/lib/libobjc.A.dylib"

type
  ctRef = uint ## a CoreFoundation object reference

  ## Structs passed by value.
  cfRange = object
    location, length: int
  cgPoint = object
    x, y: float64
  cgSize = object
    w, h: float64
  cgRect = object
    x, y, w, h: float64
  cgAffineTransform = object
    a, b, c, d, tx, ty: float64
  ctParagraphStyleSetting = object
    spec: uint32
    size: uint
    value: pointer

const
  cfStringEncodingUTF8 = 0x08000100'u32
  cfNumberSInt32Type = 3
  cfNumberSInt64Type = 4
  cfNumberFloat64Type = 6

  ctFontUIFontSystem = 2'u32
  ctFontItalicTrait = 1'u32 shl 0
  ctFontMonoSpaceTrait = 1'u32 shl 10
  ctFontColorGlyphsTrait = 1'u32 shl 13
  ctFontOrientationDefault = 0'u32
  ctRunStatusRightToLeft = 1'u32 shl 0
  ctBaseWritingDirectionSpec = 13'u32

  cgImageAlphaOnly = 7'u32
  cgImageAlphaPremultipliedLst = 1'u32
  cgBitmapByteOrder32Big = 4'u32 shl 12

{.passL: "-framework CoreText -framework CoreFoundation -framework CoreGraphics -framework AppKit".}

proc dlopen(path: cstring, mode: cint): pointer
  {.importc: "dlopen", dynlib: "libdl.dylib".}
proc dlsym(handle: pointer, name: cstring): pointer
  {.importc: "dlsym", dynlib: "libdl.dylib".}
const rtldNow = 2
const rtldGlobal = 8

## Core Foundation.
proc cfRelease(obj: ctRef)
  {.importc: "CFRelease", dynlib: libCFs, cdecl.}
proc cfRetain(obj: ctRef): ctRef
  {.importc: "CFRetain", dynlib: libCFs, cdecl.}
proc cfHash(obj: ctRef): uint
  {.importc: "CFHash", dynlib: libCFs, cdecl.}
proc cfEqual(a, b: ctRef): bool
  {.importc: "CFEqual", dynlib: libCFs, cdecl.}
proc cfStringCreateWithCharacters(alloc: ctRef, chars: ptr uint16,
                                  n: int): ctRef
  {.importc: "CFStringCreateWithCharacters", dynlib: libCFs, cdecl.}
proc cfStringCreateWithBytes(alloc: ctRef, bytes: ptr byte, n: int,
                             encoding: uint32, external: bool): ctRef
  {.importc: "CFStringCreateWithBytes", dynlib: libCFs, cdecl.}
proc cfStringGetLength(s: ctRef): int
  {.importc: "CFStringGetLength", dynlib: libCFs, cdecl.}
proc cfStringGetCharacters(s: ctRef, r: cfRange, outv: ptr uint16)
  {.importc: "CFStringGetCharacters", dynlib: libCFs, cdecl.}
proc cfDictionaryCreate(alloc: ctRef, keys, values: ptr ctRef, n: int,
                        keyCallbacks, valueCallbacks: ctRef): ctRef
  {.importc: "CFDictionaryCreate", dynlib: libCFs, cdecl.}
proc cfDictionaryGetValue(d, key: ctRef): ctRef
  {.importc: "CFDictionaryGetValue", dynlib: libCFs, cdecl.}
proc cfArrayGetCount(a: ctRef): int
  {.importc: "CFArrayGetCount", dynlib: libCFs, cdecl.}
proc cfArrayGetValueAtIndex(a: ctRef, i: int): ctRef
  {.importc: "CFArrayGetValueAtIndex", dynlib: libCFs, cdecl.}
proc cfSetCreate(alloc: ctRef, values: ptr ctRef, n: int,
                 callbacks: ctRef): ctRef
  {.importc: "CFSetCreate", dynlib: libCFs, cdecl.}
proc cfArrayCreate(alloc: ctRef, values: ptr ctRef, n: int,
                   callbacks: ctRef): ctRef
  {.importc: "CFArrayCreate", dynlib: libCFs, cdecl.}
proc cfNumberCreate(alloc: ctRef, typ: int, value: pointer): ctRef
  {.importc: "CFNumberCreate", dynlib: libCFs, cdecl.}
proc cfNumberGetValue(n: ctRef, typ: int, value: pointer): bool
  {.importc: "CFNumberGetValue", dynlib: libCFs, cdecl.}
proc cfAttributedStringCreate(alloc, str, attrs: ctRef): ctRef
  {.importc: "CFAttributedStringCreate", dynlib: libCFs, cdecl.}
proc cfAttributedStringCreateMutableCopy(alloc: ctRef, max: int,
                                         attributed: ctRef): ctRef
  {.importc: "CFAttributedStringCreateMutableCopy", dynlib: libCFs,
   cdecl.}
proc cfAttributedStringSetAttribute(attributed: ctRef, r: cfRange,
                                    name, value: ctRef)
  {.importc: "CFAttributedStringSetAttribute", dynlib: libCFs, cdecl.}
proc cfDataCreate(alloc: ctRef, bytes: ptr byte, n: int): ctRef
  {.importc: "CFDataCreate", dynlib: libCFs, cdecl.}
proc cfDataGetLength(data: ctRef): int
  {.importc: "CFDataGetLength", dynlib: libCFs, cdecl.}
proc cfDataGetBytePtr(data: ctRef): ptr byte
  {.importc: "CFDataGetBytePtr", dynlib: libCFs, cdecl.}

## Core Text.
proc ctFontCreateWithFontDescriptor(desc: ctRef, size: float64,
                                    matrix: pointer): ctRef
  {.importc: "CTFontCreateWithFontDescriptor", dynlib: libCT, cdecl.}
proc ctFontCreateUIFontForLanguage(typ: uint32, size: float64,
                                   language: ctRef): ctRef
  {.importc: "CTFontCreateUIFontForLanguage", dynlib: libCT, cdecl.}
proc ctFontCreateCopyWithSymbolicTraits(font: ctRef, size: float64,
                                        matrix: pointer,
                                        value, mask: uint32): ctRef
  {.importc: "CTFontCreateCopyWithSymbolicTraits", dynlib: libCT, cdecl.}
proc ctFontCreateCopyWithAttributes(font: ctRef, size: float64,
                                    matrix: pointer, desc: ctRef): ctRef
  {.importc: "CTFontCreateCopyWithAttributes", dynlib: libCT, cdecl.}
proc ctFontDescriptorCreateWithAttributes(attrs: ctRef): ctRef
  {.importc: "CTFontDescriptorCreateWithAttributes", dynlib: libCT, cdecl.}
proc ctFontDescriptorCreateMatchingFontDescriptor(desc,
    mandatory: ctRef): ctRef
  {.importc: "CTFontDescriptorCreateMatchingFontDescriptor",
   dynlib: libCT, cdecl.}
proc ctFontDescriptorCopyAttribute(desc, name: ctRef): ctRef
  {.importc: "CTFontDescriptorCopyAttribute", dynlib: libCT, cdecl.}
proc ctFontManagerCopyAvailableFontFamilyNames(): ctRef
  {.importc: "CTFontManagerCopyAvailableFontFamilyNames",
   dynlib: libCT, cdecl.}
proc ctFontGetAscent(font: ctRef): float64
  {.importc: "CTFontGetAscent", dynlib: libCT, cdecl.}
proc ctFontGetDescent(font: ctRef): float64
  {.importc: "CTFontGetDescent", dynlib: libCT, cdecl.}
proc ctFontGetLeading(font: ctRef): float64
  {.importc: "CTFontGetLeading", dynlib: libCT, cdecl.}
proc ctFontGetSize(font: ctRef): float64
  {.importc: "CTFontGetSize", dynlib: libCT, cdecl.}
proc ctFontGetMatrix(font: ctRef): cgAffineTransform
  {.importc: "CTFontGetMatrix", dynlib: libCT, cdecl.}
proc ctFontGetSymbolicTraits(font: ctRef): uint32
  {.importc: "CTFontGetSymbolicTraits", dynlib: libCT, cdecl.}
proc ctFontGetUnderlinePosition(font: ctRef): float64
  {.importc: "CTFontGetUnderlinePosition", dynlib: libCT, cdecl.}
proc ctFontGetUnderlineThickness(font: ctRef): float64
  {.importc: "CTFontGetUnderlineThickness", dynlib: libCT, cdecl.}
proc ctFontGetXHeight(font: ctRef): float64
  {.importc: "CTFontGetXHeight", dynlib: libCT, cdecl.}
proc ctFontGetUnitsPerEm(font: ctRef): uint32
  {.importc: "CTFontGetUnitsPerEm", dynlib: libCT, cdecl.}
proc ctFontCopyTable(font: ctRef, tag: uint32, options: uint32): ctRef
  {.importc: "CTFontCopyTable", dynlib: libCT, cdecl.}
proc ctFontCreatePathForGlyph(font: ctRef, glyph: uint16,
                              matrix: pointer): ctRef
  {.importc: "CTFontCreatePathForGlyph", dynlib: libCT, cdecl.}
proc ctFontGetBoundingRectsForGlyphs(font: ctRef, orientation: uint32,
    glyphs: ptr uint16, rects: ptr cgRect, n: int): cgRect
  {.importc: "CTFontGetBoundingRectsForGlyphs", dynlib: libCT, cdecl.}
proc ctFontDrawGlyphs(font: ctRef, glyphs: ptr uint16,
                      positions: ptr cgPoint, n: int, context: ctRef)
  {.importc: "CTFontDrawGlyphs", dynlib: libCT, cdecl.}
proc ctParagraphStyleCreate(settings: ptr ctParagraphStyleSetting,
                            n: int): ctRef
  {.importc: "CTParagraphStyleCreate", dynlib: libCT, cdecl.}
proc ctTypesetterCreateWithAttributedString(str: ctRef): ctRef
  {.importc: "CTTypesetterCreateWithAttributedString", dynlib: libCT,
   cdecl.}
proc ctTypesetterSuggestLineBreak(typesetter: ctRef, start: int,
                                  width: float64): int
  {.importc: "CTTypesetterSuggestLineBreak", dynlib: libCT, cdecl.}
proc ctTypesetterCreateLine(typesetter: ctRef, r: cfRange): ctRef
  {.importc: "CTTypesetterCreateLine", dynlib: libCT, cdecl.}
proc ctLineGetGlyphRuns(line: ctRef): ctRef
  {.importc: "CTLineGetGlyphRuns", dynlib: libCT, cdecl.}
proc ctLineGetStringRange(line: ctRef): cfRange
  {.importc: "CTLineGetStringRange", dynlib: libCT, cdecl.}
proc ctRunGetGlyphCount(run: ctRef): int
  {.importc: "CTRunGetGlyphCount", dynlib: libCT, cdecl.}
proc ctRunGetStringRange(run: ctRef): cfRange
  {.importc: "CTRunGetStringRange", dynlib: libCT, cdecl.}
proc ctRunGetStatus(run: ctRef): uint32
  {.importc: "CTRunGetStatus", dynlib: libCT, cdecl.}
proc ctRunGetAttributes(run: ctRef): ctRef
  {.importc: "CTRunGetAttributes", dynlib: libCT, cdecl.}
proc ctRunGetGlyphs(run: ctRef, r: cfRange, outv: ptr uint16)
  {.importc: "CTRunGetGlyphs", dynlib: libCT, cdecl.}
proc ctRunGetPositions(run: ctRef, r: cfRange, outv: ptr cgPoint)
  {.importc: "CTRunGetPositions", dynlib: libCT, cdecl.}
proc ctRunGetAdvances(run: ctRef, r: cfRange, outv: ptr cgSize)
  {.importc: "CTRunGetAdvances", dynlib: libCT, cdecl.}
proc ctRunGetStringIndices(run: ctRef, r: cfRange, outv: ptr int)
  {.importc: "CTRunGetStringIndices", dynlib: libCT, cdecl.}
proc ctRunDelegateCreate(callbacks: pointer, refcon: pointer): ctRef
  {.importc: "CTRunDelegateCreate", dynlib: libCT, cdecl.}

## Core Graphics.
proc cgColorSpaceCreateDeviceRGB(): ctRef
  {.importc: "CGColorSpaceCreateDeviceRGB", dynlib: libCGs, cdecl.}
proc cgBitmapContextCreate(data: pointer, w, h, bitsPerComponent,
                           bytesPerRow: int, space: ctRef,
                           info: uint32): ctRef
  {.importc: "CGBitmapContextCreate", dynlib: libCGs, cdecl.}
proc cgContextRelease(ctx: ctRef)
  {.importc: "CGContextRelease", dynlib: libCGs, cdecl.}
proc cgContextSetShouldAntialias(ctx: ctRef, on: bool)
  {.importc: "CGContextSetShouldAntialias", dynlib: libCGs, cdecl.}
proc cgContextSetShouldSmoothFonts(ctx: ctRef, on: bool)
  {.importc: "CGContextSetShouldSmoothFonts", dynlib: libCGs, cdecl.}
proc cgContextSetAllowsFontSubpixelPositioning(ctx: ctRef, on: bool)
  {.importc: "CGContextSetAllowsFontSubpixelPositioning", dynlib: libCGs,
   cdecl.}
proc cgContextSetShouldSubpixelPositionFonts(ctx: ctRef, on: bool)
  {.importc: "CGContextSetShouldSubpixelPositionFonts", dynlib: libCGs,
   cdecl.}
proc cgContextSetAllowsFontSubpixelQuantization(ctx: ctRef, on: bool)
  {.importc: "CGContextSetAllowsFontSubpixelQuantization",
   dynlib: libCGs, cdecl.}
proc cgContextSetShouldSubpixelQuantizeFonts(ctx: ctRef, on: bool)
  {.importc: "CGContextSetShouldSubpixelQuantizeFonts", dynlib: libCGs,
   cdecl.}
proc cgContextScaleCTM(ctx: ctRef, sx, sy: float64)
  {.importc: "CGContextScaleCTM", dynlib: libCGs, cdecl.}
proc cgContextSetRGBFillColor(ctx: ctRef, r, g, b, a: float64)
  {.importc: "CGContextSetRGBFillColor", dynlib: libCGs, cdecl.}
proc cgPathRelease(path: ctRef)
  {.importc: "CGPathRelease", dynlib: libCGs, cdecl.}

type cgPathElement = object
  kind: int32
  points: ptr cgPoint

proc cgPathApply(path: ctRef, info: pointer,
                 fn: proc(info: pointer, el: ptr cgPathElement) {.cdecl.})
  {.importc: "CGPathApply", dynlib: libCGs, cdecl.}

## Objective-C (the little of it needed: NSFont and NSUserDefaults).
proc objcGetClassCT(name: cstring): ctRef
  {.importc: "objc_getClass", dynlib: libObjCP, cdecl.}
proc selRegisterNameCT(name: cstring): ctRef
  {.importc: "sel_registerName", dynlib: libObjCP, cdecl.}
proc msgSendCT(obj, sel: ctRef): ctRef
  {.importc: "objc_msgSend", dynlib: libObjCP, cdecl.}
proc msgSendCT1(obj, sel: ctRef, a: ctRef): ctRef
  {.importc: "objc_msgSend", dynlib: libObjCP, cdecl.}
proc msgSendDouble2(obj, sel: ctRef, a, b: float64): ctRef
  {.importc: "objc_msgSend", dynlib: libObjCP, cdecl.}
proc msgSendLong(obj, sel: ctRef, a: ctRef): clong
  {.importc: "objc_msgSend", dynlib: libObjCP, cdecl.}
proc msgSendBool(obj, sel: ctRef, a: ctRef): bool
  {.importc: "objc_msgSend", dynlib: libObjCP, cdecl.}
proc ctPoolPush(): pointer
  {.importc: "objc_autoreleasePoolPush", dynlib: libObjCP, cdecl.}
proc ctPoolPop(pool: pointer)
  {.importc: "objc_autoreleasePoolPop", dynlib: libObjCP, cdecl.}

proc ctSend(obj: ctRef, name: string, arg: ctRef = 0): ctRef =
  if arg == 0:
    msgSendCT(obj, selRegisterNameCT(name))
  else:
    msgSendCT1(obj, selRegisterNameCT(name), arg)

proc ctResponds(obj: ctRef, name: string): bool =
  msgSendBool(obj, selRegisterNameCT("respondsToSelector:"),
              selRegisterNameCT(name))

## Constants are pointers to CFStringRefs, or callback structs.
proc cfConst(lib: string, name: string): ctRef =
  let h = dlopen(lib, rtldNow)
  if h.isNil:
    return 0
  let p = dlsym(h, name)
  if p.isNil:
    return 0
  cast[ptr ctRef](p)[]

proc cfOptFn[T](lib, name: string, fn: var T) =
  let h = dlopen(lib, rtldNow)
  if h.isNil:
    return
  let p = dlsym(h, name)
  if not p.isNil:
    fn = cast[T](p)

var
  # Optional symbols (macOS 10.12+): tracking and kerning names,
  # the cascade list, language and OpenType feature attributes.
  ctTrackingName, ctKernName, ctCascadeList, ctLanguageName,
    ctFeatureSettings, ctFeatureTag, ctFeatureValue,
    ctRunDelegateAttribute: ctRef
  ctDescriptorsFromData: proc(data: ctRef): ctRef {.cdecl.}
  ctColorSpaceWithName: proc(name: ctRef): ctRef {.cdecl.}
  ctSRGBName: ctRef

  cfKeyCallbacks, cfValueCallbacks, cfSetCallbacks,
    cfArrayCallbacks: ctRef
  ctFontAttributeName, ctParagraphStyleName, ctFamilyNameAttribute,
    ctTraitsAttribute, ctWeightTrait, ctSymbolicTrait: ctRef

## The leaves of the run delegate, in Nim rather than assembly.
proc runDelegateDealloc(refcon: pointer) {.cdecl, gcsafe.} = discard
proc runDelegateAscent(refcon: pointer): cdouble {.cdecl, gcsafe.} =
  cast[ptr array[3, cdouble]](refcon)[0]
proc runDelegateDescent(refcon: pointer): cdouble {.cdecl, gcsafe.} =
  cast[ptr array[3, cdouble]](refcon)[1]
proc runDelegateWidth(refcon: pointer): cdouble {.cdecl, gcsafe.} =
  cast[ptr array[3, cdouble]](refcon)[2]

## runDelegateCallbacks is a CTRunDelegateCallbacks, version 1.
type runDelegateCallbacks = object
  version: clong
  dealloc: proc(refcon: pointer) {.cdecl.}
  ascent, descent, width: proc(refcon: pointer): cdouble {.cdecl.}

## delegates makes Core Text's run delegates, which give inline objects
## their size, from metrics the engine keeps until it lays out the next
## text.
type delegates = object
  callbacks: runDelegateCallbacks
  metrics: seq[array[3, cdouble]]

var runDelegates: delegates

## reset makes room for the metrics of n objects.
proc reset(d: var delegates, n: int) =
  d.metrics = newSeq[array[3, cdouble]](n)

## delegate returns a run delegate, owned, giving object k its height
## and width, standing on the baseline.
proc delegate(d: var delegates, k: int, width, height: float32): ctRef =
  if ctRunDelegateAttribute == 0 or k >= d.metrics.len:
    return 0
  d.metrics[k] = [cdouble(height), 0, cdouble(width)]
  ctRunDelegateCreate(addr d.callbacks, addr d.metrics[k])

var ctLoaded: bool

proc loadCoreText() =
  ## Finds the optional symbols once; the rest link statically.
  if ctLoaded:
    return
  ctLoaded = true
  cfKeyCallbacks = cfConst(libCFs, "kCFTypeDictionaryKeyCallBacks")
  cfValueCallbacks = cfConst(libCFs, "kCFTypeDictionaryValueCallBacks")
  cfSetCallbacks = cfConst(libCFs, "kCFTypeSetCallBacks")
  cfArrayCallbacks = cfConst(libCFs, "kCFTypeArrayCallBacks")
  ctFontAttributeName = cfConst(libCT, "kCTFontAttributeName")
  ctParagraphStyleName = cfConst(libCT, "kCTParagraphStyleAttributeName")
  ctFamilyNameAttribute = cfConst(libCT, "kCTFontFamilyNameAttribute")
  ctTraitsAttribute = cfConst(libCT, "kCTFontTraitsAttribute")
  ctWeightTrait = cfConst(libCT, "kCTFontWeightTrait")
  ctSymbolicTrait = cfConst(libCT, "kCTFontSymbolicTrait")
  ctTrackingName = cfConst(libCT, "kCTTrackingAttributeName")
  ctKernName = cfConst(libCT, "kCTKernAttributeName")
  ctCascadeList = cfConst(libCT, "kCTFontCascadeListAttribute")
  ctLanguageName = cfConst(libCT, "kCTLanguageAttributeName")
  ctFeatureSettings = cfConst(libCT, "kCTFontFeatureSettingsAttribute")
  ctFeatureTag = cfConst(libCT, "kCTFontOpenTypeFeatureTag")
  ctFeatureValue = cfConst(libCT, "kCTFontOpenTypeFeatureValue")
  ctRunDelegateAttribute = cfConst(libCT, "kCTRunDelegateAttributeName")
  ctSRGBName = cfConst(libCGs, "kCGColorSpaceSRGB")
  cfOptFn(libCT, "CTFontManagerCreateFontDescriptorsFromData",
          ctDescriptorsFromData)
  cfOptFn(libCGs, "CGColorSpaceCreateWithName", ctColorSpaceWithName)
  runDelegates.callbacks = runDelegateCallbacks(version: 1,
    dealloc: runDelegateDealloc, ascent: runDelegateAscent,
    descent: runDelegateDescent, width: runDelegateWidth)
  # dlopen'd for the NSFont class's registration.
  discard dlopen(libAppKitP, rtldNow or rtldGlobal)

proc cfString(s: string): ctRef =
  ## An owned CFString.
  if s.len == 0:
    return cfStringCreateWithBytes(0, nil, 0, cfStringEncodingUTF8,
                                   false)
  cfStringCreateWithBytes(0, cast[ptr byte](s.cstring), s.len,
                          cfStringEncodingUTF8, false)

proc utf16Decode(u: openArray[uint16]): seq[Rune] =
  result = newSeqOfCap[Rune](u.len)
  var i = 0
  while i < u.len:
    var r = int(u[i])
    if r >= 0xD800 and r < 0xDC00 and i + 1 < u.len and
        u[i + 1] >= 0xDC00 and u[i + 1] < 0xE000:
      r = ((r - 0xD800) shl 10) + int(u[i + 1]) - 0xDC00 + 0x10000
      inc i
    result.add Rune(r)
    inc i

proc goString(s: ctRef): string =
  let n = cfStringGetLength(s)
  if n <= 0:
    return ""
  var buf = newSeq[uint16](n)
  cfStringGetCharacters(s, cfRange(location: 0, length: n), addr buf[0])
  let runes = utf16Decode(buf)
  result = newStringOfCap(runes.len * 3)
  for r in runes:
    result.add r.toUTF8

proc cfDictionary(keys, values: openArray[ctRef]): ctRef =
  cfDictionaryCreate(0, addr keys[0], addr values[0], keys.len,
                     cfKeyCallbacks, cfValueCallbacks)

proc cfFloat(v: float64): ctRef =
  var vv = v
  cfNumberCreate(0, cfNumberFloat64Type, addr vv)

## nsWeight converts a CSS weight to NSFont's (and Core Text's) scale,
## from -1 to 1.
proc nsWeight(w: int): float64 =
  let steps = [-0.8, -0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.62]
  let f = (float64(max(100, min(w, 900))) - 100) / 100
  let i = min(int(f), steps.len - 2)
  steps[i] + (steps[i + 1] - steps[i]) * (f - float64(i))

type
  attrsKey = object
    font: ctRef
    rtl: bool
    lang: string

  registeredFace = object
    desc: ctRef
    weight: float64 ## -1 to 1
    italic: bool
    mono: bool

  bandKey = object
    font: ctRef
    glyph: uint32
    lo, hi: float32

  CoreText = ref object of Engine
    styles: array[2, ctRef] ## paragraph styles: left-to-right, right-to-left
    srgb: ctRef
    smooth: bool ## the user leaves font smoothing on
    ## bands caches where glyphs' outlines cross underlines (inkInBand).
    bands: Table[bandKey, array[2, float32]]

    primary: Table[Style, ctRef] ## the CTFont of each style
    fonts: Table[uint, seq[Font]] ## by CFHash of their CTFont
    ## native finds Fonts by their CTFont, which they retain.
    native: Table[ctRef, Font]
    ## oblique maps an upright Font to its synthetic italic variant.
    oblique: Table[Font, Font]
    ## italic names an attribute that marks the runes of italic spans in
    ## a text that is not italic, owned, so that Core Text ends a run
    ## where italics start or stop even when both sides are in one font,
    ## as a CJK font without an italic face. Any value marks them; it is
    ## its own.
    italic: ctRef
    ## attrs are the attributes of strings in a font of primary, in each
    ## direction, without tracking or kerning, owned.
    attrs: Table[attrsKey, ctRef]
    ## seg and breaks find where lines may break (lineBreaks).
    seg: Segmenter
    breaks: seq[bool]
    color: Table[ctRef, bool]

    ## Buffers shape reuses: the text in UTF-16 with the rune of each
    ## code unit, the attributes of the string, the code unit of each
    ## rune, and what Core Text tells of a run.
    u16: seq[uint16]
    index, at: seq[int]
    keys, values: seq[ctRef]
    runIDs: seq[uint16]
    runPoints: seq[cgPoint]
    runAdvances: seq[cgSize]
    runIndices: seq[int]

    registered: Table[string, seq[registeredFace]] ## by lowercased family
    ## names are the families of registered, as the app gave them.
    names: seq[string]

## Forward declarations of decoration.nim's helpers, included later.
proc rune*(r: decoRange, k: int): Rune
proc span*(r: decoRange, i, j: int): tuple[x0, x1: float32]
proc runs*(r: decoRange, fn: proc(f: Font, i, j: int))
proc baseline*(r: decoRange): float32
proc cut*(x0, x1: float32, cuts: seq[array[2, float32]],
          minLen: float32): seq[array[2, float32]]
proc skipsInk*(r: Rune): bool
proc monospaced(e: CoreText, family: string): bool

proc hash(k: attrsKey): Hash =
  hash(k.font) !& hash(k.rtl) !& hash(k.lang)

proc hash(k: bandKey): Hash =
  hash(k.font) !& hash(k.glyph) !& hash(k.lo) !& hash(k.hi)

## fontSmoothing reports whether the user leaves font smoothing on:
## AppKit turns it off when AppleFontSmoothing is 0, or not a number,
## which Core Graphics' bitmap contexts do not heed.
proc fontSmoothing(): bool =
  let pool = ctPoolPush()
  defer: ctPoolPop(pool)
  let cls = objcGetClassCT("NSUserDefaults")
  if cls == 0:
    return true
  let defaults = ctSend(cls, "standardUserDefaults")
  let key = cfString("AppleFontSmoothing")
  defer: cfRelease(key)
  if ctSend(defaults, "objectForKey:", key) == 0:
    return true
  msgSendLong(defaults, selRegisterNameCT("integerForKey:"), key) != 0

## namedDesc returns the descriptor of the face of a family the system
## has that best matches a weight and italics, owned, or 0.
proc namedDesc(e: CoreText, family: string, weight: int,
               italic: bool): ctRef

## systemFont returns the system font, or its monospaced kind, owned.
proc systemFont(e: CoreText, size: float32, weight: int, italic,
                mono: bool): ctRef

## named returns a font of a family the system has, owned, or 0.
proc named(e: CoreText, family: string, size: float32, weight: int,
           italic: bool): ctRef =
  let desc = e.namedDesc(family, weight, italic)
  if desc == 0:
    return 0
  defer: cfRelease(desc)
  ctFontCreateWithFontDescriptor(desc, float64(size), nil)

## namedDesc returns the descriptor of the face of a family the system
## has that best matches a weight and italics, owned, or 0.
proc namedDesc(e: CoreText, family: string, weight: int,
               italic: bool): ctRef =
  let name = cfString(family)
  defer: cfRelease(name)
  var symbolic = int32(0)
  if italic:
    symbolic = int32(ctFontItalicTrait)
  let w = cfFloat(nsWeight(weight))
  defer: cfRelease(w)
  let s = cfNumberCreate(0, cfNumberSInt32Type, addr symbolic)
  defer: cfRelease(s)
  let traits = cfDictionary([ctWeightTrait, ctSymbolicTrait], [w, s])
  defer: cfRelease(traits)
  let attrs = cfDictionary(
    [ctFamilyNameAttribute, ctTraitsAttribute], [name, traits])
  defer: cfRelease(attrs)
  let desc = ctFontDescriptorCreateWithAttributes(attrs)
  if desc == 0:
    return 0
  defer: cfRelease(desc)
  var mandatory = [ctFamilyNameAttribute]
  let set = cfSetCreate(0, addr mandatory[0], 1, cfSetCallbacks)
  defer: cfRelease(set)
  ctFontDescriptorCreateMatchingFontDescriptor(desc, set)

proc systemFont(e: CoreText, size: float32, weight: int, italic,
                mono: bool): ctRef =
  ## The system font, or its monospaced kind, owned.
  let pool = ctPoolPush()
  defer: ctPoolPop(pool)
  let selName = if mono: "monospacedSystemFontOfSize:weight:"
                else: "systemFontOfSize:weight:"
  var font: ctRef
  let cls = objcGetClassCT("NSFont")
  if cls != 0 and ctResponds(cls, selName):
    font = msgSendDouble2(cls, selRegisterNameCT(selName),
                          float64(size), nsWeight(weight))
    if font != 0:
      font = cfRetain(font)
  if font == 0:
    if mono:
      font = e.named("Menlo", size, weight, false)
    else:
      font = ctFontCreateUIFontForLanguage(ctFontUIFontSystem,
                                           float64(size), 0)
  if font != 0 and italic:
    let f = ctFontCreateCopyWithSymbolicTraits(font, 0, nil,
      ctFontItalicTrait, ctFontItalicTrait)
    if f != 0:
      cfRelease(font)
      font = f
  font

## noKerning reports whether features turn kerning off, which Core Text
## does by a kern of 0 rather than by the feature.
proc noKerning(list: string): bool =
  for f in features(list):
    if f.tag == [byte('k'), byte('e'), byte('r'), byte('n')] and
        f.value == 0:
      return true
  false

## withFeatures returns a copy of font with OpenType features, owned,
## or 0 when Core Text takes no features by tag.
proc withFeatures(font: ctRef, fs: seq[feature]): ctRef =
  if fs.len == 0 or ctFeatureSettings == 0 or ctFeatureTag == 0 or
      ctFeatureValue == 0:
    return 0
  var settings = newSeq[ctRef](fs.len)
  for i, f in fs:
    var tagStr = newString(4)
    copyMem(addr tagStr[0], unsafeAddr f.tag[0], 4)
    let tag = cfString(tagStr)
    var v = int64(f.value)
    let value = cfNumberCreate(0, cfNumberSInt64Type, addr v)
    settings[i] = cfDictionary([ctFeatureTag, ctFeatureValue],
                               [tag, value])
    cfRelease(tag)
    cfRelease(value)
  let array = cfArrayCreate(0, addr settings[0], settings.len,
                            cfArrayCallbacks)
  for s in settings:
    cfRelease(s)
  let attrs = cfDictionary([ctFeatureSettings], [array])
  cfRelease(array)
  let desc = ctFontDescriptorCreateWithAttributes(attrs)
  cfRelease(attrs)
  defer: cfRelease(desc)
  ctFontCreateCopyWithAttributes(font, 0, nil, desc)
    # size 0 keeps the font's

## registeredDesc returns the descriptor of the face of a registered
## family that best matches a style, not owned.
proc registeredDesc(faces: seq[registeredFace], style: Style): ctRef =
  let want = nsWeight(style.weight())
  var best = -1
  for i, f in faces:
    if best < 0:
      best = i
      continue
    var s = abs(f.weight - want)
    if f.italic != style.italic:
      s += 4
    var sb = abs(faces[best].weight - want)
    if faces[best].italic != style.italic:
      sb += 4
    if s < sb:
      best = i
  faces[best].desc

## registeredFont returns the font of the face of a registered family
## that best matches a style, owned.
proc registeredFont(faces: seq[registeredFace], style: Style): ctRef =
  ctFontCreateWithFontDescriptor(registeredDesc(faces, style),
                                 float64(style.fontSize()), nil)

## forgetPrimary lets go of the fonts of styles, and of their
## attributes.
proc forgetPrimary(e: CoreText) =
  for _, f in e.primary.pairs:
    cfRelease(f)
  e.primary.clear()
  for _, a in e.attrs.pairs:
    cfRelease(a)
  e.attrs.clear()

proc ctFontOfStyle(e: CoreText, style: Style): ctRef =
  let key = Style(family: style.family, size: style.fontSize(),
                  weight: style.weight(), italic: style.italic,
                  features: style.features)
  if e.primary.hasKey(key):
    return e.primary[key]
  if e.primary.len >= 256:
    e.forgetPrimary()
  if key.features != "":
    # The font without the features, with them.
    var base = key
    base.features = ""
    var font = e.ctFontOfStyle(base)
    let with = withFeatures(font, features(key.features))
    if with != 0:
      font = with
    else:
      discard cfRetain(font)
    e.primary[key] = font
    return font
  var font: ctRef
  let families = familyList(key.family)
  var chosen = -1
  for i, family in families:
    chosen = i
    case generic(family)
    of "system-ui", "sans-serif":
      font = e.systemFont(key.size, key.weight, key.italic, false)
    of "monospace":
      font = e.systemFont(key.size, key.weight, key.italic, true)
    of "serif":
      for name in ["Times New Roman", "Times", "Georgia"]:
        font = e.named(name, key.size, key.weight, key.italic)
        if font != 0:
          break
    else:
      let low = family.toLowerAscii()
      if e.registered.hasKey(low):
        font = registeredFont(e.registered[low], key)
      else:
        font = e.named(family, key.size, key.weight, key.italic)
    if font != 0:
      break
  if font == 0:
    font = e.systemFont(key.size, key.weight, key.italic, false)
  elif ctCascadeList != 0:
    # The families after it come before the system's for what it lacks.
    var descs: seq[ctRef]
    for family in families[chosen + 1 .. ^1]:
      if generic(family) != "":
        continue
      let low = family.toLowerAscii()
      if e.registered.hasKey(low):
        let d = registeredDesc(e.registered[low], key)
        discard cfRetain(d)
        descs.add d
      else:
        let d = e.namedDesc(family, key.weight, key.italic)
        if d != 0:
          descs.add d
    if descs.len > 0:
      let array = cfArrayCreate(0, addr descs[0], descs.len,
                                cfArrayCallbacks)
      let attrs = cfDictionary([ctCascadeList], [array])
      let desc = ctFontDescriptorCreateWithAttributes(attrs)
      let with = ctFontCreateCopyWithAttributes(font, 0, nil, desc)
      if with != 0:
        cfRelease(font)
        font = with
      for obj in descs & @[array, attrs, desc]:
        cfRelease(obj)
  e.primary[key] = font
  font

## obliqueSkew slants synthetic italics by 14°, as WebKit does.
let obliqueSkew = tan(14 * math.Pi / 180)

## syntheticItalic returns a slanted copy of a font without an italic
## face, owned, or 0 when it has one. Core Text's y axis points up, so a
## positive c moves the glyph's top right. A font already transformed is
## left as it is, and color glyphs stay upright, as Core Text draws
## their bitmaps.
proc syntheticItalic(font: ctRef): ctRef =
  if font == 0 or (ctFontGetSymbolicTraits(font) and
      (ctFontItalicTrait or ctFontColorGlyphsTrait)) != 0:
    return 0
  var matrix = ctFontGetMatrix(font)
  if matrix.c != 0:
    return 0
  matrix.c = obliqueSkew
  ctFontCreateCopyWithAttributes(font, 0, addr matrix, 0)

## isColor reports whether font draws color glyphs.
proc isColor(e: CoreText, font: ctRef): bool =
  if e.color.hasKey(font):
    return e.color[font]
  let c = (ctFontGetSymbolicTraits(font) and ctFontColorGlyphsTrait) != 0
  e.color[font] = c
  c

## fontOf returns the Font of a CTFont.
proc fontOf(e: CoreText, font: ctRef): Font =
  if e.native.hasKey(font):
    return e.native[font]
  let h = cfHash(font)
  if e.fonts.hasKey(h):
    for f in e.fonts[h]:
      if f.native == font or cfEqual(f.native, font):
        return f
  discard cfRetain(font)
  let f = Font(size: float32(ctFontGetSize(font)),
               ascent: float32(ctFontGetAscent(font)),
               descent: float32(ctFontGetDescent(font)),
               lineGap: float32(ctFontGetLeading(font)),
               native: font,
               shaded: e.smooth and not e.isColor(font),
               thickens: not e.isColor(font))
  e.fonts.mgetOrPut(h, @[]).add f
  e.native[font] = f
  f

## runFont returns the Font of a run's CTFont, slanted when the run is
## italic and the font has no italic face.
proc runFont(e: CoreText, font: ctRef, italic: bool): Font =
  let base = e.fontOf(font)
  if not italic:
    return base
  if e.oblique.hasKey(base):
    return e.oblique[base]
  var f = base
  let with = syntheticItalic(font)
  if with != 0:
    f = e.fontOf(with)
    cfRelease(with)
  e.oblique[base] = f
  f

## styleSpans returns a copy of the attributed string of text, of style,
## with the font and tracking of each span over its runes, owned.
proc styleSpans(e: CoreText, attributed: ctRef, style: Style,
                spans: openArray[Span], text: openArray[Rune]): ctRef =
  let styled = cfAttributedStringCreateMutableCopy(0, 0, attributed)
  # The UTF-16 code unit of each rune.
  e.at.setLen(text.len + 1)
  e.at[0] = 0
  for i in 0 ..< text.len:
    e.at[i + 1] = e.at[i] + 1
    if int(text[i]) >= 0x10000:
      inc e.at[i + 1]
  let at = e.at
  var objects = 0
  for i, sp in spans:
    if sp.objectWidth > 0:
      var start = 0
      if i > 0:
        start = spans[i - 1].`end`
      objects += max(min(sp.`end`, text.len) - start, 0)
  runDelegates.reset(objects)
  objects = 0
  var start0 = 0
  for sp in spans:
    let to = max(start0, min(sp.`end`, text.len))
    let r = cfRange(location: at[start0], length: at[to] - at[start0])
    let start = start0
    start0 = to
    if r.length == 0:
      continue
    if sp.objectWidth > 0:
      # Each rune is an object of its own: a run Core Text sizes by its
      # delegate.
      for k in start ..< to:
        let d = runDelegates.delegate(objects, sp.objectWidth,
                                      sp.objectHeight)
        if d != 0:
          cfAttributedStringSetAttribute(styled,
            cfRange(location: at[k], length: at[k + 1] - at[k]),
            ctRunDelegateAttribute, d)
          cfRelease(d)
        inc objects
    let s = sp.style(style)
    let font = e.ctFontOfStyle(s)
    if font != 0:
      cfAttributedStringSetAttribute(styled, r, ctFontAttributeName,
                                   font)
    if s.italic and not style.italic:
      cfAttributedStringSetAttribute(styled, r, e.italic, e.italic)
    if s.letterSpacing != style.letterSpacing and ctTrackingName != 0:
      let tracking = cfFloat(float64(s.letterSpacing))
      cfAttributedStringSetAttribute(styled, r, ctTrackingName, tracking)
      cfRelease(tracking)
    if noKerning(sp.features) and ctKernName != 0:
      let zero = cfFloat(0)
      cfAttributedStringSetAttribute(styled, r, ctKernName, zero)
      cfRelease(zero)
    if s.lang != style.lang and s.lang != "" and ctLanguageName != 0:
      let tag = cfString(s.lang)
      cfAttributedStringSetAttribute(styled, r, ctLanguageName, tag)
      cfRelease(tag)
  styled

## penAdvances gives the room Core Text leaves between letters by their
## positions alone, as between Han and Latin letters in Chinese or
## Japanese text, to the advance of the letter before it, so that the
## widths of lines and the carets follow the pen. Only room ahead of the
## pen counts: a mark placed back over its letter leaves the advances as
## they are. Right-to-left runs keep theirs.
proc penAdvances(runs: var seq[shapedRun]) =
  var prev: ptr Glyph
  var pen = 0f
  for i in 0 ..< runs.len:
    for j in 0 ..< runs[i].glyphs.len:
      let g = addr runs[i].glyphs[j]
      if prev != nil and not prev.rtl and not g.rtl:
        let gap = g.x - pen
        if gap > 1e-3:
          prev.advance += gap
          pen += gap
      else:
        pen = g.x
      pen += g.advance
      prev = g

## line reads the runs of a line of a text that italic says is italic,
## or whose runs styleSpans marked as such.
proc ctLine(e: CoreText, line: ctRef, index: seq[int],
            n: int, italic: bool): shapedLine =
  proc at(i: int): int = index[max(0, min(i, n))]
  let r = ctLineGetStringRange(line)
  result = shapedLine(start: at(r.location),
                      `end`: at(r.location + r.length))
  let runs = ctLineGetGlyphRuns(line)
  let mark = e.scratch.runs.len
  for i in 0 ..< cfArrayGetCount(runs):
    let run = cfArrayGetValueAtIndex(runs, i)
    let rr = ctRunGetStringRange(run)
    let attrs = ctRunGetAttributes(run)
    let f = e.runFont(
      cfDictionaryGetValue(attrs, ctFontAttributeName),
      italic or
        cfDictionaryGetValue(attrs, e.italic) != 0)
    var sr = shapedRun(font: f, start: at(rr.location),
                       `end`: at(rr.location + rr.length))
    let count = ctRunGetGlyphCount(run)
    if count > 0:
      e.runIDs.setLen(count)
      e.runPoints.setLen(count)
      e.runAdvances.setLen(count)
      e.runIndices.setLen(count)
      let all = cfRange()
      ctRunGetGlyphs(run, all, addr e.runIDs[0])
      ctRunGetPositions(run, all, addr e.runPoints[0])
      ctRunGetAdvances(run, all, addr e.runAdvances[0])
      ctRunGetStringIndices(run, all, addr e.runIndices[0])
      let rtl = (ctRunGetStatus(run) and ctRunStatusRightToLeft) != 0
      sr.glyphs = e.scratch.glyphRoom(count)
      for j in 0 ..< count:
        sr.glyphs[j] = Glyph(font: f, id: uint32(e.runIDs[j]),
          x: float32(e.runPoints[j].x), y: -float32(e.runPoints[j].y),
          advance: float32(e.runAdvances[j].w),
          cluster: at(e.runIndices[j]), rtl: rtl)
    result.runs = e.scratch.addRun(mark, sr)
  # penAdvances mutates the seq in scratch
  penAdvances(result.runs)

method shape*(e: CoreText, text: openArray[Rune], style: Style,
              spans: openArray[Span], width: float32, rtl,
              wholeWords: bool): seq[shapedLine] =
  let font = e.ctFontOfStyle(style)
  if font == 0 or text.len == 0:
    return @[]
  e.u16.setLen(0)
  e.index.setLen(0)
  appendUTF16(e.u16, e.index, text)
  let u16 = e.u16
  let index = e.index
  let n = u16.len
  let str = cfStringCreateWithCharacters(0, addr u16[0], n)
  defer: cfRelease(str)
  let paragraph = if rtl: e.styles[1] else: e.styles[0]
  var lang = style.lang
  if ctLanguageName == 0:
    lang = ""
  let key = attrsKey(font: font, rtl: rtl, lang: lang)
  var keys = @[ctFontAttributeName, ctParagraphStyleName]
  var values = @[font, paragraph]
  var base = 2
  if lang != "":
    # The language picks the glyphs of a font that has several, as Han
    # characters in Chinese and Japanese, and the fonts Core Text falls
    # back to.
    let tag = cfString(lang)
    defer: cfRelease(tag)
    keys.add ctLanguageName
    values.add tag
    inc base
  if style.letterSpacing != 0 and ctTrackingName != 0:
    # Tracking, in points as DIPs, keeps the font's kerning.
    let tracking = cfFloat(float64(style.letterSpacing))
    defer: cfRelease(tracking)
    keys.add ctTrackingName
    values.add tracking
  if noKerning(style.features) and ctKernName != 0:
    let zero = cfFloat(0)
    defer: cfRelease(zero)
    keys.add ctKernName
    values.add zero
  e.keys = keys
  e.values = values
  var attrs = e.attrs.getOrDefault(key)
  if keys.len > base:
    attrs = cfDictionary(keys, values)
    defer: cfRelease(attrs)
  elif attrs == 0:
    # The font of a style lives in primary, with its attributes.
    attrs = cfDictionary(keys, values)
    e.attrs[key] = attrs
  var attributed = cfAttributedStringCreate(0, str, attrs)
  if spans.len > 0:
    let styled = e.styleSpans(attributed, style, spans, text)
    cfRelease(attributed)
    attributed = styled
  defer: cfRelease(attributed)
  let typesetter = ctTypesetterCreateWithAttributedString(attributed)
  if typesetter == 0:
    return @[]
  defer: cfRelease(typesetter)
  var breaks: seq[bool]
  if wholeWords and width > 0:
    e.breaks = lineBreaks(e.seg, e.breaks, text)
    breaks = e.breaks
  var lines: seq[shapedLine]
  let mark = e.scratch.lines.len
  var start = 0
  while start < n:
    var count = n - start
    if width > 0:
      count = max(ctTypesetterSuggestLineBreak(typesetter, start,
                                             float64(width)), 1)
      # Core Text breaks a word that does not fit a line; carry on to
      # the next break instead.
      if breaks.len > 0:
        var `end` = min(start + count, n)
        while `end` < n and (index[`end`] == index[`end` - 1] or
            not breaks[index[`end`]]):
          inc `end`
        count = `end` - start
    let line = ctTypesetterCreateLine(typesetter,
      cfRange(location: start, length: count))
    if line == 0:
      break
    lines = e.scratch.addLine(mark,
      e.ctLine(line, index, n, style.italic))
    cfRelease(line)
    start += count
  lines

## snapLine puts a line of thickness t (whole points) centered at p on
## whole points.
proc snapLine(p, t: float64): float64 =
  if int(t) mod 2 == 0:
    return floor(p + 0.5)
  floor(p) + 0.5

## ctUnderline returns where Core Text centers the underline of a font
## below the baseline, and how thick it draws it, in points.
proc ctUnderline(f: Font): tuple[center, thick: float32] =
  let font = f.native
  var pos = ctFontGetUnderlinePosition(font)
  let th = ctFontGetUnderlineThickness(font)
  let asc = ctFontGetAscent(font)
  let desc = ctFontGetDescent(font)
  var d = desc
  if desc < 2:
    d = (asc + desc) / 4
  let reach = min(d * 5.3636991028295373, asc + desc)
  if pos >= 0: # no underline position
    pos = -0.08805546253922189 * reach
  var p = -pos
  var t = th
  if d >= 2 and th > 0.35:
    t = ceil(th)
    if t >= d or (d <= 4 and t >= 3) or (d <= 2.5 and t >= 2):
      t -= 1
    p = snapLine(p, t)
    if p < 1.5 or (p == 1.5 and d > 4):
      p += 1
  if d > 0:
    p = min(p, floor(d) - t / 2)
  p = max(p, ceil(th) + t / 2)
  if t <= 0: # no underline thickness
    t = reach * 0.044027731269610945
  (float32(p), float32(t))

## ctStrikethrough returns where Core Text centers the strikethrough of
## a font above the baseline, and how thick it draws it, in points:
## through the middle of the x-height, as thick as the underline.
proc ctStrikethrough(f: Font): tuple[center, thick: float32] =
  let font = f.native
  var p = ctFontGetXHeight(font) / 2
  let th = ctFontGetUnderlineThickness(font)
  if p <= 0:
    # No x-height: the strikeout of the OS/2 table.
    let t = ctFontCopyTable(font, 0x4F532F32'u32, 0)
    if t != 0:
      if cfDataGetLength(t) >= 30:
        let b = cfDataGetBytePtr(t)
        let bp = cast[ptr UncheckedArray[byte]](b)
        let size = int16(uint16(bp[26]) shl 8 or uint16(bp[27]))
        let pos = int16(uint16(bp[28]) shl 8 or uint16(bp[29]))
        let em = ctFontGetSize(font) /
          float64(max(int(ctFontGetUnitsPerEm(font)), 1))
        p = (float64(pos) - float64(size) / 2) * em
        let th2 = float64(size) * em
        cfRelease(t)
        var tt = th2
        if p > 1 and tt > 0.35:
          tt = ceil(tt)
          p = snapLine(p, tt)
        return (float32(p), float32(tt))
      cfRelease(t)
  var t = th
  if p > 1 and th > 0.35:
    t = ceil(th)
    p = snapLine(p, t)
  (float32(p), float32(t))

## The outline of a glyph, flattened into segments, as CGPathApply
## hands its elements to the one callback made for it.
var
  outlineSegs: seq[array[4, float64]]
  outlineAt: array[2, float64] ## the current point
  outlineFrom: array[2, float64] ## the start of the subpath

## bezier returns the point at t of a Bézier curve of control points c.
proc bezier(c: openArray[array[2, float64]], t: float64):
    array[2, float64] =
  var p = @c
  var n = p.len - 1
  while n > 0:
    for k in 0 ..< n:
      p[k] = [p[k][0] + (p[k + 1][0] - p[k][0]) * t,
              p[k][1] + (p[k + 1][1] - p[k][1]) * t]
    dec n
  p[0]

proc outlineCallback(info: pointer, el: ptr cgPathElement) {.cdecl.} =
  proc pt(i: int): array[2, float64] =
    let pp = cast[ptr UncheckedArray[cgPoint]](el.points)[i]
    [pp.x, pp.y]
  proc line(q: array[2, float64]) =
    outlineSegs.add [outlineAt[0], outlineAt[1], q[0], q[1]]
    outlineAt = q
  case el.kind
  of 0: # move
    outlineAt = pt(0)
    outlineFrom = outlineAt
  of 1: # line
    line(pt(0))
  of 2, 3: # quadratic and cubic curves, in 16 lines
    let p0 = outlineAt
    var c = @[p0, pt(0), pt(1)]
    if el.kind == 3:
      c.add pt(2)
    for k in 1 .. 16:
      line(bezier(c, k / 16))
  of 4: # close
    line(outlineFrom)
  else:
    discard

## glyphOutline returns the outline of a glyph in points, y up, as line
## segments. The text system's lock serializes its callers.
proc glyphOutline(font: ctRef, glyph: uint16): seq[array[4, float64]] =
  outlineSegs.setLen(0)
  let path = ctFontCreatePathForGlyph(font, glyph, nil)
  if path == 0:
    return @[]
  cgPathApply(path, nil, outlineCallback)
  cgPathRelease(path)
  outlineSegs

## bandX returns how far left and right of the origin a glyph's outline
## reaches between lo and hi points above the baseline.
proc bandX(segs: seq[array[4, float64]], lo, hi: float64):
    tuple[a, b: float64, found: bool] =
  var a = Inf
  var b = -Inf
  for s in segs:
    for e2 in [[s[0], s[1]], [s[2], s[3]]]:
      let x = e2[0]
      let y = e2[1]
      if y >= lo and y <= hi:
        a = min(a, x)
        b = max(b, x)
    # crossings of the edges' range
    for yy in [lo, hi]:
      let (y0, y1) = (s[1], s[3])
      if (y0 <= yy) != (y1 <= yy) and y0 != y1:
        let t = (yy - y0) / (y1 - y0)
        let x = s[0] + (s[2] - s[0]) * t
        a = min(a, x)
        b = max(b, x)
  (a, b, a <= b)

## inkInBand returns how far left and right of its origin the outline
## of a glyph reaches between lo and hi points above the baseline.
proc inkInBand(e: CoreText, f: Font, id: uint32, lo, hi: float32):
    tuple[a, b: float32, ok: bool] =
  let key = bandKey(font: f.native, glyph: id, lo: lo, hi: hi)
  if e.bands.hasKey(key):
    let v = e.bands[key]
    return (v[0], v[1], v[0] <= v[1])
  if e.bands.len >= 4096:
    e.bands.clear()
  let segs = glyphOutline(f.native, uint16(id))
  let (ax, bx, found) = bandX(segs, float64(lo), float64(hi))
  var v = [1f, 0f]
  if found:
    v = [float32(ax), float32(bx)]
  e.bands[key] = v
  (v[0], v[1], found)

## shadeGray returns the sRGB gray of the relative luminance a shade
## stands for.
proc shadeGray(shade: Shade): float64 =
  let y = float64(shade) / float64(Shades)
  if y <= 0.0031308:
    return y * 12.92
  1.055 * pow(y, 1 / 2.4) - 0.055

method decorate*(e: CoreText, r: decoRange): seq[Stroke] =
  ## Places underlines and strikethroughs as Core Text draws them for
  ## AppKit, which snaps them in points, the DIPs of a screen, from the
  ## baseline: an underline as low and thick as those of the fonts of
  ## the glyphs under it want it, skipping their ink, a strikethrough
  ## through the middle of the x-height of the text's own font, and
  ## both from where the text starts to its width rounded up to a whole
  ## point, leaving out whitespace starting or ending a line. The
  ## baseline is the glyphs', a whole pixel, as AppKit's labels have on
  ## whole points.
  let gs = r.line.glyphs
  var i = r.i
  var j = r.j
  if i == 0:
    while i < j and isWhiteSpace(r.rune(i)):
      inc i
  if j == gs.len:
    while j > i and isWhiteSpace(r.rune(j - 1)):
      dec j
  if i >= j:
    return @[]
  let (x0, _) = r.span(i, j)
  var width = 0f
  for k in i ..< j:
    width += gs[k].advance
  let x1 = x0 + float32(ceil(float64(width) - 1e-4))
  var center, thick = 0f # below the baseline
  if r.d == Strikethrough:
    let (p, t) = ctStrikethrough(r.font)
    center = -p
    thick = t
  else:
    r.runs(proc(f: Font, i, j: int) =
      let (p, t) = ctUnderline(f)
      center = max(center, p)
      thick = max(thick, t))
  var pieces = @[[x0, x1]]
  if r.d == Underline:
    var cuts: seq[array[2, float32]]
    for k in i ..< j:
      let g = gs[k]
      if g.font.isNil or not skipsInk(r.rune(k)):
        continue
      let (a, b, ok) = e.inkInBand(g.font, g.id, -(center + thick / 2),
                                   -(center - thick / 2))
      if ok:
        cuts.add [g.x + a - thick, g.x + b + thick]
    pieces = cut(x0, x1, cuts, 0.75 * thick)
  let s = r.scale
  let base = e.baseline(r.baseline() * s)
  result = newSeq[Stroke](pieces.len)
  for k, p in pieces:
    result[k] = Stroke(x0: (r.x + p[0]) * s, x1: (r.x + p[1]) * s,
                       top: base + (center - thick / 2) * s,
                       bottom: base + (center + thick / 2) * s)

## positions follows Core Graphics' subpixel quantization, which AppKit
## leaves on: glyphs go to the position left of their pen, among fewer
## the larger they are, at most five a pixel and one from 34 pixels an
## em.
method positions*(e: CoreText, f: Font, scale: float32,
                  subpixel: bool): tuple[n: int, round: bool] =
  let px = float64(f.size * scale)
  if px <= 0:
    return (1, false)
  (min(5, max(1, int(ceil(100 / (3 * px) - 1e-9)))), false)

## baseline is the whole pixel at or below y: Core Graphics draws a
## glyph from the pixel below its pen in its y-up space, as AppKit does
## on flipped views.
method baseline*(e: CoreText, y: float32): float32 =
  float32(ceil(float64(y) - 1e-3))

## textParams leaves coverage as it is: Core Graphics blends text in
## sRGB space, as renderers do, without subpixels since macOS 10.14.
method textParams*(e: CoreText): tuple[p: scene.TextParams, subpixel: bool] =
  (scene.TextParams(), false)

## join: Core Graphics blends each glyph of a run in turn.
method join*(e: CoreText): bool = false

method glyph*(e: CoreText, f: Font, id: uint32, scale, dx: float32,
              shade: Shade, subpixel: bool): bitmap =
  let font = f.native
  var g = uint16(id)
  var r: cgRect
  discard ctFontGetBoundingRectsForGlyphs(font,
    ctFontOrientationDefault, addr g, addr r, 1)
  if r.w <= 0 or r.h <= 0:
    return bitmap()
  let s = float64(scale)
  let x = float64(dx)
  # Smoothing spreads a glyph up to a pixel further.
  let smooth = (f.shaded and shade != Flat) or shade == Thick
  var pad = 1
  if smooth:
    pad = 2
  # Core Graphics' y goes up: the box from r.y to r.y+r.h above the
  # baseline is from -(r.y+r.h) to -r.y below it.
  let left = int(floor(r.x * s + x)) - pad
  let right = int(ceil((r.x + r.w) * s + x)) + pad
  let top = int(floor(-(r.y + r.h) * s)) - pad
  let bottom = int(ceil(-r.y * s)) + pad
  let w = right - left
  let h = bottom - top
  if w > 2048 or h > 2048:
    return bitmap()
  let color = e.isColor(font)
  var pix: seq[byte]
  var ctx: ctRef
  if color:
    pix = newSeq[byte](4 * w * h)
    ctx = cgBitmapContextCreate(addr pix[0], w, h, 8, 4 * w, e.srgb,
      cgImageAlphaPremultipliedLst or cgBitmapByteOrder32Big)
  else:
    pix = newSeq[byte](w * h)
    ctx = cgBitmapContextCreate(addr pix[0], w, h, 8, w, 0,
                                cgImageAlphaOnly)
  if ctx == 0:
    return bitmap()
  cgContextSetShouldAntialias(ctx, true)
  # Font smoothing emboldens glyphs more the lighter the fill color is,
  # even in a context of alpha alone: the gray of the shade sets how
  # much. Fonts are shaded while the user leaves it on; thick text is
  # smoothed with white, the most.
  cgContextSetShouldSmoothFonts(ctx, smooth)
  cgContextSetAllowsFontSubpixelPositioning(ctx, true)
  cgContextSetShouldSubpixelPositionFonts(ctx, true)
  cgContextSetAllowsFontSubpixelQuantization(ctx, false)
  cgContextSetShouldSubpixelQuantizeFonts(ctx, false)
  var fill = 0.0
  if shade == Thick:
    fill = 1
  elif smooth:
    fill = shadeGray(shade)
  cgContextSetRGBFillColor(ctx, fill, fill, fill, 1)
  cgContextScaleCTM(ctx, s, s)
  # The bitmap's rows go from its top; the context's origin is at its
  # bottom left, the baseline bottom pixels above it.
  var pos = cgPoint(x: (x - float64(left)) / s,
                    y: float64(bottom) / s)
  ctFontDrawGlyphs(font, addr g, addr pos, 1, ctx)
  cgContextRelease(ctx)
  bitmap(left: left, top: top, w: w, h: h, pix: pix, color: color)

method font*(e: CoreText, style: Style): Font =
  let f = e.ctFontOfStyle(style)
  if f == 0:
    return nil
  e.fontOf(f)

method families*(e: CoreText, mono: bool): tuple[app, system: seq[string]] =
  var app, system: seq[string]
  for name in e.names:
    let low = name.toLowerAscii()
    var isMono = false
    if e.registered.hasKey(low):
      for f in e.registered[low]:
        if f.mono:
          isMono = true
          break
    if not mono or isMono:
      app.add name
  let arr = ctFontManagerCopyAvailableFontFamilyNames()
  if arr == 0:
    return (app, system)
  defer: cfRelease(arr)
  for i in 0 ..< cfArrayGetCount(arr):
    let name = goString(cfArrayGetValueAtIndex(arr, i))
    if name == "" or name.startsWith("."):
      continue # the system's hidden families
    if mono and not e.monospaced(name):
      continue
    system.add name
  (app, system)

## monospaced reports whether a family's regular font is monospaced.
proc monospaced(e: CoreText, family: string): bool =
  let desc = e.namedDesc(family, 400, false)
  if desc == 0:
    return false
  defer: cfRelease(desc)
  let traits = ctFontDescriptorCopyAttribute(desc, ctTraitsAttribute)
  if traits == 0:
    return false
  defer: cfRelease(traits)
  let s = cfDictionaryGetValue(traits, ctSymbolicTrait)
  if s == 0:
    return false
  var v: int64
  discard cfNumberGetValue(s, cfNumberSInt64Type, addr v)
  (v and int64(ctFontMonoSpaceTrait)) != 0

method register*(e: CoreText, data: openArray[byte], family: string) =
  if ctDescriptorsFromData.isNil:
    raise newException(ValueError,
      "mynim: adding fonts needs macOS 10.13 or later")
  if data.len == 0:
    raise newException(ValueError, "mynim: no font data")
  let d = cfDataCreate(0, cast[ptr byte](data[0].addr), data.len)
  defer: cfRelease(d)
  let descs = ctDescriptorsFromData(d)
  if descs == 0:
    raise newException(ValueError,
      "mynim: cannot add font: not a font Core Text reads")
  defer: cfRelease(descs)
  let n = cfArrayGetCount(descs)
  if n == 0:
    raise newException(ValueError,
      "mynim: cannot add font: not a font Core Text reads")
  for i in 0 ..< n:
    let desc = cfArrayGetValueAtIndex(descs, i)
    var face = registeredFace(desc: cfRetain(desc))
    var name = ""
    let s = ctFontDescriptorCopyAttribute(desc, ctFamilyNameAttribute)
    if s != 0:
      name = goString(s)
      cfRelease(s)
    let traits = ctFontDescriptorCopyAttribute(desc, ctTraitsAttribute)
    if traits != 0:
      let w = cfDictionaryGetValue(traits, ctWeightTrait)
      if w != 0:
        discard cfNumberGetValue(w, cfNumberFloat64Type,
                                 addr face.weight)
      let sv = cfDictionaryGetValue(traits, ctSymbolicTrait)
      if sv != 0:
        var v: int64
        discard cfNumberGetValue(sv, cfNumberSInt64Type, addr v)
        face.italic = (v and int64(ctFontItalicTrait)) != 0
      cfRelease(traits)
    let font = ctFontCreateWithFontDescriptor(desc, 12, nil)
    if font != 0:
      face.mono = (ctFontGetSymbolicTraits(font) and
                   ctFontMonoSpaceTrait) != 0
      cfRelease(font)
    for f in [name, family]:
      if f != "":
        let key = f.toLowerAscii()
        e.registered.mgetOrPut(key, @[]).add face
        e.names.add f
  e.forgetPrimary()

method fontCount*(e: CoreText): int =
  for _, fs in e.fonts.pairs:
    result += fs.len

## forgetFonts lets go of the CTFonts of the Fonts made so far, and of
## what is known of them; the fonts of styles stay.
method forgetFonts*(e: CoreText) =
  for _, fs in e.fonts.pairs:
    for f in fs:
      cfRelease(f.native)
  e.fonts.clear()
  e.native.clear()
  e.oblique.clear()
  e.color.clear()

proc newCoreText(): CoreText =
  loadCoreText()
  result = CoreText()
  result.italic = cfString("MyGoItalic")
  for i, dir in [int8(0), int8(1)]: # kCTWritingDirectionLeftToRight,
                                    # RightToLeft
    var d = dir
    var s = ctParagraphStyleSetting(spec: ctBaseWritingDirectionSpec,
                                    size: 1, value: addr d)
    result.styles[i] = ctParagraphStyleCreate(addr s, 1)
  if not ctColorSpaceWithName.isNil and ctSRGBName != 0:
    result.srgb = ctColorSpaceWithName(ctSRGBName)
  if result.srgb == 0:
    result.srgb = cgColorSpaceCreateDeviceRGB()
  result.smooth = fontSmoothing()
