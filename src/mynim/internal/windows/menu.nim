## menu.nim (menu.go): native menus — the menu bar, popup menus and
## accelerators. WM_COMMAND reports 16-bit command ids, which map
## back to the items they were built from.

proc setItemInfo*(menu: uint, cmd: uint16, label: string,
  enabled, checked, radio: bool)
proc trackPopup*(b: WinBackend, menu, owner: uint,
  pt: w32Point, flags: uint): uint16
proc focusedWindow*(b: WinBackend): w32Window
proc editRole*(w: w32Window, role: string): bool
proc focusedWebView*(w: w32Window): w32Window
proc titleBar*(w: w32Window): platform.TitleBar
proc atoi*(s: string): int

var emptyAccels* = initTable[accelKey, uint16]()

proc newMenuTable*(): menuTable =
  menuTable(entries: initTable[uint16, menuEntry]())

proc newOwner*(t: menuTable): int =
  inc t.nextOwner
  t.nextOwner

proc add*(t: menuTable, e: menuEntry): uint16 =
  while true:
    inc t.next
    if t.next == 0 or t.next >= 0xF000:
      ## 0xF000 and up are system commands
      t.next = 1
    if not t.entries.hasKey(t.next):
      t.entries[t.next] = e
      return t.next

## drop forgets the items of an owner (a menu bar, popup or tray
## menu).
proc drop*(t: menuTable, owner: int) =
  if owner == 0:
    return
  var gone: seq[uint16]
  for id, e in t.entries:
    if e.owner == owner:
      gone.add(id)
  for id in gone:
    t.entries.del(id)

proc acceleratorText*(a: accelerator.Accelerator): string
proc virtualKey*(key: string): tuple[vk: uint32, ok: bool]

## buildMenu creates a native menu bar or popup menu.
proc buildMenu*(b: WinBackend, m: Menu, bar: bool, owner: int,
    accels: var Table[accelKey, uint16]): uint =
  var h: uint
  if bar:
    h = procCreateMenu()
  else:
    h = procCreatePopupMenu()
  for it in m.items:
    if not it.visible:
      continue
    if it.`type` == menuItemSeparator:
      discard procAppendMenuW(h, mfSeparator, 0, 0)
      continue
    var flags = uint(mfString)
    if not it.enabled:
      flags = flags or uint(mfGrayed)
    if not it.submenu.isNil:
      let sub = b.buildMenu(it.submenu, false, owner, accels)
      discard procAppendMenuW(h, flags or uint(mfPopup), sub,
        cast[uint](u16(it.label)))
      continue
    if it.checked:
      flags = flags or uint(mfChecked)
    let e = menuEntry(uid: it.id, role: it.role, owner: owner,
      menu: h, radio: it.`type` == menuItemRadio)
    let cmd = b.menus.add(e)
    var label = it.label
    if it.accelerator != "":
      let a = accelerator.parse(it.accelerator, "windows")
      if a.key != "":
        e.accel = acceleratorText(a)
        label &= "\t" & e.accel
        let (vk, ok) = virtualKey(a.key)
        if ok:
          accels[accelKey(vk: vk, mods: a.modifiers)] = cmd
    discard procAppendMenuW(h, flags, uint(cmd),
      cast[uint](u16(label)))
    if e.radio:
      setItemInfo(h, cmd, label, it.enabled, it.checked, true)
  h

## menuItemInfo is MENUITEMINFOW.
type menuItemInfo* = object
  size*, mask*, `type`*, state*: uint32
  id*: uint32
  subMenu*, bmpChecked*, bmpUnchecked*, itemData*: uint
  typeData*: pointer
  cch*: uint32
  bmpItem*: uint

proc setItemInfo*(menu: uint, cmd: uint16, label: string,
    enabled, checked, radio: bool) =
  var mi = menuItemInfo(mask: miimState or miimFType or miimString,
    typeData: cast[pointer](cast[uint](u16(label))))
  mi.size = uint32(sizeof(mi))
  if radio:
    mi.`type` = mftRadioCheck
  if checked:
    mi.state = mi.state or mfsChecked
  if not enabled:
    mi.state = mi.state or mfsDisabled
  discard procSetMenuItemInfoW(menu, uint(cmd), 0,
    cast[uint](addr mi))

## installMenu shows m as the window's menu bar (nil removes it).
proc installMenu*(w: w32Window, m: Menu) =
  let old = w.hmenu
  w.b.menus.drop(w.owner)
  w.menu = m
  w.hmenu = 0
  w.owner = 0
  w.accels = initTable[accelKey, uint16]()
  if not m.isNil and m.items.len > 0:
    w.owner = w.b.menus.newOwner()
    w.hmenu = w.b.buildMenu(m, true, w.owner, w.accels)
  w.attachMenu()
  if old != 0:
    discard procDestroyMenu(old)

## menuShown reports whether the menu bar is on the window. One that
## hides is there only while the keyboard is in it, and a window
## without a caption, in full screen or with a material behind its
## page has none.
proc menuShown*(w: w32Window): bool =
  w.hmenu != 0 and not w.barless() and
    (not w.autoHideMenu or w.revealed)

## barless reports a window that has no menu bar: Alt and F10 open
## its menus in a popup instead. A window without a caption, or in
## full screen, has no room for it, and one without a redirection
## bitmap would not show what GDI draws of it, though it took
## clicks.
proc barless*(w: w32Window): bool =
  w.captionless() or w.fullScreen or w.noRedirect

## attachMenu puts the menu bar on the window, or takes it off one
## whose bar hides. Its shortcuts work either way: they come from
## the webview.
proc attachMenu*(w: w32Window) =
  var bar = 0'u
  if w.menuShown():
    bar = w.hmenu
  discard procSetMenu(w.hwnd, bar)

## revealMenu shows a menu bar that hides for the menu loop, which
## Alt or F10 starts with SC_KEYMENU and which runs inside
## DefWindowProc.
proc revealMenu*(w: w32Window, wp, lp: uint): uint =
  w.revealed = true
  w.attachMenu()
  let r = procDefWindowProcW(w.hwnd, wmSysCommand, wp, lp)
  w.revealed = false
  if not w.closed:
    w.attachMenu()
  r

## popupMenuBar opens the menus of the menu bar from the top-left
## corner of a window without room for the bar, below the title bar
## the page draws, when Alt or F10 would take the keyboard to the
## bar; Alt and a letter (key) open the menu of the letter in it, as
## in the bar. The popup holds the bar's own submenus, so their
## items keep their states and commands, and gives them back before
## it is destroyed.
proc popupMenuBar*(w: w32Window, key: uint) =
  let n = procGetMenuItemCount(w.hmenu)
  let count = int(int32(n))
  if count <= 0:
    return
  let popup = procCreatePopupMenu()
  for i in 0 ..< count:
    var buf = newSeq[uint16](256)
    discard procGetMenuStringW(w.hmenu, uint(i),
      cast[uint](addr buf[0]), uint(buf.len), mfByPosition)
    let state = procGetMenuState(w.hmenu, uint(i), mfByPosition)
    var flags = uint(mfString) or (state and uint(mfGrayed))
    var item = procGetSubMenu(w.hmenu, uint(i))
    if item != 0:
      flags = flags or uint(mfPopup)
    else:
      item = procGetMenuItemID(w.hmenu, uint(i))
    discard procAppendMenuW(popup, flags, item,
      cast[uint](addr buf[0]))
  var pt = w32Point(y: toPx(w.titleBar().height,
    dpiOf(w.hwnd)))
  discard procClientToScreen(w.hwnd, cast[uint](addr pt))
  if key != 0:
    ## The menu loop takes the letter as typed in the popup.
    w.menuKey = menuKey(popup: popup, key: key)
    postMessage(w.hwnd, wmChar, key, 0)
  let cmd = w.b.trackPopup(popup, w.hwnd, pt, 0)
  w.menuKey = menuKey()
  for i in countdown(count - 1, 0):
    discard procRemoveMenu(popup, uint(i), mfByPosition)
  discard procDestroyMenu(popup)
  if cmd != 0 and not w.closed:
    w.b.menuCommand(cmd, w)

## menuChar answers WM_MENUCHAR, which a menu sends its window for a
## letter that names none of its items. Alt and a letter that names
## no menu of the bar open none, as in the bar: the popup closes. A
## letter typed in it later cannot be that one, which names none of
## its items.
proc menuChar*(w: w32Window, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  let k = w.menuKey
  if k.popup != 0 and lp == k.popup and
      (wp and 0xFFFF) == k.key:
    return (uint(mncClose) shl 16, true)
  (0'u, false)

method setApplicationMenu*(b: WinBackend, m: Menu) =
  b.appMenu = m
  for w in b.windows.values:
    if not w.ownMenu and w.hasAppMenu():
      w.installMenu(m)

method updateMenuItem*(b: WinBackend, it: MenuItem) =
  for cmd, e in b.menus.entries:
    if e.uid != it.id:
      continue
    var label = it.label
    if e.accel != "":
      label &= "\t" & e.accel
    setItemInfo(e.menu, cmd, label, it.enabled, it.checked,
      e.radio)
  for w in b.windows.values:
    if w.menuShown():
      discard procDrawMenuBar(w.hwnd)

## menuCommand runs the item behind a command id.
proc menuCommand*(b: WinBackend, cmd: uint16, w: w32Window) =
  let e = b.menus.entries.getOrDefault(cmd)
  if e.isNil:
    return
  var w = w
  if w.isNil:
    w = b.focusedWindow()
  if not w.isNil and editRole(w, e.role):
    return
  if not w.isNil:
    w.h.menuItemClicked(e.uid)
  else:
    b.h.menuItemClicked(e.uid)

proc focusedWindow*(b: WinBackend): w32Window =
  let fg = procGetForegroundWindow()
  b.windows.getOrDefault(fg)

## formatCommands are the page's commands of the Format menu's
## roles; in native UI, they go to the content as the other roles.
const formatCommands = {
  "bold": "bold", "italic": "italic", "underline": "underline",
  "strikethrough": "strikeThrough", "alignLeft": "justifyLeft",
  "alignCenter": "justifyCenter",
  "alignRight": "justifyRight"}.toTable

proc jsString*(s: string): string =
  $(%s)

## editRole performs the edit roles in the page. The page needs a
## user gesture for them, which DevTools evaluation provides; paste
## types the clipboard's text, since pages may not read the
## clipboard.
proc editRole*(w: w32Window, role: string): bool =
  let commands = {
    "undo": "undo", "redo": "redo", "cut": "cut", "copy": "copy",
    "delete": "delete", "selectAll": "selectAll"}.toTable
  let v = w.focusedWebView()
  if not v.isNil:
    ## The page of a web view in the content has the keyboard.
    return editRole(v, role)
  if not w.surface.isNil:
    if not commands.hasKey(role) and role != "paste" and
        role != "pasteAndMatchStyle":
      return false
    discard w.h.surfaceEvent(
      SurfaceEvent(kind: surfaceCommand, text: role))
    return true
  if role == "paste" or role == "pasteAndMatchStyle":
    let text = w32Clipboard(b: w.b).readText()
    let params = $(%*{"text": text})
    w.withWebView(proc() =
      w.devtools("Input.insertText", params, nil))
    return true
  var cmd = commands.getOrDefault(role)
  if cmd == "":
    ## The Format menu's, in the page with the keyboard.
    cmd = formatCommands.getOrDefault(role)
  if cmd == "":
    return false
  let params = $(%*{"expression":
    %("document.execCommand(" & jsString(cmd) & ")"),
    "userGesture": %true})
  w.withWebView(proc() =
    w.devtools("Runtime.evaluate", params, nil))
  true

method popupMenu*(b: WinBackend, m: Menu, pw: Window,
    pos: ref platform.Point) =
  var owner = b.appHwnd
  var w = cast[w32Window](pw)
  if not w.isNil and not w.closed:
    owner = w.hwnd
  else:
    w = nil
  let id = b.menus.newOwner()
  defer: b.menus.drop(id)
  let menu = b.buildMenu(m, false, id, emptyAccels)
  defer: discard procDestroyMenu(menu)

  var pt: w32Point
  if not pos.isNil and not w.isNil:
    let dpi = dpiOf(w.hwnd)
    pt = w32Point(x: int32(toPx(pos.x, dpi)),
      y: int32(toPx(pos.y, dpi)))
    discard procClientToScreen(w.hwnd, cast[uint](addr pt))
  else:
    discard procGetCursorPos(cast[uint](addr pt))
  var flags = 0'u
  if m.rightToLeft:
    ## Its right edge at the point, laid out from the right.
    flags = tpmRightAlign or tpmLayoutRTL
  let cmd = b.trackPopup(menu, owner, pt, flags)
  if cmd != 0:
    b.menuCommand(cmd, w)

## trackPopup shows a popup menu, with TrackPopupMenuEx's flags
## besides those it always gives, and returns the chosen command,
## or 0.
proc trackPopup*(b: WinBackend, menu, owner: uint,
    pt: w32Point, flags: uint): uint16 =
  ## The owner must be in the foreground, or the menu does not
  ## close when the user clicks elsewhere.
  discard procSetForegroundWindow(owner)
  let cmd = procTrackPopupMenuEx(menu,
    tpmReturnCmd or tpmRightButton or uint32(flags), uint(uint32(pt.x)),
    uint(uint32(pt.y)), owner, 0)
  postMessage(owner, 0, 0, 0) ## WM_NULL, as the documentation asks
  uint16(cmd)

## Keyboard accelerators.

proc currentModifiers*(): accelerator.Modifiers =
  proc down(vk: uint): bool =
    int16(procGetKeyState(vk)) < 0
  var m: accelerator.Modifiers
  if down(vkControl):
    m = m or accelerator.ctrl
  if down(vkMenu):
    m = m or accelerator.alt
  if down(vkShift):
    m = m or accelerator.shift
  if down(vkLWin) or down(vkRWin):
    m = m or accelerator.super
  m

proc acceleratorText*(a: accelerator.Accelerator): string =
  var parts: seq[string]
  if a.has(accelerator.ctrl):
    parts.add("Ctrl")
  if a.has(accelerator.alt):
    parts.add("Alt")
  if a.has(accelerator.shift):
    parts.add("Shift")
  if a.has(accelerator.super):
    parts.add("Win")
  var key = a.key
  if key.len == 1:
    key = key.toUpperAscii()
  parts.add(key)
  parts.join("+")

const namedVirtualKeys = {
  "Enter": 0x0D'u32, "Tab": 0x09, "Space": 0x20,
  "Backspace": 0x08, "Delete": 0x2E, "Insert": 0x2D,
  "Escape": 0x1B, "Up": 0x26, "Down": 0x28, "Left": 0x25,
  "Right": 0x27, "Home": 0x24, "End": 0x23, "PageUp": 0x21,
  "PageDown": 0x22, "VolumeUp": 0xAF, "VolumeDown": 0xAE,
  "VolumeMute": 0xAD, "MediaNextTrack": 0xB0,
  "MediaPreviousTrack": 0xB1, "MediaStop": 0xB2,
  "MediaPlayPause": 0xB3, "PrintScreen": 0x2C, "NumDec": 0x6E,
  "NumAdd": 0x6B, "NumSub": 0x6D, "NumMult": 0x6A,
  "NumDiv": 0x6F, "CapsLock": 0x14, "NumLock": 0x90,
  "ScrollLock": 0x91, ",": 0xBC, "-": 0xBD, ".": 0xBE,
  "=": 0xBB, "+": 0xBB, ";": 0xBA, "/": 0xBF, "`": 0xC0,
  "[": 0xDB, "\\": 0xDC, "]": 0xDD, "'": 0xDE}.toTable

## virtualKey returns the virtual-key code of an accelerator key.
proc virtualKey*(key: string): tuple[vk: uint32, ok: bool] =
  if namedVirtualKeys.hasKey(key):
    return (namedVirtualKeys[key], true)
  if key.len == 1:
    let c = key[0]
    if c >= 'a' and c <= 'z':
      return (uint32(int(c) - int('a') + int('A')), true)
    if c >= '0' and c <= '9':
      return (uint32(c), true)
  if key.startsWith("F"):
    let n = atoi(key[1..^1])
    if n >= 1 and n <= 24:
      return (0x70'u32 + uint32(n - 1), true)
  if key.startsWith("Num"):
    let n = atoi(key[3..^1])
    if n >= 0 and n <= 9 and key.len == 4:
      return (0x60'u32 + uint32(n), true)
  (0'u32, false)

proc atoi*(s: string): int =
  if s == "":
    return -1
  for c in s:
    if c < '0' or c > '9':
      return -1
    result = result * 10 + int(c) - int('0')
