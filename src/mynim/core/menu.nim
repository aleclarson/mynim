## menu.go + menu_text.go — menus, menu items with roles, and the
## default menu bar.
##
## The labels menu items take from their role (MenuItem.role) are
## MyNim's own strings: they say the language the app shows
## (app.locale), and an item whose label is its role's says the new
## language's when it changes.

proc snapshotLocked(it: MenuItem): platform.MenuItem
proc roleDefaults(r: MenuRole): tuple[label, accel: string]
proc roleSubmenu(r: MenuRole): seq[MenuItem]
proc performRole(role: MenuRole; win: Window)
proc refreshMenus()

proc separator*(): MenuItem =
  ## Returns a separator item.
  MenuItem(`type`: menuItemSeparator)

## appLanguage returns the language the app shows, or "" before it
## worked out which.
proc appLanguage(): string =
  let s = locales.shown.load(moAcquire)
  if s != nil: s.locale else: ""

## menuMessages returns MyNim's own strings in the language the app
## shows; in its own language before it worked out which (app.locale).
proc menuMessages(): l10n.Messages = l10n.`in`(appLanguage())

## platformTexts returns the words the backends say of their own in a
## language (platform.Texts).
proc platformTexts(locale: string): platform.Texts =
  let tx = l10n.`in`(locale)
  platform.Texts(ok: tx.ok(), cancel: tx.cancel(), open: tx.open(),
    save: tx.save(), selectFolder: tx.selectFolder(),
    about: tx.menuAbout("\x00"))

## menuMu guards the state of all menus and items.
var menuMu: Lock
menuMu.initLock()

## menuItems holds every item by uid. Go uses a weak map so items
## dropped from every menu can die; a strong table keeps them (menus
## stay in use for the app's life anyway).
var menuItems: tuple[next: int; byID: Table[int, MenuItem]]
menuItems.byID = initTable[int, MenuItem]()

proc `$`*(r: MenuRole): string =
  ## The role's string form, as the platform snapshot carries.
  const names: array[MenuRole, string] = [
    roleNone: "",
    roleUndo: "undo", roleRedo: "redo", roleCut: "cut",
    roleCopy: "copy", rolePaste: "paste",
    rolePasteAndMatchStyle: "pasteAndMatchStyle", roleDelete: "delete",
    roleSelectAll: "selectAll", roleReload: "reload",
    roleForceReload: "forceReload", roleToggleDevTools: "toggleDevTools",
    roleResetZoom: "resetZoom", roleZoomIn: "zoomIn",
    roleZoomOut: "zoomOut", roleToggleFullScreen: "toggleFullScreen",
    roleMinimize: "minimize", roleZoom: "zoom", roleClose: "close",
    roleNew: "new", roleOpen: "open", roleOpenRecent: "openRecent",
    roleSave: "save", roleSaveAs: "saveAs", roleDuplicate: "duplicate",
    roleRename: "rename", roleMoveTo: "moveTo", roleRevert: "revert",
    roleQuit: "quit", roleAbout: "about", roleHide: "hide",
    roleHideOthers: "hideOthers", roleUnhide: "unhide",
    roleFront: "front", roleServices: "services",
    roleStartSpeaking: "startSpeaking", roleStopSpeaking: "stopSpeaking",
    roleWindow: "window", roleHelp: "help", roleAppMenu: "appMenu",
    roleFileMenu: "fileMenu", roleEditMenu: "editMenu",
    roleViewMenu: "viewMenu", roleWindowMenu: "windowMenu",
    roleFormatMenu: "formatMenu", roleBold: "bold", roleItalic: "italic",
    roleUnderline: "underline", roleStrikethrough: "strikethrough",
    roleAlignLeft: "alignLeft", roleAlignCenter: "alignCenter",
    roleAlignRight: "alignRight",
  ]
  names[r]

const macOnlyRoles: set[MenuRole] = {
  roleAbout, roleHide, roleHideOthers, roleUnhide, roleFront,
  roleServices, roleStartSpeaking, roleStopSpeaking, roleAppMenu,
  rolePasteAndMatchStyle, roleWindow, roleHelp}

var zoomSteps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25,
                 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]

proc nextZoom(cur: float64; dir: int): float64 =
  if dir > 0:
    for s in zoomSteps:
      if s > cur + 0.001:
        return s
    return zoomSteps[^1]
  for i in countdown(zoomSteps.len - 1, 0):
    if zoomSteps[i] < cur - 0.001:
      return zoomSteps[i]
  zoomSteps[0]

proc roleDefaults(r: MenuRole): tuple[label, accel: string] =
  let mac = hostOS == "macosx"
  let name = app.name()
  let tx = menuMessages()
  case r
  of roleUndo: (tx.menuUndo(), "CmdOrCtrl+Z")
  of roleRedo:
    when defined(windows): (tx.menuRedo(), "Ctrl+Y")
    else: (tx.menuRedo(), "Shift+CmdOrCtrl+Z")
  of roleCut: (tx.menuCut(), "CmdOrCtrl+X")
  of roleCopy: (tx.menuCopy(), "CmdOrCtrl+C")
  of rolePaste: (tx.menuPaste(), "CmdOrCtrl+V")
  of rolePasteAndMatchStyle:
    (tx.menuPasteAndMatchStyle(), "Shift+Alt+CmdOrCtrl+V")
  of roleDelete: (tx.menuDelete(), "")
  of roleSelectAll: (tx.menuSelectAll(), "CmdOrCtrl+A")
  of roleReload: (tx.menuReload(), "CmdOrCtrl+R")
  of roleForceReload: (tx.menuForceReload(), "Shift+CmdOrCtrl+R")
  of roleToggleDevTools:
    if mac: (tx.menuToggleDevTools(), "Alt+Cmd+I")
    else: (tx.menuToggleDevTools(), "Ctrl+Shift+I")
  of roleResetZoom: (tx.menuActualSize(), "CmdOrCtrl+0")
  of roleZoomIn: (tx.menuZoomIn(), "CmdOrCtrl+Plus")
  of roleZoomOut: (tx.menuZoomOut(), "CmdOrCtrl+-")
  of roleToggleFullScreen:
    if mac: (tx.menuToggleFullScreen(), "Ctrl+Cmd+F")
    else: (tx.menuToggleFullScreen(), "F11")
  of roleMinimize: (tx.menuMinimize(), "CmdOrCtrl+M")
  of roleZoom: (tx.menuZoom(), "")
  of roleClose:
    if hasDocuments(): (tx.menuClose(), "CmdOrCtrl+W")
    else: (tx.menuCloseWindow(), "CmdOrCtrl+W")
  of roleNew: (tx.menuNew(), "CmdOrCtrl+N")
  of roleOpen: (tx.menuOpen(), "CmdOrCtrl+O")
  of roleOpenRecent: (tx.menuOpenRecent(), "")
  of roleSave: (tx.menuSave(), "CmdOrCtrl+S")
  of roleSaveAs:
    if mac: (tx.menuSaveAs(), "Alt+Shift+Cmd+S")
    else: (tx.menuSaveAs(), "Ctrl+Shift+S")
  of roleDuplicate:
    if mac: (tx.menuDuplicate(), "Shift+Cmd+S")
    else: (tx.menuDuplicate(), "")
  of roleRename: (tx.menuRename(), "")
  of roleMoveTo: (tx.menuMoveTo(), "")
  of roleRevert:
    if mac: (tx.menuRevertToSaved(), "")
    else: (tx.menuRevert(), "")
  of roleQuit:
    if mac: (tx.menuQuitApp(name), "Cmd+Q")
    elif hostOS == "windows": (tx.menuExit(), "")
    else: (tx.menuQuit(), "Ctrl+Q")
  of roleAbout: (tx.menuAbout(name), "")
  of roleHide: (tx.menuHide(name), "Cmd+H")
  of roleHideOthers: (tx.menuHideOthers(), "Alt+Cmd+H")
  of roleUnhide: (tx.menuShowAll(), "")
  of roleFront: (tx.menuBringAllToFront(), "")
  of roleServices: (tx.menuServices(), "")
  of roleStartSpeaking: (tx.menuStartSpeaking(), "")
  of roleStopSpeaking: (tx.menuStopSpeaking(), "")
  of roleWindow, roleWindowMenu: (tx.menuWindow(), "")
  of roleHelp: (tx.menuHelp(), "")
  of roleAppMenu: (name, "")
  of roleFileMenu: (tx.menuFile(), "")
  of roleEditMenu: (tx.menuEdit(), "")
  of roleViewMenu: (tx.menuView(), "")
  of roleFormatMenu: (tx.menuFormat(), "")
  of roleBold: (tx.menuBold(), "CmdOrCtrl+B")
  of roleItalic: (tx.menuItalic(), "CmdOrCtrl+I")
  of roleUnderline: (tx.menuUnderline(), "CmdOrCtrl+U")
  of roleStrikethrough: (tx.menuStrikethrough(), "Shift+CmdOrCtrl+X")
  of roleAlignLeft:
    if mac: (tx.menuAlignLeft(), "Cmd+{")
    else: (tx.menuAlignLeft(), "Ctrl+L")
  of roleAlignCenter:
    if mac: (tx.menuCenter(), "Cmd+|")
    else: (tx.menuCenter(), "Ctrl+E")
  of roleAlignRight:
    if mac: (tx.menuAlignRight(), "Cmd+}")
    else: (tx.menuAlignRight(), "Ctrl+R")
  else: ($r, "")

## roleSubmenu returns the default items of submenu roles.
proc roleSubmenu(r: MenuRole): seq[MenuItem] =
  let mac = hostOS == "macosx"
  case r
  of roleAppMenu:
    @[MenuItem(role: roleAbout), separator(), MenuItem(role: roleServices),
      separator(), MenuItem(role: roleHide), MenuItem(role: roleHideOthers),
      MenuItem(role: roleUnhide), separator(), MenuItem(role: roleQuit)]
  of roleFileMenu:
    if hasDocuments():
      # DocumentGroup's File menu on macOS; KStandardAction's and
      # Notepad's elsewhere.
      if mac:
        return @[MenuItem(role: roleNew), MenuItem(role: roleOpen),
          MenuItem(role: roleOpenRecent), separator(),
          MenuItem(role: roleClose), MenuItem(role: roleSave),
          MenuItem(role: roleDuplicate), MenuItem(role: roleRename),
          MenuItem(role: roleMoveTo), MenuItem(role: roleRevert)]
      return @[MenuItem(role: roleNew), MenuItem(role: roleOpen),
        MenuItem(role: roleOpenRecent), separator(),
        MenuItem(role: roleSave), MenuItem(role: roleSaveAs),
        MenuItem(role: roleRevert), separator(),
        MenuItem(role: roleClose), separator(), MenuItem(role: roleQuit)]
    if mac:
      return @[MenuItem(role: roleClose)]
    return @[MenuItem(role: roleQuit)]
  of roleOpenRecent:
    recentMenuItems()
  of roleEditMenu:
    var items = @[MenuItem(role: roleUndo), MenuItem(role: roleRedo),
      separator(), MenuItem(role: roleCut), MenuItem(role: roleCopy),
      MenuItem(role: rolePaste)]
    if mac:
      items.add MenuItem(role: rolePasteAndMatchStyle)
      items.add MenuItem(role: roleDelete)
      items.add MenuItem(role: roleSelectAll)
      items.add separator()
      items.add MenuItem(label: menuMessages().menuSpeech(),
        submenu: @[MenuItem(role: roleStartSpeaking),
                   MenuItem(role: roleStopSpeaking)])
      return items
    items.add MenuItem(role: roleDelete)
    items.add separator()
    items.add MenuItem(role: roleSelectAll)
    items
  of roleFormatMenu:
    @[MenuItem(role: roleBold), MenuItem(role: roleItalic),
      MenuItem(role: roleUnderline), MenuItem(role: roleStrikethrough),
      separator(), MenuItem(role: roleAlignLeft),
      MenuItem(role: roleAlignCenter), MenuItem(role: roleAlignRight)]
  of roleViewMenu:
    @[MenuItem(role: roleReload), MenuItem(role: roleForceReload),
      MenuItem(role: roleToggleDevTools), separator(),
      MenuItem(role: roleResetZoom), MenuItem(role: roleZoomIn),
      MenuItem(role: roleZoomOut), separator(),
      MenuItem(role: roleToggleFullScreen)]
  of roleWindowMenu:
    if mac:
      return @[MenuItem(role: roleMinimize), MenuItem(role: roleZoom),
        separator(), MenuItem(role: roleFront)]
    @[MenuItem(role: roleMinimize), MenuItem(role: roleClose)]
  else: @[]

## radioGroup returns the run of adjacent radio items containing it.
proc radioGroup(it: MenuItem): seq[MenuItem] =
  let items = it.parent.items
  var idx = -1
  for i, x in items:
    if x == it:
      idx = i
      break
  if idx < 0:
    return @[it]
  var start, stop = idx
  while start > 0 and items[start - 1].`type` == menuItemRadio:
    dec start
  while stop < items.len - 1 and items[stop + 1].`type` == menuItemRadio:
    inc stop
  items[start..stop]

proc uncheckRadioSiblings(it: MenuItem) =
  if it.parent == nil:
    return
  for s in it.radioGroup():
    s.checked = false

const platformTypeOf: array[MenuItemType, platform.MenuItemType] = [
  menuItemNormal: platform.menuItemNormal,
  menuItemSeparator: platform.menuItemSeparator,
  menuItemSubmenu: platform.menuItemSubmenu,
  menuItemCheckbox: platform.menuItemCheckbox,
  menuItemRadio: platform.menuItemRadio,
]

proc snapshotLocked(m: Menu): platform.Menu =
  if m == nil:
    return nil
  let pm = platform.Menu()
  for it in m.items:
    pm.items.add it.snapshotLocked()
  pm

proc snapshotLocked(it: MenuItem): platform.MenuItem =
  let p = platform.MenuItem(
    id: it.uid,
    label: it.label,
    role: $it.role,
    accelerator: it.accelerator,
    enabled: not it.disabled,
    visible: not it.hidden,
    checked: it.checked,
    toolTip: it.toolTip,
    `type`: platformTypeOf[it.`type`])
  if it.sub != nil:
    p.submenu = it.sub.snapshotLocked()
  p

proc snapshot*(m: Menu): platform.Menu =
  if m == nil:
    return nil
  menuMu.acquire()
  result = m.snapshotLocked()
  menuMu.release()

## prepareItem registers an item and expands its role. menuMu must be
## held.
proc prepareItem(it: MenuItem; parent: Menu): MenuItem =
  it.parent = parent
  if it.uid == 0:
    inc menuItems.next
    it.uid = menuItems.next
    menuItems.byID[it.uid] = it
    if menuItems.byID.len > 256 and (menuItems.byID.len mod 256) == 0:
      var dead: seq[int]
      for id, x in menuItems.byID:
        if x == nil:
          dead.add id
      for id in dead:
        menuItems.byID.del(id)
  if it.role != roleNone:
    let (label, accel) = roleDefaults(it.role)
    if it.label == "":
      it.label = label
      it.roleLabel = label
    if it.accelerator == "":
      it.accelerator = accel
    if it.submenu.len == 0:
      it.submenu = roleSubmenu(it.role)
    when not defined(macosx):
      if it.role in macOnlyRoles:
        it.hidden = true
  if it.`type` == menuItemNormal and it.submenu.len > 0:
    it.`type` = menuItemSubmenu
  if it.submenu.len > 0:
    let sub = Menu()
    for child in it.submenu:
      sub.items.add prepareItem(child, sub)
    it.sub = sub
  it

proc newMenu*(items: openArray[MenuItem]): Menu =
  ## Builds a menu from a template:
  ##
  ##   let m = newMenu(@[
  ##     MenuItem(role: roleAppMenu),
  ##     MenuItem(label: "File", submenu: @[
  ##       MenuItem(label: "New Window", accelerator: "CmdOrCtrl+N",
  ##                click: newWindowCb),
  ##       separator(),
  ##       MenuItem(role: roleClose),
  ##     ]),
  ##     MenuItem(role: roleEditMenu),
  ##   ])
  let m = Menu()
  menuMu.acquire()
  for it in items:
    m.items.add prepareItem(it, m)
  menuMu.release()
  m

proc items*(m: Menu): seq[MenuItem] =
  ## The items of the menu.
  menuMu.acquire()
  result = m.items
  menuMu.release()

proc append*(m: Menu; items: varargs[MenuItem]) =
  ## Adds items at the end of the menu.
  menuMu.acquire()
  for it in items:
    m.items.add prepareItem(it, m)
  menuMu.release()
  refreshMenus()

proc insert*(m: Menu; pos: int; item: MenuItem) =
  ## Adds item at position pos.
  menuMu.acquire()
  m.items.insert(prepareItem(item, m), min(max(pos, 0), m.items.len))
  menuMu.release()
  refreshMenus()

proc itemByIDLocked(m: Menu; id: string): MenuItem =
  for it in m.items:
    if it.id == id:
      return it
    if it.sub != nil:
      let found = it.sub.itemByIDLocked(id)
      if found != nil:
        return found
  nil

proc itemByID*(m: Menu; id: string): MenuItem =
  ## Finds an item by ID in the menu and its submenus.
  menuMu.acquire()
  result = m.itemByIDLocked(id)
  menuMu.release()

proc lookupMenuItem(id: int): MenuItem =
  menuMu.acquire()
  result = menuItems.byID.getOrDefault(id)
  menuMu.release()

## refreshMenus re-installs menus in use after their structure changed.
proc refreshMenus() =
  if not app.isReady():
    return
  discard postMain(proc() =
    let m = app.menu()
    if m != nil:
      backend().setApplicationMenu(m.snapshot())
    for w in allWindows():
      if w.menu != nil and w.native != nil:
        w.native.setMenu(w.menu.snapshot()))

## --- item state ---

proc update(it: MenuItem; fn: proc() {.closure.}) =
  menuMu.acquire()
  fn()
  var snaps: seq[platform.MenuItem]
  if it.uid != 0:
    snaps.add it.snapshotLocked()
    if it.`type` == menuItemRadio and it.parent != nil:
      for s in it.radioGroup():
        if s != it:
          snaps.add s.snapshotLocked()
  menuMu.release()
  if snaps.len > 0:
    discard postMain(proc() =
      for s in snaps:
        backend().updateMenuItem(s))

proc getBool(it: MenuItem; fn: proc(): bool {.closure.}): bool =
  menuMu.acquire()
  result = fn()
  menuMu.release()

proc setEnabled*(it: MenuItem; v: bool) =
  ## Enables or disables the item.
  it.update(proc() = it.disabled = not v)

proc isEnabled*(it: MenuItem): bool =
  ## Whether the item is enabled.
  not it.getBool(proc(): bool = it.disabled)

proc setVisible*(it: MenuItem; v: bool) =
  ## Shows or hides the item.
  it.update(proc() = it.hidden = not v)

proc isVisible*(it: MenuItem): bool =
  ## Whether the item is visible.
  not it.getBool(proc(): bool = it.hidden)

proc setChecked*(it: MenuItem; v: bool) =
  ## Checks or unchecks a checkbox or radio item.
  it.update(proc() =
    if v and it.`type` == menuItemRadio:
      it.uncheckRadioSiblings()
    it.checked = v)

proc isChecked*(it: MenuItem): bool =
  ## Whether a checkbox or radio item is checked.
  it.getBool(proc(): bool = it.checked)

proc setLabel*(it: MenuItem; label: string) =
  ## Changes the label of the item.
  it.update(proc() = it.label = label)

proc setAccelerator*(it: MenuItem; acc: string) =
  ## Changes the keyboard shortcut of the item.
  it.update(proc() = it.accelerator = acc)

## --- popups ---

proc popupMenuAt(m: Menu; w: Window; pos: ref platform.Point;
    rtl: bool) =
  ## Shows the menu over w at pos (nil: the mouse position), laid out
  ## right to left with rtl, as those of native UI laid out so. It
  ## returns once the menu is closed.
  let snap = m.snapshot()
  if snap != nil:
    snap.rightToLeft = rtl
  onMain(proc() =
    var n: platform.Window
    if w != nil:
      n = w.native
    backend().popupMenu(snap, n, pos))

proc popUp*(m: Menu; win: Window) =
  ## Shows the menu as a context menu at the mouse position over win.
  ## It returns once the menu is closed.
  needsApp("menu.popUp")
  m.popupMenuAt(win, nil, false)

proc popUpAt*(m: Menu; win: Window; x, y: int) =
  ## Shows the menu as a context menu at a position relative to the
  ## top-left corner of win's page area.
  needsApp("menu.popUpAt")
  var p: ref platform.Point
  new(p)
  p.x = x
  p.y = y
  m.popupMenuAt(win, p, false)

## --- clicks and roles ---

## menuItemClicked runs on the main thread when the backend reports a
## click.
proc menuItemClicked(id: int; win: Window) =
  let it = lookupMenuItem(id)
  if it == nil:
    return
  case it.`type`
  of menuItemCheckbox:
    it.setChecked(not it.isChecked())
  of menuItemRadio:
    it.setChecked(true)
  else: discard
  performRole(it.role, win)
  if it.click != nil:
    it.click(it, win)

## performRole implements roles that backends report back to the app.
proc performRole(role: MenuRole; win: Window) =
  case role
  of roleQuit:
    app.quit()
    return
  of roleNone:
    return
  of roleNew, roleOpen, roleSave, roleSaveAs, roleDuplicate,
     roleRename, roleMoveTo, roleRevert:
    documentRole(role, win)
    return
  else: discard
  if win == nil or win.native == nil:
    return
  let n = win.native
  # A window showing native UI has no page to reload or zoom; it has
  # its own inspector.
  case role
  of roleToggleDevTools:
    if win.conn != nil and win.conn.toggleDevTools != nil:
      win.conn.toggleDevTools()
      return
  of roleReload, roleForceReload, roleResetZoom, roleZoomIn, roleZoomOut:
    if win.content != nil:
      return
  else: discard
  case role
  of roleReload:
    n.reload(false)
  of roleForceReload:
    n.reload(true)
  of roleToggleDevTools:
    if n.isDevToolsOpened():
      n.closeDevTools()
    else:
      n.openDevTools()
  of roleResetZoom:
    n.setZoom(1)
  of roleZoomIn:
    n.setZoom(nextZoom(n.zoom(), 1))
  of roleZoomOut:
    n.setZoom(nextZoom(n.zoom(), -1))
  of roleToggleFullScreen:
    n.setFullScreen(not n.isFullScreen())
  of roleMinimize:
    n.minimize()
  of roleZoom:
    if n.isMaximized():
      n.unmaximize()
    else:
      n.maximize()
  of roleClose:
    win.close()
  of roleUndo, roleRedo, roleCut, roleCopy, rolePaste, roleDelete,
     roleSelectAll, rolePasteAndMatchStyle:
    var cmd = case role
      of roleUndo: "undo"
      of roleRedo: "redo"
      of roleCut: "cut"
      of roleCopy: "copy"
      of rolePaste: "paste"
      of roleDelete: "delete"
      of roleSelectAll: "selectAll"
      else: "pasteAndMatchStyle"
    if win.content != nil:
      win.contentCommand(cmd)
      return
    if role == rolePasteAndMatchStyle:
      cmd = "paste"
    n.eval("document.execCommand(\"" & cmd & "\")")
  of roleBold, roleItalic, roleUnderline, roleStrikethrough,
     roleAlignLeft, roleAlignCenter, roleAlignRight:
    if win.content != nil:
      win.contentCommand($role)
      return
    let cmd = case role
      of roleBold: "bold"
      of roleItalic: "italic"
      of roleUnderline: "underline"
      of roleStrikethrough: "strikeThrough"
      of roleAlignLeft: "justifyLeft"
      of roleAlignCenter: "justifyCenter"
      else: "justifyRight"
    n.eval("document.execCommand(\"" & cmd & "\")")
  else: discard

## defaultMenu is installed when the app does not set one. Only macOS
## gets a default menu bar: it hosts the standard shortcuts (copy,
## paste, quit, ...), and apps with documents, whose File menu saves
## them.
proc defaultMenu(): Menu =
  when not defined(macosx):
    if hasDocuments():
      return newMenu(@[MenuItem(role: roleFileMenu),
                       MenuItem(role: roleEditMenu)])
    return nil
  else:
    newMenu(@[MenuItem(role: roleAppMenu), MenuItem(role: roleFileMenu),
      MenuItem(role: roleEditMenu), MenuItem(role: roleViewMenu),
      MenuItem(role: roleWindowMenu)])

## relabelMenus gives the items whose label is their role's the role's
## label now, as the language the app shows changed, and shows the
## menus in use with them: the menus of the app and of windows anew,
## and the others, as those of trays and the Dock, item by item. Main
## thread only.
proc relabelMenus() =
  menuMu.acquire()
  var changed: seq[platform.MenuItem]
  for id, it in menuItems.byID:
    if it == nil or it.role == roleNone or it.roleLabel == "" or
        it.label != it.roleLabel:
      continue
    let (label, _) = roleDefaults(it.role)
    if label != it.label:
      it.label = label
      it.roleLabel = label
      changed.add it.snapshotLocked()
  menuMu.release()
  if changed.len == 0 or not app.isReady():
    return # menus take their labels as run installs them
  let m = app.menu()
  if m != nil:
    backend().setApplicationMenu(m.snapshot())
  for w in allWindows():
    if w.menu != nil and w.native != nil:
      w.native.setMenu(w.menu.snapshot())
  for it in changed:
    backend().updateMenuItem(it)
