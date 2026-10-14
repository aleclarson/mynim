## menu.nim: menu bars, context menus and tray menus are GtkMenus. Native
## menu items are tracked per owner (a window's menu bar, a popup, a
## tray) so they can be updated in place and forgotten when rebuilt.

var
  cbMenuActivate*, cbMenuDeactivate*: pointer
  cbMenuKey*, cbCanActivateAccel*, cbMenuBarDeactivate*: pointer

# modifierMask holds the GDK modifiers that make a key a shortcut:
# Shift, Control, Alt, Super, Hyper and Meta.
const modifierMask = 1'u32 shl 0 or 1'u32 shl 2 or 1'u32 shl 3 or
  1'u32 shl 26 or 1'u32 shl 27 or 1'u32 shl 28

# editCommands are handled by the focused webview itself.
var editCommands = {
  "undo": "Undo", "redo": "Redo", "cut": "Cut", "copy": "Copy",
  "paste": "Paste", "pasteAndMatchStyle": "PasteAsPlainText",
  "delete": "Delete", "selectAll": "SelectAll",
  # The Format menu's.
  "bold": "Bold", "italic": "Italic", "underline": "Underline",
  "strikethrough": "Strikethrough", "alignLeft": "JustifyLeft",
  "alignCenter": "JustifyCenter", "alignRight": "JustifyRight"}.toTable

proc window*(b: Backend, data: pointer): gtkWindow ## window.nim
proc focusedWebView*(w: gtkWindow): gtkWindow ## window.nim
proc menuHides*(w: gtkWindow): bool ## below
proc revealMenu*(w: gtkWindow) ## below
proc installMenu*(w: gtkWindow, m: Menu) ## below

const stateFullscreen = 1'u32 shl 10 # GDK_WINDOW_STATE_FULLSCREEN

proc initMenuCallbacks*() =
  cbMenuActivate = cast[pointer](
    proc(item, data: pointer) {.cdecl.} =
      if settingState:
        return
      let b = theBackend
      let id = cast[int](data)
      # A submenu may have focus. Resolve this native item's window, as
      # the same item may appear in several windows' menu bars.
      var w: gtkWindow
      for n in itemsByID.getOrDefault(id):
        if n.item == item and n.windowID != 0:
          w = b.window(cast[pointer](n.windowID))
          if w.isNil:
            return
          break
      if editCommands.hasKey(itemRoles.getOrDefault(id)):
        if w.isNil:
          for x in b.windows.values:
            if not x.closed and gtkWindowIsActive(x.win):
              w = x
              break
        var v: gtkWindow
        if not w.isNil:
          v = w.focusedWebView()
        if not v.isNil:
          # The page of a web view in the content has the keyboard.
          webkitWebViewExecuteEditingCommand(v.web,
            cs(editCommands[itemRoles[id]]))
        elif not w.isNil:
          if not w.surface.isNil:
            let role = itemRoles[id]
            discard w.h.surfaceEvent(SurfaceEvent(kind: surfaceCommand,
              text: role))
          else:
            webkitWebViewExecuteEditingCommand(w.web,
              cs(editCommands[itemRoles[id]]))
        return
      if not w.isNil:
        w.h.menuItemClicked(id)
      else:
        b.h.menuItemClicked(id))
  cbMenuDeactivate = cast[pointer](
    proc(menu, loop: pointer) {.cdecl.} = gMainLoopQuit(loop))
  # Alt pressed and released alone, or F10, show a menu bar that hides.
  cbMenuKey = cast[pointer](
    proc(widget, event, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      if w.isNil:
        return false
      if not w.menuHides() or w.menubar.isNil or
          gtkWidgetGetVisible(w.menubar):
        w.altAlone = false
        return false
      # GdkEventKey: type 0, state 24, keyval 28.
      let press = field[int32](event, 0) == 8 # GDK_KEY_PRESS
      let state = field[uint32](event, 24)
      let key = field[uint32](event, 28)
      let alt = key == 0xffe9 or key == 0xffea # Alt_L, Alt_R
      if press and key == 0xffc7 and (state and modifierMask) == 0: # F10
        w.revealMenu()
        return true
      elif press:
        w.altAlone = alt and (state and modifierMask) == 0
      elif alt and w.altAlone:
        w.altAlone = false
        w.revealMenu()
      else:
        w.altAlone = false
      false)
  # GTK activates the shortcuts of widgets on screen only: a menu bar
  # that hides keeps its own.
  cbCanActivateAccel = cast[pointer](
    proc(widget: pointer, signal: uint32, data: pointer): bool {.cdecl.} =
      let w = theBackend.window(data)
      not w.isNil and w.menuHides())
  cbMenuBarDeactivate = cast[pointer](
    proc(shell, data: pointer) {.cdecl.} =
      let w = theBackend.window(data)
      if not w.isNil and w.menuHides():
        gtkWidgetHide(shell))

proc newOwner(): int =
  inc menuOwners
  menuOwners

proc dropOwner(owner: int) =
  if owner == 0: return
  for id in toSeq(itemsByID.keys):
    var kept: seq[nativeItem]
    for n in itemsByID[id]:
      if n.owner != owner:
        kept.add n
    if kept.len == 0:
      itemsByID.del(id)
    else:
      itemsByID[id] = kept

proc gtkAccelerator(acc: string): tuple[key, mods: uint32, ok: bool]
proc buildItem(it: MenuItem, accel: pointer, owner,
    windowID: int): pointer
proc applyState(item: pointer, it: MenuItem, check: bool)
proc hasAppMenu*(w: gtkWindow): bool
proc firstMenu(bar: pointer): pointer

## buildMenu fills a GtkMenuShell with items.
proc buildMenu(shell: pointer, m: Menu, accel: pointer, owner,
    windowID: int) =
  for it in m.items:
    gtkMenuShellAppend(shell, buildItem(it, accel, owner, windowID))

proc buildItem(it: MenuItem, accel: pointer, owner,
    windowID: int): pointer =
  var item: pointer
  var check = false
  case it.`type`
  of menuItemSeparator:
    item = gtkSeparatorMenuItemNew()
  of menuItemCheckbox, menuItemRadio:
    item = gtkCheckMenuItemNewWithLabel(cs(it.label))
    gtkCheckMenuItemSetDrawAsRadio(item, it.`type` == menuItemRadio)
    check = true
  else:
    item = gtkMenuItemNewWithLabel(cs(it.label))
  if not it.submenu.isNil:
    let sub = gtkMenuNew()
    buildMenu(sub, it.submenu, accel, owner, windowID)
    gtkMenuItemSetSubmenu(item, sub)
  elif it.`type` != menuItemSeparator:
    discard connect(item, "activate", cbMenuActivate,
      cast[pointer](it.id))
    itemRoles[it.id] = it.role
    if not accel.isNil and it.accelerator != "":
      let (key, mods, ok) = gtkAccelerator(it.accelerator)
      if ok:
        gtkWidgetAddAccelerator(item, cs("activate"), accel, key, mods,
          1) # GTK_ACCEL_VISIBLE
  applyState(item, it, check)
  itemsByID.mgetOrPut(it.id, @[]).add nativeItem(
    owner: owner, item: item, check: check, windowID: windowID)
  item

proc applyState(item: pointer, it: MenuItem, check: bool) =
  gtkWidgetSetSensitive(item, it.enabled)
  gtkWidgetSetNoShowAll(item, not it.visible)
  gtkWidgetSetVisible(item, it.visible)
  if check:
    settingState = true
    gtkCheckMenuItemSetActive(item, it.checked)
    settingState = false
  if it.toolTip != "":
    gtkWidgetSetTooltipText(item, cs(it.toolTip))

var gdkKeyNames = {
  "Enter": "Return", "Tab": "Tab", "Space": "space",
  "Backspace": "BackSpace", "Delete": "Delete", "Insert": "Insert",
  "Escape": "Escape", "Up": "Up", "Down": "Down", "Left": "Left",
  "Right": "Right", "Home": "Home", "End": "End", "PageUp": "Page_Up",
  "PageDown": "Page_Down", "+": "plus",
  "VolumeUp": "XF86AudioRaiseVolume",
  "VolumeDown": "XF86AudioLowerVolume",
  "VolumeMute": "XF86AudioMute", "MediaNextTrack": "XF86AudioNext",
  "MediaPreviousTrack": "XF86AudioPrev", "MediaStop": "XF86AudioStop",
  "MediaPlayPause": "XF86AudioPlay", "PrintScreen": "Print",
  "NumDec": "KP_Decimal", "NumAdd": "KP_Add", "NumSub": "KP_Subtract",
  "NumMult": "KP_Multiply", "NumDiv": "KP_Divide",
  "CapsLock": "Caps_Lock", "NumLock": "Num_Lock",
  "ScrollLock": "Scroll_Lock"}.toTable

## gtkAccelerator converts an accelerator to a GDK keyval and modifier
## mask.
proc gtkAccelerator(acc: string): tuple[key, mods: uint32, ok: bool] =
  var a: accelerator.Accelerator
  try:
    a = accelerator.parse(acc, "linux")
  except CatchableError:
    return (0'u32, 0'u32, false)
  var mods: uint32
  if a.has(accelerator.shift): mods = mods or 1'u32 shl 0
  if a.has(accelerator.ctrl): mods = mods or 1'u32 shl 2
  if a.has(accelerator.alt): mods = mods or 1'u32 shl 3
  if a.has(accelerator.super): mods = mods or 1'u32 shl 26
  var key: uint32
  if gdkKeyNames.getOrDefault(a.key) != "":
    key = gdkKeyvalFromName(cs(gdkKeyNames[a.key]))
  elif a.key.startsWith("F") and a.key.len > 1:
    key = gdkKeyvalFromName(cs(a.key))
  elif a.key.startsWith("Num") and a.key.len == 4:
    key = gdkKeyvalFromName(cs("KP_" & a.key[3..^1]))
  else:
    key = gdkUnicodeToKeyval(uint32(a.key.runeAt(0)))
  (key, mods, key != 0)

method setApplicationMenu*(b: Backend, m: Menu) =
  b.appMenu = m
  for w in b.windows.values:
    if not w.ownMenu and w.hasAppMenu():
      w.installMenu(m)

## hasAppMenu tells whether the window shows the application menu in its
## menu bar: flyouts and panels show none.
proc hasAppMenu*(w: gtkWindow): bool =
  w.opts.flyout.isNil and not w.opts.panel

method setMenu*(w: gtkWindow, m: Menu) =
  w.ownMenu = not m.isNil
  var mm = m
  if mm.isNil and w.hasAppMenu():
    mm = w.b.appMenu
  w.installMenu(mm)

## installMenu replaces the menu bar at the top of the window.
proc installMenu*(w: gtkWindow, m: Menu) =
  if not w.menubar.isNil:
    gtkWidgetDestroy(w.menubar)
    w.menubar = nil
    dropOwner(w.owner)
    # Accelerators live in the group; start with a fresh one.
    gtkWindowRemoveAccelGroup(w.win, w.accel)
    gObjectUnref(w.accel)
    w.accel = gtkAccelGroupNew()
    gtkWindowAddAccelGroup(w.win, w.accel)
  if m.isNil or m.items.len == 0:
    return
  w.owner = newOwner()
  w.menubar = gtkMenuBarNew()
  buildMenu(w.menubar, m, w.accel, w.owner, w.id)
  gtkBoxPackStart(w.box, w.menubar, false, false, 0)
  gtkBoxReorderChild(w.box, w.menubar, 0)
  gtkWidgetShowAll(w.menubar)
  # The bar shows as menuHides says, whatever shows the window.
  gtkWidgetSetNoShowAll(w.menubar, true)
  gtkWidgetSetVisible(w.menubar, not w.menuHides())
  let data = cast[pointer](w.id)
  discard connect(w.menubar, "can-activate-accel",
    cbCanActivateAccel, data)
  discard connect(w.menubar, "deactivate", cbMenuBarDeactivate, data)

method setAutoHideMenu*(w: gtkWindow, v: bool) =
  w.autoHideMenu = v
  if not w.menubar.isNil:
    gtkWidgetSetVisible(w.menubar, not w.menuHides())

## menuHides reports whether the menu bar shows only while its menus are
## open: one that hides, and any in full screen, which leaves the page
## the whole screen.
proc menuHides*(w: gtkWindow): bool =
  w.autoHideMenu or (w.state and stateFullscreen) != 0

## revealMenu shows a menu bar that hides and opens its first menu, as
## F10 does in GTK, while the key event is current: the menu grabs its
## device. The bar hides again when its menus close.
proc revealMenu*(w: gtkWindow) =
  gtkWidgetShow(w.menubar)
  # The menu opens under its item: lay the bar out now.
  gtkContainerCheckResize(w.win)
  let item = firstMenu(w.menubar)
  if not item.isNil:
    discard gtkWidgetMnemonicActivate(item, false) # as the item's mnemonic
  else:
    gtkWidgetHide(w.menubar) # nothing to open, so no deactivate to come

## firstMenu returns the first menu of a menu bar that the user can open.
proc firstMenu(bar: pointer): pointer =
  let list = gtkContainerGetChildren(bar)
  defer: gListFree(list)
  var node = list
  while not node.isNil:
    let item = field[pointer](node, 0)
    if gtkWidgetGetVisible(item) and gtkWidgetIsSensitive(item):
      return item
    node = field[pointer](node, 8)
  nil

method updateMenuItem*(b: Backend, it: MenuItem) =
  for n in itemsByID.getOrDefault(it.id):
    if it.`type` != menuItemSeparator:
      gtkMenuItemSetLabel(n.item, cs(it.label))
    applyState(n.item, it, n.check)

proc popupTrigger*(w: gtkWindow): pointer ## window.nim
proc contentWindow*(w: gtkWindow): pointer ## window.nim

## popupMenu shows a context menu and blocks until it is dismissed.
method popupMenu*(b: Backend, m: Menu, pw: Window, pos: ref platform.Point) =
  # GTK positions menus relative to a window: the given one, else the
  # active one.
  var w = gtkWindow(pw)
  if w.isNil or w.closed:
    w = nil
    for x in b.windows.values:
      if not x.closed and gtkWindowIsActive(x.win):
        w = x
        break
  if w.isNil:
    return # nowhere to show it
  let owner = newOwner()
  defer: dropOwner(owner)
  let menu = gtkMenuNew()
  buildMenu(menu, m, nil, owner, w.id)
  gtkWidgetShowAll(menu)
  let event = w.popupTrigger()
  let anchor = w.contentWindow()
  const northWest = 1'i32 # GDK_GRAVITY_NORTH_WEST
  var corner = northWest
  if m.rightToLeft:
    # GTK_TEXT_DIR_RTL lays the menu out from the right (its items
    # take the default direction, which GTK takes from the locale),
    # and GDK_GRAVITY_NORTH_EAST opens it to the left of the point.
    gtkWidgetSetDirection(menu, 2)
    corner = 3
  if pos != nil and not anchor.isNil:
    var r = gdkRectangle(x: int32(pos.x), y: int32(pos.y),
      width: 1, height: 1)
    gtkMenuPopupAtRect(menu, anchor, addr r, northWest, corner, event)
  elif not event.isNil:
    gtkMenuPopupAtPointer(menu, event)
  elif not anchor.isNil:
    # No mouse press to anchor to: at the pointer.
    var x, y: int32
    let pointer0 = gdkSeatGetPointer(
      gdkDisplayGetDefaultSeat(gdkDisplayGetDefault()))
    discard gdkWindowGetDevicePosition(anchor, pointer0, addr x,
      addr y, nil)
    var r = gdkRectangle(x: x, y: y, width: 1, height: 1)
    gtkMenuPopupAtRect(menu, anchor, addr r, northWest, northWest, nil)
  if not gtkWidgetGetVisible(menu):
    # GTK could not show it: there is no dismissal to wait for.
    gtkWidgetDestroy(menu)
    return
  let loop = gMainLoopNew(nil, false)
  discard connect(menu, "deactivate", cbMenuDeactivate, loop)
  b.popups.add menu
  b.quitLoops.add loop
  gMainLoopRun(loop)
  b.quitLoops.setLen(b.quitLoops.len - 1)
  b.popups.setLen(b.popups.len - 1)
  gMainLoopUnref(loop)
  gtkWidgetDestroy(menu)

# --- Tray icons (AppIndicator / StatusNotifierItem). ---

method newTray*(b: Backend, h: TrayHandler):
    tuple[t: Tray, err: ref CatchableError] =
  if appIndicatorNew.isNil:
    return (nil, newException(CatchableError,
      "mynim: tray icons need libayatana-appindicator3: " &
      errUnsupported().msg))
  inc b.nextTray
  let t = gtkTray(b: b, h: h, id: b.nextTray)
  let name = "mynim-" & $getCurrentProcessId() & "-" & $t.id
  t.ind = appIndicatorNew(cs(name), cs("application-x-executable"), 0) # APPLICATION_STATUS
  appIndicatorSetStatus(t.ind, 1) # ACTIVE
  # AppIndicator only shows up once it has a menu.
  t.setMenu(Menu())
  b.trays[t.id] = t
  (t, nil)

method setImage*(t: gtkTray, png: seq[byte], `template`: bool) =
  if t.iconDir == "":
    t.iconDir = createTempDir("mynim-tray-", "")
  # A new file name makes the indicator host reload the icon.
  inc t.icons
  let name = "icon-" & $t.icons
  writeFile(t.iconDir / name & ".png", cast[string](png))
  appIndicatorSetIconThemePath(t.ind, cs(t.iconDir))
  appIndicatorSetIconFull(t.ind, cs(name), cs(""))

method setTitle*(t: gtkTray, title: string) =
  appIndicatorSetLabel(t.ind, cs(title), cs(title))

method setToolTip*(t: gtkTray, tip: string) =
  if not appIndicatorSetTitle.isNil:
    appIndicatorSetTitle(t.ind, cs(tip))

method setMenu*(t: gtkTray, m: Menu) =
  dropOwner(t.owner)
  t.owner = newOwner()
  let menu = gtkMenuNew()
  if not m.isNil:
    buildMenu(menu, m, nil, t.owner, 0)
  gtkWidgetShowAll(menu)
  appIndicatorSetMenu(t.ind, menu)
  t.menu = menu

method popUpMenu*(t: gtkTray, m: Menu) = discard
method bounds*(t: gtkTray): platform.Rect = platform.Rect()

method destroy*(t: gtkTray) =
  if t.ind.isNil: return
  appIndicatorSetStatus(t.ind, 0) # PASSIVE
  gObjectUnref(t.ind)
  t.ind = nil
  dropOwner(t.owner)
  t.b.trays.del(t.id)
  if t.iconDir != "":
    try: removeDir(t.iconDir)
    except OSError: discard
