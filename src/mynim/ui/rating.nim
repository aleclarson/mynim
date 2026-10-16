## A keyboard- and pointer-accessible star rating control.

proc ratingStar(data: string): Svg =
  let parsed = parseSvg(data)
  if parsed.error.len > 0:
    raise newException(ValueError, "ui: could not parse rating star SVG")
  parsed.svg

let filledRatingStar = ratingStar("""
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <path d="M12 2.25 14.9 8.4 21.7 9.4 16.8 14.1 17.9 20.8 12 17.4 6.1 20.8 7.2 14.1 2.3 9.4 9.1 8.4Z" fill="currentColor"/>
</svg>
""")

let emptyRatingStar = ratingStar("""
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <path d="M12 2.25 14.9 8.4 21.7 9.4 16.8 14.1 17.9 20.8 12 17.4 6.1 20.8 7.2 14.1 2.3 9.4 9.1 8.4Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>
</svg>
""")

proc rating*(c: Context; value: var int; maximum: int): Element =
  ## Creates a star rating. Clicking the selected star clears it; arrows and
  ## Home/End change the value. Label the slider for assistive technology.
  if maximum <= 0:
    raise newException(ValueError, "ui: rating maximum must be positive")
  value = min(max(value, 0), maximum)
  var frameValue = float64(value)
  result = c.sliderBase(frameValue, 0, float64(maximum)).step(1)
  let node = result.node
  if node == nil:
    return
  node.rating = true
  node.row = true
  node.gapX = 0
  result = result.shrink(0)
  if result.changed():
    value = int(round(frameValue))

  let theme = c.theme
  let starSize = theme.fontSize * 1.25'f32
  var stars: seq[Element]
  discard result.children(proc() =
    for _ in 0..<maximum:
      stars.add(c.box().size(starSize, starSize).shrink(0))
  )
  var hoverIndex = -1
  for index, star in stars:
    if star.hovered():
      hoverIndex = index
  for index, star in stars:
    let filled = if hoverIndex >= 0:
        index <= hoverIndex
      else:
        index < value
    discard star.children(proc() =
      discard c.svg(if filled: filledRatingStar else: emptyRatingStar)
        .fill().svgColor(if filled: theme.warning else: theme.textMuted)
    )
