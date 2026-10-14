## icon.nim (icon.go): the icon Explorer shows for a file, a folder or
## an application (IShellItemImageFactory, without thumbnails).

var iidIShellItemImageFactory* = guid(
  "bcc18b79-ba16-442f-80c4-8a59c30c463b")

## dibSection is DIBSECTION, which GetObject fills for a DIB section.
type dibSection* = object
  bmType*, bmWidth*, bmHeight*, bmWidthBytes*: int32
  bmPlanes*, bmBitsPixel*: uint16
  bmBits*: uint
  biSize*: uint32
  biWidth*, biHeight*: int32
  ## The rest of BITMAPINFOHEADER, dsBitfields, dshSection and
  ## dsOffset.
  rest*: array[7, uint32]
  pad0: array[3, uint32]
  pad1: uint
  pad2: uint32

## fileIcon returns the icon Windows draws for path at size by size
## pixels, as a PNG image.
proc imageOfDIB*(hbm: uint): tuple[img: NrgbaImage,
  err: ref CatchableError]

method fileIcon*(s: w32Shell, path: string, size: int):
    tuple[png: seq[byte], err: ref CatchableError] =
  var factory: uint
  let r = procSHCreateItemFromParsingName(cast[uint](u16(path)), 0,
    cast[uint](addr iidIShellItemImageFactory),
    cast[uint](addr factory))
  if failed(r) or factory == 0:
    return (@[], hresultError("finding " & path, r))
  defer: release(factory)
  const iconOnly = 0x4'u ## SIIGBF_ICONONLY
  var hbm: uint
  let sz = uint(uint32(size)) or uint(uint32(size)) shl 32 ## SIZE, by value
  let r2 = comCall(factory, 3, sz, iconOnly, cast[uint](addr hbm))
  if failed(r2) or hbm == 0: ## GetImage
    return (@[], hresultError("the icon of " & path, r2))
  defer: discard procDeleteObject(hbm)
  let (img, err) = imageOfDIB(hbm)
  if not err.isNil:
    return (@[], err)
  (pngEncode(img), nil)

## imageOfDIB copies a 32-bit DIB section of the shell, whose pixels
## are BGRA with straight alpha, as RgbaImage's are.
proc imageOfDIB*(hbm: uint): tuple[img: NrgbaImage,
    err: ref CatchableError] =
  var ds: dibSection
  if procGetObjectW(hbm, uint(sizeof(ds)), cast[uint](addr ds)) == 0 or
      ds.bmBits == 0 or ds.bmBitsPixel != 32:
    return (nil, newException(CatchableError,
      "mynim: the icon is not a 32-bit DIB section (" &
        $ds.bmBitsPixel & " bits)"))
  let w = int(ds.bmWidth)
  let h = int(ds.bmHeight)
  let stride = int(ds.bmWidthBytes)
  let src = cast[ptr UncheckedArray[byte]](cast[pointer](ds.bmBits))
  var img = NrgbaImage()
  new(img)
  img.rect = image.Rectangle(max: image.Point(x: w, y: h))
  img.pix = newSeq[uint8](w * h * 4)
  img.stride = w * 4
  for y in 0 ..< h:
    var row = y
    if ds.biHeight > 0: ## bottom-up
      row = h - 1 - y
    let so = row * stride
    for x in 0 ..< w:
      let d = y * img.stride + 4 * x
      img.pix[d] = src[so + 4 * x + 2]
      img.pix[d + 1] = src[so + 4 * x + 1]
      img.pix[d + 2] = src[so + 4 * x]
      img.pix[d + 3] = src[so + 4 * x + 3]
  (img, nil)
