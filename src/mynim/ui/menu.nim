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
