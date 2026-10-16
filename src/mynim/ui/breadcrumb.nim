## A path of selectable locations.

proc breadcrumbs*(c: Context; items: openArray[string];
                  chosen: var int): Element =
  ## Creates a labeled path; clicking or activating a link reports its index.
  let theme = c.theme
  let entries = @items
  let chosenPtr = addr chosen
  result = c.row().alignItems(Align.Center).gap(theme.space(0.5'f32))
    .minWidth(0)
  let path = result
  let pathNode = path.node
  if pathNode == nil:
    return
  pathNode[].accessRole = platform.roleGroup
  pathNode[].accessRoleSet = true
  discard path.children(proc() =
    for index, item in entries:
      if index > 0:
        let separator = c.text(if c.direction() == Direction.RightToLeft:
          "‹" else: "›").textColor(theme.textMuted)
          .textSize(theme.space(3)).shrink(0)
        let separatorNode = separator.node
        if separatorNode != nil:
          separatorNode[].accessHidden = true

      if index == entries.len - 1:
        let current = c.text(item).textWeight(500).shrink(1).minWidth(0)
        let currentNode = current.node
        if currentNode != nil:
          currentNode[].textMaxLines = 1
      else:
        var link = c.buttonBase().key(index)
          .padding(theme.space(0.5'f32), theme.space(1.5'f32))
          .radius(theme.radius).minWidth(theme.space(6)).shrink(1)
          .label(item)
        let linkNode = link.node
        if linkNode != nil:
          linkNode[].accessRole = platform.roleLink
          linkNode[].accessRoleSet = true
        let hovered = link.hovered()
        if hovered:
          discard link.background(theme.surfaceHover)
        discard link.children(proc() =
          let linkText = c.text(item).textColor(theme.textMuted)
            .shrink(1).minWidth(0)
          let linkTextNode = linkText.node
          if linkTextNode != nil:
            linkTextNode[].textMaxLines = 1
            linkTextNode[].accessHidden = true
        )
        if link.clicked():
          chosenPtr[] = index
          path.markBoundValueChanged()
  )
