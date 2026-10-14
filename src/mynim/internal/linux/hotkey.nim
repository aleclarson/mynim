## hotkey.nim: on X11, global shortcuts grab their keys on the root
## window, and the key presses arrive through a GDK event filter.
## Elsewhere the desktop binds them through the XDG desktop portal
## (hotkey_portal.nim).

var x11*: tuple[
  loaded, ok: bool,
  stringToKeysym: proc(name: cstring): uint64 {.cdecl.},
  keysymToKeycode: proc(dpy: pointer, keysym: uint64): uint8 {.cdecl.},
  grabKey: proc(dpy: pointer, keycode: int32, modifiers: uint32,
                window: uint64, ownerEvents: bool,
                pointerMode, keyboardMode: int32): int32 {.cdecl.},
  ungrabKey: proc(dpy: pointer, keycode: int32, modifiers: uint32,
                  window: uint64): int32 {.cdecl.},
  defaultRoot: proc(dpy: pointer): uint64 {.cdecl.},
  flush: proc(dpy: pointer): int32 {.cdecl.},
  displayType: proc(): uint {.cdecl.},
  xdisplay: proc(display: pointer): pointer {.cdecl.},
  errorTrapPush: proc(display: pointer) {.cdecl.},
  errorTrapPop: proc(display: pointer): int32 {.cdecl.},
  addFilter: proc(window, fn, data: pointer) {.cdecl.}]

var cbHotkeyFilter*: pointer

proc bindShortcut*(b: Backend, id: int, a: accelerator.Accelerator): ref CatchableError
proc unbindShortcut*(b: Backend, id: int)
proc ungrab*(b: Backend, g: grab)

# X modifier masks.
const
  shiftMask* = 1'u32 shl 0
  lockMask* = 1'u32 shl 1  # Caps Lock
  controlMask* = 1'u32 shl 2
  mod1Mask* = 1'u32 shl 3  # Alt
  mod2Mask* = 1'u32 shl 4  # Num Lock
  mod4Mask* = 1'u32 shl 6  # Super

## hotkeyFilter reports the key presses of grabbed shortcuts.
proc hotkeyFilter(xevent, event, data: pointer): int32 {.cdecl.} =
  const keyPress = 2'i32
  const filterContinue = 0'i32
  const filterRemove = 2'i32
  let ev = cast[ptr uint](addr xevent)[]
  if cast[ptr int32](ev)[] != keyPress:
    return filterContinue
  # XKeyEvent: state and keycode follow the time.
  let state = cast[ptr uint32](ev + 80)[] and
    (shiftMask or controlMask or mod1Mask or mod4Mask)
  let keycode = uint8(cast[ptr uint32](ev + 84)[])
  for id, g in theBackend.grabs:
    if g.keycode == keycode and g.mods == state:
      theBackend.h.hotkeyPressed(id)
      return filterRemove
  filterContinue

## loadX11 binds the X11 functions once; it reports whether global
## shortcuts can work: GDK runs on an X server.
proc loadX11*(): bool =
  if x11.loaded:
    return x11.ok
  x11.loaded = true
  let (lib, err) = openLib("libX11.so.6")
  if not err.isNil:
    return false
  let ok = bindFunc(lib, cast[ptr pointer](addr x11.stringToKeysym),
      "XStringToKeysym") and
    bindFunc(lib, cast[ptr pointer](addr x11.keysymToKeycode),
      "XKeysymToKeycode") and
    bindFunc(lib, cast[ptr pointer](addr x11.grabKey), "XGrabKey") and
    bindFunc(lib, cast[ptr pointer](addr x11.ungrabKey), "XUngrabKey") and
    bindFunc(lib, cast[ptr pointer](addr x11.defaultRoot),
      "XDefaultRootWindow") and
    bindFunc(lib, cast[ptr pointer](addr x11.flush), "XFlush") and
    bindFunc(libGDK, cast[ptr pointer](addr x11.displayType),
      "gdk_x11_display_get_type") and
    bindFunc(libGDK, cast[ptr pointer](addr x11.xdisplay),
      "gdk_x11_display_get_xdisplay") and
    bindFunc(libGDK, cast[ptr pointer](addr x11.errorTrapPush),
      "gdk_x11_display_error_trap_push") and
    bindFunc(libGDK, cast[ptr pointer](addr x11.errorTrapPop),
      "gdk_x11_display_error_trap_pop") and
    bindFunc(libGDK, cast[ptr pointer](addr x11.addFilter),
      "gdk_window_add_filter")
  if not ok:
    return false
  x11.ok = gTypeCheckInstanceIsA(gdkDisplayGetDefault(), x11.displayType())
  if x11.ok:
    cbHotkeyFilter = cast[pointer](hotkeyFilter)
    x11.addFilter(nil, cbHotkeyFilter, nil)
  x11.ok

method registerHotkey*(b: Backend, id: int, acc: string) =
  var a: accelerator.Accelerator
  try:
    a = accelerator.parse(acc, "linux")
  except CatchableError as e:
    raise e
  if portalShortcutsOnly or not loadX11():
    let err = b.bindShortcut(id, a)
    if not err.isNil: raise err
    return
  let display = gdkDisplayGetDefault()
  let dpy = x11.xdisplay(display)
  let keycode = x11.keysymToKeycode(dpy,
    x11.stringToKeysym(cs(a.keysym())))
  if keycode == 0:
    raise newException(CatchableError,
      "mynim: the keyboard has no key for " & acc)
  var mods: uint32
  for (m, x) in [(accelerator.shift, shiftMask),
                 (accelerator.ctrl, controlMask),
                 (accelerator.alt, mod1Mask),
                 (accelerator.super, mod4Mask)]:
    if a.has(m): mods = mods or x
  let g = grab(keycode: keycode, mods: mods)
  let root = x11.defaultRoot(dpy)
  x11.errorTrapPush(display)
  for lock in [0'u32, lockMask, mod2Mask, lockMask or mod2Mask]:
    discard x11.grabKey(dpy, int32(keycode), mods or lock, root,
      false, 1, 1) # GrabModeAsync
  if x11.errorTrapPop(display) != 0:
    b.ungrab(g)
    raise newException(CatchableError,
      "mynim: " & acc & " is already a global shortcut of another app")
  b.grabs[id] = g

method unregisterHotkey*(b: Backend, id: int) =
  if b.grabs.hasKey(id):
    let g = b.grabs[id]
    b.grabs.del(id)
    b.ungrab(g)
  b.unbindShortcut(id)

proc ungrab*(b: Backend, g: grab) =
  let display = gdkDisplayGetDefault()
  let dpy = x11.xdisplay(display)
  let root = x11.defaultRoot(dpy)
  x11.errorTrapPush(display)
  for lock in [0'u32, lockMask, mod2Mask, lockMask or mod2Mask]:
    discard x11.ungrabKey(dpy, int32(g.keycode), g.mods or lock, root)
  discard x11.flush(dpy)
  discard x11.errorTrapPop(display)
