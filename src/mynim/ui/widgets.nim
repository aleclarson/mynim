## Text helpers and theme-styled controls built on the stateful bases.

type
  TextFormatKind = enum
    tfOther, tfString, tfChar, tfSigned, tfUnsigned, tfFloat, tfBool
  ## One value accepted by textf's heterogeneous argument list.
  TextFormatArg* = object
    kind: TextFormatKind
    text: string
    signedValue: int64
    unsignedValue: uint64
    floatValue: float64
    boolValue: bool

proc toTextFormatArg*[T](value: T): TextFormatArg =
  ## Converts a value for textf's format string.
  result.text = $value
  when T is string:
    result.kind = tfString
    result.text = value
  elif T is cstring:
    result.kind = tfString
    result.text = $value
  elif T is char:
    result.kind = tfChar
  elif T is bool:
    result.kind = tfBool
    result.boolValue = value
  elif T is SomeSignedInt:
    result.kind = tfSigned
    result.signedValue = int64(value)
  elif T is SomeUnsignedInt:
    result.kind = tfUnsigned
    result.unsignedValue = uint64(value)
  elif T is SomeFloat:
    result.kind = tfFloat
    result.floatValue = float64(value)
  else:
    result.kind = tfOther

proc textFormatType(value: TextFormatArg): string =
  case value.kind
  of tfString: "string"
  of tfChar: "int32"
  of tfSigned: "int"
  of tfUnsigned: "uint"
  of tfFloat: "float64"
  of tfBool: "bool"
  of tfOther: "value"

proc radixDigits(value: uint64; radix: uint64; uppercase: bool): string =
  const digits = "0123456789abcdef"
  const upperDigits = "0123456789ABCDEF"
  var n = value
  while n > 0:
    let digit = int(n mod radix)
    result.add(if uppercase: upperDigits[digit] else: digits[digit])
    n = n div radix
  if result.len == 0:
    result = "0"
  result.reverse()

proc quoteText(value: string): string =
  result.add('"')
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else: result.add(ch)
  result.add('"')

proc formatRune(codepoint: int64): string =
  if codepoint < 0 or codepoint > 0x10ffff or
      codepoint in 0xd800'i64 .. 0xdfff'i64:
    return "\uFFFD"
  $Rune(int(codepoint))

proc formatRune(codepoint: uint64): string =
  if codepoint > 0x10ffff'u64:
    return "\uFFFD"
  formatRune(int64(codepoint))

proc formatTextArg(value: TextFormatArg; verb: char; flags: set[char];
                   width, precision: int): string =
  var body = ""
  var prefix = ""
  var sign = ""
  var numeric = false
  var valid = true

  case verb
  of 'v':
    body = value.text
    numeric = value.kind in {tfSigned, tfUnsigned, tfFloat}
  of 'T':
    body = value.textFormatType()
  of 's':
    if value.kind in {tfString, tfChar, tfOther}:
      body = value.text
    else:
      valid = false
  of 't':
    if value.kind == tfBool:
      body = if value.boolValue: "true" else: "false"
    else:
      valid = false
  of 'q':
    if value.kind in {tfString, tfChar}:
      body = quoteText(value.text)
    elif value.kind in {tfSigned, tfUnsigned}:
      let runeText = if value.kind == tfSigned:
          formatRune(value.signedValue)
        else:
          formatRune(value.unsignedValue)
      body = quoteText(runeText)
    else:
      valid = false
  of 'c':
    if value.kind in {tfSigned, tfUnsigned}:
      body = if value.kind == tfSigned:
          formatRune(value.signedValue)
        else:
          formatRune(value.unsignedValue)
    else:
      valid = false
  of 'd', 'b', 'o', 'x', 'X':
    if value.kind in {tfSigned, tfUnsigned}:
      numeric = true
      var magnitude: uint64
      if value.kind == tfSigned:
        if value.signedValue < 0:
          sign = "-"
          magnitude = uint64(-(value.signedValue + 1)) + 1'u64
        else:
          magnitude = uint64(value.signedValue)
      else:
        magnitude = value.unsignedValue
      case verb
      of 'd': body = $magnitude
      of 'b':
        body = radixDigits(magnitude, 2, false)
        if '#' in flags: prefix = "0b"
      of 'o':
        body = radixDigits(magnitude, 8, false)
        if '#' in flags and body[0] != '0': prefix = "0"
      of 'x', 'X':
        body = radixDigits(magnitude, 16, verb == 'X')
        if '#' in flags:
          prefix = if verb == 'X': "0X" else: "0x"
      else: discard
      if precision > body.len:
        body = repeat('0', precision - body.len) & body
    elif value.kind in {tfString, tfChar} and verb in {'x', 'X'}:
      for ch in value.text:
        let byteDigits = radixDigits(uint64(ord(ch)), 16, verb == 'X')
        if byteDigits.len == 1:
          body.add('0')
        body.add(byteDigits)
      if precision >= 0 and value.text.len > precision:
        body.setLen(precision * 2)
    else:
      valid = false
  of 'f', 'F', 'e', 'E', 'g', 'G':
    if value.kind == tfFloat:
      numeric = true
      let mode = if verb in {'e', 'E'}: ffScientific
        elif verb in {'g', 'G'}: ffDefault else: ffDecimal
      let digits = if precision < 0: 6 else: min(precision, 32)
      body = formatFloat(value.floatValue, mode, digits)
      if verb in {'E', 'G'}:
        for i in 0 ..< body.len:
          if body[i] == 'e': body[i] = 'E'
      if verb in {'g', 'G'} and '#' notin flags:
        let exponent = body.find({'e', 'E'})
        let mantissaEnd = if exponent < 0: body.len else: exponent
        var endIndex = mantissaEnd
        while endIndex > 0 and body[endIndex - 1] == '0':
          dec endIndex
        if endIndex > 0 and body[endIndex - 1] == '.':
          dec endIndex
        if endIndex < mantissaEnd:
          body = if exponent < 0: body[0 ..< endIndex]
            else: body[0 ..< endIndex] & body[mantissaEnd .. ^1]
      if body.len > 0 and body[0] == '-':
        sign = "-"
        body = body[1 .. ^1]
    else:
      valid = false
  else:
    valid = false

  if not valid:
    return "%!" & $verb & "(" & value.textFormatType() & "=" &
      value.text & ")"

  if verb == 'v' and numeric and body.len > 0 and body[0] == '-':
    sign = "-"
    body = body[1 .. ^1]
  if numeric and sign.len == 0:
    if '+' in flags: sign = "+"
    elif ' ' in flags: sign = " "
  if verb == 's' and precision >= 0 and body.len > precision:
    body.setLen(precision)

  let missing = max(width - sign.len - prefix.len - body.len, 0)
  if '-' in flags:
    return sign & prefix & body & repeat(' ', missing)
  if '0' in flags and numeric and precision < 0:
    return sign & prefix & repeat('0', missing) & body
  repeat(' ', missing) & sign & prefix & body

proc formatText(format: string; args: openArray[TextFormatArg]): string =
  var i = 0
  var nextArg = 0
  while i < format.len:
    if format[i] != '%':
      result.add(format[i])
      inc i
      continue
    let start = i
    inc i
    if i < format.len and format[i] == '%':
      result.add('%')
      inc i
      continue

    var argIndex = nextArg
    if i < format.len and format[i] == '[':
      inc i
      var oneBased = 0
      while i < format.len and format[i] in Digits:
        oneBased = min(oneBased * 10 + ord(format[i]) - ord('0'), 100_000)
        inc i
      if i < format.len and format[i] == ']' and oneBased > 0:
        argIndex = oneBased - 1
        inc i
    var flags: set[char] = {}
    while i < format.len and format[i] in {'#', '0', '+', '-', ' '}:
      flags.incl(format[i])
      inc i
    var width = 0
    while i < format.len and format[i] in Digits:
      width = min(width * 10 + ord(format[i]) - ord('0'), 100_000)
      inc i
    var precision = -1
    if i < format.len and format[i] == '.':
      inc i
      precision = 0
      while i < format.len and format[i] in Digits:
        precision = min(precision * 10 + ord(format[i]) - ord('0'), 32)
        inc i
    if i >= format.len:
      result.add(format[start .. ^1])
      break
    let verb = format[i]
    inc i
    if verb == '%':
      result.add('%')
      continue
    nextArg = argIndex + 1
    if argIndex < 0 or argIndex >= args.len:
      result.add("%!" & $verb & "(MISSING)")
    else:
      result.add(formatTextArg(args[argIndex], verb, flags, width, precision))

  if nextArg < args.len:
    result.add("%!(EXTRA ")
    for index in nextArg ..< args.len:
      if index > nextArg:
        result.add(", ")
      result.add(args[index].textFormatType() & "=" & args[index].text)
    result.add(')')

proc textf*(c: Context; format: string;
            args: varargs[TextFormatArg, toTextFormatArg]): Element =
  ## Adds text formatted with common fmt.Sprintf verbs, width and precision.
  c.text(formatText(format, args))

proc themedButton(c: Context; label: string; primary: bool): Element =
  let theme = c.theme
  result = c.buttonBase()
  let wasPressed = result.pressed()
  let wasHovered = result.hovered()
  let grouped = c.segmentedToggles and not primary
  let toolbar = c.toolbarButtons and not primary and not grouped
  var foreground = theme.text
  if primary:
    foreground = theme.accentText
    result = result.padding(theme.space(1.5), theme.space(3.5))
      .radius(theme.radius)
      .background(if wasPressed: theme.accentPressed
        elif wasHovered: theme.accentHover else: theme.accent)
  elif grouped:
    result = result.gap(theme.space(1.5))
      .padding(theme.space(1), theme.space(3))
      .radius(max(theme.radius - theme.space(0.5), 0'f32))
      .background(if wasPressed: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  elif toolbar:
    result = result.gap(theme.space(1.5))
      .padding(theme.space(1.5), theme.space(2.5))
      .radius(theme.radius)
      .background(if wasPressed: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  else:
    result = result.gap(theme.space(1.5))
      .padding(theme.space(1.5), theme.space(3.5))
      .radius(theme.radius)
      .background(if wasPressed: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: theme.surface)
      .border(1, theme.border)
  if label.len > 0:
    result = result.label(label).children(proc() =
      discard c.text(label).textColor(foreground)
    )

proc button*(c: Context; label: string): Element =
  ## Creates a themed button. Respond to activation with clicked() or onClick().
  c.themedButton(label, primary = false)

proc menuButton*(c: Context; label: string;
                 build: proc(menu: Menu) {.closure.}): Element =
  ## Creates a themed button that opens a native menu.
  let theme = c.theme
  result = c.themedButton("", primary = false).label(label)
  discard result.children(proc() =
    discard c.text(label)
    let arrow = c.text("▾").textColor(theme.textMuted)
    let arrowNode = arrow.node
    if arrowNode != nil:
      arrowNode[].accessHidden = true
  )
  let node = result.node
  if node != nil:
    node[].accessRole = platform.roleMenuButton
    node[].accessRoleSet = true
    node[].menuBuilder = build
    let openMenu = c.openMenu
    let identity = node[].identity
    node[].clickHandler = proc(mods: platform.Modifiers) =
      if openMenu != nil:
        openMenu(identity, build)

proc contextMenu*(e: Element;
                  build: proc(menu: Menu) {.closure.}): Element =
  ## Builds a native context menu when the element receives a secondary click.
  result = e
  let node = e.node
  if node != nil:
    node[].contextMenuBuilder = build

proc primaryButton*(c: Context; label: string): Element =
  ## Creates an accent-colored button for the primary action.
  c.themedButton(label, primary = true)

proc link*(c: Context; label, url: string): Element =
  ## Creates accessible text that opens app paths in the active Router and
  ## external URLs in the system browser.
  let open = c.openURL
  let router = c.routeRouter
  result = c.text(label).textColor(c.theme.accent)
    .cursor(platform.cursorPointer)
    .onClick(proc() =
      if url.len > 0 and router != nil and isAppPath(url):
        router.push(url)
      elif url.len > 0 and open != nil:
        open(url, nil)
    )
  let node = result.node
  if node != nil:
    node[].accessRole = platform.roleLink
    node[].accessRoleSet = true

proc icon*(c: Context; vector: Svg): Element =
  ## Adds a decorative SVG icon sized to the text font and tinted with text
  ## color. Add a label when the icon conveys information by itself.
  result = c.newElement(false, identityKindIcon)
  let node = result.node
  if node != nil:
    node[].icon = true
    node[].vector = vector
    node[].vectorColor = if c.themeEnabled: c.theme.text else: rgb(0, 0, 0)
    node[].fit = Fit.Contain
    node[].textStyle.size = if c.themeEnabled: c.theme.fontSize else: 16'f32
    if c.themeEnabled:
      node[].textStyle.family = c.theme.font
    let parent = int(c.owner.parent)
    var ancestor = parent
    var inheritedColor, inheritedSize = false
    while ancestor > 0 and ancestor < c.owner.nodes.len:
      let inherited = c.owner.nodes[ancestor]
      if not inheritedColor and inherited.textColorSet:
        node[].vectorColor = inherited.textColor
        node[].textColor = inherited.textColor
        node[].textColorSet = true
        inheritedColor = true
      if not inheritedSize and inherited.textStyle.size > 0:
        node[].textStyle.size = inherited.textStyle.size
        inheritedSize = true
      ancestor = int(inherited.parent)
    if parent > 0 and parent < c.owner.nodes.len and
        not c.owner.nodes[parent].row:
      node[].selfAlign = Align.Start

proc spacer*(c: Context): Element =
  ## Fills free space in its row or column, pushing siblings apart.
  c.box().grow()

proc divider*(c: Context): Element =
  ## Adds a one-pixel line across the current row or column.
  let parent = int(c.owner.parent)
  let row = parent > 0 and parent < c.owner.nodes.len and
    c.owner.nodes[parent].row
  result = c.box().background(c.theme.border).shrink(0)
    .alignSelf(Align.Stretch)
  if row:
    result = result.width(1)
  else:
    result = result.height(1)

proc sliderTickCount(low, high, step: float64): int =
  if classify(step) in {fcNan, fcInf, fcNegInf} or step <= 0 or
      high <= low:
    return 0
  let intervals = (high - low) / step
  if intervals > 61:
    return 0
  result = int(floor(intervals + 1e-9)) + 1
  if result > 61:
    result = 0

proc slider*(c: Context; value: var float64; low, high: float64;
             stepSize = 0'f64): Element =
  ## Creates a themed horizontal slider. Set its label and observe edits with
  ## changed() or onChange(); stepSize snaps pointer and keyboard input.
  let theme = c.theme
  result = c.sliderBase(value, low, high)
  let ticks = sliderTickCount(low, high, stepSize)
  let knobWidth = theme.space(5)
  let knobHeight = theme.space(4)
  let height = theme.space(if ticks > 0: 7 else: 5)
  let centerY = theme.space(2.5)
  let trackHeight = theme.space(1.5)
  let tickHeight = theme.space(1.5)
  result = result.height(height)
    .minWidth(theme.space(20)).paddingX(knobWidth / 2)
  if stepSize > 0:
    result = result.step(stepSize)
  let amount = if high > low:
      min(max((value - low) / (high - low), 0'f64), 1'f64).float32
    else:
      0'f32
  let rtl = c.direction() == Direction.RightToLeft
  let position = if rtl: 1'f32 - amount else: amount
  let hovered = result.hovered()
  let pressed = result.pressed()
  let knobColor = if pressed: theme.accentPressed
    elif hovered: theme.accentHover else: theme.accent
  discard result.children(proc() =
    let area = c.box().fill().shrink(0)
    discard area.children(proc() =
      discard c.box().absolute().left(0).right(0)
        .top(centerY - trackHeight / 2).height(trackHeight)
        .radius(trackHeight / 2).background(theme.border)
      for index in 0..<ticks:
        let fraction = float32(index) / float32(max(ticks - 1, 1))
        discard c.box().absolute().leftPercent(fraction * 100)
          .top(centerY + knobHeight / 2 + theme.space(1))
          .size(1, tickHeight).margin(0, 0, 0, -0.5'f32)
          .background(theme.textMuted.alpha(0.6'f32))
      discard c.box().absolute()
        .leftPercent((if rtl: position else: 0'f32) * 100)
        .top(centerY - trackHeight / 2).widthPercent(amount * 100)
        .height(trackHeight)
        .radius(trackHeight / 2)
        .background(theme.accent)
      discard c.box().absolute().leftPercent(position * 100)
        .top(centerY - knobHeight / 2).size(knobWidth, knobHeight)
        .margin(0, 0, 0, -knobWidth / 2)
        .radius(knobHeight / 2)
        .background(knobColor).border(2, theme.background)
        .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.18'f32))
    )
  )

proc stepSlider*(c: Context; value: var float64; low, high, step: float64): Element =
  ## Creates a themed slider with step snapping and ticks for its range.
  c.slider(value, low, high, step)

proc checkboxIndicator(c: Context; theme: Theme; checked, mixed,
                       hovered: bool): Element =
  let size = theme.space(4)
  result = c.box().size(size, size).shrink(0)
    .radius(theme.space(1)).center()
  if checked or mixed:
    discard result.background(theme.accent)
    if mixed:
      discard result.children(proc() =
        discard c.box().size(size * 0.5'f32, theme.space(0.5))
          .shrink(0).radius(theme.space(0.25)).background(theme.accentText)
      )
    else:
      discard result.children(proc() =
        discard c.text("✓").textSize(theme.space(2.5))
          .textColor(theme.accentText)
      )
  else:
    discard result.background(theme.background)
      .border(1, theme.border.mix(theme.text, 0.25'f32))
    if hovered:
      discard result.border(1, theme.accent)

proc checkbox*(c: Context; checked: var bool; label: string): Element =
  ## Creates a themed check box with a label.
  if c.checkboxGroup != nil:
    c.checkboxGroup.boxes.add(addr checked)
  let theme = c.theme
  var frameChecked = checked
  result = c.checkboxBase(frameChecked).gap(theme.space(2))
  if result.changed():
    checked = frameChecked
  result = result.label(label)
  let row = result
  result = result.children(proc() =
    discard c.checkboxIndicator(theme, frameChecked, false, row.hovered())
    if label.len > 0:
      discard c.text(label)
  )

proc checkboxGroup*(c: Context; label: string;
                    build: proc() {.closure.}): Element =
  ## Creates a parent check box for checkboxes built in the child closure.
  ## The parent is checked when all children are checked and mixed when some
  ## are checked. Clicking it checks all children, or clears all when checked.
  let theme = c.theme
  result = c.column().gap(theme.space(2)).shrink(0)
  let group = result
  result = result.children(proc() =
    var header = c.row().focusable().shrink(0).gap(theme.space(2))
      .focusRing(false).onClick(proc() = discard)
    let headerNode = header.node
    if headerNode != nil:
      headerNode.activateEnter = false
      headerNode.accessRole = platform.roleCheckBox
      headerNode.accessRoleSet = true
    header = header.label(label)

    let previousGroup = c.checkboxGroup
    let children = CheckboxGroupBuild()
    c.checkboxGroup = children
    try:
      let childGroup = c.column().gap(theme.space(2))
        .paddingStart(theme.space(6)).label(label)
      if childGroup.node != nil:
        childGroup.node.accessRole = platform.roleGroup
        childGroup.node.accessRoleSet = true
      discard childGroup.children(build)
    finally:
      c.checkboxGroup = previousGroup

    var checkedCount = 0
    for box in children.boxes:
      if box[]:
        inc checkedCount
    let allChecked = checkedCount > 0 and checkedCount == children.boxes.len
    let mixed = checkedCount > 0 and not allChecked
    if headerNode != nil:
      if allChecked:
        headerNode.accessExtraStates =
          headerNode.accessExtraStates or platform.accessChecked
      elif mixed:
        headerNode.accessExtraStates =
          headerNode.accessExtraStates or platform.accessMixed

    discard header.children(proc() =
      discard c.checkboxIndicator(theme, allChecked, mixed, header.hovered())
      discard c.text(label)
    )

    if header.clicked():
      for box in children.boxes:
        box[] = not allChecked
      group.markBoundValueChanged()
  )

proc toggle*(c: Context; on: var bool; label: string): Element =
  ## Creates a themed toggle button. Use toggleGroup to join toggles into a
  ## single keyboard stop.
  let theme = c.theme
  var frameOn = on
  result = c.toggleBase(frameOn).gap(theme.space(1.5))
  if result.changed():
    on = frameOn
  result = result.label(label)
  let wasHovered = result.hovered()
  result = result.padding(theme.space(1), theme.space(2)).center()
  if c.segmentedToggles:
    result = result.radius(max(theme.radius - theme.space(0.5), 0'f32))
      .background(if frameOn:
        (if theme.dark: theme.surfacePressed else: theme.background)
      elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  elif c.toolbarButtons:
    result = result.radius(theme.radius).background(if frameOn:
      theme.surfacePressed
    elif wasHovered: theme.surfaceHover else: rgba(0, 0, 0, 0))
  else:
    result = result.radius(theme.radius)
      .background(if frameOn: theme.surfacePressed
        elif wasHovered: theme.surfaceHover else: theme.surface)
      .border(1, theme.border)
  if label.len > 0:
    result = result.children(proc() = discard c.text(label))

proc toggleGroup*(c: Context; build: proc() {.closure.}): Element =
  ## Builds toggle buttons as joined segments with one Tab stop.
  let theme = c.theme
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .padding(theme.space(0.5)).gap(theme.space(0.5))
    .radius(theme.radius).background(theme.surface)
    .border(1, theme.border).focusGroup(FocusOrientation.Both)
  let previous = c.segmentedToggles
  c.segmentedToggles = true
  try:
    result = result.children(build)
  finally:
    c.segmentedToggles = previous

proc segment*(c: Context; selected: var int; index: int): Element =
  ## Creates one custom-content radio segment for segmentedBase.
  result = c.radioBase(selected, index).center()
  let node = result.node
  if node != nil:
    node.accessExtraStates = node.accessExtraStates or platform.accessSegment

proc segmentedBase*(c: Context; selected: var int; count: int;
                    build: proc(selected: var int) {.closure.}): Element =
  ## Creates a radio-style segmented group whose segments can have custom
  ## content. Build options with segment() inside build; set the group's
  ## accessible name with label().
  var frameSelection = selected
  if count > 0:
    frameSelection = max(0, min(frameSelection, count - 1))
    selected = frameSelection
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .focusGroup(FocusOrientation.Both, selects = true)
  let track = result
  let node = track.node
  if node != nil:
    node.accessRole = platform.roleRadioGroup
    node.accessRoleSet = true
  let firstChildSlot = c.owner.nodes.len
  if build != nil:
    discard track.children(proc() = build(frameSelection))
  var selectionChanged = false
  for slot in firstChildSlot..<c.owner.nodes.len:
    let child = c.owner.nodes[slot]
    if (child.accessExtraStates and platform.accessSegment) !=
        platform.AccessStates(0) and child.valueChangedInBuild:
      selectionChanged = true
      break
  if selectionChanged:
    selected = frameSelection
    track.markBoundValueChanged()

proc segmented*(c: Context; selected: var int;
                labels: openArray[string]): Element =
  ## Creates a radio-style segmented control whose selected index changes on
  ## click or group arrow navigation. Set its accessible name with label().
  let theme = c.theme
  let segmentLabels = @labels
  var frameSelection = selected
  if segmentLabels.len > 0:
    frameSelection = max(0, min(frameSelection, segmentLabels.high))
    selected = frameSelection
  result = c.row().shrink(0).alignItems(Align.Stretch)
    .padding(theme.space(0.5)).gap(theme.space(0.5))
    .radius(theme.radius).background(theme.surface)
    .border(1, theme.border)
    .focusGroup(FocusOrientation.Both, selects = true)
  let track = result
  let node = track.node
  if node != nil:
    node.accessRole = platform.roleRadioGroup
    node.accessRoleSet = true
  var selectionChanged = false
  result = result.children(proc() =
    for index, label in segmentLabels:
      var segment = c.segment(frameSelection, index)
        .gap(theme.space(1.5)).padding(theme.space(1), theme.space(3))
        .radius(max(theme.radius - theme.space(0.5), 0'f32))
        .center().focusRing(false)
      if segment.changed():
        selectionChanged = true
      let isSelected = frameSelection == index
      segment = segment.label(label).background(if isSelected:
        (if theme.dark: theme.surfacePressed else: theme.background)
      elif segment.hovered(): theme.surfaceHover else: rgba(0, 0, 0, 0))
      if isSelected:
        segment = segment.shadow(0, 1, 2, 0,
          rgba(0, 0, 0, 0.12'f32))
      discard segment.children(proc() = discard c.text(label))
  )
  if selectionChanged:
    selected = frameSelection
    track.markBoundValueChanged()

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
  let position = result.animate("knob", if frameOn: 1'f32 else: 0'f32,
    initDuration(milliseconds = 140))
  let travel = theme.space(9) - height
  let offColor = theme.border.mix(theme.text, 0.15'f32)
  result = result.size(theme.space(9), height).padding(inset)
    .justify(Align.Start)
    .alignItems(Align.Center).radius(height / 2)
    .background(offColor.mix(theme.accent, position))
  result = result.children(proc() =
    discard c.box().size(height - 2 * inset, height - 2 * inset)
      .shrink(0).radius(height / 2).background(rgb(255, 255, 255))
      .shadow(0, 1, 2, 0, rgba(0, 0, 0, 0.25'f32))
      .margin(0, if rightToLeft: position * travel else: 0'f32,
        0, if rightToLeft: 0'f32 else: position * travel)
  )
