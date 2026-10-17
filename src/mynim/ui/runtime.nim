## A window runtime that builds a frame and submits its scene to the
## platform GPU renderer, with the CPU rasterizer as fallback.

type
  View* = proc(c: Context) {.closure.}

  Content* = ref object of surface.Content
    view: View

  Runtime = ref object
    conn: surface.Conn
    view: View
    context: Context
    systemTheme: Theme
    systemPreferences: platform.Preferences
    frameLayout: LayoutResult
    pressTarget: Element
    pressMods: platform.Modifiers
    inputPressButton: int
    inputPressCaptured: bool
    byPosition: HashSet[platform.Key]
    scrollbarDrag: ScrollbarDrag
    focusSlot, keyPressSlot: int
    keyPressKey: platform.Key
    focusGroupLast: Table[uint64, uint64]
    modalFocusReturns: Table[uint64, uint64]
    activeModalIdentity: uint64
    listReorder, tableReorder: ListState
    gridReorder: GridState
    pointerCursor: platform.Cursor
    hasPointerCursor: bool
    textInputAdapter: TextInputAdapter
    lastTextInput: platform.TextInputState
    inputComposition: platform.InputComposition
    pointerX, pointerY: float32
    pressX, pressY: float32
    dragCandidateIdentity: uint64
    nativeDragStarted: bool
    pointerDraggableIdentity, pointerDraggableSerial: uint64
    pointerDraggableLastX, pointerDraggableLastY: float32
    pointerDraggableVelocityX, pointerDraggableVelocityY: float32
    pointerDraggableLastAt: MonoTime
    pointerDraggableMoved, pointerDraggableCaught,
      pointerDraggableReleasePending, pointerDraggableCanceled: bool
    localDrag: LocalDragState
    splitPointerOffset: float64
    hasPointer: bool
    hoverSlots, pressHoverSlots, pressedSlots, clickedSlots,
      doubleClickedSlots: seq[int]
    frameScene: scene.Scene
    hasScene: bool
    accessibilityOn: bool
    keyboardFocusVisible, surfaceFocused, hasTextInputState,
      inFrame, closed, ready, gpuTried, themeDirty, poseOnlyFrame: bool
    gpuError: string
    software: raster.Renderer
    when defined(macosx):
      metalRenderer: metalGpu.Renderer
    elif defined(windows):
      d3d11Renderer: d3d11Gpu.Renderer
    elif (defined(linux) and (defined(amd64) or defined(arm64))) or
        defined(emscripten):
      glRenderer: glGpu.Renderer

  LocalDragState = ref object
    sourceIdentity, overIdentity: uint64
    value: RootRef
    preview: scene.Image
    width, height, hotX, hotY: int
    canceled: bool

  TextInputAdapter = ref object of platform.TextInputClient
    runtime: Runtime
    slot: int
    client: platform.TextInputClient

proc newContent*(view: View): Content =
  ## Creates native UI content for WindowOptions.content.
  Content(view: view)

proc updateSystemTheme(rt: Runtime) =
  var dark = false
  if rt.conn.isDark != nil:
    dark = rt.conn.isDark()
  rt.systemPreferences = platform.Preferences(textScale: 1)
  if rt.conn.preferences != nil:
    rt.systemPreferences = rt.conn.preferences()
  rt.systemTheme = if dark: darkTheme() else: lightTheme()
  rt.systemTheme.followPreferences(rt.systemPreferences)
  let text = textStack.shared()
  if rt.conn.uiFont != nil:
    rt.systemTheme.font = rt.conn.uiFont()
    text.setUIFamily(rt.systemTheme.font)
  if rt.conn.fontRendering != nil:
    let rendering = rt.conn.fontRendering()
    text.setFontRendering(rendering.antialias, rendering.hinting,
                          rendering.subpixels)
  rt.themeDirty = false

proc frameDimension(value: float64; name: string): float32 =
  if classify(value) in {fcNan, fcInf, fcNegInf} or
      abs(value) > float64(high(float32)):
    raise newException(ValueError, "ui: surface " & name & " is out of range")
  float32(max(value, 0))

proc scrollDelta(value: float64): float32 =
  if classify(value) in {fcNan, fcInf, fcNegInf} or
      abs(value) > float64(high(float32)):
    0'f32
  else:
    float32(value)

proc releaseGpu(rt: Runtime) =
  when defined(macosx):
    if rt.metalRenderer != nil:
      rt.metalRenderer.release()
      rt.metalRenderer = nil
  elif defined(windows):
    if rt.d3d11Renderer != nil:
      rt.d3d11Renderer.release()
      rt.d3d11Renderer = nil
  elif (defined(linux) and (defined(amd64) or defined(arm64))) or
      defined(emscripten):
    if rt.glRenderer != nil:
      rt.glRenderer.release()
      rt.glRenderer = nil

proc tryGpu(rt: Runtime; frame: scene.Scene): bool =
  when defined(macosx):
    let native = rt.conn.surface.native()
    if native.layer == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      try:
        rt.metalRenderer = metalGpu.new(native.layer)
      except CatchableError as error:
        rt.gpuError = error.msg
    if rt.metalRenderer == nil:
      return false
    try:
      rt.metalRenderer.render(frame)
      return true
    except CatchableError as error:
      rt.gpuError = error.msg
      rt.releaseGpu()
      false
  elif defined(linux) and (defined(amd64) or defined(arm64)):
    let native = rt.conn.surface.native()
    if native.glArea == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      let (renderer, error) = glGpu.newRenderer()
      if error == nil:
        rt.glRenderer = renderer
      else:
        rt.gpuError = error.msg
    if rt.glRenderer == nil:
      return false
    let error = rt.glRenderer.render(frame)
    if error == nil:
      return true
    rt.gpuError = error.msg
    rt.releaseGpu()
    false
  elif defined(windows):
    let native = rt.conn.surface.native()
    if native.hwnd == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      let (renderer, error) = d3d11Gpu.new(native.hwnd, native.composed)
      if error.len == 0:
        rt.d3d11Renderer = renderer
      else:
        rt.gpuError = error
    if rt.d3d11Renderer == nil:
      return false
    let error = rt.d3d11Renderer.render(frame)
    if error.len == 0:
      return true
    rt.gpuError = error
    rt.releaseGpu()
    false
  elif defined(emscripten):
    let native = rt.conn.surface.native()
    if native.canvas == 0:
      return false
    if not rt.gpuTried:
      rt.gpuTried = true
      let (renderer, error) = glGpu.newRenderer()
      if error == nil:
        rt.glRenderer = renderer
      else:
        rt.gpuError = error.msg
    if rt.glRenderer == nil:
      return false
    let error = rt.glRenderer.render(frame)
    if error == nil:
      return true
    rt.gpuError = error.msg
    rt.releaseGpu()
    false
  else:
    false

proc present(rt: Runtime; frame: scene.Scene) =
  if frame.width <= 0 or frame.height <= 0:
    return
  if rt.tryGpu(frame):
    return
  if rt.gpuError.len > 0:
    stderr.writeLine("mynim: drawing without the GPU: " & rt.gpuError)
    rt.gpuError.setLen(0)
  discard rt.software.render(frame)
  let image = rt.software.image
  rt.conn.surface.presentPixels(image.pix, image.stride, image.w, image.h)

proc focusableSlot(layout: LayoutResult; slot: int): bool =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or not owner.hasFrame or
      layout.generation != owner.generation or slot <= 0 or
      slot >= owner.nodes.len:
    return false
  if layout.backfaceBlocked[slot] or owner.effectivelyDisabled(slot) or
      owner.effectivelyToolbarCollapsed(slot):
    return false
  let node = owner.nodes[slot]
  node.focusable or node.clickHandler != nil

proc tabStopSlot(layout: LayoutResult; slot: int): bool =
  if not layout.focusableSlot(slot):
    return false
  let node = layout.owner.nodes[slot]
  not node.tabStopSet or node.tabStop

proc clickableSlot(layout: LayoutResult; slot: int): bool =
  let owner = layout.owner
  owner != nil and not owner.closed and not owner.inBuild and owner.hasFrame and
    layout.generation == owner.generation and slot > 0 and
    slot < owner.nodes.len and owner.nodes[slot].clickHandler != nil

proc keyboardActivationSlot(layout: LayoutResult; slot: int;
                            key: platform.Key): bool =
  if not layout.clickableSlot(slot):
    return false
  case key
  of platform.keyEnter:
    layout.owner.nodes[slot].activateEnter
  of platform.keySpace:
    true
  else:
    false

proc focusGroupOf(layout: LayoutResult; slot: int): int =
  let owner = layout.owner
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return -1
  result = -1
  var current = slot
  while current > 0:
    if owner.nodes[current].focusGroupSet:
      result = current
    current = int(owner.nodes[current].parent)

proc focusGroupEntry(rt: Runtime; layout: LayoutResult;
                     groupSlot: int): int =
  let owner = layout.owner
  if owner == nil or groupSlot <= 0 or groupSlot >= owner.nodes.len:
    return -1
  let groupIdentity = owner.nodes[groupSlot].identity
  if rt.focusGroupLast.hasKey(groupIdentity):
    let lastIdentity = rt.focusGroupLast[groupIdentity]
    let lastSlot = owner.idSlots.getOrDefault(lastIdentity, -1)
    if layout.tabStopSlot(lastSlot) and
        layout.focusGroupOf(lastSlot) == groupSlot:
      return lastSlot
  var first = -1
  for slot in 1..<owner.nodes.len:
    if not layout.tabStopSlot(slot) or
        layout.focusGroupOf(slot) != groupSlot:
      continue
    if first < 0:
      first = slot
    let node = owner.nodes[slot]
    let states = node.accessExtraStates
    if (node.accessRole in {platform.roleRadio, platform.roleTab} and
        (states and platform.accessChecked) != platform.AccessStates(0)) or
        (node.accessRole == platform.roleTreeItem and
         (states and platform.accessSelected) != platform.AccessStates(0)):
      return slot
  first

proc isFocusGroupTabStop(rt: Runtime; layout: LayoutResult; slot: int): bool =
  let groupSlot = layout.focusGroupOf(slot)
  groupSlot < 0 or rt.focusGroupEntry(layout, groupSlot) == slot

proc cancelKeyPress(rt: Runtime)
proc refreshPointer(rt: Runtime)
proc requestFrame(rt: Runtime)
proc requestPoseFrame(rt: Runtime)

proc nextFocusSlot(rt: Runtime; layout: LayoutResult; current: int;
                   reverse: bool): int =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or not owner.hasFrame or
      layout.generation != owner.generation:
    return -1
  let last = owner.nodes.high
  if last <= 0:
    return -1
  let currentGroup = layout.focusGroupOf(current)
  var slot = current
  if slot < 1 or slot > last:
    slot = if reverse: 1 else: 0
  for _ in 0..<last:
    if reverse:
      dec slot
      if slot < 1:
        slot = last
    else:
      inc slot
      if slot > last:
        slot = 1
    let candidateGroup = layout.focusGroupOf(slot)
    if layout.tabStopSlot(slot) and
        (currentGroup < 0 or candidateGroup != currentGroup) and
        rt.isFocusGroupTabStop(layout, slot):
      return slot
  -1

proc handleFocusGroupKey(rt: Runtime; key: platform.Key;
                         mods: platform.Modifiers): bool =
  if mods != 0 or not rt.frameLayout.focusableSlot(rt.focusSlot):
    return false
  let groupSlot = rt.frameLayout.focusGroupOf(rt.focusSlot)
  if groupSlot < 0:
    return false
  let owner = rt.frameLayout.owner
  let group = owner.nodes[groupSlot]
  var members: seq[int]
  var at = -1
  for slot in 1..<owner.nodes.len:
    if rt.frameLayout.focusableSlot(slot) and
        rt.frameLayout.focusGroupOf(slot) == groupSlot:
      if slot == rt.focusSlot:
        at = members.len
      members.add(slot)
  if at < 0 or members.len == 0:
    return false

  let horizontal = group.focusOrientation in
    {FocusOrientation.Horizontal, FocusOrientation.Both}
  let vertical = group.focusOrientation in
    {FocusOrientation.Vertical, FocusOrientation.Both}
  var next = -1
  var back, forth = false
  case key
  of platform.keyLeft:
    back = not group.rightToLeft
    forth = group.rightToLeft
  of platform.keyRight:
    back = group.rightToLeft
    forth = not group.rightToLeft
  of platform.keyUp:
    back = true
  of platform.keyDown:
    forth = true
  else:
    discard
  if key == platform.keyHome:
    next = 0
  elif key == platform.keyEnd:
    next = members.high
  elif (horizontal and key in {platform.keyLeft, platform.keyRight}) or
      (vertical and key in {platform.keyUp, platform.keyDown}):
    let movingBack = back
    next = if movingBack:
        (at - 1 + members.len) mod members.len
      else:
        (at + 1) mod members.len
  else:
    return false

  let nextSlot = members[next]
  rt.focusSlot = nextSlot
  rt.keyboardFocusVisible = true
  rt.cancelKeyPress()
  let nextIdentity = owner.nodes[nextSlot].identity
  rt.focusGroupLast[group.identity] = nextIdentity
  if group.groupSelects:
    let handler = owner.nodes[nextSlot].clickHandler
    if handler != nil:
      handler(0)
      rt.clickedSlots = @[nextSlot]
  discard rt.frameLayout.revealSlot(nextSlot)
  rt.refreshPointer()
  rt.requestFrame()
  true

proc rememberFocusGroup(rt: Runtime) =
  let layout = rt.frameLayout
  if layout.focusableSlot(rt.focusSlot):
    let groupSlot = layout.focusGroupOf(rt.focusSlot)
    if groupSlot >= 0:
      let owner = layout.owner
      rt.focusGroupLast[owner.nodes[groupSlot].identity] =
        owner.nodes[rt.focusSlot].identity

proc pruneFocusGroups(rt: Runtime; layout: LayoutResult) =
  let owner = layout.owner
  var stale: seq[uint64]
  for groupIdentity, memberIdentity in rt.focusGroupLast:
    let groupSlot = owner.idSlots.getOrDefault(groupIdentity, -1)
    let memberSlot = owner.idSlots.getOrDefault(memberIdentity, -1)
    if groupSlot <= 0 or groupSlot >= owner.nodes.len or
        not owner.nodes[groupSlot].focusGroupSet or
        not layout.focusableSlot(memberSlot) or
        layout.focusGroupOf(memberSlot) != groupSlot:
      stale.add(groupIdentity)
  for groupIdentity in stale:
    rt.focusGroupLast.del(groupIdentity)

proc splitRootSlot(owner: ElementOwner; slot: int): int =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return -1
  var current = slot
  while current > 0 and current < owner.nodes.len:
    if owner.nodes[current].splitPane:
      return current
    current = int(owner.nodes[current].parent)
  -1

proc isWithinNode(owner: ElementOwner; ancestor, slot: int): bool =
  if owner == nil or ancestor <= 0 or slot <= 0:
    return false
  var current = slot
  while current > 0 and current < owner.nodes.len:
    if current == ancestor:
      return true
    current = int(owner.nodes[current].parent)
  false

proc comboBoxKey(rt: Runtime; key: platform.Key;
                 mods: platform.Modifiers): bool =
  if mods != 0:
    return false
  let owner = rt.frameLayout.owner
  let slot = rt.focusSlot
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return false
  let node = owner.nodes[slot]
  if not node.comboBoxInput or node.comboBoxState == nil:
    return false
  let state = node.comboBoxState
  if key == platform.keyBackspace and state.tokenField and
      state.query.len == 0 and state.tokenCount > 0:
    inc state.pendingTokenRemovals
    rt.keyboardFocusVisible = true
    rt.requestFrame()
    return true
  case key
  of platform.keyDown:
    if not state.open:
      state.open = true
      state.filtering = false
      state.highlight = 0
      state.pointerRevision = owner.pointerRevision
    elif state.visibleOptions.len > 0:
      state.highlight = min(max(state.highlight + 1, 0),
        state.visibleOptions.high)
    rt.keyboardFocusVisible = true
    rt.requestFrame()
    true
  of platform.keyUp:
    if not state.open:
      state.open = true
      state.filtering = false
      state.highlight = -2
      state.pointerRevision = owner.pointerRevision
    elif state.visibleOptions.len > 0:
      state.highlight = if state.highlight < 0:
          state.visibleOptions.high
        else:
          max(state.highlight - 1, 0)
    rt.keyboardFocusVisible = true
    rt.requestFrame()
    true
  of platform.keyEnter:
    if state.open and state.highlight >= 0 and
        state.highlight < state.visibleOptions.len:
      state.pendingChoice = state.visibleOptions[state.highlight]
      state.hasPendingChoice = true
      state.open = false
      state.filtering = false
      state.highlight = -1
      rt.keyboardFocusVisible = true
      rt.requestFrame()
      return true
    false
  of platform.keyEscape:
    if not state.open:
      return false
    state.open = false
    state.filtering = false
    state.highlight = -1
    rt.keyboardFocusVisible = true
    rt.requestFrame()
    true
  else:
    false

proc setRuntimeFocus(rt: Runtime; layout: LayoutResult; slot: int)

proc dismissPopover(rt: Runtime): bool =
  let owner = rt.frameLayout.owner
  if owner == nil:
    return false
  for slot in countdown(owner.nodes.high, 1):
    let state = owner.nodes[slot].popoverState
    if state != nil and state.open and owner.inActiveModalScope(slot):
      let anchorSlot = owner.idSlots.getOrDefault(state.anchorIdentity, -1)
      if not owner.isWithinNode(slot, rt.focusSlot) and
          not owner.isWithinNode(anchorSlot, rt.focusSlot):
        continue
      state.pendingDismiss = true
      if anchorSlot > 0 and rt.frameLayout.focusableSlot(anchorSlot):
        rt.setRuntimeFocus(rt.frameLayout, anchorSlot)
        rt.keyboardFocusVisible = true
        owner.nodes[anchorSlot].focusVisible = true
        owner.focusVisibleSlots.add(anchorSlot)
      rt.requestFrame()
      return true

proc dismissPopoverOutside(rt: Runtime; x, y: float32): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil:
    return false
  for slot in countdown(owner.nodes.high, 1):
    let state = owner.nodes[slot].popoverState
    if state == nil or not state.open or
        not owner.inActiveModalScope(slot):
      continue
    let anchorSlot = owner.idSlots.getOrDefault(state.anchorIdentity, -1)
    let inPanel = slot < layout.rects.len and
      layout.containsPointer(slot, x, y) and
      layout.insideClips(slot, x, y)
    let inAnchor = anchorSlot > 0 and anchorSlot < layout.rects.len and
      layout.containsPointer(anchorSlot, x, y) and
      layout.insideClips(anchorSlot, x, y)
    if inPanel or inAnchor:
      return false
    state.pendingDismiss = true
    rt.requestFrame()
    return true

proc dismissModal(rt: Runtime): bool =
  let owner = rt.frameLayout.owner
  if owner == nil or owner.activeModalIdentity == 0:
    return false
  for slot in countdown(owner.nodes.high, 1):
    let node = owner.nodes[slot]
    if not node.modal or node.identity != owner.activeModalIdentity:
      continue
    if node.dialogState != nil and node.dialogState.dismissOnEscape:
      node.dialogState.pendingDismiss = true
      rt.requestFrame()
      return true
    return false

proc accessibilityTree(layout: LayoutResult;
                      focusSlot: int): platform.AccessTree =
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation or
      layout.rects.len != owner.nodes.len:
    return
  if layout.focusableSlot(focusSlot):
    result.focus = uint64(focusSlot + 1)
  var accessIndex = newSeq[int](owner.nodes.len)
  for index in accessIndex.mitems:
    index = -1
  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    if node.accessHidden or layout.backfaceBlocked[slot] or
        owner.effectivelyInert(slot) or
        not owner.inActiveModalScope(slot) or
        owner.effectivelyToolbarCollapsed(slot):
      continue
    let isDisabled = owner.effectivelyDisabled(slot)
    let image = node.bitmap != nil or node.vector != nil
    let listContainer = node.listState != nil and node.listRowIndex == -1
    let listItem = node.listState != nil and node.listRowIndex >= 0 and
      not node.listRowAction
    if image and node.label.len == 0 and node.clickHandler == nil and
        not node.focusable and node.textClient == nil and not listItem and
        not node.accessRoleSet:
      continue
    if not image and not node.hasText and node.clickHandler == nil and
        not node.focusable and node.textClient == nil and node.label.len == 0 and
        not listContainer and not listItem and not node.accessRoleSet:
      continue

    let role = if node.accessRoleSet:
        node.accessRole
      elif listContainer:
        platform.roleList
      elif listItem:
        platform.roleListItem
      elif node.textClient != nil:
        platform.roleTextField
      elif node.clickHandler != nil:
        platform.roleButton
      elif node.hasText:
        platform.roleText
      elif image:
        platform.roleImage
      else:
        platform.roleGroup
    var label = node.label
    if label.len == 0 and node.hasText and not node.textOverlay:
      label = node.textValue
    var parentSlot = int(node.parent)
    if node.overlayOwnerIdentity != 0:
      let logicalParent = owner.idSlots.getOrDefault(
        node.overlayOwnerIdentity, -1)
      if logicalParent >= 0:
        parentSlot = logicalParent
    if node.textInline and node.clickHandler == nil and not node.focusable and
        not node.accessRoleSet and node.label.len == 0:
      accessIndex[slot] = if parentSlot >= 0 and parentSlot < accessIndex.len:
          accessIndex[parentSlot]
        else:
          -1
      continue
    if node.rangeSliderThumb and parentSlot > 0 and
        parentSlot < owner.nodes.len and owner.nodes[parentSlot].label.len > 0:
      label = owner.nodes[parentSlot].label & " " & label
    elif node.accessLabelFromParent and parentSlot > 0 and
        parentSlot < owner.nodes.len and owner.nodes[parentSlot].label.len > 0:
      label = owner.nodes[parentSlot].label & " " & label
    let parent = if parentSlot >= 0: accessIndex[parentSlot] else: -1
    let rect = layout.visualRects[slot]
    var accessible = platform.AccessNode(id: uint64(slot + 1),
      parent: parent, role: role, label: label,
      bounds: platform.RectF(x: rect.x.float64, y: rect.y.float64,
        w: rect.w.float64, h: rect.h.float64))
    accessible.description = node.accessDescription
    accessible.value = node.accessValue
    accessible.states = accessible.states or node.accessSort
    accessible.states = accessible.states or node.accessExtraStates
    accessible.actions = accessible.actions or node.accessExtraActions
    accessible.level = node.accessLevel
    accessible.posInSet = node.accessPosInSet
    accessible.setSize = node.accessSetSize
    if node.comboBoxInput and node.comboBoxState != nil and
        node.comboBoxState.open:
      accessible.states = accessible.states or platform.accessExpanded
    if isDisabled:
      accessible.states = accessible.states or platform.accessDisabled
    if node.slider:
      accessible.min = node.sliderLow
      accessible.max = node.sliderHigh
      if node.splitHandle:
        let ancestor = owner.splitRootSlot(slot)
        if ancestor > 0 and ancestor < layout.rects.len:
          let bounds = layout.rects[ancestor]
          let total = if node.splitVertical: bounds.h else: bounds.w
          accessible.max = max(float64(total) - 1 - node.sliderLow,
            node.sliderLow)
      accessible.now = node.sliderValue
      accessible.step = node.sliderStep
      if not isDisabled:
        accessible.actions = accessible.actions or platform.actionIncrement or
          platform.actionDecrement
      if node.sliderVertical:
        accessible.states = accessible.states or platform.accessVertical
    elif node.hasAccessRange:
      accessible.min = node.accessMin
      accessible.max = node.accessMax
      accessible.now = node.accessNow
      accessible.step = node.accessStep
      if not isDisabled and node.accessStepHandler != nil:
        accessible.actions = accessible.actions or
          platform.actionIncrement or platform.actionDecrement
    if node.textClient != nil:
      let (value, _) = node.textClient.textForRange(platform.TextRange(
        start: 0, `end`: high(int)))
      accessible.value = value
      accessible.placeholder = node.placeholder
      if node.textClient of TextFieldClient and
          TextFieldClient(node.textClient).password:
        accessible.states = accessible.states or platform.accessPassword
      if node.textClient of TextFieldClient and
          TextFieldClient(node.textClient).readOnly:
        accessible.states = accessible.states or platform.accessReadOnly
    if not isDisabled and
        (node.focusable or node.clickHandler != nil or node.textClient != nil):
      accessible.states = accessible.states or platform.accessFocusable
      accessible.actions = accessible.actions or platform.actionFocus
    if listItem and node.listState.selectionEnabled and
        not node.listRowHeader:
      accessible.states = accessible.states or platform.accessSelectable
      let selected = if node.listState.multiSelectionEnabled:
          node.listState.isSelected(node.listRowIndex)
        else:
          node.listState.selected() == node.listRowIndex
      if selected:
        accessible.states = accessible.states or platform.accessSelected
    if listContainer and node.listState.multiSelectionEnabled:
      accessible.states = accessible.states or platform.accessMultiselectable
    if layout.hasScrollAncestor(slot):
      accessible.actions = accessible.actions or platform.actionScrollIntoView
    if not isDisabled and node.textClient != nil and
        not (node.textClient of TextFieldClient and
          TextFieldClient(node.textClient).readOnly):
      accessible.actions = accessible.actions or platform.actionSetValue
    if not isDisabled and (node.clickHandler != nil or
        role == platform.roleButton or
        (listItem and node.listState.selectionEnabled and
          not node.listRowHeader)):
      accessible.actions = accessible.actions or platform.actionPress
    result.nodes.add(accessible)
    accessIndex[slot] = result.nodes.high

  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    if not node.comboBoxInput or node.comboBoxState == nil or
        not node.comboBoxState.open:
      continue
    let state = node.comboBoxState
    if state.highlight < 0 or state.highlight >= state.itemIdentities.len:
      continue
    let itemSlot = owner.idSlots.getOrDefault(
      state.itemIdentities[state.highlight], -1)
    if itemSlot > 0 and itemSlot < accessIndex.len and
        accessIndex[itemSlot] >= 0:
      result.focus = uint64(itemSlot + 1)
      break

  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    if node.activeDescendantIdentity == 0 or
        not owner.isWithinNode(slot, focusSlot):
      continue
    let itemSlot = owner.idSlots.getOrDefault(
      node.activeDescendantIdentity, -1)
    if itemSlot > 0 and itemSlot < accessIndex.len and
        accessIndex[itemSlot] >= 0:
      result.focus = uint64(itemSlot + 1)
      break

proc updateAccessibility(rt: Runtime) =
  if rt.accessibilityOn and rt.conn.surface != nil:
    let owner = rt.context.owner
    var tree = rt.frameLayout.accessibilityTree(rt.focusSlot)
    if owner != nil and owner.announcements.len > 0:
      tree.announcements = owner.announcements
      owner.announcements.setLen(0)
    rt.conn.surface.updateAccessibility(tree)

proc cancelKeyPress(rt: Runtime) =
  rt.keyPressSlot = -1
  rt.keyPressKey = platform.keyUnknown

proc rememberInteraction(owner: ElementOwner; identities: seq[uint64];
                         slots: openArray[int]; flag: uint8) =
  for slot in slots:
    if slot > 0 and slot < identities.len:
      let identity = identities[slot]
      if identity != 0:
        owner.previousInteraction[identity] =
          owner.previousInteraction.getOrDefault(identity) or flag

proc remapSlot(identities: seq[uint64]; owner: ElementOwner;
               oldSlot: int): int =
  if oldSlot > 0 and oldSlot < identities.len and owner != nil:
    return owner.idSlots.getOrDefault(identities[oldSlot], -1)
  -1

proc remapSlots(identities: seq[uint64]; owner: ElementOwner;
                oldSlots: seq[int]): seq[int] =
  for oldSlot in oldSlots:
    let slot = remapSlot(identities, owner, oldSlot)
    if slot > 0:
      result.add(slot)

proc applyHandleFocusRequests(rt: Runtime; layout: LayoutResult): bool =
  let owner = layout.owner
  if owner == nil or owner.focusRequests.len == 0:
    return
  var pending: seq[HandleFocusRequest]
  var requestedSlot = -1
  for request in owner.focusRequests:
    let slot = owner.idSlots.getOrDefault(request.identity, -1)
    if slot > 0 and layout.focusableSlot(slot):
      requestedSlot = slot
    else:
      pending.add(request)
  owner.focusRequests = pending
  if requestedSlot <= 0:
    return
  for slot in 1..<owner.nodes.len:
    owner.nodes[slot].focused = false
    owner.nodes[slot].focusVisible = false
  rt.focusSlot = requestedSlot
  rt.keyboardFocusVisible = false
  rt.cancelKeyPress()
  owner.nodes[requestedSlot].focused = true
  owner.focusedSlots = @[requestedSlot]
  owner.focusVisibleSlots.setLen(0)
  owner.focusIdentity = owner.nodes[requestedSlot].identity
  if layout.revealSlot(requestedSlot):
    rt.requestFrame()
  rt.requestFrame()
  true

proc modalInitialFocus(layout: LayoutResult): int =
  let owner = layout.owner
  if owner == nil or owner.activeModalIdentity == 0:
    return -1
  var firstTabStop = -1
  var fallback = -1
  for slot in 1..<owner.nodes.len:
    if not layout.focusableSlot(slot):
      continue
    let node = owner.nodes[slot]
    if node.autoFocus:
      return slot
    if fallback < 0:
      fallback = slot
    if firstTabStop < 0 and layout.tabStopSlot(slot):
      firstTabStop = slot
  if firstTabStop > 0: firstTabStop else: fallback

proc setRuntimeFocus(rt: Runtime; layout: LayoutResult; slot: int) =
  let owner = layout.owner
  if owner == nil:
    return
  for index in 1..<owner.nodes.len:
    owner.nodes[index].focused = false
    owner.nodes[index].focusVisible = false
  owner.focusedSlots.setLen(0)
  owner.focusVisibleSlots.setLen(0)
  rt.focusSlot = -1
  rt.keyboardFocusVisible = false
  if slot > 0 and slot < owner.nodes.len and layout.focusableSlot(slot):
    rt.focusSlot = slot
    owner.nodes[slot].focused = true
    owner.focusedSlots.add(slot)
    owner.focusIdentity = owner.nodes[slot].identity
    if layout.revealSlot(slot):
      rt.requestFrame()
  else:
    owner.focusIdentity = 0
  rt.cancelKeyPress()
  rt.requestFrame()

proc applyModalFocus(rt: Runtime; layout: LayoutResult;
                     previousFocusIdentity: uint64) =
  let owner = layout.owner
  if owner == nil:
    return
  let previousModal = rt.activeModalIdentity
  let modal = owner.activeModalIdentity
  var target = -1
  if modal != previousModal:
    if modal != 0 and not rt.modalFocusReturns.hasKey(modal):
      rt.modalFocusReturns[modal] = previousFocusIdentity
    if previousModal != 0 and rt.modalFocusReturns.hasKey(previousModal):
      let savedIdentity = rt.modalFocusReturns[previousModal]
      let savedSlot = owner.idSlots.getOrDefault(savedIdentity, -1)
      if savedSlot > 0 and (modal == 0 or
          owner.nodes[savedSlot].modalScopeIdentity == modal):
        target = savedSlot
        rt.modalFocusReturns.del(previousModal)

  if target < 0 and modal != 0 and
      not layout.focusableSlot(rt.focusSlot):
    target = layout.modalInitialFocus()
  if target > 0:
    rt.setRuntimeFocus(layout, target)
  rt.activeModalIdentity = modal

proc shortcutActionRegistered(rt: Runtime; mods: platform.Modifiers;
                              key: platform.Key): bool =
  let owner = rt.context.owner
  if owner == nil or owner.closed or not owner.focusActive:
    return
  let focusedIdentity = if rt.focusSlot > 0 and rt.focusSlot < owner.nodes.len:
      owner.nodes[rt.focusSlot].identity
    else:
      0'u64
  for shortcut in owner.actions:
    if shortcut.kind != actionShortcut or shortcut.modifiers != mods or
        shortcut.key != key or
        shortcut.identity == 0 or shortcut.generation != owner.generation:
      continue
    if owner.idSlots.getOrDefault(shortcut.identity, -1) < 0:
      continue
    let shortcutSlot = owner.idSlots.getOrDefault(shortcut.identity, -1)
    if not owner.inActiveModalScope(shortcutSlot):
      continue
    if focusedIdentity == 0:
      if shortcut.identity == rootIdentity:
        return true
      continue
    var identity = focusedIdentity
    var remaining = owner.identityParents.len + 1
    while identity != 0 and remaining > 0:
      if identity == shortcut.identity:
        return true
      identity = owner.identityParents.getOrDefault(identity)
      dec remaining

proc runShortcutAction(rt: Runtime; mods: platform.Modifiers;
                      key: platform.Key): bool =
  let owner = rt.context.owner
  if owner == nil or owner.closed or not owner.focusActive:
    return false
  let focusedIdentity = if rt.focusSlot > 0 and rt.focusSlot < owner.nodes.len:
      owner.nodes[rt.focusSlot].identity
    else:
      0'u64
  var winner = -1
  var bestDistance = high(int)
  for index, shortcut in owner.actions:
    if shortcut.kind != actionShortcut or shortcut.modifiers != mods or
        shortcut.key != key or
        shortcut.identity == 0 or shortcut.generation != owner.generation:
      continue
    if owner.idSlots.getOrDefault(shortcut.identity, -1) < 0:
      continue
    let shortcutSlot = owner.idSlots.getOrDefault(shortcut.identity, -1)
    if not owner.inActiveModalScope(shortcutSlot):
      continue
    if focusedIdentity == 0:
      if shortcut.identity == rootIdentity and bestDistance > 0:
        winner = index
        bestDistance = 0
      continue
    var identity = focusedIdentity
    var distance = 0
    var remaining = owner.identityParents.len + 1
    while identity != 0 and remaining > 0:
      if identity == shortcut.identity:
        if distance < bestDistance:
          winner = index
          bestDistance = distance
        break
      identity = owner.identityParents.getOrDefault(identity)
      inc distance
      dec remaining
  if winner < 0:
    return false
  let action = owner.actions[winner].action
  if action == nil:
    return false
  action()
  rt.requestFrame()
  true

proc updateTextInput(rt: Runtime)

proc textFieldTextKey(rt: Runtime; client: TextFieldClient;
                      key: platform.Key; mods: platform.Modifiers): bool =
  if client == nil or client.onTextKey == nil or client.hasMark or
      fieldTypesText(key, mods):
    return false
  if not client.fieldWantsKey(key, mods) and
      rt.shortcutActionRegistered(mods, key):
    return false

  let owner = rt.frameLayout.owner
  if owner == nil or owner.closed:
    return false
  let identity = if rt.focusSlot > 0 and rt.focusSlot < owner.nodes.len:
      owner.nodes[rt.focusSlot].identity
    else:
      0'u64
  let before = client.fieldText()
  let taken = client.dispatchTextKey(key, mods)
  let changed = before != client.fieldText()
  let textWasSet = client.textKeySet
  if changed:
    owner.deferTextInputChange(identity, owner.generation)
    rt.inputComposition.reset()
    rt.updateTextInput()
    rt.requestFrame()
  elif textWasSet:
    rt.requestFrame()
  if taken:
    rt.keyboardFocusVisible = true
    rt.requestFrame()
    return true
  false

proc submitFocusedText(rt: Runtime; mods: platform.Modifiers): bool =
  let owner = rt.context.owner
  if owner == nil or owner.closed or not owner.focusActive or mods != 0 or
      rt.focusSlot <= 0 or rt.focusSlot >= owner.nodes.len:
    return false
  let node = owner.nodes[rt.focusSlot]
  if node.textClient == nil:
    return false
  let identity = node.identity
  for action in owner.actions:
    if action.kind != actionSubmit or action.identity != identity or
        action.generation != owner.generation:
      continue
    if node.textClient of TextFieldClient:
      owner.deferTextInputSubmit(identity, owner.generation)
    else:
      let notices = owner.pendingNotices.getOrDefault(identity)
      if (notices and noticeSubmitted) == 0:
        discard owner.notifyAction(identity, owner.generation, actionSubmit)
    rt.requestFrame()
    return true
  false

proc inputChanged(rt: Runtime; slot: int; before: string)

proc inputTarget(adapter: TextInputAdapter): platform.TextInputClient =
  if adapter == nil or adapter.runtime == nil:
    return nil
  let rt = adapter.runtime
  if rt.closed or not rt.surfaceFocused or rt.focusSlot != adapter.slot or
      not rt.frameLayout.focusableSlot(adapter.slot):
    return nil
  let owner = rt.frameLayout.owner
  if owner.nodes[adapter.slot].textClient != adapter.client:
    return nil
  adapter.client

proc inputChanged(adapter: TextInputAdapter; before: string) =
  if adapter.inputTarget() != nil:
    adapter.runtime.inputChanged(adapter.slot, before)

proc inputChanged(rt: Runtime; slot: int; before: string) =
  if rt == nil or rt.closed:
    return
  let owner = rt.frameLayout.owner
  if owner != nil and not owner.closed and slot > 0 and
      slot < owner.nodes.len and owner.nodes[slot].textClient != nil:
    let identity = owner.nodes[slot].identity
    let client = owner.nodes[slot].textClient
    let changed = if client of TextFieldClient:
      let field = TextFieldClient(client)
      if field.password:
        not field.hasMark and (field.nativeChanged or
          platform.clientTextContext(client).text != before)
      else:
        platform.clientTextContext(client).text != before
    else:
      platform.clientTextContext(client).text != before
    if changed:
      if client of TextFieldClient:
        owner.deferTextInputChange(identity, owner.generation)
      else:
        discard owner.notifyAction(identity, owner.generation, actionChange)
  rt.requestFrame()
  rt.updateTextInput()

method textForRange*(adapter: TextInputAdapter; r: platform.TextRange):
    tuple[s: string, actual: platform.TextRange] =
  let client = adapter.inputTarget()
  if client != nil:
    return client.textForRange(r)
  ("", platform.TextRange())

method selection*(adapter: TextInputAdapter): platform.TextSelection =
  let client = adapter.inputTarget()
  if client != nil:
    return client.selection()
  platform.TextSelection()

method markedRange*(adapter: TextInputAdapter):
    tuple[r: platform.TextRange, ok: bool] =
  let client = adapter.inputTarget()
  if client != nil:
    return client.markedRange()
  (platform.TextRange(), false)

method replaceText*(adapter: TextInputAdapter; r: ref platform.TextRange;
                    value: string) =
  let client = adapter.inputTarget()
  if client != nil:
    let before = platform.clientTextContext(adapter).text
    client.replaceText(r, value)
    adapter.inputChanged(before)

method setMarkedText*(adapter: TextInputAdapter; r: ref platform.TextRange;
                      value: string; selected: platform.TextRange) =
  let client = adapter.inputTarget()
  if client != nil:
    let before = platform.clientTextContext(adapter).text
    client.setMarkedText(r, value, selected)
    adapter.inputChanged(before)

method unmarkText*(adapter: TextInputAdapter) =
  let client = adapter.inputTarget()
  if client != nil:
    let before = platform.clientTextContext(adapter).text
    client.unmarkText()
    adapter.inputChanged(before)

method boundsForRange*(adapter: TextInputAdapter; r: platform.TextRange):
    tuple[bounds: platform.RectF, actual: platform.TextRange, ok: bool] =
  let client = adapter.inputTarget()
  if client == nil:
    return (platform.RectF(), platform.TextRange(), false)
  result = client.boundsForRange(r)
  if result.ok:
    let layout = adapter.runtime.frameLayout
    let bounds = layout.transformedLocalRect(adapter.slot, Rect(
      x: float32(result.bounds.x), y: float32(result.bounds.y),
      w: float32(result.bounds.w), h: float32(result.bounds.h)))
    result.bounds = platform.RectF(x: float64(bounds.x),
      y: float64(bounds.y), w: float64(bounds.w), h: float64(bounds.h))

method indexForPoint*(adapter: TextInputAdapter; x, y: float64):
    tuple[i: int, ok: bool] =
  let client = adapter.inputTarget()
  if client == nil:
    return (0, false)
  let (localX, localY, ok) = adapter.runtime.frameLayout.localPoint(
    adapter.slot, float32(x), float32(y))
  if not ok:
    return (0, false)
  let rect = adapter.runtime.frameLayout.rects[adapter.slot]
  client.indexForPoint(float64(localX - rect.x), float64(localY - rect.y))

proc release(adapter: TextInputAdapter) =
  if adapter == nil or adapter.client == nil:
    return
  let (_, marked) = adapter.client.markedRange()
  if marked:
    adapter.client.unmarkText()
  adapter.client = nil

proc sameTextInput(a, b: platform.TextInputState): bool =
  a.active == b.active and a.caret.x == b.caret.x and
    a.caret.y == b.caret.y and a.caret.w == b.caret.w and
    a.caret.h == b.caret.h and a.text == b.text and
    a.start == b.start and a.`end` == b.`end` and a.client == b.client and
    a.noInputMethod == b.noInputMethod

proc utf16AtRune(value: string; offset: int): int =
  var left = max(offset, 0)
  for rune in value.runes:
    if left <= 0:
      break
    result += (if ord(rune) > 0xFFFF: 2 else: 1)
    dec left

proc runeAtUtf16(value: string; offset: int): int =
  let target = max(offset, 0)
  var units = 0
  for rune in value.runes:
    let count = if ord(rune) > 0xFFFF: 2 else: 1
    if units + count > target:
      break
    units += count
    inc result

proc inputRange(rt: Runtime; first, pastLast: int): platform.TextRange =
  if rt.textInputAdapter == nil or
      rt.textInputAdapter.inputTarget() == nil:
    return
  let context = platform.clientTextContext(rt.textInputAdapter)
  context.range(platform.TextRange(start: utf16AtRune(context.text, first),
    `end`: utf16AtRune(context.text, pastLast)))

proc updateTextInput(rt: Runtime) =
  if rt.closed or rt.conn.surface == nil:
    return
  let frameOwner = rt.frameLayout.owner
  if frameOwner != nil and
      rt.frameLayout.rects.len == frameOwner.nodes.len:
    var areaLayoutChanged = false
    for slot in 1..<frameOwner.nodes.len:
      let node = frameOwner.nodes[slot]
      if node.textClient of TextFieldClient and
          TextFieldClient(node.textClient).multiline:
        let field = TextFieldClient(node.textClient)
        field.insetX = node.pad[3] + node.border[3]
        field.insetY = node.pad[0] + node.border[0]
        field.style = node.textStyle
        field.rightToLeft = node.rightToLeft
        areaLayoutChanged = field.captureAreaLayout(frameOwner,
          rt.frameLayout.rects, slot) or areaLayoutChanged
    if areaLayoutChanged:
      rt.requestFrame()
  var focusedClient: platform.TextInputClient
  var focusedSlot = -1
  if rt.surfaceFocused and rt.frameLayout.focusableSlot(rt.focusSlot):
    let owner = rt.frameLayout.owner
    focusedSlot = rt.focusSlot
    focusedClient = owner.nodes[focusedSlot].textClient

  if focusedClient == nil:
    if rt.textInputAdapter != nil:
      rt.textInputAdapter.release()
      rt.textInputAdapter = nil
      rt.inputComposition.reset()
  elif rt.textInputAdapter == nil or
      rt.textInputAdapter.slot != focusedSlot or
      rt.textInputAdapter.client != focusedClient:
    if rt.textInputAdapter != nil:
      rt.textInputAdapter.release()
      rt.inputComposition.reset()
    rt.textInputAdapter = TextInputAdapter(runtime: rt, slot: focusedSlot,
                                            client: focusedClient)

  if focusedClient of TextFieldClient:
    let node = rt.frameLayout.owner.nodes[focusedSlot]
    let field = TextFieldClient(focusedClient)
    field.insetX = node.pad[3] + node.border[3]
    field.insetY = node.pad[0] + node.border[0]
    field.style = node.textStyle
    field.rightToLeft = node.rightToLeft
    field.rebuildFieldLayout()

  var state: platform.TextInputState
  if rt.textInputAdapter != nil:
    let adapter = rt.textInputAdapter
    let context = platform.clientTextContext(adapter)
    state.active = true
    state.noInputMethod = rt.frameLayout.owner.nodes[focusedSlot].noInputMethod
    state.client = adapter
    state.text = context.text
    state.start = runeAtUtf16(context.text, context.start)
    state.`end` = runeAtUtf16(context.text, context.`end`)
    let selected = adapter.selection()
    let selection = selected.`range`
    let caret = if selected.reversed: selection.start else: selection.`end`
    let (bounds, _, hasBounds) = adapter.boundsForRange(
      platform.TextRange(start: caret, `end`: caret))
    if hasBounds:
      state.caret = bounds
    else:
      let rect = rt.frameLayout.rects[focusedSlot]
      let caret = rt.frameLayout.transformedLocalRect(focusedSlot,
        Rect(w: 1, h: max(rect.h, 1'f32)))
      state.caret = platform.RectF(x: float64(caret.x),
        y: float64(caret.y), w: float64(caret.w), h: float64(caret.h))

  if not rt.hasTextInputState and not state.active:
    return
  if rt.hasTextInputState and rt.lastTextInput.sameTextInput(state):
    return
  if rt.hasTextInputState and rt.lastTextInput.active and
      rt.lastTextInput.noInputMethod != state.noInputMethod:
    rt.inputComposition.reset()
  rt.conn.surface.setTextInput(state)
  rt.lastTextInput = state
  rt.hasTextInputState = true

proc editTextField(rt: Runtime; client: TextFieldClient;
                   range: platform.TextRange; value: string) =
  if client.readOnly:
    return
  let before = platform.clientTextContext(client).text
  rt.inputComposition.reset()
  let target = new platform.TextRange
  target[] = range
  client.replaceText(target, value)
  rt.inputChanged(rt.focusSlot, before)
  rt.keyboardFocusVisible = true
  rt.updateTextInput()

proc textFieldCommand(rt: Runtime; command: string): bool =
  let owner = rt.frameLayout.owner
  if owner == nil or rt.focusSlot <= 0 or rt.focusSlot >= owner.nodes.len:
    return false
  let rawClient = owner.nodes[rt.focusSlot].textClient
  if not (rawClient of TextFieldClient):
    return false
  let client = TextFieldClient(rawClient)
  if client.hasMark:
    return command in ["copy", "cut", "paste", "pasteAndMatchStyle",
                       "selectAll", "delete", "undo", "redo"]

  let selected = client.fieldRange()
  case command
  of "copy":
    if client.password:
      return true
    let (text, actual) = client.textForRange(selected)
    if actual.start < actual.`end` and rt.conn != nil and
        rt.conn.clipboard != nil:
      rt.conn.clipboard.writeText(text)
    true
  of "cut":
    if client.readOnly or client.password:
      return true
    let (text, actual) = client.textForRange(selected)
    if actual.start < actual.`end`:
      if rt.conn != nil and rt.conn.clipboard != nil:
        rt.conn.clipboard.writeText(text)
      client.areaUndoGroupOpen = false
      client.textUndoGroupOpen = false
      rt.editTextField(client, actual, "")
    true
  of "paste", "pasteAndMatchStyle":
    if client.readOnly:
      return true
    let text = if rt.conn != nil and rt.conn.clipboard != nil:
        rt.conn.clipboard.readText()
      else:
        ""
    if client.onPaste != nil:
      let taken = client.onPaste(text)
      rt.requestFrame()
      if taken:
        return true
    if text.len > 0:
      let (_, actual) = client.textForRange(selected)
      client.areaUndoGroupOpen = false
      client.textUndoGroupOpen = false
      rt.editTextField(client, actual, text)
      client.areaUndoGroupOpen = false
      client.textUndoGroupOpen = false
    true
  of "selectAll":
    client.areaUndoGroupOpen = false
    client.textUndoGroupOpen = false
    client.anchor = 0
    client.caret = client.fieldUtf16Len()
    client.areaHasDesiredX = false
    rt.keyboardFocusVisible = true
    rt.updateTextInput()
    rt.requestFrame()
    true
  of "delete":
    let (_, actual) = client.textForRange(selected)
    if not client.readOnly and actual.start < actual.`end`:
      client.areaUndoGroupOpen = false
      client.textUndoGroupOpen = false
      rt.editTextField(client, actual, "")
    true
  of "undo", "redo":
    if client.readOnly:
      return true
    client.areaUndoGroupOpen = false
    client.textUndoGroupOpen = false
    let changed = if command == "undo":
      if client.multiline: client.undoTextArea()
      else: client.undoTextField()
    else:
      if client.multiline: client.redoTextArea()
      else: client.redoTextField()
    if changed:
      owner.deferTextInputChange(owner.nodes[rt.focusSlot].identity,
                                 owner.generation)
      rt.keyboardFocusVisible = true
      rt.updateTextInput()
      rt.requestFrame()
    true
  else:
    false

when defined(macosx):
  proc deleteToParagraphEnd(rt: Runtime; client: TextFieldClient): bool =
    if client.readOnly:
      return true
    let current = client.fieldRuneIndex(client.caret)
    let paragraph = client.fieldParagraphRange(current)
    var pastLast = paragraph.`end`
    if pastLast == current and pastLast < client.fieldRuneLen():
      inc pastLast
    if current < pastLast:
      rt.editTextField(client, platform.TextRange(
        start: client.fieldUtf16Offset(current),
        `end`: client.fieldUtf16Offset(pastLast)), "")
    true

proc textFieldKey(rt: Runtime; key: platform.Key;
                  mods: platform.Modifiers): bool =
  let owner = rt.frameLayout.owner
  if owner == nil or rt.focusSlot <= 0 or rt.focusSlot >= owner.nodes.len:
    return false
  let rawClient = owner.nodes[rt.focusSlot].textClient
  if not (rawClient of TextFieldClient):
    return false
  let client = TextFieldClient(rawClient)
  if client.hasMark:
    return true
  if rt.textFieldTextKey(client, key, mods):
    return true

  let extend = (mods and platform.modShift) != 0
  when defined(macosx):
    let emacsBaseMods = mods and not platform.modShift
    if emacsBaseMods == platform.modCtrl:
      case key
      of platform.keyA, platform.keyE:
        client.fieldMoveParagraphEdge(key == platform.keyE, extend)
        rt.keyboardFocusVisible = true
        rt.updateTextInput()
        rt.requestFrame()
        return true
      of platform.keyK:
        return rt.deleteToParagraphEnd(client)
      of platform.keyB:
        return rt.textFieldKey(platform.keyLeft,
          if extend: platform.modShift else: 0)
      of platform.keyF:
        return rt.textFieldKey(platform.keyRight,
          if extend: platform.modShift else: 0)
      of platform.keyP:
        return rt.textFieldKey(platform.keyUp,
          if extend: platform.modShift else: 0)
      of platform.keyN:
        return rt.textFieldKey(platform.keyDown,
          if extend: platform.modShift else: 0)
      of platform.keyH:
        return rt.textFieldKey(platform.keyBackspace,
          if extend: platform.modShift else: 0)
      of platform.keyD:
        return rt.textFieldKey(platform.keyDelete,
          if extend: platform.modShift else: 0)
      else:
        discard

  let command = when defined(macosx): platform.modSuper else: platform.modCtrl
  if key == platform.keyZ and
      (mods == command or mods == (command or platform.modShift)):
    client.areaUndoGroupOpen = false
    client.textUndoGroupOpen = false
    if client.readOnly:
      return true
    let changed = if (mods and platform.modShift) != 0:
        (if client.multiline: client.redoTextArea()
          else: client.redoTextField())
      else:
        (if client.multiline: client.undoTextArea()
          else: client.undoTextField())
    if changed:
      let identity = owner.nodes[rt.focusSlot].identity
      owner.deferTextInputChange(identity, owner.generation)
      rt.keyboardFocusVisible = true
      rt.updateTextInput()
      rt.requestFrame()
    return true

  if mods == command:
    case key
    of platform.keyC:
      return rt.textFieldCommand("copy")
    of platform.keyX:
      return rt.textFieldCommand("cut")
    of platform.keyV:
      return rt.textFieldCommand("paste")
    else:
      discard
  elif mods == (command or platform.modShift) and key == platform.keyV:
    return rt.textFieldCommand("pasteAndMatchStyle")

  if key == platform.keyA and mods == command:
    client.areaUndoGroupOpen = false
    client.textUndoGroupOpen = false
    client.anchor = 0
    client.caret = client.fieldUtf16Len()
    client.areaHasDesiredX = false
    rt.keyboardFocusVisible = true
    rt.updateTextInput()
    rt.requestFrame()
    return true

  let baseMods = mods and not platform.modShift
  let wordMods = when defined(macosx): platform.modAlt
    else: platform.modCtrl
  let wordMove = baseMods == wordMods
  let lineMove = when defined(macosx): baseMods == platform.modSuper
    else: false
  if key in {platform.keyLeft, platform.keyRight} and
      (baseMods == 0 or wordMove or lineMove):
    if lineMove:
      let current = client.fieldRuneIndex(client.caret)
      let rtl = client.fieldCaretRightToLeft(current)
      let forward = if rtl: key == platform.keyLeft
        else: key == platform.keyRight
      discard client.fieldMove(
        if forward: platform.keyEnd else: platform.keyHome, extend)
    else:
      discard client.fieldMove(key, extend, byWord = wordMove)
    rt.keyboardFocusVisible = true
    rt.updateTextInput()
    rt.requestFrame()
    return true

  if key in {platform.keyHome, platform.keyEnd} and
      baseMods in {0'u8, platform.modCtrl}:
    discard client.fieldMove(key, extend,
      documentEdge = baseMods == platform.modCtrl)
    rt.keyboardFocusVisible = true
    rt.updateTextInput()
    rt.requestFrame()
    return true

  let documentVertical = when defined(macosx):
      baseMods == platform.modSuper and
        key in {platform.keyUp, platform.keyDown}
    else:
      false
  if key in {platform.keyUp, platform.keyDown} and
      (baseMods == 0 or documentVertical):
    if documentVertical:
      discard client.fieldMove(
        if key == platform.keyUp: platform.keyHome else: platform.keyEnd,
        extend, documentEdge = true)
    else:
      discard client.fieldMove(key, extend)
    rt.keyboardFocusVisible = true
    rt.updateTextInput()
    rt.requestFrame()
    return true

  if client.multiline and key == platform.keyEnter and mods == 0:
    if client.readOnly:
      return true
    if rt.textInputAdapter == nil:
      return false
    let replacement = new platform.TextRange
    replacement[] = client.fieldRange()
    rt.keyboardFocusVisible = true
    rt.inputComposition.reset()
    rt.textInputAdapter.replaceText(replacement, "\n")
    return true

  let wordDelete = baseMods == wordMods
  let lineDelete = when defined(macosx): baseMods == platform.modSuper
    else: false
  if key in {platform.keyBackspace, platform.keyDelete} and
      (baseMods == 0 or wordDelete or
       (lineDelete and key == platform.keyBackspace)):
    if client.readOnly:
      return true
    let (range, ok) = client.fieldDeleteRange(key,
      byWord = wordDelete, toLineStart = lineDelete)
    if not ok:
      return true
    if rt.textInputAdapter == nil:
      return false
    let replacement = new platform.TextRange
    replacement[] = range
    rt.keyboardFocusVisible = true
    rt.inputComposition.reset()
    rt.textInputAdapter.replaceText(replacement, "")
    return true
  false

proc textInputSlot(owner: ElementOwner; slot: int): int =
  result = -1
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return
  var current = slot
  while current > 0 and current < owner.nodes.len:
    let node = owner.nodes[current]
    if node.textClient of TextFieldClient:
      return current
    if node.textAreaOwner of TextFieldClient:
      let parent = int(node.parent)
      if parent > 0 and parent < owner.nodes.len and
          owner.nodes[parent].textClient == node.textAreaOwner:
        return parent
      return
    current = int(node.parent)

proc updatePointerCursor(rt: Runtime) =
  var cursor = platform.cursorDefault
  if rt.hasPointer:
    var slot = -1
    let owner = rt.frameLayout.owner
    if owner != nil and rt.pressTarget.owner == owner and
        int(rt.pressTarget.slot) > 0 and
        int(rt.pressTarget.slot) < owner.nodes.len and
        owner.nodes[int(rt.pressTarget.slot)].splitHandle:
      slot = int(rt.pressTarget.slot)
    else:
      let target = rt.frameLayout.targetAt(rt.pointerX, rt.pointerY)
      if target.owner != nil:
        slot = int(target.slot)
    if slot > 0 and slot < owner.nodes.len:
      let node = owner.nodes[slot]
      if node.pointerCursorSet:
        cursor = node.pointerCursor
      elif node.splitHandle:
        cursor = if node.splitVertical: platform.cursorResizeNS
          else: platform.cursorResizeEW
      elif node.tableResizeHandle:
        cursor = platform.cursorResizeEW
      elif node.textClient != nil or node.textAreaOwner != nil:
        cursor = platform.cursorText
  if not rt.hasPointerCursor or rt.pointerCursor != cursor:
    rt.conn.surface.setCursor(cursor)
    rt.pointerCursor = cursor
    rt.hasPointerCursor = true

proc refreshPointer(rt: Runtime) =
  if rt.frameLayout.owner != nil and not rt.frameLayout.owner.closed:
    rt.frameLayout.owner.pointerX = rt.pointerX
    rt.frameLayout.owner.pointerY = rt.pointerY
    rt.frameLayout.owner.hasPointer = rt.hasPointer
  rt.hoverSlots.setLen(0)
  rt.pressedSlots.setLen(0)
  let under = if rt.hasPointer:
      rt.frameLayout.slotsAt(rt.pointerX, rt.pointerY)
    else:
      @[]
  if rt.pressTarget.owner != nil:
    for slot in rt.pressHoverSlots:
      if slot in under:
        rt.hoverSlots.add(slot)
        rt.pressedSlots.add(slot)
  else:
    rt.hoverSlots = under
    rt.pressedSlots.setLen(0)
  if rt.frameLayout.clickableSlot(rt.keyPressSlot) and
      rt.focusSlot == rt.keyPressSlot and rt.keyPressSlot notin rt.pressedSlots:
    rt.pressedSlots.add(rt.keyPressSlot)
  rt.updatePointerCursor()

proc sliderAncestor(layout: LayoutResult; slot: int): int =
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation:
    return -1
  var current = slot
  while current > 0 and current < owner.nodes.len:
    let node = owner.nodes[current]
    if node.slider or node.rangeSlider:
      return current
    current = int(node.parent)
  -1

proc colorPlaneAncestor(owner: ElementOwner; slot: int): int =
  if owner == nil or owner.closed or slot <= 0 or slot >= owner.nodes.len:
    return -1
  var current = slot
  while current > 0 and current < owner.nodes.len:
    if owner.nodes[current].colorPlane:
      return current
    current = int(owner.nodes[current].parent)
  -1

proc queueSliderValue(rt: Runtime; slot: int; value: float64): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation or
      slot <= 0 or slot >= owner.nodes.len:
    return false
  let node = owner.nodes[slot]
  if not node.slider or classify(value) in {fcNan, fcInf, fcNegInf}:
    return false
  let identity = node.identity
  let current = owner.pendingSliderValues.getOrDefault(identity,
    node.sliderValue)
  var low = node.sliderLow
  var high = node.sliderHigh
  if node.splitHandle:
    let ancestor = owner.splitRootSlot(slot)
    if ancestor > 0 and ancestor < layout.rects.len:
      let bounds = layout.rects[ancestor]
      let total = if node.splitVertical: bounds.h else: bounds.w
      high = max(float64(total) - 1 - low, low)
  let next = if node.splitHandle:
      min(max(value, low), high)
    else:
      let snapped = value.snapSliderValue(low, high, node.sliderStep)
      min(max(snapped, node.sliderClampLow), node.sliderClampHigh)
  if next == current:
    return false
  owner.pendingSliderValues[identity] = next
  rt.requestFrame()
  true

proc beginSplitPointer(rt: Runtime; slot: int) =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return
  let rootSlot = owner.splitRootSlot(slot)
  if rootSlot <= 0 or rootSlot >= layout.rects.len:
    return
  let node = owner.nodes[slot]
  let bounds = layout.rects[rootSlot]
  let (pointerX, pointerY, ok) = layout.localPoint(rootSlot,
    rt.pointerX, rt.pointerY)
  if not ok:
    return
  let raw = if node.splitVertical:
      pointerY - bounds.y - 0.5'f32
    elif node.rightToLeft:
      bounds.x + bounds.w - pointerX - 0.5'f32
    else:
      pointerX - bounds.x - 0.5'f32
  let current = owner.pendingSliderValues.getOrDefault(node.identity,
    node.sliderValue)
  rt.splitPointerOffset = float64(raw) - current

proc rangeSliderThumbSlot(owner: ElementOwner; rootSlot: int;
                          handle: int8): int =
  if owner == nil or rootSlot <= 0 or rootSlot >= owner.nodes.len:
    return -1
  var child = int(owner.nodes[rootSlot].firstChild)
  while child > 0 and child < owner.nodes.len:
    let node = owner.nodes[child]
    if node.rangeSliderThumb and node.rangeSliderHandle == handle:
      return child
    child = int(node.nextSibling)
  -1

proc queueRangeSliderPointer(rt: Runtime; slot: int;
                             activatePointer: bool): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  let hitNode = owner.nodes[slot]
  let rootSlot = if hitNode.rangeSlider: slot else: int(hitNode.parent)
  if rootSlot <= 0 or rootSlot >= owner.nodes.len or
      not owner.nodes[rootSlot].rangeSlider or rootSlot >= layout.rects.len:
    return false
  let root = owner.nodes[rootSlot]
  let lowSlot = owner.rangeSliderThumbSlot(rootSlot, 0)
  let highSlot = owner.rangeSliderThumbSlot(rootSlot, 1)
  if lowSlot < 0 or highSlot < 0:
    return false

  let bounds = layout.rects[rootSlot]
  let (pointerX, _, ok) = layout.localPoint(rootSlot, rt.pointerX,
    rt.pointerY)
  if not ok:
    return false
  let left = bounds.x + root.border[3] + root.pad[3]
  let width = bounds.w - root.contentInsetX
  if width <= 0:
    return false
  var fraction = (pointerX - left) / width
  if root.rightToLeft:
    fraction = 1'f32 - fraction
  fraction = max(0'f32, min(1'f32, fraction))
  let targetValue = root.sliderLow + fraction.float64 *
    (root.sliderHigh - root.sliderLow)

  var handle = if hitNode.rangeSliderThumb:
      hitNode.rangeSliderHandle
    else:
      -1'i8
  if activatePointer or not owner.rangeSliderDrags.hasKey(root.identity):
    if handle < 0:
      let lowValue = owner.nodes[lowSlot].sliderValue
      let highValue = owner.nodes[highSlot].sliderValue
      handle = if abs(targetValue - highValue) < abs(targetValue - lowValue) or
          targetValue > highValue: 1'i8 else: 0'i8
  else:
    handle = owner.rangeSliderDrags[root.identity]
  if activatePointer:
    owner.rangeSliderDrags[root.identity] = handle

  let thumbSlot = if handle == 0: lowSlot else: highSlot
  let focusChanged = rt.focusSlot != thumbSlot or rt.keyboardFocusVisible
  rt.focusSlot = thumbSlot
  rt.keyboardFocusVisible = false
  rt.cancelKeyPress()
  if focusChanged:
    rt.requestFrame()
  rt.queueSliderValue(thumbSlot, targetValue) or focusChanged

proc rangeSliderIdentity(owner: ElementOwner; slot: int): uint64 =
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return 0
  let node = owner.nodes[slot]
  if node.rangeSlider:
    return node.identity
  if node.rangeSliderThumb:
    let parent = int(node.parent)
    if parent > 0 and parent < owner.nodes.len and
        owner.nodes[parent].rangeSlider:
      return owner.nodes[parent].identity
  0

proc queueSliderPointer(rt: Runtime; slot: int;
                        activatePointer = false): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation or
      slot <= 0 or slot >= owner.nodes.len or
      slot >= layout.rects.len or
      classify(rt.pointerX) in {fcNan, fcInf, fcNegInf} or
      classify(rt.pointerY) in {fcNan, fcInf, fcNegInf}:
    return false
  let node = owner.nodes[slot]
  if node.rangeSlider or node.rangeSliderThumb:
    return rt.queueRangeSliderPointer(slot, activatePointer)
  if node.splitHandle:
    if activatePointer:
      return false
    let ancestor = owner.splitRootSlot(slot)
    if ancestor <= 0 or ancestor >= layout.rects.len:
      return false
    let (pointerX, pointerY, ok) = layout.localPoint(ancestor,
      rt.pointerX, rt.pointerY)
    if not ok:
      return false
    let bounds = layout.rects[ancestor]
    let position = if node.splitVertical:
        pointerY - bounds.y
      elif node.rightToLeft:
        bounds.x + bounds.w - pointerX
      else:
        pointerX - bounds.x
    return rt.queueSliderValue(slot,
      float64(position - 0.5'f32) - rt.splitPointerOffset)
  if node.stepper or (node.rating and not activatePointer):
    return false
  let (pointerX, pointerY, ok) = layout.localPoint(slot,
    rt.pointerX, rt.pointerY)
  if not ok:
    return false
  let bounds = layout.rects[slot]
  var fraction: float32
  if node.sliderVertical:
    let top = bounds.y + node.border[0] + node.pad[0]
    let height = bounds.h - node.contentInsetY
    if height <= 0:
      return false
    fraction = 1 - (pointerY - top) / height
  else:
    let left = bounds.x + node.border[3] + node.pad[3]
    let width = bounds.w - node.contentInsetX
    if width <= 0:
      return false
    fraction = (pointerX - left) / width
    if node.rightToLeft:
      fraction = 1 - fraction
  fraction = max(0'f32, min(1'f32, fraction))
  if node.rating:
    let maximum = int(node.sliderHigh - node.sliderLow)
    if maximum <= 0:
      return false
    let index = min(max(int(floor(float64(fraction) * float64(maximum))) + 1,
      1), maximum)
    let identity = node.identity
    let current = owner.pendingSliderValues.getOrDefault(identity,
      node.sliderValue)
    let next = if current == float64(index): node.sliderLow
      else: float64(index)
    return rt.queueSliderValue(slot, next)
  let value = node.sliderLow + fraction.float64 *
    (node.sliderHigh - node.sliderLow)
  rt.queueSliderValue(slot, value)

proc queueColorPlanePointer(rt: Runtime; slot: int): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or owner.closed or layout.generation != owner.generation or
      slot <= 0 or slot >= owner.nodes.len or slot >= layout.rects.len:
    return false
  let node = owner.nodes[slot]
  if not node.colorPlane or
      classify(rt.pointerX) in {fcNan, fcInf, fcNegInf} or
      classify(rt.pointerY) in {fcNan, fcInf, fcNegInf}:
    return false
  let (pointerX, pointerY, ok) = layout.localPoint(slot,
    rt.pointerX, rt.pointerY)
  if not ok:
    return false
  let bounds = layout.rects[slot]
  let left = bounds.x + node.border[3] + node.pad[3]
  let top = bounds.y + node.border[0] + node.pad[0]
  let width = bounds.w - node.contentInsetX
  let height = bounds.h - node.contentInsetY
  if width <= 0 or height <= 0:
    return false
  let current = owner.pendingColorPlanes.getOrDefault(node.identity,
    ColorPlaneValue(saturation: node.colorPlaneSaturation,
                    brightness: node.colorPlaneBrightness))
  let next = ColorPlaneValue(
    saturation: min(max(float64((pointerX - left) / width), 0), 1),
    brightness: min(max(float64(1 - (pointerY - top) / height), 0), 1))
  if next == current:
    return false
  owner.pendingColorPlanes[node.identity] = next
  rt.requestFrame()
  true

proc sliderKey(rt: Runtime; key: platform.Key;
               mods: platform.Modifiers): bool =
  if mods != 0 or not rt.frameLayout.focusableSlot(rt.focusSlot):
    return false
  let owner = rt.frameLayout.owner
  if owner == nil or rt.focusSlot <= 0 or rt.focusSlot >= owner.nodes.len:
    return false
  let node = owner.nodes[rt.focusSlot]
  if node.colorPlane:
    let current = owner.pendingColorPlanes.getOrDefault(node.identity,
      ColorPlaneValue(saturation: node.colorPlaneSaturation,
                      brightness: node.colorPlaneBrightness))
    var next = current
    case key
    of platform.keyLeft:
      next.saturation = max(0, current.saturation - 0.01)
    of platform.keyRight:
      next.saturation = min(1, current.saturation + 0.01)
    of platform.keyDown:
      next.brightness = max(0, current.brightness - 0.01)
    of platform.keyUp:
      next.brightness = min(1, current.brightness + 0.01)
    else:
      return false
    if next != current:
      owner.pendingColorPlanes[node.identity] = next
      rt.requestFrame()
    return true
  if not node.slider:
    return false
  let identity = node.identity
  let current = owner.pendingSliderValues.getOrDefault(identity,
    node.sliderValue)
  if node.splitHandle:
    var value = current
    let step = node.sliderStep
    if node.sliderVertical:
      case key
      of platform.keyUp: value -= step
      of platform.keyDown: value += step
      else: return false
    else:
      case key
      of platform.keyLeft:
        value += (if node.rightToLeft: step else: -step)
      of platform.keyRight:
        value += (if node.rightToLeft: -step else: step)
      else: return false
    discard rt.queueSliderValue(rt.focusSlot, value)
    return true
  let range = node.sliderHigh - node.sliderLow
  let step = if node.sliderStep > 0: node.sliderStep else: range / 100
  let pageStep = max(step, range / 10)
  var value = current
  if node.stepper:
    case key
    of platform.keyLeft:
      value += (if node.rightToLeft: step else: -step)
    of platform.keyRight:
      value += (if node.rightToLeft: -step else: step)
    of platform.keyDown:
      value -= step
    of platform.keyUp:
      value += step
    of platform.keyHome:
      value = node.sliderClampLow
    of platform.keyEnd:
      value = node.sliderClampHigh
    else:
      return false
    discard rt.queueSliderValue(rt.focusSlot, value)
    return true
  case key
  of platform.keyLeft:
    value += (if node.rightToLeft and not node.sliderVertical: step else: -step)
  of platform.keyRight:
    value += (if node.rightToLeft and not node.sliderVertical: -step else: step)
  of platform.keyDown:
    value -= step
  of platform.keyUp:
    value += step
  of platform.keyPageDown:
    value -= pageStep
  of platform.keyPageUp:
    value += pageStep
  of platform.keyHome:
    value = node.sliderClampLow
  of platform.keyEnd:
    value = node.sliderClampHigh
  else:
    return false
  discard rt.queueSliderValue(rt.focusSlot, value)
  true

proc autoScrollListReorder(rt: Runtime; state: ListState): bool
proc gridReorderTarget(rt: Runtime; state: GridState)
proc autoScrollGridReorder(rt: Runtime; state: GridState): bool
proc paintLocalDrag(rt: Runtime; frame: var scene.Scene)
proc showMenuButton(rt: Runtime; identity: uint64;
                    build: proc(menu: Menu) {.closure.})

proc beginPointerDraggable(rt: Runtime) =
  rt.pointerDraggableIdentity = 0
  rt.pointerDraggableMoved = false
  rt.pointerDraggableCaught = false
  rt.pointerDraggableReleasePending = false
  rt.pointerDraggableCanceled = false
  let owner = rt.frameLayout.owner
  if owner == nil or rt.pressTarget.owner != owner:
    return
  if rt.listReorder != nil or rt.gridReorder != nil or
      rt.tableReorder != nil:
    return
  var slot = int(rt.pressTarget.slot)
  if owner.textInputSlot(slot) >= 0 or
      rt.frameLayout.sliderAncestor(slot) >= 0 or
      owner.colorPlaneAncestor(slot) >= 0:
    return
  var child = slot
  while child > 0 and child < owner.nodes.len:
    if owner.nodes[child].splitHandle or
        owner.nodes[child].tableResizeHandle:
      return
    child = int(owner.nodes[child].parent)
  while slot > 0 and slot < owner.nodes.len:
    let node = owner.nodes[slot]
    if node.draggable and not owner.effectivelyDisabled(slot):
      rt.pointerDraggableIdentity = node.identity
      rt.pointerDraggableCaught = node.draggableMoving
      if rt.pointerDraggableSerial == high(uint64):
        rt.pointerDraggableSerial = 1
      else:
        inc rt.pointerDraggableSerial
      rt.pointerDraggableLastX = rt.pointerX
      rt.pointerDraggableLastY = rt.pointerY
      rt.pointerDraggableVelocityX = 0
      rt.pointerDraggableVelocityY = 0
      rt.pointerDraggableLastAt = getMonoTime()
      return
    slot = int(node.parent)

proc updatePointerDraggable(rt: Runtime) =
  if rt.pointerDraggableIdentity == 0 or
      rt.pointerDraggableReleasePending:
    return
  let now = getMonoTime()
  let elapsed = float64((now - rt.pointerDraggableLastAt).inNanoseconds) /
    1_000_000_000
  let movedX = rt.pointerX != rt.pointerDraggableLastX
  let movedY = rt.pointerY != rt.pointerDraggableLastY
  if (movedX or movedY) and elapsed > 0 and elapsed <= 0.1:
    rt.pointerDraggableVelocityX =
      float32((rt.pointerX - rt.pointerDraggableLastX) / elapsed)
    rt.pointerDraggableVelocityY =
      float32((rt.pointerY - rt.pointerDraggableLastY) / elapsed)
  elif elapsed > 0.1 or elapsed < 0:
    rt.pointerDraggableVelocityX = 0
    rt.pointerDraggableVelocityY = 0
  rt.pointerDraggableLastX = rt.pointerX
  rt.pointerDraggableLastY = rt.pointerY
  rt.pointerDraggableLastAt = now
  let dx = rt.pointerX - rt.pressX
  let dy = rt.pointerY - rt.pressY
  if dx * dx + dy * dy >= 16:
    rt.pointerDraggableMoved = true

proc renderFrame(rt: Runtime; presentFrame = true) =
  if rt.closed or rt.inFrame:
    return
  rt.inFrame = true
  rt.poseOnlyFrame = true
  defer: rt.inFrame = false

  let size = rt.conn.surface.size()
  let width = frameDimension(size.width, "width")
  let height = frameDimension(size.height, "height")
  let scale = if classify(size.scale) in {fcNan, fcInf, fcNegInf} or
      size.scale <= 0 or size.scale > float64(high(float32)):
    1'f32
  else:
    float32(size.scale)

  if rt.themeDirty:
    rt.updateSystemTheme()
  rt.context.owner.focusActive = rt.surfaceFocused
  rt.context.theme = rt.systemTheme
  rt.context.rightToLeft = rt.conn.rightToLeft != nil and
    rt.conn.rightToLeft()
  rt.context.localeTag = if rt.conn.locale == nil: "" else: rt.conn.locale()
  rt.context.region = if rt.conn.region == nil: i18n.Region()
    else: rt.conn.region()
  rt.context.titleBar = if rt.conn.titleBar == nil: platform.TitleBar()
    else: rt.conn.titleBar()
  rt.context.vibrancy = rt.conn.vibrancy != nil and rt.conn.vibrancy()
  rt.context.openURL = rt.conn.openURL
  rt.context.openMenu = proc(identity: uint64;
      build: proc(menu: Menu) {.closure.}) =
    rt.showMenuButton(identity, build)
  rt.context.queueClick = proc(identity: uint64) =
    let owner = rt.context.owner
    if owner == nil or not owner.idSlots.hasKey(identity):
      return
    let slot = owner.idSlots[identity]
    if slot > 0 and slot < owner.nodes.len and
        owner.nodes[slot].clickHandler != nil and
        not owner.effectivelyDisabled(slot) and
        slot notin rt.clickedSlots:
      rt.clickedSlots.add(slot)
  rt.context.themeEnabled = true
  rt.context.themeBackground = false

  rt.refreshPointer()
  let previousOwner = rt.context.owner
  var previousIdentities = newSeq[uint64](previousOwner.nodes.len)
  for slot, node in previousOwner.nodes:
    previousIdentities[slot] = node.identity
  previousOwner.focusIdentity =
    if rt.focusSlot > 0 and rt.focusSlot < previousIdentities.len:
      previousIdentities[rt.focusSlot]
    else:
      0'u64
  let previousFocusIdentity = previousOwner.focusIdentity
  previousOwner.previousInteraction.clear()
  previousOwner.rememberInteraction(previousIdentities, rt.hoverSlots,
    identityHovered)
  previousOwner.rememberInteraction(previousIdentities, rt.pressedSlots,
    identityPressed)
  previousOwner.rememberInteraction(previousIdentities, rt.clickedSlots,
    identityClicked)
  previousOwner.rememberInteraction(previousIdentities, rt.doubleClickedSlots,
    identityDoubleClicked)
  if rt.focusSlot > 0 and rt.focusSlot < previousIdentities.len:
    let identity = previousIdentities[rt.focusSlot]
    previousOwner.previousInteraction[identity] =
      previousOwner.previousInteraction.getOrDefault(identity) or
        identityFocused
    if rt.keyboardFocusVisible:
      previousOwner.previousInteraction[identity] =
        previousOwner.previousInteraction[identity] or identityFocusVisible
  let previousPressTargetIdentity =
    if rt.pressTarget.owner == previousOwner and
        int(rt.pressTarget.slot) < previousIdentities.len:
      previousIdentities[int(rt.pressTarget.slot)]
    else:
      0'u64
  let previousTextInputSlot =
    if rt.textInputAdapter == nil: -1 else: rt.textInputAdapter.slot
  rt.rememberFocusGroup()
  previousOwner.hoveredSlots.setLen(0)
  previousOwner.pressedSlots.setLen(0)
  previousOwner.clickedSlots.setLen(0)
  previousOwner.doubleClickedSlots.setLen(0)
  previousOwner.focusedSlots.setLen(0)
  previousOwner.focusVisibleSlots.setLen(0)
  rt.clickedSlots.setLen(0)
  rt.doubleClickedSlots.setLen(0)
  rt.context.reduceMotion = rt.systemPreferences.reduceMotion
  if rt.context.owner != nil and not rt.context.owner.closed:
    rt.context.owner.pointerX = rt.pointerX
    rt.context.owner.pointerY = rt.pointerY
    rt.context.owner.hasPointer = rt.hasPointer
    var gesture = DraggableGesture(
      identity: rt.pointerDraggableIdentity,
      serial: rt.pointerDraggableSerial,
      pressX: rt.pressX, pressY: rt.pressY,
      x: rt.pointerX, y: rt.pointerY,
      velocityX: rt.pointerDraggableVelocityX,
      velocityY: rt.pointerDraggableVelocityY,
      held: rt.pointerDraggableIdentity != 0 and
        not rt.pointerDraggableReleasePending,
      moved: rt.pointerDraggableMoved,
      released: rt.pointerDraggableReleasePending,
      canceled: rt.pointerDraggableCanceled)
    let owner = rt.frameLayout.owner
    if rt.pointerDraggableIdentity != 0 and owner != nil:
      let slot = owner.idSlots.getOrDefault(rt.pointerDraggableIdentity, -1)
      if slot > 0 and slot < owner.nodes.len:
        let parent = int(owner.nodes[slot].parent)
        if parent >= 0:
          let (pressX, pressY, pressOk) = rt.frameLayout.localPoint(parent,
            gesture.pressX, gesture.pressY)
          let (x, y, pointOk) = rt.frameLayout.localPoint(parent,
            gesture.x, gesture.y)
          let (velocityX, velocityY, velocityOk) =
            rt.frameLayout.localVector(parent, gesture.x, gesture.y,
              gesture.velocityX, gesture.velocityY)
          if pressOk and pointOk and velocityOk:
            gesture.pressX = pressX
            gesture.pressY = pressY
            gesture.x = x
            gesture.y = y
            gesture.velocityX = velocityX
            gesture.velocityY = velocityY
    rt.context.owner.draggableGesture = gesture
  rt.context.build(rt.view)
  let currentOwner = rt.context.owner
  currentOwner.draggableGesture = DraggableGesture()
  if rt.pointerDraggableReleasePending:
    rt.pointerDraggableIdentity = 0
    rt.pointerDraggableMoved = false
    rt.pointerDraggableCaught = false
    rt.pointerDraggableReleasePending = false
    rt.pointerDraggableCanceled = false
  rt.hoverSlots = remapSlots(previousIdentities, currentOwner, rt.hoverSlots)
  rt.pressedSlots = remapSlots(previousIdentities, currentOwner, rt.pressedSlots)
  rt.pressHoverSlots = remapSlots(previousIdentities, currentOwner,
    rt.pressHoverSlots)
  rt.focusSlot = remapSlot(previousIdentities, currentOwner, rt.focusSlot)
  rt.keyPressSlot = remapSlot(previousIdentities, currentOwner, rt.keyPressSlot)
  if rt.focusSlot < 0:
    rt.keyboardFocusVisible = false
  if rt.keyPressSlot < 0:
    rt.cancelKeyPress()
  if previousPressTargetIdentity != 0 and
      currentOwner.idSlots.hasKey(previousPressTargetIdentity):
    rt.pressTarget = Element(owner: currentOwner,
      slot: uint32(currentOwner.idSlots[previousPressTargetIdentity]),
      generation: currentOwner.generation)
  else:
    rt.pressTarget = Element()
    rt.inputPressCaptured = false
    rt.pressHoverSlots.setLen(0)
  if rt.inputPressCaptured:
    let capturedSlot = int(rt.pressTarget.slot)
    if capturedSlot <= 0 or capturedSlot >= currentOwner.nodes.len or
        currentOwner.nodes[capturedSlot].inputHandler == nil:
      rt.inputPressCaptured = false
  if rt.textInputAdapter != nil:
    rt.textInputAdapter.slot = remapSlot(previousIdentities, currentOwner,
      previousTextInputSlot)
  if rt.focusSlot > 0:
    currentOwner.focusedSlots.add(rt.focusSlot)
    if rt.keyboardFocusVisible:
      currentOwner.focusVisibleSlots.add(rt.focusSlot)
  currentOwner.focusIdentity =
    if rt.focusSlot > 0 and rt.focusSlot < currentOwner.nodes.len:
      currentOwner.nodes[rt.focusSlot].identity
    else:
      0'u64
  let layout = rt.context.layoutAt(Rect(w: width, h: height),
    getMonoTime(), rt.systemPreferences.reduceMotion)
  discard rt.applyHandleFocusRequests(layout)
  rt.pruneFocusGroups(layout)
  if rt.focusSlot >= 0 and not layout.focusableSlot(rt.focusSlot):
    rt.focusSlot = -1
    rt.keyboardFocusVisible = false
    currentOwner.focusIdentity = 0
    rt.cancelKeyPress()
    layout.owner.focusedSlots.setLen(0)
    layout.owner.focusVisibleSlots.setLen(0)
    for slot in 1..<layout.owner.nodes.len:
      layout.owner.nodes[slot].focused = false
      layout.owner.nodes[slot].focusVisible = false
    rt.requestFrame()
  rt.applyModalFocus(layout, previousFocusIdentity)
  rt.frameLayout = layout
  rt.updatePointerCursor()
  if presentFrame and rt.listReorder != nil and
      rt.listReorder.reorderDragging and rt.autoScrollListReorder(rt.listReorder):
    rt.requestFrame()
  if presentFrame and rt.gridReorder != nil and
      rt.gridReorder.reorderDragging:
    rt.gridReorderTarget(rt.gridReorder)
    if rt.autoScrollGridReorder(rt.gridReorder):
      rt.requestFrame()
  rt.updateTextInput()
  rt.frameScene = layout.paintScene(scale)
  rt.paintLocalDrag(rt.frameScene)
  rt.hasScene = true
  rt.updateAccessibility()
  if presentFrame:
    rt.present(rt.frameScene)

  if presentFrame and layout.animating:
    if layout.poseOnlyAnimating:
      rt.requestPoseFrame()
    else:
      rt.requestFrame()

  if presentFrame and currentOwner.afterDeadline != MonoTime():
    if getMonoTime() >= currentOwner.afterDeadline:
      currentOwner.afterDeadline = MonoTime()
    else:
      rt.requestFrame()

  if presentFrame and not rt.ready and rt.conn.ready != nil and
      rt.conn.post != nil:
    rt.ready = true
    rt.conn.post(rt.conn.ready)

  rt.poseOnlyFrame = rt.poseOnlyFrame and presentFrame and
    layout.poseOnlyAnimating and
    currentOwner.afterDeadline == MonoTime() and rt.listReorder == nil and
    rt.gridReorder == nil and rt.tableReorder == nil and
    rt.scrollbarDrag.state == nil and rt.localDrag == nil and
    rt.pointerDraggableIdentity == 0

proc renderPoseOnlyFrame(rt: Runtime) =
  if rt.closed or rt.inFrame:
    return
  rt.inFrame = true
  defer: rt.inFrame = false

  let size = rt.conn.surface.size()
  let width = frameDimension(size.width, "width")
  let height = frameDimension(size.height, "height")
  let scale = if classify(size.scale) in {fcNan, fcInf, fcNegInf} or
      size.scale <= 0 or size.scale > float64(high(float32)):
    1'f32
  else:
    float32(size.scale)
  let owner = rt.context.owner
  if owner == nil or owner.closed or owner.inBuild or not owner.hasFrame:
    rt.poseOnlyFrame = false
    return

  owner.frameNow = getMonoTime()
  owner.reduceMotion = rt.systemPreferences.reduceMotion
  owner.animating = false
  owner.poseAnimating = false
  owner.otherAnimating = false
  owner.samplePoses()
  let layout = rt.context.layoutAt(Rect(w: width, h: height), owner.frameNow,
    rt.systemPreferences.reduceMotion)
  if not layout.poseOnlyAnimating:
    rt.poseOnlyFrame = false
    rt.inFrame = false
    rt.renderFrame()
    return

  rt.frameLayout = layout
  rt.refreshPointer()
  rt.updateTextInput()
  rt.frameScene = layout.paintScene(scale)
  rt.paintLocalDrag(rt.frameScene)
  rt.hasScene = true
  rt.updateAccessibility()
  rt.present(rt.frameScene)
  rt.poseOnlyFrame = rt.poseOnlyFrame and layout.poseOnlyAnimating and
    owner.afterDeadline == MonoTime() and rt.listReorder == nil and
    rt.gridReorder == nil and rt.tableReorder == nil and
    rt.scrollbarDrag.state == nil and rt.localDrag == nil and
    rt.pointerDraggableIdentity == 0
  if layout.animating:
    rt.requestPoseFrame()

proc requestFrame(rt: Runtime) =
  rt.poseOnlyFrame = false
  if not rt.closed and rt.conn.surface != nil:
    rt.conn.surface.requestFrame()

proc requestPoseFrame(rt: Runtime) =
  if not rt.closed and rt.conn.surface != nil:
    rt.conn.surface.requestFrame()

proc cancelListReorder(rt: Runtime) =
  if rt.listReorder != nil:
    rt.listReorder.cancelListReorder()
    rt.listReorder = nil

proc cancelGridReorder(rt: Runtime) =
  if rt.gridReorder != nil:
    rt.gridReorder.cancelGridReorder()
    rt.gridReorder = nil

proc cancelTableReorder(rt: Runtime) =
  if rt.tableReorder != nil:
    rt.tableReorder.cancelTableColumnDrag()
    rt.tableReorder = nil

proc beginListReorder(rt: Runtime; target: Element) =
  rt.cancelListReorder()
  if target.owner == nil or target.owner != rt.frameLayout.owner:
    return
  var slot = int(target.slot)
  while slot > 0 and slot < target.owner.nodes.len:
    let node = target.owner.nodes[slot]
    if node.listState != nil and node.listRowIndex >= 0:
      let listSlot = int(node.listState.frameSlot)
      let (x, y, ok) = rt.frameLayout.localPoint(listSlot,
        rt.pointerX, rt.pointerY)
      if ok and node.listState.beginListReorder(node.listRowIndex, x, y):
        rt.listReorder = node.listState
        return
    slot = int(node.parent)

proc beginGridReorder(rt: Runtime; target: Element) =
  rt.cancelGridReorder()
  if target.owner == nil or target.owner != rt.frameLayout.owner:
    return
  var slot = int(target.slot)
  while slot > 0 and slot < target.owner.nodes.len:
    let node = target.owner.nodes[slot]
    if node.gridCellState != nil:
      let gridSlot = int(node.gridCellState.rows.frameSlot)
      let (x, y, ok) = rt.frameLayout.localPoint(gridSlot,
        rt.pointerX, rt.pointerY)
      if ok and node.gridCellState.beginGridReorder(node.gridItemIndex, x, y):
        rt.gridReorder = node.gridCellState
        return
    slot = int(node.parent)

proc beginTableReorder(rt: Runtime; target: Element) =
  rt.cancelTableReorder()
  if target.owner == nil or target.owner != rt.frameLayout.owner:
    return
  var slot = int(target.slot)
  while slot > 0 and slot < target.owner.nodes.len:
    let node = target.owner.nodes[slot]
    if node.tableState != nil and node.tableColumnHeader and
        node.tableColumnId.len > 0 and
        not node.tableColumnFixed:
      let tableSlot = int(node.tableState.frameSlot)
      let (x, _, ok) = rt.frameLayout.localPoint(tableSlot,
        rt.pointerX, rt.pointerY)
      if ok and node.tableState.beginTableColumnDrag(node.tableColumnId, x):
        rt.tableReorder = node.tableState
        return
    slot = int(node.parent)

proc beginTableResize(rt: Runtime; target: Element): bool =
  rt.cancelTableReorder()
  if target.owner == nil or target.owner != rt.frameLayout.owner:
    return false
  var slot = int(target.slot)
  while slot > 0 and slot < target.owner.nodes.len:
    let node = target.owner.nodes[slot]
    if node.tableResizeHandle and node.tableState != nil:
      let tableSlot = int(node.tableState.frameSlot)
      let (x, _, ok) = rt.frameLayout.localPoint(tableSlot,
        rt.pointerX, rt.pointerY)
      if ok and node.tableState.beginTableColumnResize(node.tableColumnId,
          x, target.owner.nodes, rt.frameLayout.rects):
        rt.tableReorder = node.tableState
        return true
    slot = int(node.parent)
  false

proc showTableHeaderMenu(rt: Runtime; target: Element;
                         x, y: float32): bool =
  if target.owner == nil or target.owner != rt.frameLayout.owner or
      rt.conn.popupMenu == nil:
    return false
  var slot = int(target.slot)
  var state: ListState
  var column = -1
  var rightToLeft = false
  while slot > 0 and slot < target.owner.nodes.len:
    let node = target.owner.nodes[slot]
    if node.tableState != nil and node.tableColumnHeader:
      state = node.tableState
      column = node.tableColumnIndex
      rightToLeft = node.rightToLeft
      break
    if state == nil and node.tableHeaderMenuArea:
      state = node.tableState
      rightToLeft = node.rightToLeft
    slot = int(node.parent)
  if state == nil or state.headerMenu == nil:
    return false

  let build = state.headerMenu
  let opening = newUiMenu(0, "", rightToLeft)
  build(opening, column)
  if opening.snapshot.items.len > 0:
    rt.conn.popupMenu(opening.snapshot, float64(x), float64(y),
      proc(id: int) =
        if rt.closed:
          return
        var chosenLabel = ""
        for item in opening.snapshot.items:
          if item.id == id:
            chosenLabel = item.label
            break
        let selection = newUiMenu(id, chosenLabel, rightToLeft)
        build(selection, column)
        if selection.session.choiceSeen:
          rt.requestFrame()
    )
  true

proc showContextMenu(rt: Runtime; target: Element; x, y: float32): bool =
  if rt.closed or rt.conn.popupMenu == nil or
      target.owner == nil or target.owner != rt.frameLayout.owner:
    return false
  let owner = rt.frameLayout.owner
  var slot = int(target.slot)
  var build: proc(menu: Menu) {.closure.}
  var rightToLeft = false
  while slot > 0 and slot < owner.nodes.len:
    let node = owner.nodes[slot]
    if node.contextMenuBuilder != nil:
      if owner.effectivelyDisabled(slot) or
          owner.effectivelyToolbarCollapsed(slot):
        return false
      build = node.contextMenuBuilder
      rightToLeft = node.rightToLeft
      break
    slot = int(node.parent)
  if build == nil:
    return false

  let opening = newUiMenu(0, "", rightToLeft)
  build(opening)
  if opening.snapshot.items.len > 0:
    rt.conn.popupMenu(opening.snapshot, float64(x), float64(y),
      proc(id: int) =
        if rt.closed:
          return
        var chosenLabel = ""
        for item in opening.snapshot.items:
          if item.id == id:
            chosenLabel = item.label
            break
        let selection = newUiMenu(id, chosenLabel, rightToLeft)
        build(selection)
        if selection.session.choiceSeen:
          rt.requestFrame()
    )
  true

proc showMenuButton(rt: Runtime; identity: uint64;
                    build: proc(menu: Menu) {.closure.}) =
  if rt.closed or rt.conn.popupMenu == nil or build == nil or
      rt.frameLayout.owner == nil:
    return
  let owner = rt.frameLayout.owner
  let slot = owner.idSlots.getOrDefault(identity, -1)
  if slot <= 0 or slot >= rt.frameLayout.rects.len or
      owner.effectivelyDisabled(slot) or
      owner.effectivelyToolbarCollapsed(slot):
    return
  let node = owner.nodes[slot]
  let bounds = rt.frameLayout.visualRects[slot]
  let menu = newUiMenu(0, "", node.rightToLeft)
  build(menu)
  if menu.snapshot.items.len == 0:
    return
  let x = if node.rightToLeft: bounds.x + bounds.w else: bounds.x
  let y = bounds.y + bounds.h
  rt.conn.popupMenu(menu.snapshot, float64(x), float64(y),
    proc(id: int) =
      if rt.closed:
        return
      var chosenLabel = ""
      for item in menu.snapshot.items:
        if item.id == id:
          chosenLabel = item.label
          break
      let selection = newUiMenu(id, chosenLabel, node.rightToLeft)
      build(selection)
      if selection.session.choiceSeen:
        rt.requestFrame()
  )

proc listReorderTarget(rt: Runtime; state: ListState) =
  if state == nil or rt.frameLayout.owner == nil:
    return
  let slot = int(state.frameSlot)
  if slot <= 0 or slot >= rt.frameLayout.owner.nodes.len or
      state.frameOwner != cast[pointer](rt.frameLayout.owner) or
      state.generation != rt.frameLayout.generation:
    state.reorderTargetValid = false
    return
  updateListReorderTarget(rt.frameLayout.owner.nodes,
    rt.frameLayout.rects, state, slot)

proc autoScrollListReorder(rt: Runtime; state: ListState): bool =
  if state == nil or not state.reorderDragging or
      not rt.hasPointer or rt.frameLayout.owner == nil:
    return false
  let slot = int(state.frameSlot)
  if slot <= 0 or slot >= rt.frameLayout.owner.nodes.len or
      state.frameOwner != cast[pointer](rt.frameLayout.owner) or
      state.generation != rt.frameLayout.generation:
    return false
  let node = rt.frameLayout.owner.nodes[slot]
  if not node.scrollY or node.scrollState == nil:
    return false
  let box = rt.frameLayout.rects[slot]
  let left = box.x + node.border[3] + node.pad[3]
  let right = box.x + box.w - node.border[1] - node.pad[1]
  let top = box.y + node.border[0] + node.pad[0]
  let bottom = box.y + box.h - node.border[2] - node.pad[2]
  if state.reorderPointerX < left or state.reorderPointerX >= right or
      not rt.frameLayout.insideClips(slot, rt.pointerX, rt.pointerY):
    return false
  const edge = 32'f32
  let y = state.reorderPointerY
  var delta: float32
  if y < top + edge:
    delta = -min((top + edge - y) / 2, edge / 2)
  elif y > bottom - edge:
    delta = min((y - (bottom - edge)) / 2, edge / 2)
  if delta == 0:
    return false
  let scroll = node.scrollState
  let old = scroll.offsetY
  scroll.stopScrollMotion()
  scroll.offsetY = min(max(old + delta, 0'f32), scroll.maxY)
  scroll.offsetY != old

proc gridReorderTarget(rt: Runtime; state: GridState) =
  let owner = rt.frameLayout.owner
  if state == nil or owner == nil or rt.frameLayout.rects.len != owner.nodes.len:
    return
  let rootSlot = int(state.rows.frameSlot)
  if rootSlot <= 0 or rootSlot >= owner.nodes.len or
      state.rows.frameOwner != cast[pointer](owner) or
      state.rows.generation != rt.frameLayout.generation:
    state.reorderTargetValid = false
    state.reorderTargetCell = -1
    return
  let rootBox = rt.frameLayout.rects[rootSlot]
  if not rootBox.contains(state.reorderPointerX, state.reorderPointerY) or
      not rt.frameLayout.insideClips(rootSlot, rt.pointerX, rt.pointerY):
    state.reorderTargetValid = false
    state.reorderTargetCell = -1
    return

  var bestSlot = -1
  var bestItem = -1
  var bestDistance = -1'f32
  for slot in 1..<owner.nodes.len:
    let node = owner.nodes[slot]
    if node.gridCellState != state or node.gridItemIndex < 0:
      continue
    let box = rt.frameLayout.rects[slot]
    if state.reorderPointerY < box.y or
        state.reorderPointerY >= box.y + box.h:
      continue
    let distance = abs(state.reorderPointerX - (box.x + box.w / 2))
    if bestSlot < 0 or distance < bestDistance:
      bestSlot = slot
      bestItem = node.gridItemIndex
      bestDistance = distance

  if bestSlot < 0:
    for slot in 1..<owner.nodes.len:
      let node = owner.nodes[slot]
      if node.gridCellState == state and
          node.gridItemIndex == state.itemCount - 1:
        state.reorderTarget = state.itemCount
        state.reorderTargetCell = node.gridItemIndex
        state.reorderTargetAfter = true
        state.reorderTargetValid = true
        return
    state.reorderTargetValid = false
    state.reorderTargetCell = -1
    return

  let box = rt.frameLayout.rects[bestSlot]
  let node = owner.nodes[bestSlot]
  let after = (state.reorderPointerX >= box.x + box.w / 2) !=
    node.rightToLeft
  state.reorderTarget = if after: bestItem + 1 else: bestItem
  state.reorderTargetCell = bestItem
  state.reorderTargetAfter = after
  state.reorderTargetValid = true

proc autoScrollGridReorder(rt: Runtime; state: GridState): bool =
  if state == nil or not state.reorderDragging or
      not rt.hasPointer or rt.frameLayout.owner == nil:
    return false
  let slot = int(state.rows.frameSlot)
  let owner = rt.frameLayout.owner
  if slot <= 0 or slot >= owner.nodes.len or
      state.rows.frameOwner != cast[pointer](owner) or
      state.rows.generation != rt.frameLayout.generation:
    return false
  let node = owner.nodes[slot]
  if not node.scrollY or node.scrollState == nil:
    return false
  let box = rt.frameLayout.rects[slot]
  let left = box.x + node.border[3] + node.pad[3]
  let right = box.x + box.w - node.border[1] - node.pad[1]
  let top = box.y + node.border[0] + node.pad[0]
  let bottom = box.y + box.h - node.border[2] - node.pad[2]
  if state.reorderPointerX < left or state.reorderPointerX >= right or
      not rt.frameLayout.insideClips(slot, rt.pointerX, rt.pointerY):
    return false
  const edge = 32'f32
  var delta = 0'f32
  if state.reorderPointerY < top + edge:
    delta = -min((top + edge - state.reorderPointerY) / 2, edge / 2)
  elif state.reorderPointerY > bottom - edge:
    delta = min((state.reorderPointerY - (bottom - edge)) / 2, edge / 2)
  if delta == 0:
    return false
  let scroll = node.scrollState
  let old = scroll.offsetY
  scroll.stopScrollMotion()
  scroll.offsetY = min(max(old + delta, 0'f32), scroll.maxY)
  scroll.offsetY != old

proc dragCandidate(rt: Runtime; target: Element): uint64 =
  let owner = rt.frameLayout.owner
  if target.owner == nil or target.owner != owner or
      target.generation != rt.frameLayout.generation:
    return
  var slot = int(target.slot)
  while slot > 0 and slot < owner.nodes.len:
    let node = owner.nodes[slot]
    if (node.dragDataProvider != nil or node.dragValueProvider != nil) and
        not owner.effectivelyDisabled(slot):
      return node.identity
    slot = int(node.parent)

proc dragPreview(rt: Runtime; slot: int; startX, startY: float32):
    tuple[img: sourceImage.Image, hotspot: sourceImage.Point] =
  let layout = rt.frameLayout
  if slot <= 0 or slot >= layout.rects.len or not rt.hasScene:
    return
  let rect = layout.visualRects[slot]
  let left = max(0'f32, rect.x)
  let top = max(0'f32, rect.y)
  let right = min(rect.x + rect.w, layout.root.w)
  let bottom = min(rect.y + rect.h, layout.root.h)
  let width = min(int(right - left), 512)
  let height = min(int(bottom - top), 512)
  if width <= 0 or height <= 0:
    return
  var renderer: raster.Renderer
  discard renderer.render(rt.frameScene)
  let source = renderer.image
  let pixels = source.rgba()
  let scale = rt.frameScene.scale
  let preview = sourceImage.RgbaImage(pix: newSeq[uint8](width * height * 4),
    stride: width * 4, rect: sourceImage.rect(0, 0, width, height))
  for y in 0..<height:
    for x in 0..<width:
      let sx = int((left + float32(x)) * scale)
      let sy = int((top + float32(y)) * scale)
      if sx < 0 or sy < 0 or sx >= source.w or sy >= source.h:
        continue
      let sourceOffset = (sy * source.w + sx) * 4
      let to = (y * width + x) * 4
      preview.pix[to] = pixels[sourceOffset]
      preview.pix[to + 1] = pixels[sourceOffset + 1]
      preview.pix[to + 2] = pixels[sourceOffset + 2]
      preview.pix[to + 3] = pixels[sourceOffset + 3]
  result.img = preview
  result.hotspot = sourceImage.Point(
    x: min(max(int(startX - left), 0), width - 1),
    y: min(max(int(startY - top), 0), height - 1))

proc updateLocalDragTarget(rt: Runtime) =
  let drag = rt.localDrag
  let owner = rt.frameLayout.owner
  if drag == nil or drag.canceled or owner == nil:
    return
  let slot = rt.frameLayout.valueDropTargetAt(rt.pointerX, rt.pointerY,
    drag.value)
  drag.overIdentity = if slot > 0: owner.nodes[slot].identity else: 0'u64
  owner.dragOverIdentity = drag.overIdentity

proc clearDragOwner(owner: ElementOwner) =
  if owner == nil:
    return
  owner.dragSourceIdentity = 0
  owner.dragOverIdentity = 0
  owner.dragValue = nil
  owner.dragCanceled = false

proc paintLocalDrag(rt: Runtime; frame: var scene.Scene) =
  let drag = rt.localDrag
  if drag == nil or drag.canceled or drag.preview == nil:
    return
  let scale = frame.scale
  let x = (rt.pointerX - float32(drag.hotX)) * scale
  let y = (rt.pointerY - float32(drag.hotY)) * scale
  frame.ops.add(scene.Op(kind: scene.opImage,
    rect: scene.Rect(x: x, y: y,
      w: float32(drag.width) * scale, h: float32(drag.height) * scale),
    image: drag.preview,
    src: scene.Rect(w: float32(drag.width), h: float32(drag.height)),
    opacity: 0.75))

proc startDragFromPress(rt: Runtime): bool =
  if rt.nativeDragStarted or rt.dragCandidateIdentity == 0 or
      rt.pressTarget.owner != rt.frameLayout.owner:
    return false
  let dx = rt.pointerX - rt.pressX
  let dy = rt.pointerY - rt.pressY
  if dx * dx + dy * dy < 16:
    return false
  let owner = rt.frameLayout.owner
  let identity = rt.dragCandidateIdentity
  if owner == nil or not owner.idSlots.hasKey(identity):
    return false
  let slot = owner.idSlots[identity]
  if slot <= 0 or slot >= owner.nodes.len or owner.effectivelyDisabled(slot):
    return false
  let node = owner.nodes[slot]
  if node.dragDataProvider == nil and node.dragValueProvider == nil:
    return false
  let localValue = if node.dragValueProvider != nil:
      node.dragValueProvider()
    else:
      nil
  rt.dragCandidateIdentity = 0
  rt.pressTarget = Element()
  rt.pressMods = 0
  rt.pressHoverSlots.setLen(0)
  rt.refreshPointer()
  owner.dragSourceIdentity = identity
  owner.dragValue = localValue
  owner.dragOverIdentity = 0
  owner.dragCanceled = false
  rt.nativeDragStarted = node.dragDataProvider != nil
  if rt.nativeDragStarted:
    var options = node.dragDataOptions
    if options.preview == nil:
      let (preview, hotspot) = rt.dragPreview(slot, rt.pressX, rt.pressY)
      options.preview = preview
      options.hotspot = hotspot
    let data = node.dragDataProvider()
    let startErr = if rt.conn.startDataDrag != nil:
        rt.conn.startDataDrag(data, localValue, options,
          float64(rt.pointerX), float64(rt.pointerY))
      else:
        platform.errUnsupported()
    if startErr != nil:
      clearDragOwner(owner)
      if options.done != nil:
        options.done(transfer.Result(err: startErr))
  elif localValue != nil:
    let (preview, hotspot) = rt.dragPreview(slot, rt.pressX, rt.pressY)
    let bounds = if preview == nil: sourceImage.Rectangle() else: preview.bounds()
    rt.localDrag = LocalDragState(sourceIdentity: identity, value: localValue,
      preview: if preview == nil: nil else: scene.newSceneImage(preview),
      width: bounds.dx(), height: bounds.dy(), hotX: hotspot.x,
      hotY: hotspot.y)
    rt.updateLocalDragTarget()
  else:
    clearDragOwner(owner)
  rt.requestFrame()
  true

proc inputHandlerSlot(layout: LayoutResult; start: int): int =
  let owner = layout.owner
  var slot = start
  while owner != nil and slot > 0 and slot < owner.nodes.len:
    if owner.nodes[slot].inputHandler != nil and
        not owner.effectivelyDisabled(slot) and
        not owner.effectivelyToolbarCollapsed(slot):
      return slot
    slot = int(owner.nodes[slot].parent)

proc inputHandlerAt(layout: LayoutResult; x, y: float32): int =
  let target = layout.targetAt(x, y)
  if target.owner == layout.owner:
    return layout.inputHandlerSlot(int(target.slot))

proc focusedInputHandlerSlot(rt: Runtime): int =
  if rt.surfaceFocused:
    return rt.frameLayout.inputHandlerSlot(rt.focusSlot)

proc deliverInput(rt: Runtime; slot: int; ev: InputEvent): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return false
  let handler = owner.nodes[slot].inputHandler
  if handler == nil:
    return false
  var input = ev
  let (x, y, ok) = layout.localPoint(slot, rt.pointerX, rt.pointerY)
  if ok:
    let rect = layout.rects[slot]
    input.x = x - rect.x
    input.y = y - rect.y
  else:
    input.x = 0
    input.y = 0
  if input.kind == InputKind.InputScroll:
    let (dx, dy, vectorOk) = layout.localVector(slot, rt.pointerX,
      rt.pointerY, input.dx, input.dy)
    if vectorOk:
      input.dx = dx
      input.dy = dy
    else:
      input.dx = 0
      input.dy = 0
  result = handler(input)
  if result:
    rt.requestFrame()

proc focusInputTarget(rt: Runtime; start: int) =
  let layout = rt.frameLayout
  let owner = layout.owner
  var slot = start
  while owner != nil and slot > 0 and slot < owner.nodes.len:
    if layout.focusableSlot(slot) and not owner.effectivelyDisabled(slot):
      rt.setRuntimeFocus(layout, slot)
      return
    slot = int(owner.nodes[slot].parent)

proc captureInputPointerDown(rt: Runtime; slot, button: int;
    mods: platform.Modifiers; clicks: int): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil or slot <= 0 or slot >= owner.nodes.len:
    return false
  let input = InputEvent(kind: InputKind.InputPointerDown, button: button,
    clicks: max(clicks, 1), mods: mods)
  if not rt.deliverInput(slot, input):
    return false
  rt.inputPressCaptured = true
  rt.inputPressButton = button
  rt.pressTarget = Element(owner: owner, slot: uint32(slot),
    generation: layout.generation)
  rt.pressMods = mods
  rt.pressX = rt.pointerX
  rt.pressY = rt.pointerY
  rt.dragCandidateIdentity = 0
  rt.pressHoverSlots = layout.slotsAt(rt.pointerX, rt.pointerY)
  rt.refreshPointer()
  true

proc inputKeyDown(rt: Runtime; ev: platform.SurfaceEvent): platform.Key =
  result = ev.key
  if platform.keyByPosition(result, ev.physicalKey, ev.mods):
    rt.byPosition.incl(ev.physicalKey)
    result = ev.physicalKey
  elif not ev.repeat:
    rt.byPosition.excl(ev.physicalKey)

proc inputKeyUp(rt: Runtime; ev: platform.SurfaceEvent): platform.Key =
  result = ev.key
  if result == platform.keyUnknown and ev.physicalKey in rt.byPosition:
    result = ev.physicalKey
  rt.byPosition.excl(ev.physicalKey)

proc event(rt: Runtime; ev: platform.SurfaceEvent): bool =
  if rt.closed:
    return false
  if ev.kind != platform.surfaceFrame:
    rt.poseOnlyFrame = false
  case ev.kind
  of platform.surfaceFrame:
    if rt.poseOnlyFrame:
      rt.renderPoseOnlyFrame()
    else:
      rt.renderFrame()
    true
  of platform.surfaceResize:
    rt.requestFrame()
    false
  of platform.surfaceRenew:
    rt.releaseGpu()
    rt.gpuTried = false
    rt.requestFrame()
    false
  of platform.surfaceFocus:
    rt.surfaceFocused = true
    rt.context.owner.focusActive = true
    rt.updateTextInput()
    rt.requestFrame()
    false
  of platform.keyPressed:
    let key = rt.inputKeyDown(ev)
    if key == platform.keyEscape and rt.localDrag != nil and
        not rt.localDrag.canceled:
      rt.localDrag.canceled = true
      rt.localDrag.overIdentity = 0
      if rt.frameLayout.owner != nil:
        rt.frameLayout.owner.dragCanceled = true
        rt.frameLayout.owner.dragOverIdentity = 0
      rt.requestFrame()
      return true
    if not rt.shortcutActionRegistered(ev.mods, key):
      let slot = rt.focusedInputHandlerSlot()
      if slot > 0 and rt.deliverInput(slot, InputEvent(
          kind: InputKind.InputKeyDown, key: key,
          physicalKey: ev.physicalKey, mods: ev.mods, repeat: ev.repeat)):
        rt.keyboardFocusVisible = true
        return true
    if key == platform.keyTab and
        (ev.mods and (platform.modCtrl or platform.modAlt or
          platform.modSuper)) == 0:
      if rt.runShortcutAction(ev.mods, key):
        return true
      let owner = rt.frameLayout.owner
      let client = if owner != nil and rt.focusSlot > 0 and
          rt.focusSlot < owner.nodes.len and
          owner.nodes[rt.focusSlot].textClient of TextFieldClient:
            TextFieldClient(owner.nodes[rt.focusSlot].textClient)
        else:
            nil
      if rt.textFieldTextKey(client, key, ev.mods):
        return true
      rt.rememberFocusGroup()
      let next = rt.nextFocusSlot(rt.frameLayout, rt.focusSlot,
        (ev.mods and platform.modShift) != 0)
      if next >= 0:
        rt.cancelKeyPress()
        rt.focusSlot = next
        rt.keyboardFocusVisible = true
        discard rt.frameLayout.revealSlot(next)
        rt.refreshPointer()
        rt.requestFrame()
        return true
      if rt.frameLayout.owner != nil and
          rt.frameLayout.owner.activeModalIdentity != 0:
        let fallback = if rt.frameLayout.focusableSlot(rt.focusSlot):
            rt.focusSlot
          else:
            rt.frameLayout.modalInitialFocus()
        if fallback > 0:
          rt.setRuntimeFocus(rt.frameLayout, fallback)
          rt.keyboardFocusVisible = true
          rt.frameLayout.owner.nodes[fallback].focusVisible = true
          rt.frameLayout.owner.focusVisibleSlots = @[fallback]
        return true
      return false
    if key == platform.keyEscape and ev.mods == 0 and rt.dismissPopover():
      return true
    if key == platform.keyEscape and ev.mods == 0 and rt.dismissModal():
      return true
    if rt.comboBoxKey(key, ev.mods):
      return true
    if rt.sliderKey(key, ev.mods):
      return true
    let owner = rt.frameLayout.owner
    if ev.mods == 0 and owner != nil and rt.focusSlot > 0 and
        rt.focusSlot < owner.nodes.len:
      let node = owner.nodes[rt.focusSlot]
      if node.menuBuilder != nil and
          key in {platform.keyEnter, platform.keySpace, platform.keyDown}:
        if not ev.repeat:
          rt.showMenuButton(node.identity, node.menuBuilder)
        rt.keyboardFocusVisible = true
        rt.requestFrame()
        return true
    if ev.mods == 0 and key in {platform.keyUp, platform.keyDown}:
      let owner = rt.context.owner
      if owner != nil and rt.focusSlot > 0 and
          rt.focusSlot < owner.nodes.len and
          not owner.effectivelyDisabled(rt.focusSlot) and
          not owner.effectivelyToolbarCollapsed(rt.focusSlot):
        let stepHandler = owner.nodes[rt.focusSlot].accessStepHandler
        if stepHandler != nil:
          let step = owner.nodes[rt.focusSlot].accessStep
          stepHandler(if key == platform.keyUp: step else: -step)
          rt.keyboardFocusVisible = true
          rt.requestFrame()
          return true
    if rt.textFieldKey(key, ev.mods):
      return true
    var nextFocusSlot = rt.focusSlot
    if rt.frameLayout.handleListKey(rt.focusSlot, key, ev.mods,
        nextFocusSlot):
      if nextFocusSlot != rt.focusSlot:
        rt.focusSlot = nextFocusSlot
        discard rt.frameLayout.revealSlot(nextFocusSlot)
      rt.keyboardFocusVisible = true
      rt.requestFrame()
      return true
    if rt.handleFocusGroupKey(key, ev.mods):
      return true
    if key in {platform.keyEnter, platform.keySpace} and
        ev.mods == 0 and rt.focusSlot > 0 and
        rt.frameLayout.keyboardActivationSlot(rt.focusSlot, key):
      if not ev.repeat:
        rt.keyPressSlot = rt.focusSlot
        rt.keyPressKey = key
        rt.keyboardFocusVisible = true
        rt.refreshPointer()
        rt.requestFrame()
      return true
    if key == platform.keyEnter and rt.submitFocusedText(ev.mods):
      return true
    if rt.runShortcutAction(ev.mods, key):
      return true
    if key == platform.keyEscape and
        rt.context.owner.tooltips.shown != 0:
      rt.context.owner.tooltips.dismissed = rt.context.owner.tooltips.shown
      rt.requestFrame()
      return true
    var dx, dy, page: float32
    if ev.mods == 0:
      case key
      of platform.keyDown: dy = 40
      of platform.keyUp: dy = -40
      of platform.keyRight: dx = 40
      of platform.keyLeft: dx = -40
      of platform.keyPageDown, platform.keySpace:
        page = 1
      of platform.keyPageUp:
        page = -1
      of platform.keyHome: dy = -1_000_000_000
      of platform.keyEnd: dy = 1_000_000_000
      else: discard
    elif ev.mods == platform.modShift and key == platform.keySpace:
      page = -1
    elif ev.mods == platform.modSuper and key == platform.keyHome:
      dy = -1_000_000_000
    elif ev.mods == platform.modSuper and key == platform.keyEnd:
      dy = 1_000_000_000
    when defined(macosx):
      if ev.mods == platform.modSuper and key == platform.keyUp:
        dy = -1_000_000_000
      elif ev.mods == platform.modSuper and key == platform.keyDown:
        dy = 1_000_000_000
    if (dx != 0 or dy != 0 or page != 0) and
        rt.frameLayout.scrollKey(rt.focusSlot, rt.pointerX, rt.pointerY,
          dx, dy, page, rt.hasPointer):
      rt.requestFrame()
      return true
    false
  of platform.keyReleased:
    let key = rt.inputKeyUp(ev)
    let slot = rt.focusedInputHandlerSlot()
    if slot > 0 and rt.deliverInput(slot, InputEvent(
        kind: InputKind.InputKeyUp, key: key,
        physicalKey: ev.physicalKey, mods: ev.mods, repeat: ev.repeat)):
      rt.keyboardFocusVisible = true
      return true
    if key == rt.keyPressKey and rt.keyPressSlot > 0:
      let slot = rt.keyPressSlot
      let activate = rt.focusSlot == slot and
        rt.frameLayout.keyboardActivationSlot(slot, rt.keyPressKey)
      rt.cancelKeyPress()
      if activate:
        let handler = rt.frameLayout.owner.nodes[slot].clickHandler
        handler(0)
        rt.clickedSlots = @[slot]
      rt.refreshPointer()
      rt.requestFrame()
      return true
    false
  of platform.surfaceCommand:
    let slot = rt.focusedInputHandlerSlot()
    if slot > 0:
      var input = InputEvent(kind: InputKind.InputCommand, text: ev.text)
      if rt.deliverInput(slot, input):
        return true
      if ev.text == "pasteAndMatchStyle":
        input.text = "paste"
        if rt.deliverInput(slot, input):
          return true
    rt.textFieldCommand(ev.text)
  of platform.pointerScroll:
    discard rt.event(platform.SurfaceEvent(kind: platform.pointerMove,
      x: scrollDelta(ev.x), y: scrollDelta(ev.y), mods: ev.mods))
    rt.pointerX = scrollDelta(ev.x)
    rt.pointerY = scrollDelta(ev.y)
    rt.hasPointer = true
    let handlerSlot = rt.frameLayout.inputHandlerAt(rt.pointerX, rt.pointerY)
    if handlerSlot > 0 and rt.deliverInput(handlerSlot, InputEvent(
        kind: InputKind.InputScroll, dx: scrollDelta(ev.dx),
        dy: scrollDelta(ev.dy), mods: ev.mods, precise: ev.precise)):
      return true
    var dx = scrollDelta(ev.dx)
    var dy = scrollDelta(ev.dy)
    if (ev.mods and platform.modShift) != 0 and dx == 0:
      dx = dy
      dy = 0
    if rt.frameLayout.scrollAt(rt.pointerX, rt.pointerY, dx, dy):
      rt.requestFrame()
      return true
    false
  of platform.textInput:
    let adapter = rt.textInputAdapter
    if adapter == nil or adapter.inputTarget() == nil:
      let inputSlot = rt.focusedInputHandlerSlot()
      if inputSlot > 0 and rt.deliverInput(inputSlot, InputEvent(
          kind: InputKind.InputText, text: ev.text)):
        rt.keyboardFocusVisible = true
        return true
      let owner = rt.frameLayout.owner
      if owner != nil and rt.focusSlot > 0 and
          rt.focusSlot < owner.nodes.len:
        let handler = owner.nodes[rt.focusSlot].textInputHandler
        if handler != nil:
          handler(ev.text)
          rt.keyboardFocusVisible = true
          rt.requestFrame()
          return true
      if rt.frameLayout.handleListText(rt.focusSlot, ev.text):
        rt.keyboardFocusVisible = true
        rt.requestFrame()
        return true
      return false
    var replacement: ref platform.TextRange
    if ev.replace:
      replacement = new platform.TextRange
      replacement[] = rt.inputRange(ev.`from`, ev.to)
    rt.inputComposition.replace(adapter, replacement, ev.text)
    true
  of platform.textComposition:
    let adapter = rt.textInputAdapter
    if adapter == nil or adapter.inputTarget() == nil:
      let slot = rt.focusedInputHandlerSlot()
      if slot > 0 and rt.deliverInput(slot, InputEvent(
          kind: InputKind.InputCompose, text: ev.text, caret: ev.caret)):
        rt.keyboardFocusVisible = true
        return true
      return false
    when not defined(emscripten):
      if rt.lastTextInput.noInputMethod:
        return false
    if ev.text.len == 0:
      rt.inputComposition.`end`(adapter)
    else:
      var replacement: ref platform.TextRange
      if ev.replace:
        replacement = new platform.TextRange
        replacement[] = rt.inputRange(ev.`from`, ev.to)
      let caret = utf16AtRune(ev.text, ev.caret)
      adapter.setMarkedText(replacement, ev.text,
        platform.TextRange(start: caret, `end`: caret))
    true
  of platform.pointerMove:
    let moved = rt.pointerX != float32(ev.x) or rt.pointerY != float32(ev.y)
    if rt.frameLayout.owner != nil:
      inc rt.frameLayout.owner.pointerRevision
    if rt.scrollbarDrag.state != nil:
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      discard rt.frameLayout.dragScrollbar(rt.scrollbarDrag,
        rt.pointerX, rt.pointerY)
      rt.refreshPointer()
      rt.requestFrame()
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    if rt.inputPressCaptured:
      let slot = int(rt.pressTarget.slot)
      if moved:
        discard rt.deliverInput(slot, InputEvent(
          kind: InputKind.InputPointerMove, button: rt.inputPressButton,
          mods: ev.mods))
      rt.refreshPointer()
      return false
    rt.updatePointerDraggable()
    rt.refreshPointer()
    if moved and rt.pressTarget.owner == nil:
      let handlerSlot = rt.frameLayout.inputHandlerAt(rt.pointerX,
        rt.pointerY)
      if handlerSlot > 0:
        discard rt.deliverInput(handlerSlot, InputEvent(
          kind: InputKind.InputPointerMove, button: -1, mods: ev.mods))
    if rt.localDrag != nil:
      rt.updateLocalDragTarget()
      rt.requestFrame()
      return true
    if rt.pressTarget.owner == rt.frameLayout.owner:
      let owner = rt.frameLayout.owner
      let slot = owner.textInputSlot(int(rt.pressTarget.slot))
      if slot >= 0:
        let node = owner.nodes[slot]
        if node.textClient of TextFieldClient:
          let (pointerX, pointerY, ok) = rt.frameLayout.localPoint(slot,
            rt.pointerX, rt.pointerY)
          if not ok:
            return false
          let rect = rt.frameLayout.rects[slot]
          let client = TextFieldClient(node.textClient)
          client.insetX = node.pad[3] + node.border[3]
          client.insetY = node.pad[0] + node.border[0]
          if client.fieldPointerSelection(
              float64(pointerX - rect.x), float64(pointerY - rect.y),
              extend = true):
            rt.updateTextInput()
            rt.requestFrame()
    if rt.listReorder != nil:
      let state = rt.listReorder
      let (x, y, ok) = rt.frameLayout.localPoint(int(state.frameSlot),
        rt.pointerX, rt.pointerY)
      if ok and state.updateListReorder(x, y):
        rt.listReorderTarget(state)
        discard rt.autoScrollListReorder(state)
        rt.requestFrame()
        return false
    if rt.gridReorder != nil:
      let state = rt.gridReorder
      let (x, y, ok) = rt.frameLayout.localPoint(
        int(state.rows.frameSlot), rt.pointerX, rt.pointerY)
      if ok and state.updateGridReorder(x, y):
        rt.gridReorderTarget(state)
        discard rt.autoScrollGridReorder(state)
        rt.requestFrame()
        return false
    if rt.tableReorder != nil:
      let state = rt.tableReorder
      let (x, _, ok) = rt.frameLayout.localPoint(int(state.frameSlot),
        rt.pointerX, rt.pointerY)
      if ok and state.updateTableColumnDrag(rt.frameLayout.owner.nodes,
          rt.frameLayout.rects, x):
        rt.requestFrame()
      return false
    if rt.startDragFromPress():
      if rt.pointerDraggableIdentity != 0:
        rt.pointerDraggableReleasePending = true
        rt.pointerDraggableCanceled = true
      return true
    if rt.pressTarget.owner == rt.frameLayout.owner:
      let owner = rt.frameLayout.owner
      let pressSlot = int(rt.pressTarget.slot)
      let colorPlaneSlot = owner.colorPlaneAncestor(pressSlot)
      if colorPlaneSlot >= 0:
        discard rt.queueColorPlanePointer(colorPlaneSlot)
      else:
        let sliderSlot = rt.frameLayout.sliderAncestor(pressSlot)
        if sliderSlot >= 0:
          discard rt.queueSliderPointer(sliderSlot)
    var tracksPointer = false
    let owner = rt.frameLayout.owner
    if owner != nil:
      for slot in rt.hoverSlots:
        if slot > 0 and slot < owner.nodes.len and
            owner.nodes[slot].trackPointer:
          tracksPointer = true
          break
    if rt.pointerDraggableMoved or tracksPointer or
        rt.hoverSlots != previousHover or
        rt.pressedSlots != previousPressed:
      rt.requestFrame()
    false
  of platform.pointerDown:
    discard rt.event(platform.SurfaceEvent(kind: platform.pointerMove,
      x: ev.x, y: ev.y, mods: ev.mods))
    var contextClick = ev.button == 1
    var inputAttempted = false
    when defined(macosx):
      if ev.button == 0 and (ev.mods and platform.modCtrl) != 0:
        contextClick = true
    if ev.button != 0:
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      let handlerSlot = rt.frameLayout.inputHandlerAt(rt.pointerX,
        rt.pointerY)
      inputAttempted = handlerSlot > 0
      if handlerSlot > 0 and rt.captureInputPointerDown(handlerSlot,
          ev.button, ev.mods, ev.clicks):
        return true
    if contextClick:
      let previousHover = rt.hoverSlots
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      when defined(macosx):
        if ev.button == 0:
          let handlerSlot = rt.frameLayout.inputHandlerAt(rt.pointerX,
            rt.pointerY)
          inputAttempted = handlerSlot > 0
          if handlerSlot > 0 and rt.captureInputPointerDown(handlerSlot,
              ev.button, ev.mods, ev.clicks):
            return true
      rt.refreshPointer()
      let target = rt.frameLayout.targetAt(rt.pointerX, rt.pointerY)
      if rt.showContextMenu(target, rt.pointerX, rt.pointerY) or
          rt.showTableHeaderMenu(target, rt.pointerX, rt.pointerY):
        if rt.hoverSlots != previousHover:
          rt.requestFrame()
        return true
    if ev.button != 0:
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    let previousFocus = rt.focusSlot
    let previousFocusVisible = rt.keyboardFocusVisible
    rt.cancelKeyPress()
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.pressX = rt.pointerX
    rt.pressY = rt.pointerY
    rt.dragCandidateIdentity = 0
    rt.nativeDragStarted = false
    rt.pointerDraggableIdentity = 0
    rt.pointerDraggableMoved = false
    rt.pointerDraggableCaught = false
    rt.pointerDraggableReleasePending = false
    rt.pointerDraggableCanceled = false
    rt.splitPointerOffset = 0
    rt.hasPointer = true
    discard rt.dismissPopoverOutside(rt.pointerX, rt.pointerY)
    if rt.frameLayout.scrollbarPress(rt.pointerX, rt.pointerY,
        rt.scrollbarDrag):
      rt.pressTarget = Element()
      rt.pressHoverSlots.setLen(0)
      rt.refreshPointer()
      rt.requestFrame()
      return true
    rt.pressTarget = rt.frameLayout.targetAt(rt.pointerX, rt.pointerY)
    rt.dragCandidateIdentity = rt.dragCandidate(rt.pressTarget)
    rt.pressMods = ev.mods
    rt.pressHoverSlots = rt.frameLayout.slotsAt(rt.pointerX, rt.pointerY)
    if not inputAttempted and rt.pressTarget.owner == rt.frameLayout.owner:
      let targetSlot = int(rt.pressTarget.slot)
      let handlerSlot = rt.frameLayout.inputHandlerSlot(targetSlot)
      inputAttempted = handlerSlot > 0
      if handlerSlot > 0:
        rt.focusInputTarget(targetSlot)
        if rt.captureInputPointerDown(handlerSlot, ev.button, ev.mods,
            ev.clicks):
          return true
    if rt.pressTarget.owner == rt.frameLayout.owner and
        rt.pressTarget.slot > 0 and
        int(rt.pressTarget.slot) < rt.frameLayout.owner.nodes.len:
      let slot = int(rt.pressTarget.slot)
      let node = rt.frameLayout.owner.nodes[slot]
      if node.menuBuilder != nil and
          not rt.frameLayout.owner.effectivelyDisabled(slot):
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.pressTarget = Element()
        rt.pressMods = 0
        rt.pressHoverSlots.setLen(0)
        rt.showMenuButton(node.identity, node.menuBuilder)
        rt.refreshPointer()
        rt.requestFrame()
        return true
    rt.beginListReorder(rt.pressTarget)
    rt.beginGridReorder(rt.pressTarget)
    if not rt.beginTableResize(rt.pressTarget):
      rt.beginTableReorder(rt.pressTarget)
    rt.beginPointerDraggable()
    if rt.pressTarget.owner != nil:
      var slot = int(rt.pressTarget.slot)
      if rt.pressTarget.owner == rt.frameLayout.owner and
          slot > 0 and slot < rt.frameLayout.owner.nodes.len:
        let focusTarget = int(
          rt.frameLayout.owner.nodes[slot].focusTargetSlot)
        let labelTarget = int(
          rt.frameLayout.owner.nodes[slot].labelTargetSlot)
        if focusTarget > 0 and
            focusTarget < rt.frameLayout.owner.nodes.len:
          slot = focusTarget
        elif labelTarget > 0 and
            labelTarget < rt.frameLayout.owner.nodes.len:
          slot = labelTarget
      if rt.pressTarget.owner == rt.frameLayout.owner and
          rt.frameLayout.owner.effectivelyDisabled(slot):
        rt.refreshPointer()
        if rt.hoverSlots != previousHover or
            rt.pressedSlots != previousPressed:
          rt.requestFrame()
        return rt.pressTarget.owner != nil
      let colorPlaneSlot = rt.frameLayout.owner.colorPlaneAncestor(slot)
      if colorPlaneSlot >= 0:
        slot = colorPlaneSlot
        discard rt.queueColorPlanePointer(colorPlaneSlot)
      else:
        let sliderSlot = rt.frameLayout.sliderAncestor(slot)
        if sliderSlot >= 0:
          slot = sliderSlot
          if rt.frameLayout.owner.nodes[sliderSlot].splitHandle:
            rt.beginSplitPointer(sliderSlot)
          else:
            discard rt.queueSliderPointer(sliderSlot, activatePointer = true)
      var targetNode = rt.frameLayout.owner.nodes[slot]
      if targetNode.listState != nil and targetNode.listRowIndex >= 0 and
          not targetNode.listRowHeader:
        slot = int(targetNode.listState.frameSlot)
      let textSlot = rt.frameLayout.owner.textInputSlot(slot)
      if textSlot >= 0:
        slot = textSlot
      targetNode = rt.frameLayout.owner.nodes[slot]
      if rt.frameLayout.focusableSlot(slot):
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        if targetNode.textClient of TextFieldClient:
          let (pointerX, pointerY, ok) = rt.frameLayout.localPoint(slot,
            rt.pointerX, rt.pointerY)
          if not ok:
            return rt.pressTarget.owner != nil
          let rect = rt.frameLayout.rects[slot]
          let client = TextFieldClient(targetNode.textClient)
          client.insetX = targetNode.pad[3] + targetNode.border[3]
          client.insetY = targetNode.pad[0] + targetNode.border[0]
          if client.fieldPointerSelection(
              float64(pointerX - rect.x), float64(pointerY - rect.y),
              (ev.mods and platform.modShift) != 0):
            rt.updateTextInput()
    rt.refreshPointer()
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    if rt.focusSlot != previousFocus or
        rt.keyboardFocusVisible != previousFocusVisible:
      rt.requestFrame()
    return rt.pressTarget.owner != nil
  of platform.pointerUp:
    discard rt.event(platform.SurfaceEvent(kind: platform.pointerMove,
      x: ev.x, y: ev.y, mods: ev.mods))
    if rt.inputPressCaptured:
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      let slot = int(rt.pressTarget.slot)
      discard rt.deliverInput(slot, InputEvent(
        kind: InputKind.InputPointerUp, button: ev.button,
        clicks: max(ev.clicks, 1), mods: ev.mods))
      if ev.button != rt.inputPressButton:
        return false
      rt.inputPressCaptured = false
      var clicked = false
      var clickedSlot = -1
      if ev.button == 0:
        clicked = rt.frameLayout.dispatchClick(rt.pressTarget,
          rt.pointerX, rt.pointerY, rt.pressMods, clickedSlot)
      rt.clickedSlots.setLen(0)
      rt.doubleClickedSlots.setLen(0)
      if clicked:
        rt.clickedSlots.add(clickedSlot)
        if ev.clicks >= 2:
          rt.doubleClickedSlots.add(clickedSlot)
      rt.pressTarget = Element()
      rt.pressMods = 0
      rt.pressHoverSlots.setLen(0)
      rt.refreshPointer()
      rt.requestFrame()
      return clicked
    if ev.button != 0:
      return false
    rt.doubleClickedSlots.setLen(0)
    if rt.localDrag != nil:
      let drag = rt.localDrag
      let owner = rt.frameLayout.owner
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      rt.updateLocalDragTarget()
      if not drag.canceled and drag.overIdentity != 0 and owner != nil:
        owner.pendingValueDrops[drag.overIdentity] = drag.value
        owner.pendingDropGeneration = owner.generation + 1
      rt.localDrag = nil
      clearDragOwner(owner)
      rt.pressTarget = Element()
      rt.pressMods = 0
      rt.dragCandidateIdentity = 0
      rt.pressHoverSlots.setLen(0)
      rt.refreshPointer()
      rt.requestFrame()
      return true
    if rt.nativeDragStarted:
      rt.nativeDragStarted = false
      rt.dragCandidateIdentity = 0
      clearDragOwner(rt.frameLayout.owner)
      rt.pressTarget = Element()
      rt.pressMods = 0
      rt.pressHoverSlots.setLen(0)
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.refreshPointer()
      rt.requestFrame()
      return true
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    rt.updatePointerDraggable()
    if rt.scrollbarDrag.state != nil:
      rt.scrollbarDrag.state.scrollbarDragging = false
      rt.scrollbarDrag = ScrollbarDrag()
      rt.refreshPointer()
      rt.requestFrame()
      return true
    if rt.listReorder != nil:
      let state = rt.listReorder
      let (x, y, ok) = rt.frameLayout.localPoint(int(state.frameSlot),
        rt.pointerX, rt.pointerY)
      if ok and state.updateListReorder(x, y):
        rt.listReorderTarget(state)
        let slot = int(state.frameSlot)
        let owner = rt.frameLayout.owner
        let canDrop = owner != nil and slot > 0 and
          slot < owner.nodes.len and
          state.frameOwner == cast[pointer](owner) and
          state.generation == rt.frameLayout.generation and
          rt.frameLayout.insideClips(slot, rt.pointerX, rt.pointerY)
        discard state.finishListReorder(commit = canDrop)
        rt.listReorder = nil
        rt.pressTarget = Element()
        rt.pressMods = 0
        rt.pressHoverSlots.setLen(0)
        rt.refreshPointer()
        rt.requestFrame()
        return true
      discard state.finishListReorder(commit = false)
      rt.listReorder = nil
    if rt.gridReorder != nil:
      let state = rt.gridReorder
      let (x, y, ok) = rt.frameLayout.localPoint(
        int(state.rows.frameSlot), rt.pointerX, rt.pointerY)
      if ok and state.updateGridReorder(x, y):
        rt.gridReorderTarget(state)
        let slot = int(state.rows.frameSlot)
        let owner = rt.frameLayout.owner
        let canDrop = owner != nil and slot > 0 and
          slot < owner.nodes.len and
          state.rows.frameOwner == cast[pointer](owner) and
          state.rows.generation == rt.frameLayout.generation and
          rt.frameLayout.containsPointer(slot, rt.pointerX, rt.pointerY) and
          rt.frameLayout.insideClips(slot, rt.pointerX, rt.pointerY)
        discard state.finishGridReorder(commit = canDrop)
        rt.gridReorder = nil
        rt.pressTarget = Element()
        rt.pressMods = 0
        rt.pressHoverSlots.setLen(0)
        rt.refreshPointer()
        rt.requestFrame()
        return true
      discard state.finishGridReorder(commit = false)
      rt.gridReorder = nil
    if rt.tableReorder != nil:
      let state = rt.tableReorder
      let (x, _, ok) = rt.frameLayout.localPoint(int(state.frameSlot),
        rt.pointerX, rt.pointerY)
      if ok:
        discard state.updateTableColumnDrag(rt.frameLayout.owner.nodes,
          rt.frameLayout.rects, x)
      let moved = state.finishTableColumnDrag()
      rt.tableReorder = nil
      if moved:
        rt.pressTarget = Element()
        rt.pressMods = 0
        rt.pressHoverSlots.setLen(0)
        rt.refreshPointer()
        rt.requestFrame()
        return true
      if ev.clicks >= 2 and rt.pressTarget.owner == rt.frameLayout.owner:
        let target = rt.pressTarget
        let node = target.owner.nodes[int(target.slot)]
        if node.tableResizeHandle and node.tableState != nil:
          node.tableState.tableFitColumn = node.tableColumnId
          rt.pressTarget = Element()
          rt.pressMods = 0
          rt.pressHoverSlots.setLen(0)
          rt.refreshPointer()
          rt.requestFrame()
          return true
    if rt.pointerDraggableIdentity != 0:
      rt.pointerDraggableReleasePending = true
      let suppressClick = rt.pointerDraggableMoved or
        rt.pointerDraggableCaught
      rt.requestFrame()
      if suppressClick:
        rt.pressTarget = Element()
        rt.pressMods = 0
        rt.dragCandidateIdentity = 0
        rt.pressHoverSlots.setLen(0)
        rt.refreshPointer()
        return true
    let sliderSlot = if rt.pressTarget.owner == rt.frameLayout.owner:
        rt.frameLayout.sliderAncestor(int(rt.pressTarget.slot))
      else:
        -1
    let colorPlaneSlot = if rt.pressTarget.owner == rt.frameLayout.owner:
        rt.frameLayout.owner.colorPlaneAncestor(int(rt.pressTarget.slot))
      else:
        -1
    if sliderSlot >= 0:
      let rangeIdentity = rt.frameLayout.owner.rangeSliderIdentity(sliderSlot)
      discard rt.queueSliderPointer(sliderSlot)
      if rangeIdentity != 0:
        rt.frameLayout.owner.rangeSliderDrags.del(rangeIdentity)
    if colorPlaneSlot >= 0:
      discard rt.queueColorPlanePointer(colorPlaneSlot)
    var clickedSlot = -1
    let clicked = rt.frameLayout.dispatchClick(rt.pressTarget,
      rt.pointerX, rt.pointerY, rt.pressMods, clickedSlot)
    if clicked and ev.clicks >= 2 and clickedSlot > 0 and
        clickedSlot < rt.frameLayout.owner.nodes.len:
      var slot = clickedSlot
      while slot > 0 and slot < rt.frameLayout.owner.nodes.len:
        let node = rt.frameLayout.owner.nodes[slot]
        if node.gridCellState != nil and node.gridCellState.selectable:
          node.gridCellState.pendingSubmitted = true
          break
        slot = int(node.parent)
    result = clicked or sliderSlot >= 0 or colorPlaneSlot >= 0
    rt.clickedSlots.setLen(0)
    if clicked:
      rt.clickedSlots.add(clickedSlot)
      if ev.clicks >= 2:
        rt.doubleClickedSlots.add(clickedSlot)
      if clickedSlot > 0 and clickedSlot < rt.frameLayout.owner.nodes.len:
        var rowSlot = clickedSlot
        while rowSlot > 0 and rowSlot < rt.frameLayout.owner.nodes.len:
          let rowNode = rt.frameLayout.owner.nodes[rowSlot]
          if rowNode.listState != nil and rowNode.listRowIndex >= 0:
            let state = rowNode.listState
            state.lastClickRow = rowNode.listRowIndex
            state.lastClickCount = max(ev.clicks, 1)
            state.lastClickGeneration = rt.frameLayout.owner.generation + 1
            if ev.clicks >= 2:
              var ancestor = rowSlot
              var listIdentity = 0'u64
              while ancestor > 0 and
                  ancestor < rt.frameLayout.owner.nodes.len:
                let listNode = rt.frameLayout.owner.nodes[ancestor]
                if listNode.listState == state and listNode.listRowIndex == -1:
                  listIdentity = listNode.identity
                ancestor = int(listNode.parent)
              if listIdentity != 0:
                let notices = rt.frameLayout.owner.pendingNotices
                  .getOrDefault(listIdentity)
                rt.frameLayout.owner.pendingNotices[listIdentity] =
                  notices or noticeSubmitted
            break
          rowSlot = int(rowNode.parent)
    rt.pressTarget = Element()
    rt.pressMods = 0
    rt.dragCandidateIdentity = 0
    rt.splitPointerOffset = 0
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    if result or rt.hoverSlots != previousHover or
        rt.pressedSlots != previousPressed:
      rt.requestFrame()
    return result
  of platform.fileDragOver:
    let previous = rt.context.owner.fileOverIdentity
    let previousHover = rt.hoverSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    let slot = rt.frameLayout.fileDropTargetAt(rt.pointerX, rt.pointerY)
    let identity = if slot > 0:
        rt.frameLayout.owner.nodes[slot].identity
      else:
        0'u64
    rt.context.owner.fileOverIdentity = identity
    rt.refreshPointer()
    if previous != identity or previousHover != rt.hoverSlots:
      rt.requestFrame()
    identity != 0
  of platform.fileDragLeave:
    if rt.context.owner.fileOverIdentity != 0:
      rt.context.owner.fileOverIdentity = 0
      rt.requestFrame()
    false
  of platform.fileDrop:
    rt.context.owner.fileOverIdentity = 0
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    let slot = rt.frameLayout.fileDropTargetAt(rt.pointerX, rt.pointerY)
    if slot <= 0 or ev.files.len == 0:
      return false
    let identity = rt.frameLayout.owner.nodes[slot].identity
    if rt.context.owner.pendingFileDrops.hasKey(identity):
      rt.context.owner.pendingFileDrops[identity].add(ev.files)
    else:
      rt.context.owner.pendingFileDrops[identity] = @(ev.files)
    rt.context.owner.pendingDropGeneration = rt.context.owner.generation + 1
    rt.requestFrame()
    true
  of platform.dataDragOver:
    let owner = rt.frameLayout.owner
    if owner == nil or ev.drag == nil:
      if ev.drag != nil:
        ev.drag.operation = transfer.None
        ev.drag.formats = @[]
      return false
    let previousHover = rt.hoverSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    let target = rt.frameLayout.dataDropTargetAt(rt.pointerX, rt.pointerY,
      ev.drag)
    let identity = if target.slot > 0:
        owner.nodes[target.slot].identity
      else:
        0'u64
    let localIdentity = if target.localValue: identity else: 0'u64
    let offerChanged = owner.dataOverOffer.formats != ev.drag.offer.formats or
      owner.dataOverOffer.operations != ev.drag.offer.operations or
      owner.dataOverOffer.suggested != ev.drag.offer.suggested
    let changed = owner.dataOverIdentity != identity or
      owner.dataOverLocalIdentity != localIdentity or
      owner.dataOverLocal != (if target.localValue: ev.drag.`local` else: nil) or
      offerChanged
    owner.dataOverIdentity = identity
    owner.dataOverLocalIdentity = localIdentity
    owner.dataOverLocal = if target.localValue: ev.drag.`local` else: nil
    if identity != 0:
      owner.dataOverOffer = ev.drag.offer
      owner.dataOverOffer.formats = @(ev.drag.offer.formats)
      ev.drag.operation = target.operation
      ev.drag.formats = target.formats
    else:
      owner.dataOverOffer = transfer.Offer()
      ev.drag.operation = transfer.None
      ev.drag.formats = @[]
    rt.refreshPointer()
    if changed or previousHover != rt.hoverSlots:
      rt.requestFrame()
    identity != 0
  of platform.dataDragLeave:
    let owner = rt.context.owner
    if owner.dataOverIdentity != 0 or owner.fileOverIdentity != 0:
      owner.dataOverIdentity = 0
      owner.fileOverIdentity = 0
      owner.dataOverOffer = transfer.Offer()
      owner.dataOverLocalIdentity = 0
      owner.dataOverLocal = nil
      rt.requestFrame()
    false
  of platform.dataDrop:
    let owner = rt.frameLayout.owner
    if owner == nil:
      if ev.drag != nil:
        ev.drag.operation = transfer.None
        ev.drag.formats = @[]
      return false
    owner.dataOverIdentity = 0
    owner.dataOverOffer = transfer.Offer()
    owner.dataOverLocalIdentity = 0
    owner.dataOverLocal = nil
    if ev.drag == nil:
      return false
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    let target = rt.frameLayout.dataDropTargetAt(rt.pointerX, rt.pointerY,
      ev.drag)
    if target.slot <= 0:
      ev.drag.operation = transfer.None
      ev.drag.formats = @[]
      rt.requestFrame()
      return false
    let identity = owner.nodes[target.slot].identity
    if target.localValue:
      owner.pendingValueDrops[identity] = ev.drag.`local`
      owner.pendingDropGeneration = owner.generation + 1
      ev.drag.operation = target.operation
      ev.drag.formats = @[]
      rt.refreshPointer()
      rt.requestFrame()
      return true
    let (data, err) = ev.drag.data.materialize(target.formats)
    if err != nil:
      ev.drag.operation = transfer.None
      ev.drag.formats = @[]
      rt.requestFrame()
      return false
    owner.pendingDataDrops[identity] = transfer.Drop(data: data,
      operation: target.operation)
    owner.pendingDropGeneration = owner.generation + 1
    ev.drag.operation = target.operation
    ev.drag.formats = target.formats
    rt.refreshPointer()
    rt.requestFrame()
    true
  of platform.surfaceBlur:
    let previousPressed = rt.pressedSlots
    let previousFocusVisible = rt.keyboardFocusVisible
    let hadTextInput = rt.hasTextInputState and rt.lastTextInput.active
    let hadScrollbarDrag = rt.scrollbarDrag.state != nil
    let hadListReorder = rt.listReorder != nil
    let hadGridReorder = rt.gridReorder != nil
    let hadTableReorder = rt.tableReorder != nil
    let hadPointerDraggable = rt.pointerDraggableIdentity != 0
    if hadPointerDraggable:
      rt.pointerDraggableReleasePending = true
      rt.pointerDraggableCanceled = true
    if hadScrollbarDrag:
      rt.scrollbarDrag.state.scrollbarDragging = false
      rt.scrollbarDrag = ScrollbarDrag()
    rt.cancelListReorder()
    rt.cancelGridReorder()
    rt.cancelTableReorder()
    rt.cancelKeyPress()
    if rt.inputPressCaptured:
      discard rt.deliverInput(int(rt.pressTarget.slot), InputEvent(
        kind: InputKind.InputPointerUp, button: rt.inputPressButton,
        clicks: 1, mods: rt.pressMods))
      rt.inputPressCaptured = false
    rt.byPosition.clear()
    rt.keyboardFocusVisible = false
    rt.surfaceFocused = false
    rt.context.owner.focusActive = false
    rt.context.owner.rangeSliderDrags.clear()
    rt.localDrag = nil
    clearDragOwner(rt.context.owner)
    rt.pressTarget = Element()
    rt.pressMods = 0
    rt.dragCandidateIdentity = 0
    rt.nativeDragStarted = false
    rt.splitPointerOffset = 0
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    rt.updateTextInput()
    if rt.pressedSlots != previousPressed or previousFocusVisible or
        hadTextInput or hadScrollbarDrag or hadListReorder or
        hadGridReorder or hadTableReorder or hadPointerDraggable:
      rt.requestFrame()
    false
  of platform.pointerLeave:
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.hasPointer = false
    rt.refreshPointer()
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    false
  of platform.accessibilityOn:
    rt.accessibilityOn = true
    rt.context.owner.accessibilityActive = true
    rt.updateAccessibility()
    true
  of platform.accessAction:
    if ev.action == platform.accessPress:
      result = rt.frameLayout.dispatchAccessPress(ev.id)
      if result:
        let clickedSlot = int(ev.id - 1)
        var focusSlot = clickedSlot
        let targetNode = rt.frameLayout.owner.nodes[clickedSlot]
        if targetNode.listState != nil and targetNode.listRowIndex >= 0 and
            not targetNode.listRowHeader:
          focusSlot = int(targetNode.listState.frameSlot)
        rt.clickedSlots = @[clickedSlot]
        rt.focusSlot = focusSlot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        rt.requestFrame()
    elif ev.action in {platform.accessIncrement, platform.accessDecrement} and
        ev.id > 0:
      let slot = int(ev.id - 1)
      let owner = rt.frameLayout.owner
      if owner != nil and slot > 0 and slot < owner.nodes.len and
          owner.nodes[slot].slider and
          not owner.effectivelyDisabled(slot) and
          not owner.effectivelyToolbarCollapsed(slot):
        let node = owner.nodes[slot]
        let identity = node.identity
        let current = owner.pendingSliderValues.getOrDefault(identity,
          node.sliderValue)
        let delta = if ev.action == platform.accessIncrement:
            node.sliderStep
          else:
            -node.sliderStep
        let focusChanged = rt.focusSlot != slot or rt.keyboardFocusVisible
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        discard rt.queueSliderValue(slot, current + delta)
        if focusChanged:
          rt.requestFrame()
        result = true
      elif owner != nil and slot > 0 and slot < owner.nodes.len and
          owner.nodes[slot].accessStepHandler != nil and
          not owner.effectivelyDisabled(slot) and
          not owner.effectivelyToolbarCollapsed(slot):
        let node = owner.nodes[slot]
        let handler = node.accessStepHandler
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        handler(if ev.action == platform.accessIncrement:
          node.accessStep else: -node.accessStep)
        rt.requestFrame()
        result = true
    elif ev.action in {platform.accessExpand, platform.accessCollapse}:
      result = rt.frameLayout.dispatchAccessTreeAction(ev.id, ev.action)
      if result:
        let clickedSlot = int(ev.id - 1)
        let targetNode = rt.frameLayout.owner.nodes[clickedSlot]
        let focusTarget = int(targetNode.focusTargetSlot)
        rt.focusSlot = if focusTarget > 0 and
            focusTarget < rt.frameLayout.owner.nodes.len:
          focusTarget
        elif targetNode.listState != nil and
            targetNode.listRowIndex >= 0:
          int(targetNode.listState.frameSlot)
        else:
          clickedSlot
        if targetNode.treeAccessFocus != nil:
          targetNode.treeAccessFocus()
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        rt.requestFrame()
    elif ev.action == platform.accessFocus and ev.id > 0:
      let slot = int(ev.id - 1)
      if rt.frameLayout.focusableSlot(slot):
        let changed = rt.focusSlot != slot or rt.keyboardFocusVisible
        rt.focusSlot = slot
        rt.keyboardFocusVisible = false
        rt.cancelKeyPress()
        let scrolled = rt.frameLayout.revealSlot(slot)
        if changed or scrolled:
          rt.requestFrame()
        let owner = rt.frameLayout.owner
        if owner != nil and slot > 0 and slot < owner.nodes.len and
            owner.nodes[slot].treeAccessFocus != nil:
          owner.nodes[slot].treeAccessFocus()
          rt.requestFrame()
        result = true
    elif ev.action == platform.accessScrollIntoView and ev.id > 0:
      let slot = int(ev.id - 1)
      if rt.frameLayout.hasScrollAncestor(slot):
        discard rt.frameLayout.revealSlot(slot)
        rt.requestFrame()
        result = true
    elif ev.action == platform.accessSelectText and ev.id > 0:
      let slot = int(ev.id - 1)
      let owner = rt.frameLayout.owner
      if owner != nil and slot > 0 and slot < owner.nodes.len:
        let handler = owner.nodes[slot].inputHandler
        if handler != nil and not owner.effectivelyDisabled(slot) and
            not owner.effectivelyToolbarCollapsed(slot):
          result = rt.deliverInput(slot, InputEvent(
            kind: InputKind.InputSelect, start: ev.`from`, `end`: ev.to))
          rt.requestFrame()
    elif ev.action == platform.accessSetValue and ev.id > 0:
      let slot = int(ev.id - 1)
      let owner = rt.frameLayout.owner
      if owner != nil and slot > 0 and slot < owner.nodes.len and
          not owner.effectivelyDisabled(slot) and
          not owner.effectivelyToolbarCollapsed(slot):
        let node = owner.nodes[slot]
        if node.colorPlane:
          try:
            let saturation = parseFloat(ev.text) / 100
            if classify(saturation) notin {fcNan, fcInf, fcNegInf} and
                saturation >= 0 and saturation <= 1:
              let value = owner.pendingColorPlanes.getOrDefault(node.identity,
                ColorPlaneValue(saturation: node.colorPlaneSaturation,
                                brightness: node.colorPlaneBrightness))
              owner.pendingColorPlanes[node.identity] = ColorPlaneValue(
                saturation: saturation, brightness: value.brightness)
              rt.focusSlot = slot
              rt.keyboardFocusVisible = false
              rt.cancelKeyPress()
              rt.requestFrame()
              result = true
          except ValueError:
            discard
        elif node.textClient != nil:
          let client = node.textClient
          if client of TextFieldClient and TextFieldClient(client).readOnly:
            return false
          let before = platform.clientTextContext(client).text
          let (_, actual) = client.textForRange(platform.TextRange(
            start: 0, `end`: high(int)))
          let replacement = new platform.TextRange
          replacement.start = max(0, actual.start)
          replacement.`end` = max(replacement.start, actual.`end`)
          client.replaceText(replacement, ev.text)
          rt.focusSlot = slot
          rt.keyboardFocusVisible = false
          rt.inputComposition.reset()
          rt.inputChanged(slot, before)
          result = true
    return result
  else:
    false

proc capture(rt: Runtime): tuple[width, height: int, rgba: seq[byte]] =
  if rt.closed:
    return
  if not rt.hasScene:
    rt.renderFrame(false)
    rt.requestFrame()
  if not rt.hasScene:
    return

  var software: raster.Renderer
  discard software.render(rt.frameScene)
  let image = software.image
  result.width = image.w
  result.height = image.h
  result.rgba = image.pix
  for offset in countup(0, result.rgba.high - 3, 4):
    swap(result.rgba[offset], result.rgba[offset + 2])

proc render*(view: proc(c: Context) {.closure.}; width, height: int;
             scale = 1'f32): sourceImage.RgbaImage =
  ## Builds and draws one native UI frame into a premultiplied RGBA image.
  ## Width and height are DIPs; scale is device pixels per DIP.
  if view == nil:
    raise newException(ValueError, "ui: Render needs a view")
  let w = frameDimension(float64(width), "width")
  let h = frameDimension(float64(height), "height")
  let deviceScale = if classify(scale) in {fcNan, fcInf, fcNegInf} or
      scale <= 0: 1'f32 else: scale

  let c = newContext()
  defer: c.close()
  c.theme = lightTheme()
  c.themeEnabled = true
  c.themeBackground = false
  c.build(view)
  let layout = c.layoutAt(Rect(w: w, h: h), getMonoTime(),
                          c.reduceMotion)
  let frame = layout.paintScene(deviceScale)
  var software: raster.Renderer
  discard software.render(frame)
  let bitmap = software.image
  result = sourceImage.RgbaImage(pix: bitmap.rgba(),
    stride: bitmap.w * 4,
    rect: sourceImage.rect(0, 0, bitmap.w, bitmap.h))

proc close(rt: Runtime) =
  if rt.closed:
    return
  if rt.textInputAdapter != nil:
    rt.textInputAdapter.release()
    rt.textInputAdapter = nil
    rt.inputComposition.reset()
  if rt.hasTextInputState and rt.conn.surface != nil:
    rt.conn.surface.setTextInput(platform.TextInputState())
    rt.hasTextInputState = false
  rt.cancelListReorder()
  rt.cancelGridReorder()
  rt.cancelTableReorder()
  rt.closed = true
  rt.context.close()
  rt.releaseGpu()
  rt.frameLayout = LayoutResult()
  rt.pressTarget = Element()
  rt.gpuError.setLen(0)
  rt.software.release()
  rt.frameScene = scene.Scene()
  rt.hasScene = false

method attachContent*(content: Content; conn: surface.Conn) =
  let rt = Runtime(conn: conn, view: content.view, context: newContext(),
                   focusSlot: -1, keyPressSlot: -1, surfaceFocused: true,
                   themeDirty: true,
                   byPosition: initHashSet[platform.Key](),
                   focusGroupLast: initTable[uint64, uint64](),
                   modalFocusReturns: initTable[uint64, uint64]())
  rt.context.owner.focusActive = true
  let frameSurface = conn.surface
  var invalidate = conn.invalidate
  if invalidate == nil:
    invalidate = proc() =
      if frameSurface != nil:
        frameSurface.requestFrame()
  let serviceState = UiServiceState(
    clipboard: conn.clipboard,
    invalidate: invalidate,
    openURL: conn.openURL)
  initLock(serviceState.lock)
  rt.context.serviceState = serviceState
  rt.context.owner.invalidate = proc() =
    if frameSurface != nil:
      frameSurface.requestFrame()
  conn.event = proc(ev: platform.SurfaceEvent): bool = rt.event(ev)
  conn.changed = proc() = rt.requestFrame()
  conn.themeChanged = proc() =
    rt.themeDirty = true
    rt.requestFrame()
  conn.titleBarChanged = proc() = rt.requestFrame()
  conn.localeChanged = proc() = rt.requestFrame()
  conn.capture = proc(): tuple[width, height: int, rgba: seq[byte]] =
    rt.capture()
  conn.detach = proc() = rt.close()
  rt.requestFrame()
