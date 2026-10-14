## icon.go: the icon Finder shows for a file, a folder or an
## application (NSWorkspace iconForFile:), drawn at size by size
## pixels from the representation that fits it best.

## pngOfImage draws an NSImage into an sRGB bitmap of size by size
## pixels, one pixel to the point, and encodes it as PNG. It must run
## in a pool.
proc pngOfImage(img: id, size: int): seq[byte] =
  var rep = autorelease(msgInitBitmap(send(`class`("NSBitmapImageRep"),
    "alloc"),
    sel("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:"),
    nil, size, size, 8, 4, true, false,
    nsString("NSCalibratedRGBColorSpace"), 0, 0))
  if rep.isNil:
    return
  rep = send(rep, "bitmapImageRepByRetaggingWithColorSpace:",
           argu(send(`class`("NSColorSpace"), "sRGBColorSpace")))
  let ctx = send(`class`("NSGraphicsContext"),
                 "graphicsContextWithBitmapImageRep:", argu(rep))
  if ctx.isNil:
    return
  let gc = `class`("NSGraphicsContext")
  discard send(gc, "saveGraphicsState")
  discard send(gc, "setCurrentContext:", argu(ctx))
  ## NSImageInterpolationHigh
  discard send(ctx, "setImageInterpolation:", argu(3))
  ## NSCompositingOperationSourceOver
  const sourceOver = 2
  let dst = NSRect(size: NSSize(width: float64(size),
                                height: float64(size)))
  msgDrawImage(img,
    sel("drawInRect:fromRect:operation:fraction:"), dst, NSRect(),
    sourceOver.uint, 1)
  discard send(gc, "restoreGraphicsState")
  ## NSBitmapImageFileTypePNG
  goBytes(send(rep, "representationUsingType:properties:", argu(4),
    argu(send(`class`("NSDictionary"), "dictionary"))))

method fileIcon*(s: shellImpl, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  var real: string
  try:
    real = expandSymlink(path)
  except OSError as e:
    return (@[], e)
  let p = real
  var png: seq[byte]
  withPool(proc() =
    let img = send(workspace(), "iconForFile:", argu(nsString(p)))
    if not img.isNil:
      png = pngOfImage(img, size))
  if png.len == 0:
    return (@[], newException(ValueError,
                              "mynim: no icon for " & p.escape()))
  (png, nil)
