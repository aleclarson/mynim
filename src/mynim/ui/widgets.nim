## Theme-styled controls built on the stateful bases.

proc checkbox*(c: Context; checked: var bool; label: string): Element =
  ## Creates a themed check box with a label.
  let theme = c.theme
  var frameChecked = checked
  result = c.checkboxBase(frameChecked).gap(theme.space(2))
  if result.changed():
    checked = frameChecked
  result = result.label(label)
  let row = result
  result = result.children(proc() =
    let size = theme.space(4)
    let indicator = c.box().size(size, size).shrink(0)
      .radius(theme.space(1)).center()
    if frameChecked:
      discard indicator.background(theme.accent)
      discard indicator.children(proc() =
        discard c.text("✓").textSize(theme.space(2.5))
          .textColor(theme.accentText)
      )
    else:
      discard indicator.background(theme.background)
        .border(1, theme.border.mix(theme.text, 0.25'f32))
      if row.hovered():
        discard indicator.border(1, theme.accent)
    if label.len > 0:
      discard c.text(label)
  )

proc radio*[T](c: Context; selected: var T; value: T;
               label: string): Element =
  ## Creates a themed radio option with a label.
  let theme = c.theme
  var frameSelection = selected
  result = c.radioBase(frameSelection, value).gap(theme.space(2))
  if result.changed():
    selected = frameSelection
  result = result.label(label)
  let row = result
  let isSelected = frameSelection == value
  result = result.children(proc() =
    let size = theme.space(4)
    let indicator = c.box().size(size, size).shrink(0)
      .radius(size / 2).center()
    if isSelected:
      discard indicator.background(theme.accent)
      discard indicator.children(proc() =
        discard c.box().size(theme.space(1.5), theme.space(1.5))
          .shrink(0).radius(theme.space(1)).background(theme.accentText)
      )
    else:
      discard indicator.background(theme.background)
        .border(1, theme.border.mix(theme.text, 0.25'f32))
      if row.hovered():
        discard indicator.border(1, theme.accent)
    if label.len > 0:
      discard c.text(label)
  )

proc switch*(c: Context; on: var bool): Element =
  ## Creates a themed switch track and knob. Set its accessible name with label().
  let theme = c.theme
  var frameOn = on
  result = c.switchBase(frameOn)
  if result.changed():
    on = frameOn
  let height = theme.space(5)
  let inset = theme.space(0.5)
  let node = result.node
  let rightToLeft = node != nil and node.rightToLeft
  let knobAtEnd = frameOn != rightToLeft
  let offColor = theme.border.mix(theme.text, 0.15'f32)
  result = result.size(theme.space(9), height).padding(inset)
    .justify(if knobAtEnd: Align.End else: Align.Start)
    .alignItems(Align.Center).radius(height / 2)
    .background(if frameOn: theme.accent else: offColor)
  result = result.children(proc() =
    discard c.box().size(height - 2 * inset, height - 2 * inset)
      .shrink(0).radius(height / 2).background(rgb(255, 255, 255))
      .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.25'f32))
  )
