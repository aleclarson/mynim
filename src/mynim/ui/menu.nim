## Small menu builder used by native UI context menus.

proc newUiMenu(chosenId: int; chosenLabel: string;
               rightToLeft: bool): Menu =
  Menu(snapshot: platform.Menu(rightToLeft: rightToLeft),
       session: MenuSession(chosenId: chosenId, chosenLabel: chosenLabel))

proc addMenuItem(menu: Menu; label: string;
                 kind: platform.MenuItemType): MenuItem =
  if menu == nil or menu.session == nil:
    return
  inc menu.session.nextId
  let item = platform.MenuItem(id: menu.session.nextId, `type`: kind,
    label: label, enabled: true, visible: true)
  menu.snapshot.items.add(item)
  MenuItem(owner: menu, snapshot: item)

proc item*(menu: Menu; label: string): MenuItem =
  ## Adds a selectable item to the menu.
  menu.addMenuItem(label, platform.menuItemNormal)

proc menuShortcutKey(key: platform.Key): string =
  if key >= platform.key0 and key <= platform.key9:
    return $char(ord('0') + int(uint16(key) - uint16(platform.key0)))
  if key >= platform.keyA and key <= platform.keyZ:
    return $char(ord('A') + int(uint16(key) - uint16(platform.keyA)))
  if key >= platform.keyF1 and key <= platform.keyF12:
    return "F" & $(int(uint16(key) - uint16(platform.keyF1)) + 1)
  case key
  of platform.keyEnter: "Enter"
  of platform.keyEscape: "Escape"
  of platform.keyBackspace: "Backspace"
  of platform.keyTab: "Tab"
  of platform.keySpace: "Space"
  of platform.keyDelete: "Delete"
  of platform.keyInsert: "Insert"
  of platform.keyHome: "Home"
  of platform.keyEnd: "End"
  of platform.keyPageUp: "PageUp"
  of platform.keyPageDown: "PageDown"
  of platform.keyLeft: "Left"
  of platform.keyRight: "Right"
  of platform.keyUp: "Up"
  of platform.keyDown: "Down"
  of platform.keyMinus: "-"
  of platform.keyEqual: "="
  of platform.keyComma: ","
  of platform.keyPeriod: "."
  of platform.keySlash: "/"
  of platform.keySemicolon: ";"
  of platform.keyQuote: "'"
  of platform.keyBracketLeft: "["
  of platform.keyBracketRight: "]"
  of platform.keyBackslash: "\\"
  of platform.keyBackquote: "`"
  else: ""

proc shortcut*(item: MenuItem; mods: platform.Modifiers;
               key: platform.Key): MenuItem =
  ## Shows the key binding beside an item in a native context menu.
  if item == nil or item.snapshot == nil:
    return item
  let keyName = menuShortcutKey(key)
  let knownMods = platform.modSuper or platform.modCtrl or platform.modAlt or
    platform.modShift
  if keyName.len == 0 or (mods and knownMods) != mods:
    item.snapshot.accelerator = ""
    return item
  var parts: seq[string]
  for (modifier, name) in [(platform.modSuper, "Super"),
      (platform.modCtrl, "Ctrl"), (platform.modAlt, "Alt"),
      (platform.modShift, "Shift")]:
    if (mods and modifier) != 0:
      parts.add(name)
  parts.add(keyName)
  item.snapshot.accelerator = parts.join("+")
  item

proc separator*(menu: Menu) =
  ## Adds a separator to the menu.
  discard menu.addMenuItem("", platform.menuItemSeparator)

proc disabled*(item: MenuItem; value = true): MenuItem =
  ## Disables the item when value is true.
  if item != nil and item.snapshot != nil:
    item.snapshot.enabled = not value
  item

proc checked*(item: MenuItem; value = true): MenuItem =
  ## Shows a check mark when value is true.
  if item != nil and item.snapshot != nil:
    item.snapshot.`type` = platform.menuItemCheckbox
    item.snapshot.checked = value
  item

proc chosen*(item: MenuItem): bool =
  ## Reports whether the user chose this enabled item.
  if item == nil or item.owner == nil or item.snapshot == nil or
      item.owner.session == nil or not item.snapshot.enabled:
    return false
  result = item.snapshot.id == item.owner.session.chosenId and
    item.owner.session.chosenId != 0 and
    item.snapshot.label == item.owner.session.chosenLabel
  if result:
    item.owner.session.choiceSeen = true
