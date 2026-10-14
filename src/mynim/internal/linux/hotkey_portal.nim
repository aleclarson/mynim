## hotkey_portal.nim: Wayland lets apps grab no keys: the desktop binds
## global shortcuts for the apps that ask its GlobalShortcuts portal, in
## a session. A session binds its shortcuts once, so a change replaces it
## with a new session binding them all. Desktops remember the keys the
## user picks for each shortcut id, the canonical accelerator, and may
## ask the user to confirm new shortcuts.

const shortcutsPortal = "org.freedesktop.portal.GlobalShortcuts"

var wayland: tuple[
  loaded: bool,
  displayType: proc(): uint {.cdecl.},
  setStartupID: proc(display: pointer, id: cstring) {.cdecl.}]

proc syncShortcuts*(b: Backend): ref CatchableError
proc bindShortcuts*(b: Backend): ref CatchableError

proc bindShortcut*(b: Backend, id: int,
    a: accelerator.Accelerator): ref CatchableError =
  var p = addr b.portal
  if not p.available:
    if portalVersion(shortcutsPortal) == 0:
      return newException(CatchableError,
        "mynim: global shortcuts need an X11 session or a desktop with " &
        "the GlobalShortcuts portal: " & errUnsupported().msg)
    p.available = true
    let (conn, _) = bus()
    discard gDBusConnectionSignalSubscribe(conn, cs(portalName),
      cs(shortcutsPortal), cs("Activated"), cs(portalPath), nil, 0,
      cbPortalSignal, nil, nil)

  p.shortcuts[id] = a
  let err = b.syncShortcuts()
  if not err.isNil:
    p.shortcuts.del(id)
    return err
  nil

proc unbindShortcut*(b: Backend, id: int) =
  if b.portal.shortcuts.hasKey(id):
    b.portal.shortcuts.del(id)
    let err = b.syncShortcuts()
    if not err.isNil:
      stderr.writeLine("mynim: global shortcuts: " & err.msg)

## list returns the shortcuts in the order they were registered, and the
## a(sa{sv}) that describes them to the portal.
proc list(p: ptr portalShortcuts):
    tuple[accs: seq[accelerator.Accelerator], list: pointer] =
  var ids = toSeq(p.shortcuts.keys)
  ids.sort()
  var accs = newSeq[accelerator.Accelerator](ids.len)
  var items = newSeq[pointer](ids.len)
  for i, id in ids:
    let a = p.shortcuts[id]
    accs[i] = a
    items[i] = `tuple`(@[gVariantNewString(cs($a)), vardict(@[
      vardictEntry("description", gVariantNewString(cs($a))),
      vardictEntry("preferred_trigger",
        gVariantNewString(cs(a.xdgTrigger())))])])
  (accs, gVariantNewArray(nil, unsafeAddr items[0], uint(items.len)))

## reportUnbound logs the shortcuts the desktop bound to no keys: users
## may decline them, and KDE Plasma 5 binds none with portals from 1.17
## on.
proc reportUnbound(accs: seq[accelerator.Accelerator], results: pointer) =
  var keys = initTable[string, string]()
  let list = gVariantLookupValue(results, cs("shortcuts"), nil)
  if not list.isNil:
    if goStr(gVariantGetTypeString(list)) == "a(sa{sv})":
      for i in 0 ..< gVariantNChildren(list):
        let item = gVariantGetChildValue(list, i)
        let id = gVariantGetChildValue(item, 0)
        let props = gVariantGetChildValue(item, 1)
        keys[goStr(gVariantGetString(id, nil))] =
          vardictString(props, "trigger_description")
        gVariantUnref(id)
        gVariantUnref(props)
        gVariantUnref(item)
    gVariantUnref(list)
  for a in accs:
    if keys.getOrDefault($a) == "":
      stderr.writeLine(
        "mynim: global shortcuts: the desktop bound no keys to " & $a)

## shortcutSessionToken names the session after the app: KDE names the
## shortcuts of apps without an ID after it, and keeps the keys the user
## picked for them.
proc shortcutSessionToken(): string =
  var name = desktopEntryID().dup(removeSuffix(".desktop"))
  result = "mynim_"
  for r in name.runes:
    let c = r.int32
    result.add:
      if c < 0x80 and ((c >= ord('0') and c <= ord('9')) or
          (c >= ord('a') and c <= ord('z')) or
          (c >= ord('A') and c <= ord('Z'))):
        char(c)
      else:
        '_'

## bindShortcuts binds the shortcuts in the new session.
proc bindShortcuts*(b: Backend): ref CatchableError =
  var p = addr b.portal
  let (accs, list) = p.list()
  let args = @[gVariantNewObjectPath(cs(p.session)), list,
               gVariantNewString(cs(""))] # no parent window
  portalRequest(shortcutsPortal, "BindShortcuts", args, @[],
    proc(code: uint32, results: pointer) {.closure.} =
      p.busy = false
      if code != 0:
        stderr.writeLine("mynim: global shortcuts: the desktop did not " &
          "bind them (response " & $code & ")")
      else:
        reportUnbound(accs, results)
      if p.stale:
        let err = b.syncShortcuts()
        if not err.isNil:
          stderr.writeLine("mynim: global shortcuts: " & err.msg))

## syncShortcuts replaces the session with one binding the shortcuts. A
## session on its way binds them once it is created.
proc syncShortcuts*(b: Backend): ref CatchableError =
  var p = addr b.portal
  if p.busy:
    p.stale = true
    return nil
  if p.session != "":
    let (res, err) = portalCall(p.session,
      "org.freedesktop.portal.Session", "Close", nil, "")
    if err.isNil: gVariantUnref(res)
    p.session = ""
  if p.shortcuts.len == 0:
    return nil
  let (_, list) = p.list()
  let options = @[
    vardictEntry("session_handle_token",
      gVariantNewString(cs(shortcutSessionToken()))),
    # KDE Plasma 5 binds the shortcuts given here, as drafts of the
    # portal had it; portals before 1.17 pass them on.
    vardictEntry("shortcuts", list)]
  let err = portalRequest(shortcutsPortal, "CreateSession", @[], options,
    proc(code: uint32, results: pointer) {.closure.} =
      let session = vardictString(results, "session_handle")
      if code != 0 or session == "":
        p.busy = false
        stderr.writeLine("mynim: global shortcuts: the desktop portal " &
          "did not create a session (response " & $code & ")")
        return
      p.stale = false
      if p.shortcuts.len == 0:
        p.busy = false
        let (r, e) = portalCall(session,
          "org.freedesktop.portal.Session", "Close", nil, "")
        if e.isNil: gVariantUnref(r)
        return
      p.session = session
      let err = b.bindShortcuts()
      if not err.isNil:
        p.busy = false
        stderr.writeLine("mynim: global shortcuts: " & err.msg))
  if not err.isNil:
    if err.msg.contains("Error.NotAllowed"):
      return newException(CatchableError,
        "mynim: global shortcuts on Wayland need the app installed, " &
        "with its desktop entry " & desktopEntryID() & ": " & err.msg)
    return newException(CatchableError,
      "mynim: global shortcuts: " & err.msg)
  p.busy = true
  p.stale = false
  nil

## shortcutActivated handles the portal's Activated signal: (session
## handle, shortcut id, timestamp, options).
proc withActivationToken*(token: string, fn: proc())

proc shortcutActivated*(b: Backend, params: pointer) =
  proc str(i: uint): string =
    let v = gVariantGetChildValue(params, i)
    defer: gVariantUnref(v)
    goStr(gVariantGetString(v, nil))
  if str(0) != b.portal.session:
    return
  let name = str(1)
  let options = gVariantGetChildValue(params, 3)
  let token = vardictString(options, "activation_token")
  gVariantUnref(options)
  for id, a in b.portal.shortcuts:
    if $a == name:
      withActivationToken(token, proc() = b.h.hotkeyPressed(id))
      return

## withActivationToken runs fn with the XDG activation token of the key
## press that caused it: the window fn shows or focuses first uses it,
## which lets it take the focus on Wayland.
proc withActivationToken*(token: string, fn: proc()) =
  if not wayland.loaded:
    wayland.loaded = true
    if not bindFunc(libGDK, cast[ptr pointer](addr wayland.displayType),
        "gdk_wayland_display_get_type") or
        not bindFunc(libGDK, cast[ptr pointer](addr wayland.setStartupID),
        "gdk_wayland_display_set_startup_notification_id"):
      wayland.setStartupID = nil
  let display = gdkDisplayGetDefault()
  if token == "" or wayland.setStartupID.isNil or
      not gTypeCheckInstanceIsA(display, wayland.displayType()):
    fn()
    return
  wayland.setStartupID(display, cs(token))
  defer: wayland.setStartupID(display, nil)
  fn()
