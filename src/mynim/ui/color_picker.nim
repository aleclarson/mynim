## HSV color picker and popover color well.

type Hsva = object
  hue, saturation, brightness, alpha: float64

const colorSwatches = [
  ("Red", Color(r: 0xef, g: 0x44, b: 0x44, a: 255)),
  ("Orange", Color(r: 0xf9, g: 0x73, b: 0x16, a: 255)),
  ("Yellow", Color(r: 0xea, g: 0xb3, b: 0x08, a: 255)),
  ("Green", Color(r: 0x22, g: 0xc5, b: 0x5e, a: 255)),
  ("Teal", Color(r: 0x14, g: 0xb8, b: 0xa6, a: 255)),
  ("Blue", Color(r: 0x3b, g: 0x82, b: 0xf6, a: 255)),
  ("Indigo", Color(r: 0x63, g: 0x66, b: 0xf1, a: 255)),
  ("Purple", Color(r: 0xa8, g: 0x55, b: 0xf7, a: 255)),
  ("Pink", Color(r: 0xec, g: 0x48, b: 0x99, a: 255)),
  ("Brown", Color(r: 0x92, g: 0x40, b: 0x0e, a: 255)),
  ("Gray", Color(r: 0x71, g: 0x71, b: 0x7a, a: 255)),
  ("Black", Color(r: 0, g: 0, b: 0, a: 255))]

proc unit(value: float64): float64 =
  if classify(value) in {fcNan, fcInf, fcNegInf}: 0
  else: min(max(value, 0.0), 1.0)

proc colorByte(value: float64): uint8 =
  uint8(round(unit(value) * 255))

proc toHsva(color: Color): Hsva =
  let
    red = color.r.float64 / 255
    green = color.g.float64 / 255
    blue = color.b.float64 / 255
    high = max(red, max(green, blue))
    low = min(red, min(green, blue))
    delta = high - low
  var hue = 0.0
  if delta > 0:
    if high == red:
      hue = 60 * ((green - blue) / delta)
      if hue < 0: hue += 360
    elif high == green:
      hue = 60 * ((blue - red) / delta + 2)
    else:
      hue = 60 * ((red - green) / delta + 4)
  result = Hsva(hue: hue,
    saturation: if high > 0: delta / high else: 0,
    brightness: high, alpha: color.a.float64 / 255)

proc toColor(value: Hsva): Color =
  let hue = value.hue - floor(value.hue / 360) * 360
  let sector = hue / 60
  let chroma = unit(value.saturation) * unit(value.brightness)
  let sectorMod = sector - floor(sector / 2) * 2
  let second = chroma * (1 - abs(sectorMod - 1))
  var red, green, blue: float64
  case int(floor(sector))
  of 0: (red, green) = (chroma, second)
  of 1: (red, green) = (second, chroma)
  of 2: (green, blue) = (chroma, second)
  of 3: (green, blue) = (second, chroma)
  of 4: (red, blue) = (second, chroma)
  else: (red, blue) = (chroma, second)
  let offset = unit(value.brightness) - chroma
  Color(r: colorByte(red + offset), g: colorByte(green + offset),
        b: colorByte(blue + offset), a: colorByte(value.alpha))

proc newColorPickerState(color: Color): ColorPickerState =
  let value = toHsva(color)
  ColorPickerState(hue: value.hue, saturation: value.saturation,
    brightness: value.brightness, alpha: value.alpha,
    lastColor: color, hex: $color)

proc hideFromAccessibility(e: Element) =
  let n = e.node
  if n != nil:
    n[].accessHidden = true

proc checkerboard(c: Context; parent: Element; columns, rows: int) =
  if columns <= 0 or rows <= 0:
    return
  discard parent.children(proc() =
    for row in 0..<rows:
      for column in 0..<columns:
        let checker = c.box().absolute()
          .leftPercent(100'f32 * float32(column) / float32(columns))
          .topPercent(100'f32 * float32(row) / float32(rows))
          .widthPercent(100'f32 / float32(columns))
          .heightPercent(100'f32 / float32(rows))
        checker.hideFromAccessibility()
        discard checker.background(
          if (row + column) mod 2 == 0: rgb(255, 255, 255)
          else: rgb(204, 204, 204))
  )

proc previewBox(c: Context; color: Color; width, height: float32;
                theme: Theme): Element =
  result = c.box().size(width, height).radius(theme.space(1))
    .border(1, theme.border).clip().shrink(0)
  result.hideFromAccessibility()
  discard result.children(proc() =
    let checks = c.box().absolute().fill()
    checks.hideFromAccessibility()
    discard checks.clip()
    checkerboard(c, checks, 4, 4)
    let fill = c.box().absolute().fill().background(color)
    fill.hideFromAccessibility()
  )

proc colorPlaneBase(c: Context; saturation, brightness: var float64): Element =
  result = c.box().focusable().focusRing(false)
  let n = result.node
  if n == nil:
    return
  n[].colorPlane = true
  n[].colorPlaneSaturation = unit(saturation)
  n[].colorPlaneBrightness = unit(brightness)
  n[].accessRole = platform.roleSlider
  n[].accessRoleSet = true
  n[].hasAccessRange = true
  n[].accessMin = 0
  n[].accessMax = 100
  n[].accessNow = round(unit(saturation) * 100)
  n[].accessStep = 1
  n[].accessDescription = $int(round(unit(saturation) * 100)) &
    "% saturation, " & $int(round(unit(brightness) * 100)) & "% brightness"
  n[].accessValue = $int(round(unit(saturation) * 100)) & "% saturation, " &
    $int(round(unit(brightness) * 100)) & "% brightness"
  n[].label = "Saturation and brightness"
  let owner = c.owner
  let identity = n[].identity
  let base = ColorPlaneValue(saturation: unit(saturation),
                            brightness: unit(brightness))
  n[].accessStepHandler = proc(delta: float64) =
    let current = owner.pendingColorPlanes.getOrDefault(identity, base)
    let next = ColorPlaneValue(
      saturation: unit(current.saturation + delta / 100),
      brightness: current.brightness)
    if next != current:
      owner.pendingColorPlanes[identity] = next
  if owner.pendingColorPlanes.hasKey(identity):
    let pending = owner.pendingColorPlanes[identity]
    saturation = pending.saturation
    brightness = pending.brightness
    n[].colorPlaneSaturation = saturation
    n[].colorPlaneBrightness = brightness
    n[].accessNow = round(saturation * 100)
    n[].accessDescription = $int(round(saturation * 100)) &
      "% saturation, " & $int(round(brightness * 100)) & "% brightness"
    n[].accessValue = $int(round(saturation * 100)) & "% saturation, " &
      $int(round(brightness * 100)) & "% brightness"
    result.markBoundValueChanged()

proc addHueTrack(c: Context; track: Element) =
  const hues = [
    Color(r: 255, g: 0, b: 0, a: 255),
    Color(r: 255, g: 255, b: 0, a: 255),
    Color(r: 0, g: 255, b: 0, a: 255),
    Color(r: 0, g: 255, b: 255, a: 255),
    Color(r: 0, g: 0, b: 255, a: 255),
    Color(r: 255, g: 0, b: 255, a: 255),
    Color(r: 255, g: 0, b: 0, a: 255)]
  discard track.children(proc() =
    let row = c.row().fill()
    row.hideFromAccessibility()
    discard row.children(proc() =
      for index in 0..<6:
        let segment = c.box().grow().fillHeight()
          .gradient(hues[index], hues[index + 1], 90)
        segment.hideFromAccessibility()
    )
  )

proc addOpacityTrack(c: Context; track: Element; opaque: Color) =
  discard track.children(proc() =
    checkerboard(c, track, 16, 2)
    let tint = c.box().absolute().fill()
      .gradient(opaque.alpha(0), opaque, 90)
    tint.hideFromAccessibility()
  )

proc channelSlider(c: Context; value: var float64; high: float64;
                   name: string; opacityColor: Color): Element =
  let theme = c.theme
  let knob = theme.space(3)
  let trackHeight = theme.space(1.5)
  let centerY = theme.space(2.5)
  result = c.sliderBase(value, 0, high).height(theme.space(5))
    .paddingX(knob / 2).label(name).focusRing(false).shrink(0)
  let amount = if high > 0: unit(value / high).float32 else: 0'f32
  let slider = result
  discard result.children(proc() =
    let track = c.box().absolute().left(0).right(0)
      .top(centerY - trackHeight / 2).height(trackHeight)
      .radius(trackHeight / 2).clip()
    track.hideFromAccessibility()
    if name == "Hue":
      addHueTrack(c, track)
    else:
      addOpacityTrack(c, track, opacityColor)
    let thumb = c.box().absolute().leftPercent(amount * 100)
      .top(centerY - knob / 2).size(knob, knob)
      .margin(0, 0, 0, -knob / 2).radius(knob / 2)
      .background(theme.background).border(1, theme.border)
      .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.2'f32))
    thumb.hideFromAccessibility()
  )

proc colorPicker*(c: Context; color: var Color): Element =
  ## Creates an HSV color picker with a saturation/brightness plane, hue and
  ## opacity sliders, an editable hex value, and common color swatches.
  let theme = c.theme
  result = c.column().gap(theme.space(2.5)).width(theme.space(60)).shrink(0)
  let root = result.node
  if root == nil:
    return
  root[].colorPickerRoot = true
  root[].accessRole = platform.roleGroup
  root[].accessRoleSet = true
  root[].label = "Color picker"
  let identity = root[].identity
  let colorPtr = addr color
  let pickerRoot = result
  var state = c.owner.colorPickerStates.getOrDefault(identity)
  if state == nil:
    state = newColorPickerState(colorPtr[])
    c.owner.colorPickerStates[identity] = state
  elif colorPtr[] != state.lastColor:
    state = newColorPickerState(colorPtr[])
    c.owner.colorPickerStates[identity] = state

  let setColor = proc(value: Hsva; syncHex = true) =
    var value = value
    value.saturation = unit(value.saturation)
    value.brightness = unit(value.brightness)
    value.alpha = unit(value.alpha)
    state.hue = value.hue
    state.saturation = value.saturation
    state.brightness = value.brightness
    state.alpha = value.alpha
    let next = value.toColor()
    if next != colorPtr[]:
      colorPtr[] = next
      pickerRoot.markBoundValueChanged()
    state.lastColor = colorPtr[]
    state.hex = $colorPtr[]
    if syncHex and state.hexFieldIdentity != 0:
      let rawClient = c.owner.textInputClients.getOrDefault(
        state.hexFieldIdentity)
      if rawClient of TextFieldClient:
        let client = TextFieldClient(rawClient)
        client.setFieldText(state.hex)
        client.rebuildFieldLayout()
        let fieldSlot = c.owner.idSlots.getOrDefault(
          state.hexFieldIdentity, -1)
        if fieldSlot > 0 and fieldSlot < c.owner.nodes.len:
          c.owner.nodes[fieldSlot].textValue = client.fieldDisplayText()

  discard result.children(proc() =
    var saturation = state.saturation
    var brightness = state.brightness
    let plane = c.colorPlaneBase(saturation, brightness)
      .height(theme.space(40)).radius(theme.radius).border(1, theme.border)
      .clip().label("Saturation and brightness")
    let hueColor = Hsva(hue: state.hue, saturation: 1,
                        brightness: 1, alpha: 1).toColor()
    let markerSize = theme.space(3.5)
    let planeNode = plane
    discard plane.children(proc() =
      let sat = c.box().absolute().fill()
        .gradient(rgb(255, 255, 255), hueColor, 90)
      sat.hideFromAccessibility()
      let shade = c.box().absolute().fill()
        .gradient(rgba(0, 0, 0, 0), rgb(0, 0, 0), 180)
      shade.hideFromAccessibility()
      let marker = c.box().absolute()
        .leftPercent(saturation.float32 * 100)
        .topPercent((1 - brightness).float32 * 100)
        .size(markerSize + 2, markerSize + 2)
        .margin(-(markerSize + 2) / 2, 0, 0, -(markerSize + 2) / 2)
        .radius((markerSize + 2) / 2).border(1, rgba(0, 0, 0, 0.3'f32))
      marker.hideFromAccessibility()
      discard marker.children(proc() =
        let center = c.box().size(markerSize, markerSize).radius(markerSize / 2)
          .border(2, rgb(255, 255, 255))
        center.hideFromAccessibility()
      )
    )
    if plane.focusVisible():
      discard plane.shadow(0, 0, 0, 2, theme.focus)
    if plane.changed():
      setColor(Hsva(hue: state.hue, saturation: saturation,
                    brightness: brightness, alpha: state.alpha))

    var hue = state.hue
    let hueSlider = c.channelSlider(hue, 360, "Hue", transparent)
    if hueSlider.changed():
      setColor(Hsva(hue: hue, saturation: state.saturation,
                    brightness: state.brightness, alpha: state.alpha))

    var alpha = state.alpha
    let opaque = Hsva(hue: state.hue, saturation: state.saturation,
                      brightness: state.brightness, alpha: 1).toColor()
    let opacitySlider = c.channelSlider(alpha, 1, "Opacity", opaque)
    if opacitySlider.changed():
      setColor(Hsva(hue: state.hue, saturation: state.saturation,
                    brightness: state.brightness, alpha: alpha))

    let valueRow = c.row().gap(theme.space(2)).alignItems(Align.Center)
    if valueRow.node != nil:
      valueRow.node[].accessRole = platform.roleGroup
      valueRow.node[].accessRoleSet = true
      valueRow.node[].label = "Color value"
    discard valueRow.children(proc() =
        discard c.previewBox(colorPtr[], theme.space(7), theme.space(7), theme)
        let input = c.textInput(state.hex).label("Hex").grow()
        if input.node != nil:
          state.hexFieldIdentity = input.node[].identity
        if input.changed():
          try:
            let parsed = hexColor(state.hex)
            let typed = state.hex
            setColor(parsed.toHsva(), syncHex = false)
            state.hex = typed
          except ValueError:
            discard
        if not input.focused() and state.hex != $colorPtr[]:
          state.hex = $colorPtr[]
      )

    let swatches = c.grid().columnTracks(fr(1), fr(1), fr(1), fr(1),
      fr(1), fr(1)).gap(theme.space(1.5))
    if swatches.node != nil:
      swatches.node[].accessRole = platform.roleGroup
      swatches.node[].accessRoleSet = true
      swatches.node[].label = "Common colors"
    discard swatches.children(proc() =
        for swatchData in colorSwatches:
          let name = swatchData[0]
          let swatchColor = swatchData[1]
          let swatch = c.buttonBase().height(theme.space(5))
            .radius(theme.radius).background(swatchColor)
            .label(name).tooltip(name)
          if colorPtr[] == swatchColor:
            discard swatch.border(2, theme.text)
          if swatch.clicked():
            setColor(swatchColor.toHsva())
      )
  )

proc colorWell*(c: Context; color: var Color): Element =
  ## Creates a color swatch that opens the HSV color picker in a popover.
  let theme = c.theme
  let colorPtr = addr color
  result = c.buttonBase().padding(theme.space(1)).radius(theme.radius)
    .background(theme.surface).border(1, theme.border).shrink(0)
  let node = result.node
  if node == nil:
    return
  node[].accessRole = platform.roleColorWell
  node[].accessRoleSet = true
  node[].accessValue = $colorPtr[]
  node[].accessDescription = $colorPtr[]
  let identity = node[].identity
  var popoverState = c.owner.popoverStates.getOrDefault(identity)
  if popoverState == nil:
    popoverState = PopoverState(anchorIdentity: identity)
    c.owner.popoverStates[identity] = popoverState
  var open = popoverState.open
  if result.clicked():
    open = not open
  let anchor = result
  discard result.children(proc() =
    discard c.previewBox(colorPtr[], theme.space(9), theme.space(5), theme)
  )
  discard c.popover(anchor, open, proc(panel: Element) =
    let picker = c.colorPicker(colorPtr[])
    if picker.changed():
      anchor.markBoundValueChanged()
  )
  let anchorNode = anchor.node
  if anchorNode == nil:
    return
  if popoverState.open:
    anchorNode[].accessExtraStates = anchorNode[].accessExtraStates or
      platform.accessExpanded
  anchorNode[].accessValue = $colorPtr[]
  anchorNode[].accessDescription = $colorPtr[]
