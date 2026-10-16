## Horizontal, keyboard-navigable groups of toolbar controls.

proc toolbar*(c: Context; build: proc() {.closure.}): Element =
  ## Builds a named toolbar with one Tab stop and compact, hover-only controls.
  ## Use label() to give the toolbar an accessible name.
  let theme = c.theme
  result = c.row().alignItems(Align.Center).gap(theme.space(1'f32))
    .padding(theme.space(1'f32)).minWidth(0)
    .focusGroup(FocusOrientation.Horizontal)
  let node = result.node
  if node != nil:
    node[].accessRole = platform.roleToolbar
    node[].accessRoleSet = true
  let previousToolbar = c.toolbarButtons
  c.toolbarButtons = true
  try:
    discard result.children(proc() =
      if build != nil:
        build()
    )
  finally:
    c.toolbarButtons = previousToolbar
