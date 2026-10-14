## helpers.nim: helpers the backend's files share — pointer field access,
## the D-Bus session, files' paths per the XDG conventions and the
## desktop entry the desktop knows the app by.

# field reads a field of a struct behind a pointer, as unsafe.Add does.
proc field*[T](p: pointer, offset: uint): T =
  cast[ptr T](cast[uint](cast[ptr uint](addr p)[]) + offset)[]

proc appName*(): string =
  if not theBackend.isNil and theBackend.name != "":
    theBackend.name
  else:
    "MyNim"

# --- The paths of the XDG conventions (deeplink.nim, login.nim). ---

proc xdgDir*(env, fallback: string): string =
  let d = getEnv(env)
  if d.isAbsolute: return d
  getHomeDir() / fallback

# desktopName makes an application id usable in a desktop file name.
proc desktopName*(id: string): string =
  result = newStringOfCap(id.len)
  for r in id.runes:
    let c = r.int32
    result.add:
      if c < 0x80 and (c == ord('.') or c == ord('-') or c == ord('_') or
          (c >= ord('0') and c <= ord('9')) or
          (c >= ord('a') and c <= ord('z')) or
          (c >= ord('A') and c <= ord('Z'))):
        char(c)
      else:
        '-'

# executable is the file to run for a URL: the AppImage rather than the
# directory it is mounted at while running.
proc executable*(): tuple[exe: string, err: ref CatchableError] =
  let p = getEnv("APPIMAGE")
  if p != "": return (p, nil)
  var exe = getAppFilename()
  try:
    let real = expandSymlink(exe)
    if real != "": exe = real
  except OSError:
    discard
  (exe, nil)

# entryString drops what a desktop entry string value cannot hold.
proc entryString*(s: string): string =
  result = newStringOfCap(s.len)
  for r in s.runes:
    if r.int32 >= ord(' '): result.add $r

# execArg quotes an argument of the Exec key of a desktop entry: quoting
# escapes ", `, $ and \ with a backslash, and backslashes are escaped again
# because the value is a string; % is doubled for field codes.
proc execArg*(arg: string): string =
  result = newStringOfCap(arg.len + 2)
  result.add '"'
  for c in arg:
    case c
    of '"', '`', '$':
      result.add "\\\\"; result.add c
    of '\\': result.add "\\\\\\\\"
    of '%': result.add "%%"
    else: result.add c
  result.add '"'

proc writeFileAtomic*(path: string, data: string): ref CatchableError =
  let tmp = path & ".tmp"
  try:
    writeFile(tmp, data)
    moveFile(tmp, path)
    nil
  except IOError as e:
    e
  except OSError as e:
    e

# --- URIs and launches. ---

proc launch*(uri: string): ref CatchableError =
  var gerr: pointer
  if not gAppInfoLaunchDefaultForURI(cs(uri), nil, addr gerr):
    return gErr(gerr)
  nil

proc fileURI*(path: string): string =
  let f = gFileNewForPath(cs(path))
  defer: gObjectUnref(f)
  takeStr(gFileGetURI(f))

# --- Pixbufs. ---

proc pixbufFromPNG*(png: seq[byte]): tuple[pix: pointer, err: ref CatchableError] =
  if png.len == 0:
    return (nil, newException(CatchableError, "mynim: empty image"))
  let loader = gdkPixbufLoaderNew()
  defer: gObjectUnref(loader)
  var gerr: pointer
  if not gdkPixbufLoaderWrite(loader, unsafeAddr png[0], uint(png.len), addr gerr):
    discard gdkPixbufLoaderClose(loader, nil)
    return (nil, gErr(gerr))
  if not gdkPixbufLoaderClose(loader, addr gerr):
    return (nil, gErr(gerr))
  let pix = gdkPixbufLoaderGetPixbuf(loader)
  if pix.isNil:
    return (nil, newException(CatchableError, "mynim: invalid image"))
  (gObjectRef(pix), nil)

proc pngFromPixbuf*(pix: pointer): seq[byte] =
  var buf: pointer
  var size: uint
  if not gdkPixbufSaveToBufferv(pix, addr buf, addr size, cs("png"), nil, nil, nil):
    return @[]
  let bytes = cast[ptr UncheckedArray[byte]](cast[ptr pointer](addr buf)[])
  result = @(toOpenArray(bytes, 0, int(size) - 1))
  gFree(buf)

# --- D-Bus (system.nim, portal.nim). ---

var sessionBus*: pointer

proc bus*(): tuple[conn: pointer, err: ref CatchableError] =
  if not sessionBus.isNil: return (sessionBus, nil)
  var gerr: pointer
  let conn = gBusGetSync(2, nil, addr gerr) # G_BUS_TYPE_SESSION
  if conn.isNil: return (nil, gErr(gerr))
  sessionBus = conn
  (conn, nil)

proc `tuple`*(children: openArray[pointer]): pointer =
  if children.len == 0:
    gVariantNewTuple(nil, 0)
  else:
    gVariantNewTuple(unsafeAddr children[0], uint(children.len))

proc dbusCall*(name, path, iface, meth: string, params: pointer,
    replyType: string): tuple[res: pointer, err: ref CatchableError] =
  let (conn, err) = bus()
  if not err.isNil: return (nil, err)
  var rt: pointer
  if replyType != "": rt = gVariantTypeNew(cs(replyType))
  var gerr: pointer
  let res = gDBusConnectionCallSync(conn, cs(name), cs(path), cs(iface),
    cs(meth), params, rt, 0, 3000, nil, addr gerr)
  if res.isNil: return (nil, gErr(gerr))
  (res, nil)
