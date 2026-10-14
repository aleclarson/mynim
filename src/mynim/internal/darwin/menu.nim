## menu.go: NSMenu construction. Native menu items are tracked per
## owner (the app menu, a tray, a popup) so they can be updated in
## place and released when the owner rebuilds.

const ownerAppMenu = 0

var
  menuOwners = 1
  itemsByID = initTable[int, seq[nativeItem]]()
  nativeRoleSel = {
    "undo": "undo:",
    "redo": "redo:",
    "cut": "cut:",
    "copy": "copy:",
    "paste": "paste:",
    "pasteAndMatchStyle": "pasteAsPlainText:",
    "delete": "delete:",
    "selectAll": "selectAll:",
    "minimize": "performMiniaturize:",
    "zoom": "performZoom:",
    "close": "performClose:",
    "front": "arrangeInFront:",
    "togglefullscreen": "toggleFullScreen:",
    "about": "orderFrontStandardAboutPanel:",
    "hide": "hide:",
    "hideOthers": "hideOtherApplications:",
    "unhide": "unhideAllApplications:",
    "quit": "terminate:",
    "startSpeaking": "startSpeaking:",
    "stopSpeaking": "stopSpeaking:",
  }.toTable

proc newOwner(): int =
  inc menuOwners
  menuOwners

proc track(owner, itemID: int, item: id) =
  itemsByID.mgetOrPut(itemID, @[]).add nativeItem(
    owner: owner, item: retain(item))

proc dropOwner(owner: int) =
  var empty: seq[int]
  var reassign: seq[tuple[k: int, v: seq[nativeItem]]]
  for itemID, list in itemsByID:
    var kept: seq[nativeItem]
    for n in list:
      if n.owner == owner:
        release(n.item)
      else:
        kept.add n
    if kept.len == 0:
      empty.add itemID
    else:
      reassign.add (itemID, kept)
  for itemID in empty:
    itemsByID.del(itemID)
  for (k, v) in reassign:
    itemsByID[k] = v

## buildMenu creates an autoreleased NSMenu.
proc buildMenu*(b: Backend, m: Menu, title: string, owner: int): id

## keyEquivalent converts an accelerator to an NSMenuItem key
## equivalent and modifier mask.
proc keyEquivalent(acc: string): tuple[key: string, mods: uint] =
  if acc == "":
    return ("", 0)
  var a: Accelerator
  try:
    a = accelerator.parse(acc, "darwin")
  except CatchableError:
    return ("", 0)
  var mods = 0u
  if a.has(`super`):
    mods = mods or (1 shl 20)
  if a.has(ctrl):
    mods = mods or (1 shl 18)
  if a.has(alt):
    mods = mods or (1 shl 19)
  if a.has(shift):
    mods = mods or (1 shl 17)
  if a.key.len == 1:
    return (a.key, mods)
  let named = {
    "Enter": "\r", "Tab": "\t", "Space": " ", "Backspace": "\x08",
    "Delete": "\uF728", "Escape": "\x1b",
    "Up": "\uF700", "Down": "\uF701", "Left": "\uF702",
    "Right": "\uF703", "Home": "\uF729", "End": "\uF72B",
    "PageUp": "\uF72C", "PageDown": "\uF72D", "Insert": "\uF727",
    "PrintScreen": "\uF72E",
  }.toTable
  if named.hasKey(a.key):
    return (named[a.key], mods)
  if a.key.len > 1 and a.key[0] == 'F':
    var n = 0
    try:
      n = parseInt(a.key[1 .. ^1])
    except ValueError:
      return ("", 0)
    if n >= 1 and n <= 24:
      return ($Rune(0xF704 + n - 1), mods)
  ("", 0)

proc applyItemState(item: id, it: MenuItem) =
  discard send(item, "setEnabled:", argu(it.enabled))
  discard send(item, "setHidden:", argu(not it.visible))
  var state = 0u
  if it.checked and (it.`type` == menuItemCheckbox or
      it.`type` == menuItemRadio):
    state = 1
  discard send(item, "setState:", argu(state))
  if it.toolTip != "":
    discard send(item, "setToolTip:", argu(nsString(it.toolTip)))

proc buildItem*(b: Backend, it: MenuItem, owner: int): id =
  var action = sel("mynimMenuItemClicked:")
  var target = b.menuTarget
  if nativeRoleSel.hasKey(it.role):
    action = sel(nativeRoleSel[it.role])
    target = nil
  if it.submenu != nil:
    action = nil
    target = nil
  let (key, mods) = keyEquivalent(it.accelerator)
  let item = autorelease(send(send(`class`("NSMenuItem"), "alloc"),
    "initWithTitle:action:keyEquivalent:",
    argu(nsString(it.label)), argu(action), argu(nsString(key))))
  if key != "":
    discard send(item, "setKeyEquivalentModifierMask:", argu(mods))
  discard send(item, "setTarget:", argu(target))
  discard send(item, "setTag:", argu(it.id))
  applyItemState(item, it)
  if it.submenu != nil:
    let sub = b.buildMenu(it.submenu, it.label, owner)
    discard send(item, "setSubmenu:", argu(sub))
    case it.role
    of "services":
      discard send(b.app, "setServicesMenu:", argu(sub))
    of "window", "windowMenu":
      discard send(b.app, "setWindowsMenu:", argu(sub))
    of "help":
      discard send(b.app, "setHelpMenu:", argu(sub))
    else:
      discard
  track(owner, it.id, item)
  item

proc registerMenuTarget*() =
  discard classDef("MyNimMenuTarget", "NSObject", @[], @[
    methodDef("mynimMenuItemClicked:",
      cast[pointer](proc(self: id, cmd: SEL, item: id) {.cdecl.} =
        theBackend.h.menuItemClicked(sendInt(item, "tag"))),
      "v@:@@"),
  ])

method setApplicationMenu*(b: Backend, m: Menu) =
  withPool(proc() =
    dropOwner(ownerAppMenu)
    if m == nil:
      discard send(b.app, "setMainMenu:", argu(0))
      return
    discard send(b.app, "setMainMenu:",
                 argu(b.buildMenu(m, "", ownerAppMenu))))

## buildMenu creates an autoreleased NSMenu.
proc buildMenu*(b: Backend, m: Menu, title: string, owner: int): id =
  let menu = autorelease(send(send(`class`("NSMenu"), "alloc"),
    "initWithTitle:", argu(nsString(title))))
  discard send(menu, "setAutoenablesItems:", argu(0))
  for it in m.items:
    if it.`type` == menuItemSeparator:
      let item = send(`class`("NSMenuItem"), "separatorItem")
      discard send(item, "setHidden:", argu(not it.visible))
      discard send(menu, "addItem:", argu(item))
      track(owner, it.id, item)
      continue
    let item = b.buildItem(it, owner)
    discard send(menu, "addItem:", argu(item))
    if it.role == "zoomIn":
      ## Also accept Cmd+= (no shift) like other macOS apps.
      let alt = b.buildItem(MenuItem(id: it.id, label: it.label,
        role: it.role, accelerator: "CmdOrCtrl+=",
        enabled: it.enabled), owner)
      discard send(alt, "setHidden:", argu(1))
      if respondsTo(alt, "setAllowsKeyEquivalentWhenHidden:"):
        discard send(alt, "setAllowsKeyEquivalentWhenHidden:", argu(1))
      discard send(menu, "addItem:", argu(alt))
  menu




method updateMenuItem*(b: Backend, it: MenuItem) =
  withPool(proc() =
    let (key, mods) = keyEquivalent(it.accelerator)
    for n in itemsByID.getOrDefault(it.id):
      ## The hidden Cmd+= twin of "Zoom In" only follows the enabled
      ## state.
      if it.role == "zoomIn" and sendBool(n.item, "isHidden") and
          respondsTo(n.item, "allowsKeyEquivalentWhenHidden") and
          sendBool(n.item, "allowsKeyEquivalentWhenHidden"):
        discard send(n.item, "setEnabled:", argu(it.enabled))
        continue
      if it.`type` != menuItemSeparator:
        discard send(n.item, "setTitle:", argu(nsString(it.label)))
        let sub = send(n.item, "submenu")
        if not sub.isNil:
          discard send(sub, "setTitle:", argu(nsString(it.label)))
        discard send(n.item, "setKeyEquivalent:", argu(nsString(key)))
        discard send(n.item, "setKeyEquivalentModifierMask:", argu(mods))
      applyItemState(n.item, it))

method popupMenu*(b: Backend, m: Menu, pw: platform.Window,
                  pos: ref platform.Point) =
  withPool(proc() =
    let owner = newOwner()
    defer: dropOwner(owner)
    let menu = b.buildMenu(m, "", owner)
    var view: id
    var loc: NSPoint
    if pw of macWindow:
      let w = macWindow(pw)
      if w != nil and not w.closed:
        view = w.web
        if w.surface != nil:
          view = w.surface.view
        if pos != nil:
          loc = NSPoint(x: float64(pos.x), y: float64(pos.y))
          if not sendBool(view, "isFlipped"):
            loc.y = msgRect(view, sel("bounds")).size.height - loc.y
        else:
          let p = msgPoint(w.win,
                           sel("mouseLocationOutsideOfEventStream"))
          loc = msgPointFromView(view, sel("convertPoint:fromView:"),
                                 p, nil)
    else:
      loc = msgPoint(`class`("NSEvent"), sel("mouseLocation"))
    if m.rightToLeft:
      ## NSUserInterfaceLayoutDirectionRightToLeft lays the items out
      ## from the right and opens submenus to the left. A menu popped
      ## up in a view takes the view's direction, which the surface has
      ## only while the menu shows.
      discard send(menu, "setUserInterfaceLayoutDirection:", argu(1))
      if not view.isNil:
        let was = sendInt(view, "userInterfaceLayoutDirection")
        discard send(view, "setUserInterfaceLayoutDirection:", argu(1))
        defer: discard send(view, "setUserInterfaceLayoutDirection:",
                            argu(was))
    discard msgPopUpMenu(menu,
      sel("popUpMenuPositioningItem:atLocation:inView:"), nil, loc, view))

## --- Tray icons (NSStatusItem) ---

proc registerTrayTarget*() =
  discard classDef("MyNimTrayTarget", "NSObject", @[], @[
    methodDef("mynimTrayClicked:",
      cast[pointer](proc(self: id, cmd: SEL, sender: id) {.cdecl.} =
        let t = theBackend.trays.getOrDefault(sender)
        if t == nil:
          return
        let ev = send(theBackend.app, "currentEvent")
        ## NSEventTypeRightMouseUp
        if not ev.isNil and sendInt(ev, "type") == 4:
          t.h.rightClicked()
        else:
          t.h.clicked()),
      "v@:@@"),
  ])

method newTray*(b: Backend, h: TrayHandler):
    tuple[t: Tray, err: ref CatchableError] =
  if trayTarget.isNil:
    trayTarget = alloc("MyNimTrayTarget")
  let t = tray(b: b, h: h, owner: newOwner())
  withPool(proc() =
    let bar = send(`class`("NSStatusBar"), "systemStatusBar")
    ## NSVariableStatusItemLength
    t.item = retain(msgFloatID(bar, sel("statusItemWithLength:"), -1))
    t.button = send(t.item, "button")
    discard send(t.button, "setTarget:", argu(trayTarget))
    discard send(t.button, "setAction:", argu(sel("mynimTrayClicked:")))
    ## left and right mouse up
    discard send(t.button, "sendActionOn:", argu((1 shl 2) or (1 shl 4))))
  b.trays[t.button] = t
  (Tray(t), nil)

method setImage*(t: tray, png: seq[byte], `template`: bool) =
  var err: ref CatchableError = nil
  withPool(proc() =
    let img = autorelease(send(send(`class`("NSImage"), "alloc"),
      "initWithData:", argu(nsData(png))))
    if img.isNil:
      err = errInvalidImage()
      return
    ## Menu bar icons are 18 points tall.
    let size = msgSize(img, sel("size"))
    if size.height > 0:
      msgSetSize(img, sel("setSize:"),
        NSSize(width: size.width * 18 / size.height, height: 18))
    discard send(img, "setTemplate:", argu(`template`))
    discard send(t.button, "setImage:", argu(img)))
  if err != nil:
    raise err

method setTitle*(t: tray, title: string) =
  withPool(proc() =
    discard send(t.button, "setTitle:", argu(nsString(title))))

method setToolTip*(t: tray, tip: string) =
  withPool(proc() =
    discard send(t.button, "setToolTip:", argu(nsString(tip))))

method setMenu*(t: tray, m: Menu) =
  withPool(proc() =
    dropOwner(t.owner)
    if m == nil:
      discard send(t.item, "setMenu:", argu(0))
      return
    discard send(t.item, "setMenu:",
                 argu(t.b.buildMenu(m, "", t.owner))))

method popUpMenu*(t: tray, m: Menu) =
  if m == nil or t.item.isNil:
    return
  withPool(proc() =
    let owner = newOwner()
    defer: dropOwner(owner)
    let menu = t.b.buildMenu(m, "", owner)
    ## Let the status item place and track its menu, including the
    ## button's highlight. Keep its previous menu alive while swapped.
    let previous = retain(send(t.item, "menu"))
    defer: release(previous)
    discard send(t.item, "setMenu:", argu(menu))
    discard send(t.button, "performClick:", argu(0))
    ## Menu actions run in a nested event loop: they may destroy the
    ## tray or install another menu, which we must leave intact.
    if not t.item.isNil and send(t.item, "menu") == menu:
      discard send(t.item, "setMenu:", argu(previous)))

method bounds*(t: tray): platform.Rect =
  let win = send(t.button, "window")
  if win.isNil:
    return platform.Rect()
  rectFromMac(msgRect(win, sel("frame")))

method destroy*(t: tray) =
  if t.item.isNil:
    return
  t.b.trays.del(t.button)
  dropOwner(t.owner)
  discard send(send(`class`("NSStatusBar"), "systemStatusBar"),
               "removeStatusItem:", argu(t.item))
  release(t.item)
  t.item = nil
