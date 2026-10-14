## system.go: NSPasteboard clipboard, NSWorkspace shell, NSScreen,
## NSAppearance theme.

# Clipboard (NSPasteboard).

type clipboardImpl = ref object of Clipboard

const
  utString = "public.utf8-plain-text"
  utHTML = "public.html"
  utPNG = "public.png"
  utTIFF = "public.tiff"

proc pasteboard(): id = send(`class`("NSPasteboard"), "generalPasteboard")

method readText*(c: clipboardImpl): string =
  withPool(proc() =
    result = goString(send(pasteboard(), "stringForType:",
                           argu(nsString(utString)))))

method writeText*(c: clipboardImpl, text: string) =
  c.writeData(textData(text), nil)

method readHTML*(c: clipboardImpl): string =
  withPool(proc() =
    result = goString(send(pasteboard(), "stringForType:",
                           argu(nsString(utHTML)))))

method writeHTML*(c: clipboardImpl, markup: string) =
  c.writeData(newData(newItem(
    bytes(transfer.HTML, markup), bytes(transfer.Text, markup))), nil)

method readImage*(c: clipboardImpl): seq[byte] =
  withPool(proc() =
    let pb = pasteboard()
    let data = send(pb, "dataForType:", argu(nsString(utPNG)))
    if not data.isNil:
      result = goBytes(data)
      return
    let tiff = send(pb, "dataForType:", argu(nsString(utTIFF)))
    if not tiff.isNil:
      let rep = send(`class`("NSBitmapImageRep"), "imageRepWithData:",
                     argu(tiff))
      if not rep.isNil:
        result = goBytes(send(rep, "representationUsingType:properties:",
          argu(4), argu(send(`class`("NSDictionary"), "dictionary")))))

method writeImage*(c: clipboardImpl, png: seq[byte]) =
  var invalid = false
  withPool(proc() =
    let img = autorelease(send(send(`class`("NSImage"), "alloc"),
                               "initWithData:", argu(nsData(png))))
    invalid = img.isNil)
  if invalid:
    raise errInvalidImage()
  c.writeData(newData(newItem(bytes(transfer.PNG, png))), nil)

method clear*(c: clipboardImpl) =
  withPool(proc() =
    discard send(pasteboard(), "clearContents")
    if macClipboard != nil:
      macClipboard.release())

method availableFormats*(c: clipboardImpl): seq[string] =
  withPool(proc() =
    for t in arrayItems(send(pasteboard(), "types")):
      result.add goString(t))

# Shell (NSWorkspace).

type shellImpl = ref object of Shell

proc workspace(): id = send(`class`("NSWorkspace"), "sharedWorkspace")

method openExternal*(s: shellImpl, url: string): ref CatchableError =
  var err: ref CatchableError = nil
  withPool(proc() =
    let u = nsURL(url)
    if u.isNil:
      err = newException(ValueError, "mynim: invalid URL " & url)
      return
    if not sendBool(workspace(), "openURL:", argu(u)):
      err = newException(ValueError,
                         "mynim: no application can open " & url))
  err

method openPath*(s: shellImpl, path: string) =
  var err: ref CatchableError = nil
  withPool(proc() =
    if not sendBool(workspace(), "openURL:", argu(fileURL(path))):
      err = newException(ValueError, "mynim: cannot open " & path))
  if err != nil:
    raise err

method showItemInFolder*(s: shellImpl, path: string) =
  withPool(proc() =
    discard send(workspace(), "activateFileViewerSelectingURLs:",
                 argu(nsArray(fileURL(path)))))

method trashItem*(s: shellImpl, path: string) =
  var err: ref CatchableError = nil
  withPool(proc() =
    var nserr: id
    let fm = send(`class`("NSFileManager"), "defaultManager")
    if not sendBool(fm, "trashItemAtURL:resultingItemURL:error:",
                    argu(fileURL(path)), argu(nil),
                    argu(cast[pointer](addr nserr))):
      err = nsError(nserr)
      if err == nil:
        err = newException(IOError, "mynim: cannot move to trash"))
  if err != nil:
    raise err

method beep*(s: shellImpl) = nsBeep()

# Screen (NSScreen).

type screenImpl = ref object of Screen

method displays*(s: screenImpl): seq[Display] =
  withPool(proc() =
    let screens = arrayItems(send(`class`("NSScreen"), "screens"))
    if screens.len == 0:
      return
    let key = nsString("NSScreenNumber")
    for i, scr in screens:
      let num = send(send(scr, "deviceDescription"), "objectForKey:",
                     argu(key))
      let displayID = uint32(cast[uint](send(num, "unsignedIntValue")))
      var d = Display(
        id: int64(displayID),
        bounds: rectFromMac(msgRect(scr, sel("frame"))),
        workArea: rectFromMac(msgRect(scr, sel("visibleFrame"))),
        scaleFactor: msgFloat(scr, sel("backingScaleFactor")),
        rotation: int(math.round(cgDisplayRotation(displayID))),
        `internal`: cgDisplayIsBuiltin(displayID),
        primary: i == 0)
      if respondsTo(scr, "localizedName"):
        d.label = goString(send(scr, "localizedName"))
      result.add d)

method cursorPoint*(s: screenImpl): platform.Point =
  let p = msgPoint(`class`("NSEvent"), sel("mouseLocation"))
  platform.Point(x: int(math.round(p.x)),
        y: int(math.round(primaryScreenHeight() - p.y)))

# Theme (NSAppearance).

type themeImpl = ref object of Theme
  b: Backend

## UIFont is Core Text's to find: the system font.
method uiFont*(t: themeImpl): string = ""

method fontRendering*(t: themeImpl): FontRendering = FontRendering()

## preferences reads the accent color and the display settings of
## accessibility.
method preferences*(t: themeImpl): platform.Preferences =
  var p: platform.Preferences
  withPool(proc() =
    let ws = workspace()
    p.reduceMotion = sendBool(ws, "accessibilityDisplayShouldReduceMotion")
    p.highContrast = sendBool(ws,
                              "accessibilityDisplayShouldIncreaseContrast")
    # The accent, as the app's appearance draws it.
    var c: id
    let appearance = `class`("NSAppearance")
    let prev = send(appearance, "currentAppearance")
    discard send(appearance, "setCurrentAppearance:",
                 argu(send(t.b.app, "effectiveAppearance")))
    let accent = send(`class`("NSColor"), "controlAccentColor")
    if not accent.isNil:
      c = send(accent, "colorUsingColorSpace:",
               argu(send(`class`("NSColorSpace"), "sRGBColorSpace")))
    discard send(appearance, "setCurrentAppearance:", argu(prev))
    if not c.isNil:
      var r, g, b, a: float64
      discard send(c, "getRed:green:blue:alpha:",
                   argu(cast[pointer](addr r)),
                   argu(cast[pointer](addr g)),
                   argu(cast[pointer](addr b)),
                   argu(cast[pointer](addr a)))
      proc byteOf(v: float64): uint8 =
        uint8(max(0.0, min(v, 1.0)) * 255 + 0.5)
      p.accent = platform.Color(r: byteOf(r), g: byteOf(g), b: byteOf(b),
                                a: 255))
  p

method isDark*(t: themeImpl): bool =
  var dark = false
  withPool(proc() =
    let appearance = send(t.b.app, "effectiveAppearance")
    let names = nsArray(nsString("NSAppearanceNameAqua"),
                        nsString("NSAppearanceNameDarkAqua"))
    dark = goString(send(appearance,
                         "bestMatchFromAppearancesWithNames:",
                         argu(names))) == "NSAppearanceNameDarkAqua")
  dark

method setSource*(t: themeImpl, source: string) =
  withPool(proc() =
    var appearance: id
    case source
    of "light":
      appearance = send(`class`("NSAppearance"), "appearanceNamed:",
                        argu(nsString("NSAppearanceNameAqua")))
    of "dark":
      appearance = send(`class`("NSAppearance"), "appearanceNamed:",
                        argu(nsString("NSAppearanceNameDarkAqua")))
    else:
      discard
    discard send(t.b.app, "setAppearance:", argu(appearance)))
