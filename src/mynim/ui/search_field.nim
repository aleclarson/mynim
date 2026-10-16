## A themed search box with a clear action.

proc searchField*(c: Context; query: var string): Element =
  ## Creates a labeled search field with a clear button and Escape-to-clear.
  let queryPtr = addr query
  result = c.row().alignItems(Align.Center)
    .gap(c.theme.space(1.5)).padding(c.theme.space(1.5), c.theme.space(2))
    .radius(c.theme.radius).background(c.theme.surface)
    .border(1, c.theme.border)
  let fieldNode = result.node
  if fieldNode == nil:
    return
  discard result.children(proc() =
    let icon = c.text("⌕").textColor(c.theme.textMuted)
      .textSize(c.theme.fontSize).shrink(0)
    let input = c.textInputBase(queryPtr[]).grow(1)
      .minWidth(c.theme.space(15))
    discard input.placeholder("Search")
    discard input.padding(0).background(rgba(0, 0, 0, 0)).borderWidth(0)
    let inputNode = input.node
    if inputNode == nil:
      return
    inputNode[].accessExtraStates = inputNode[].accessExtraStates or
      platform.accessSearch
    fieldNode[].fieldControlSlot = int32(input.slot)
    fieldNode[].labelTargetSlot = int32(input.slot)
    let iconNode = icon.node
    if iconNode != nil:
      iconNode[].accessHidden = true
      iconNode[].focusTargetSlot = int32(input.slot)
    fieldNode[].borderColor = if input.focused(): c.theme.accent
      elif fieldNode[].hovered: c.theme.border.mix(c.theme.text, 0.2'f32)
      else: c.theme.border

    let owner = input.owner
    let identity = inputNode[].identity
    let generation = input.generation
    if queryPtr[].len > 0:
      let clear = c.buttonBase().size(c.theme.space(4), c.theme.space(4))
        .radius(c.theme.space(2))
        .background(c.theme.textMuted.alpha(0.45'f32))
        .label("Clear").tabStop(false)
      let clearNode = clear.node
      if clearNode != nil:
        clearNode[].focusTargetSlot = int32(input.slot)
      discard clear.children(proc() =
        let glyph = c.text("×").textColor(c.theme.background)
          .textSize(c.theme.fontSize)
        let glyphNode = glyph.node
        if glyphNode != nil:
          glyphNode[].accessHidden = true
      )
      discard clear.onClick(proc() =
        if queryPtr[].len > 0:
          queryPtr[].setLen(0)
          discard owner.notifyAction(identity, generation, actionChange)
      )
      discard input.onShortcut(0, platform.keyEscape, proc() =
        if queryPtr[].len > 0:
          queryPtr[].setLen(0)
          discard owner.notifyAction(identity, generation, actionChange)
      )
  )
