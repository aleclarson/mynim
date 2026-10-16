## Horizontal, keyboard-navigable groups of toolbar controls.

proc toolbar*(c: Context; build: proc() {.closure.}): Element =
  ## Builds a named toolbar with one Tab stop, compact controls, and an
  ## overflow menu for controls that do not fit. Use label() to name it.
  let theme = c.theme
  result = c.row().alignItems(Align.Center).gap(theme.space(1'f32))
    .padding(theme.space(1'f32)).minWidth(0)
    .focusGroup(FocusOrientation.Horizontal)
  let state = ToolbarState()
  let node = result.node
  if node != nil:
    node[].accessRole = platform.roleToolbar
    node[].accessRoleSet = true
    node[].toolbarState = state
  let previousToolbar = c.toolbarButtons
  c.toolbarButtons = true
  try:
    discard result.children(proc() =
      if build != nil:
        build()
      let openMenu = c.openMenu
      let queueClick = c.queueClick
      var moreIdentity = 0'u64
      let more = c.menuButton("More", proc(menu: Menu) =
        for index, entry in state.items:
          if entry.startsGroup and index > 0:
            menu.separator()
          let item = menu.item(entry.label).disabled(entry.disabled)
          if entry.toggle:
            discard item.checked(entry.checked)
          if item.chosen:
            if entry.menuBuilder != nil:
              if openMenu != nil:
                openMenu(moreIdentity, entry.menuBuilder)
            elif queueClick != nil:
              queueClick(entry.identity)
      )
      let moreNode = more.node
      if moreNode != nil:
        moreIdentity = moreNode[].identity
        moreNode[].toolbarMore = true
    )
  finally:
    c.toolbarButtons = previousToolbar
