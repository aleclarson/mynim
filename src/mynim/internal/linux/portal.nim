## portal.nim: the XDG desktop portal, which offers what the desktop
## decides on: settings, inhibiting sleep, global shortcuts. Methods that
## may involve the user return a request object at once and answer later
## with its Response signal, which cbPortalSignal routes by the object's
## path.

const
  portalName* = "org.freedesktop.portal.Desktop"
  portalPath* = "/org/freedesktop/portal/desktop"

var
  cbPortalSignal*: pointer
  portalRegistered*: bool
  portalListening*: bool
  portalRequests*: Table[string, proc(code: uint32, results: pointer)]
  portalTokens*: int
  vardictType*: pointer

proc shortcutActivated*(b: Backend, params: pointer)
proc portalCall*(path, iface, meth: string, params: pointer,
    replyType: string): tuple[res: pointer, err: ref CatchableError]
proc registerWithPortal*()
proc vardict*(entries: openArray[pointer]): pointer
proc desktopEntryID*(): string

## The namespaces of the settings portal that preferences come from.
const
  appearanceSettings* = "org.freedesktop.appearance"
  gnomeInterfaceSettings* = "org.gnome.desktop.interface"

## portalSignal handles the signals of the portal the backend subscribes
## to.
proc portalSignal*(conn, sender, path, iface, signal, params,
    data: pointer) {.cdecl.} =
  case goStr(signal)
  of "Response":
    let done = portalRequests.getOrDefault(goStr(path))
    if done.isNil: return
    portalRequests.del(goStr(path))
    let code = gVariantGetChildValue(params, 0)
    let results = gVariantGetChildValue(params, 1)
    done(gVariantGetUint32(code), results)
    gVariantUnref(code)
    gVariantUnref(results)
  of "Activated":
    theBackend.shortcutActivated(params)
  of "SettingChanged":
    # A preference, or the color scheme, changed.
    let ns = gVariantGetChildValue(params, 0)
    let name = goStr(gVariantGetString(ns, nil))
    gVariantUnref(ns)
    if name == appearanceSettings or name == gnomeInterfaceSettings:
      theBackend.h.themeChanged()
  else: discard

## watchPortalSettings follows the changes of the settings the desktop
## portal gives.
proc watchPortalSettings*() =
  let (conn, err) = bus()
  if err.isNil:
    discard gDBusConnectionSignalSubscribe(conn, cs(portalName),
      cs("org.freedesktop.portal.Settings"), cs("SettingChanged"),
      cs(portalPath), nil, 0, cbPortalSignal, nil, nil)

## portalSettings reads the settings of namespaces from the desktop
## portal, as a{sa{sv}}, which the caller unrefs.
proc portalSettings*(namespaces: varargs[string]):
    tuple[all: pointer, ok: bool] =
  var names = newSeq[pointer](namespaces.len)
  for i, n in namespaces:
    names[i] = gVariantNewString(cs(n))
  let typ = gVariantTypeNew(cs("s"))
  let arr = gVariantNewArray(typ, unsafeAddr names[0], uint(names.len))
  let (res, err) = portalCall(portalPath,
    "org.freedesktop.portal.Settings", "ReadAll",
    `tuple`(@[arr]), "(a{sa{sv}})")
  if not err.isNil: return (nil, false)
  let all = gVariantGetChildValue(res, 0)
  gVariantUnref(res)
  (all, true)

## portalSetting returns the value of key in namespace of the settings
## portalSettings read, if it is of type typ, which the caller unrefs.
proc portalSetting*(all: pointer, namespace, key, typ: string): pointer =
  let ns = gVariantLookupValue(all, cs(namespace), gVariantTypeNew(cs("a{sv}")))
  if ns.isNil: return nil
  defer: gVariantUnref(ns)
  let v = gVariantLookupValue(ns, cs(key), nil)
  if v.isNil: return nil
  if goStr(gVariantGetTypeString(v)) != typ:
    gVariantUnref(v)
    return nil
  v

## portalCall calls a method of the portal, after registering the app with
## it, which must come first.
proc portalCall*(path, iface, meth: string, params: pointer,
    replyType: string): tuple[res: pointer, err: ref CatchableError] =
  registerWithPortal()
  dbusCall(portalName, path, iface, meth, params, replyType)

## registerWithPortal tells the portal the app's ID, the name of its
## desktop entry: portals know it only for sandboxed apps and apps the
## desktop launched, and global shortcuts need it. The portal accepts it
## before any other call, when the desktop entry is installed.
proc registerWithPortal*() =
  if portalRegistered: return
  portalRegistered = true
  let id = desktopEntryID().dup(removeSuffix(".desktop"))
  let params = `tuple`(@[gVariantNewString(cs(id)), vardict(@[])])
  var res: pointer
  var err: ref CatchableError
  (res, err) = dbusCall(portalName, portalPath,
    "org.freedesktop.host.portal.Registry", "Register", params, "")
  if err.isNil: gVariantUnref(res)

## vardict builds an a{sv} from entries made by vardictEntry.
proc vardict*(entries: openArray[pointer]): pointer =
  if entries.len == 0:
    if vardictType.isNil:
      vardictType = gVariantTypeNew(cs("{sv}"))
    return gVariantNewArray(vardictType, nil, 0)
  gVariantNewArray(nil, unsafeAddr entries[0], uint(entries.len))

proc vardictEntry*(key: string, v: pointer): pointer =
  gVariantNewDictEntry(gVariantNewString(cs(key)), gVariantNewVariant(v))

## vardictString returns the string (or object path) under key in an
## a{sv}, "" when there is none.
proc vardictString*(dict: pointer, key: string): string =
  let v = gVariantLookupValue(dict, cs(key), nil)
  if v.isNil: return ""
  defer: gVariantUnref(v)
  let t = goStr(gVariantGetTypeString(v))
  if t != "s" and t != "o": return ""
  goStr(gVariantGetString(v, nil))

## portalRequest calls a portal method whose last argument is a vardict of
## options, and which answers with a Response signal: done then gets the
## response code, 0 when the request succeeded, and the results, which it
## must not keep.
proc portalRequest*(iface, meth: string, args: seq[pointer],
    options: seq[pointer],
    done: proc(code: uint32, results: pointer)): ref CatchableError =
  let (conn, err) = bus()
  if not err.isNil: return err
  if not portalListening:
    portalListening = true
    discard gDBusConnectionSignalSubscribe(conn, cs(portalName),
      cs("org.freedesktop.portal.Request"), cs("Response"), nil, nil, 0,
      cbPortalSignal, nil, nil)
  inc portalTokens
  let token = "mynim" & $portalTokens
  let sender = goStr(gDBusConnectionGetUniqueName(conn)).
    dup(removePrefix(":")).replace(".", "_")
  let path = portalPath & "/request/" & sender & "/" & token
  portalRequests[path] = done
  var opts = options
  opts.add vardictEntry("handle_token", gVariantNewString(cs(token)))
  var full = args
  full.add vardict(opts)
  var res: pointer
  var err2: ref CatchableError
  (res, err2) = portalCall(portalPath, iface, meth, `tuple`(full), "(o)")
  if not err2.isNil:
    portalRequests.del(path)
    return err2
  let handle = gVariantGetChildValue(res, 0)
  let p = goStr(gVariantGetString(handle, nil))
  if p != path:
    portalRequests.del(path) # portals before 0.9 pick the path
    portalRequests[p] = done
  gVariantUnref(handle)
  gVariantUnref(res)
  nil

## portalVersion returns the version of a portal interface, 0 when the
## desktop does not offer it.
proc portalVersion*(iface: string): uint32 =
  let (res, err) = portalCall(portalPath,
    "org.freedesktop.DBus.Properties", "Get",
    `tuple`(@[gVariantNewString(cs(iface)), gVariantNewString(cs("version"))]),
    "(v)")
  if not err.isNil: return 0
  defer: gVariantUnref(res)
  let v = gVariantGetChildValue(res, 0)
  let inner = gVariantGetVariant(v)
  gVariantUnref(v)
  defer: gVariantUnref(inner)
  if goStr(gVariantGetTypeString(inner)) != "u": return 0
  gVariantGetUint32(inner)
