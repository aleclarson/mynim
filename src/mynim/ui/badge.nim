## Compact pill labels, commonly used for counts.

proc badge*(c: Context; text: string): Element =
  ## Creates a compact pill with `text` in the current theme's text color.
  let theme = c.theme
  result = c.box().padding(0, theme.space(1.5'f32)).radius(999)
    .background(theme.text.alpha(0.1'f32)).shrink(0)
  discard result.children(proc() =
    let textElement = c.text(text).textSize(theme.fontSize - 2)
    let node = textElement.node
    if node != nil:
      node[].textNoWrap = true
  )
