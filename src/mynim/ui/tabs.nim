## Tab lists with roving focus and accessible selection state.

type TabsParts* = object ## The list and tab builder for a custom tab control.
  listElement: Element
  context: Context
  selected: ptr int
  count: int

proc list*(parts: TabsParts): Element =
  ## Returns the tab list; build its tabs inside the list's children.
  parts.listElement

proc changed*(parts: TabsParts): bool =
  ## Reports whether a tab selection changed during this frame.
  parts.listElement.changed()

proc tab*(parts: TabsParts; index: int): Element =
  ## Creates a focusable tab at index; style it and add its custom content.
  if parts.context == nil or parts.selected == nil:
    return
  if index < 0 or index >= parts.count:
    raise newException(ValueError, "ui: tab index is out of range")
  result = parts.context.row().focusable().shrink(0)
    .onClick(proc() = discard)
  let node = result.node
  if node == nil:
    return
  node.accessRole = platform.roleTab
  node.accessRoleSet = true
  node.activateEnter = false
  if node.clicked and parts.selected[] != index:
    parts.selected[] = index
    result.markBoundValueChanged()
    parts.listElement.markBoundValueChanged()
  if parts.selected[] == index:
    node.accessExtraStates = node.accessExtraStates or
      platform.accessSelected or platform.accessChecked

proc tabsBase*(c: Context; selected: var int; count: int): TabsParts =
  ## Creates a custom tab list. Arrow keys, Home, and End choose and focus tabs.
  ## Use the returned parts only while building this frame.
  let tabCount = max(count, 0)
  if tabCount > 0:
    selected = max(0, min(selected, tabCount - 1))
  let list = c.row().shrink(0).focusGroup(FocusOrientation.Horizontal,
    selects = true)
  let node = list.node
  if node != nil:
    node.accessRole = platform.roleTabList
    node.accessRoleSet = true
  result = TabsParts(listElement: list, context: c,
    selected: addr selected, count: tabCount)

proc tabs*(c: Context; selected: var int;
           labels: openArray[string]): Element =
  ## Creates themed horizontal tabs. Click or arrow keys to choose a label.
  let theme = c.theme
  let tabLabels = @labels
  let parts = c.tabsBase(selected, tabLabels.len)
  let selectedSlot = parts.selected
  let tabList = parts.list().gap(theme.space(1))
  result = tabList.children(proc() =
    for index, label in tabLabels:
      var tab = parts.tab(index).shrink(0).alignItems(Align.Center)
        .padding(theme.space(1.5), theme.space(3)).label(label)
      let isSelected = selectedSlot[] == index
      tab = tab.textColor(if isSelected: theme.text else: theme.textMuted)
      if isSelected:
        tab = tab.borderWidth(0, 0, theme.space(0.5), 0)
          .borderColor(theme.accent)
      elif tab.hovered():
        tab = tab.textColor(theme.text)
      discard tab.children(proc() =
        discard c.text(label).textWeight(if isSelected: 600 else: 400)
      )
  )
