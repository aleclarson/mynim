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
    scrollbarDrag: ScrollbarDrag
    focusSlot, keyPressSlot: int
    keyPressKey: platform.Key
    focusGroupLast: Table[uint64, uint64]
    listReorder, tableReorder: ListState
    pointerCursor: platform.Cursor
    hasPointerCursor: bool
    textInputAdapter: TextInputAdapter
    lastTextInput: platform.TextInputState
    inputComposition: platform.InputComposition
    pointerX, pointerY: float32
    splitPointerOffset: float64
    hasPointer: bool
    hoverSlots, pressHoverSlots, pressedSlots, clickedSlots: seq[int]
    frameScene: scene.Scene
    hasScene: bool
    accessibilityOn: bool
    keyboardFocusVisible, surfaceFocused, hasTextInputState,
      inFrame, closed, ready, gpuTried, themeDirty: bool
    gpuError: string
    software: raster.Renderer
    when defined(macosx):
      metalRenderer: metalGpu.Renderer
    elif defined(windows):
      d3d11Renderer: d3d11Gpu.Renderer
    elif (defined(linux) and (defined(amd64) or defined(arm64))) or
        defined(emscripten):
      glRenderer: glGpu.Renderer

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
  if owner.effectivelyDisabled(slot):
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
    if layout.focusableSlot(lastSlot) and
        layout.focusGroupOf(lastSlot) == groupSlot:
      return lastSlot
  var first = -1
  for slot in 1..<owner.nodes.len:
    if not layout.focusableSlot(slot) or layout.focusGroupOf(slot) != groupSlot:
      continue
    if first < 0:
      first = slot
    let node = owner.nodes[slot]
    if node.accessRole in {platform.roleRadio, platform.roleTab} and
        (node.accessExtraStates and platform.accessChecked) !=
          platform.AccessStates(0):
      return slot
  first

proc isFocusGroupTabStop(rt: Runtime; layout: LayoutResult; slot: int): bool =
  let groupSlot = layout.focusGroupOf(slot)
  groupSlot < 0 or rt.focusGroupEntry(layout, groupSlot) == slot

proc cancelKeyPress(rt: Runtime)
proc refreshPointer(rt: Runtime)
proc requestFrame(rt: Runtime)

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

proc dismissPopover(rt: Runtime): bool =
  let owner = rt.frameLayout.owner
  if owner == nil:
    return false
  for slot in countdown(owner.nodes.high, 1):
    let state = owner.nodes[slot].popoverState
    if state != nil and state.open:
      let anchorSlot = owner.idSlots.getOrDefault(state.anchorIdentity, -1)
      if not owner.isWithinNode(slot, rt.focusSlot) and
          not owner.isWithinNode(anchorSlot, rt.focusSlot):
        continue
      state.pendingDismiss = true
      rt.requestFrame()
      return true

proc dismissPopoverOutside(rt: Runtime; x, y: float32): bool =
  let layout = rt.frameLayout
  let owner = layout.owner
  if owner == nil:
    return false
  for slot in countdown(owner.nodes.high, 1):
    let state = owner.nodes[slot].popoverState
    if state == nil or not state.open:
      continue
    let anchorSlot = owner.idSlots.getOrDefault(state.anchorIdentity, -1)
    let inPanel = slot < layout.rects.len and
      layout.rects[slot].contains(x, y)
    let inAnchor = anchorSlot > 0 and anchorSlot < layout.rects.len and
      layout.rects[anchorSlot].contains(x, y) and
      layout.insideClips(anchorSlot, x, y)
    if inPanel or inAnchor:
      return false
    state.pendingDismiss = true
    rt.requestFrame()
    return true

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
    if node.accessHidden:
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
    let parentSlot = int(node.parent)
    if node.rangeSliderThumb and parentSlot > 0 and
        parentSlot < owner.nodes.len and owner.nodes[parentSlot].label.len > 0:
      label = owner.nodes[parentSlot].label & " " & label
    let parent = if parentSlot >= 0: accessIndex[parentSlot] else: -1
    let rect = layout.rects[slot]
    var accessible = platform.AccessNode(id: uint64(slot + 1),
      parent: parent, role: role, label: label,
      bounds: platform.RectF(x: rect.x.float64, y: rect.y.float64,
        w: rect.w.float64, h: rect.h.float64))
    accessible.description = node.accessDescription
    accessible.states = accessible.states or node.accessSort
    accessible.states = accessible.states or node.accessExtraStates
    accessible.actions = accessible.actions or node.accessExtraActions
    accessible.level = node.accessLevel
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

proc updateAccessibility(rt: Runtime) =
  if rt.accessibilityOn and rt.conn.surface != nil:
    rt.conn.surface.updateAccessibility(
      rt.frameLayout.accessibilityTree(rt.focusSlot))

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

proc updateTextInput(rt: Runtime)
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
    let rect = adapter.runtime.frameLayout.rects[adapter.slot]
    result.bounds.x += float64(rect.x)
    result.bounds.y += float64(rect.y)

method indexForPoint*(adapter: TextInputAdapter; x, y: float64):
    tuple[i: int, ok: bool] =
  let client = adapter.inputTarget()
  if client == nil:
    return (0, false)
  let rect = adapter.runtime.frameLayout.rects[adapter.slot]
  client.indexForPoint(x - float64(rect.x), y - float64(rect.y))

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
    a.start == b.start and a.`end` == b.`end` and a.client == b.client

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
      state.caret = platform.RectF(x: float64(rect.x), y: float64(rect.y),
        w: 1, h: max(float64(rect.h), 1))

  if not rt.hasTextInputState and not state.active:
    return
  if rt.hasTextInputState and rt.lastTextInput.sameTextInput(state):
    return
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
      if node.splitHandle:
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
  let raw = if node.splitVertical:
      rt.pointerY - bounds.y - 0.5'f32
    elif node.rightToLeft:
      bounds.x + bounds.w - rt.pointerX - 0.5'f32
    else:
      rt.pointerX - bounds.x - 0.5'f32
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
  let left = bounds.x + root.border[3] + root.pad[3]
  let width = bounds.w - root.contentInsetX
  if width <= 0:
    return false
  var fraction = (rt.pointerX - left) / width
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
    let bounds = layout.rects[ancestor]
    let position = if node.splitVertical:
        rt.pointerY - bounds.y
      elif node.rightToLeft:
        bounds.x + bounds.w - rt.pointerX
      else:
        rt.pointerX - bounds.x
    return rt.queueSliderValue(slot,
      float64(position - 0.5'f32) - rt.splitPointerOffset)
  if node.stepper or (node.rating and not activatePointer):
    return false
  let bounds = layout.rects[slot]
  var fraction: float32
  if node.sliderVertical:
    let top = bounds.y + node.border[0] + node.pad[0]
    let height = bounds.h - node.contentInsetY
    if height <= 0:
      return false
    fraction = 1 - (rt.pointerY - top) / height
  else:
    let left = bounds.x + node.border[3] + node.pad[3]
    let width = bounds.w - node.contentInsetX
    if width <= 0:
      return false
    fraction = (rt.pointerX - left) / width
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

proc sliderKey(rt: Runtime; key: platform.Key;
               mods: platform.Modifiers): bool =
  if mods != 0 or not rt.frameLayout.focusableSlot(rt.focusSlot):
    return false
  let owner = rt.frameLayout.owner
  if owner == nil or rt.focusSlot <= 0 or rt.focusSlot >= owner.nodes.len:
    return false
  let node = owner.nodes[rt.focusSlot]
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

proc renderFrame(rt: Runtime; presentFrame = true) =
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

  if rt.themeDirty:
    rt.updateSystemTheme()
  rt.context.owner.focusActive = rt.surfaceFocused
  rt.context.theme = rt.systemTheme
  rt.context.rightToLeft = rt.conn.rightToLeft != nil and
    rt.conn.rightToLeft()
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
  previousOwner.previousInteraction.clear()
  previousOwner.rememberInteraction(previousIdentities, rt.hoverSlots,
    identityHovered)
  previousOwner.rememberInteraction(previousIdentities, rt.pressedSlots,
    identityPressed)
  previousOwner.rememberInteraction(previousIdentities, rt.clickedSlots,
    identityClicked)
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
  previousOwner.focusedSlots.setLen(0)
  previousOwner.focusVisibleSlots.setLen(0)
  rt.clickedSlots.setLen(0)
  rt.context.reduceMotion = rt.systemPreferences.reduceMotion
  rt.context.build(rt.view)
  let currentOwner = rt.context.owner
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
    rt.pressHoverSlots.setLen(0)
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
  rt.frameLayout = layout
  rt.updatePointerCursor()
  if presentFrame and rt.listReorder != nil and
      rt.listReorder.reorderDragging and rt.autoScrollListReorder(rt.listReorder):
    rt.requestFrame()
  rt.updateTextInput()
  rt.frameScene = layout.paintScene(scale)
  rt.hasScene = true
  rt.updateAccessibility()
  if presentFrame:
    rt.present(rt.frameScene)

  if presentFrame and layout.animating:
    rt.requestFrame()

  if presentFrame and not rt.ready and rt.conn.ready != nil and
      rt.conn.post != nil:
    rt.ready = true
    rt.conn.post(rt.conn.ready)

proc requestFrame(rt: Runtime) =
  if not rt.closed and rt.conn.surface != nil:
    rt.conn.surface.requestFrame()

proc cancelListReorder(rt: Runtime) =
  if rt.listReorder != nil:
    rt.listReorder.cancelListReorder()
    rt.listReorder = nil

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
    if node.listState != nil and node.listRowIndex >= 0 and
        node.listState.beginListReorder(node.listRowIndex,
          rt.pointerX, rt.pointerY):
      rt.listReorder = node.listState
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
        not node.tableColumnFixed and
        node.tableState.beginTableColumnDrag(node.tableColumnId,
          rt.pointerX):
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
    if node.tableResizeHandle and node.tableState != nil and
        node.tableState.beginTableColumnResize(node.tableColumnId,
          rt.pointerX, target.owner.nodes, rt.frameLayout.rects):
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
      not rt.frameLayout.insideClips(slot, state.reorderPointerX,
        state.reorderPointerY):
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

proc event(rt: Runtime; ev: platform.SurfaceEvent): bool =
  if rt.closed:
    return false
  case ev.kind
  of platform.surfaceFrame:
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
    if ev.key == platform.keyTab and
        (ev.mods and (platform.modCtrl or platform.modAlt or
          platform.modSuper)) == 0:
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
      return false
    if ev.key == platform.keyEscape and ev.mods == 0 and rt.dismissPopover():
      return true
    if rt.sliderKey(ev.key, ev.mods):
      return true
    if ev.mods == 0 and ev.key in {platform.keyUp, platform.keyDown}:
      let owner = rt.context.owner
      if owner != nil and rt.focusSlot > 0 and
          rt.focusSlot < owner.nodes.len and
          not owner.effectivelyDisabled(rt.focusSlot):
        let stepHandler = owner.nodes[rt.focusSlot].accessStepHandler
        if stepHandler != nil:
          let step = owner.nodes[rt.focusSlot].accessStep
          stepHandler(if ev.key == platform.keyUp: step else: -step)
          rt.keyboardFocusVisible = true
          rt.requestFrame()
          return true
    if rt.textFieldKey(ev.key, ev.mods):
      return true
    var nextFocusSlot = rt.focusSlot
    if rt.frameLayout.handleListKey(rt.focusSlot, ev.key, ev.mods,
        nextFocusSlot):
      if nextFocusSlot != rt.focusSlot:
        rt.focusSlot = nextFocusSlot
        discard rt.frameLayout.revealSlot(nextFocusSlot)
      rt.keyboardFocusVisible = true
      rt.requestFrame()
      return true
    if rt.handleFocusGroupKey(ev.key, ev.mods):
      return true
    if ev.key in {platform.keyEnter, platform.keySpace} and
        ev.mods == 0 and rt.focusSlot > 0 and
        rt.frameLayout.keyboardActivationSlot(rt.focusSlot, ev.key):
      if not ev.repeat:
        rt.keyPressSlot = rt.focusSlot
        rt.keyPressKey = ev.key
        rt.keyboardFocusVisible = true
        rt.refreshPointer()
        rt.requestFrame()
      return true
    if ev.key == platform.keyEnter and rt.submitFocusedText(ev.mods):
      return true
    if rt.runShortcutAction(ev.mods, ev.key):
      return true
    if ev.key == platform.keyEscape and
        rt.context.owner.tooltips.shown != 0:
      rt.context.owner.tooltips.dismissed = rt.context.owner.tooltips.shown
      rt.requestFrame()
      return true
    var dx, dy, page: float32
    if ev.mods == 0:
      case ev.key
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
    elif ev.mods == platform.modShift and ev.key == platform.keySpace:
      page = -1
    elif ev.mods == platform.modSuper and ev.key == platform.keyHome:
      dy = -1_000_000_000
    elif ev.mods == platform.modSuper and ev.key == platform.keyEnd:
      dy = 1_000_000_000
    when defined(macosx):
      if ev.mods == platform.modSuper and ev.key == platform.keyUp:
        dy = -1_000_000_000
      elif ev.mods == platform.modSuper and ev.key == platform.keyDown:
        dy = 1_000_000_000
    if (dx != 0 or dy != 0 or page != 0) and
        rt.frameLayout.scrollKey(rt.focusSlot, rt.pointerX, rt.pointerY,
          dx, dy, page, rt.hasPointer):
      rt.requestFrame()
      return true
    false
  of platform.keyReleased:
    if ev.key == rt.keyPressKey and rt.keyPressSlot > 0:
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
    rt.textFieldCommand(ev.text)
  of platform.pointerScroll:
    rt.pointerX = scrollDelta(ev.x)
    rt.pointerY = scrollDelta(ev.y)
    rt.hasPointer = true
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
    if rt.scrollbarDrag.state != nil:
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      discard rt.scrollbarDrag.dragScrollbar(rt.pointerX, rt.pointerY)
      rt.refreshPointer()
      rt.requestFrame()
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    rt.refreshPointer()
    if rt.pressTarget.owner == rt.frameLayout.owner:
      let owner = rt.frameLayout.owner
      let slot = owner.textInputSlot(int(rt.pressTarget.slot))
      if slot >= 0:
        let node = owner.nodes[slot]
        if node.textClient of TextFieldClient:
          let rect = rt.frameLayout.rects[slot]
          let client = TextFieldClient(node.textClient)
          client.insetX = node.pad[3] + node.border[3]
          client.insetY = node.pad[0] + node.border[0]
          if client.fieldPointerSelection(
              float64(rt.pointerX - rect.x), float64(rt.pointerY - rect.y),
              extend = true):
            rt.updateTextInput()
            rt.requestFrame()
    if rt.listReorder != nil and
        rt.listReorder.updateListReorder(rt.pointerX, rt.pointerY):
      rt.listReorderTarget(rt.listReorder)
      discard rt.autoScrollListReorder(rt.listReorder)
      rt.requestFrame()
      return false
    if rt.tableReorder != nil:
      if rt.tableReorder.updateTableColumnDrag(rt.frameLayout.owner.nodes,
          rt.frameLayout.rects, rt.pointerX):
        rt.requestFrame()
      return false
    if rt.pressTarget.owner == rt.frameLayout.owner:
      let sliderSlot = rt.frameLayout.sliderAncestor(
        int(rt.pressTarget.slot))
      if sliderSlot >= 0:
        discard rt.queueSliderPointer(sliderSlot)
    if rt.hoverSlots != previousHover or rt.pressedSlots != previousPressed:
      rt.requestFrame()
    false
  of platform.pointerDown:
    var contextClick = ev.button == 1
    when defined(macosx):
      if ev.button == 0 and (ev.mods and platform.modCtrl) != 0:
        contextClick = true
    if contextClick:
      let previousHover = rt.hoverSlots
      rt.pointerX = float32(ev.x)
      rt.pointerY = float32(ev.y)
      rt.hasPointer = true
      rt.refreshPointer()
      let target = rt.frameLayout.targetAt(rt.pointerX, rt.pointerY)
      if rt.showTableHeaderMenu(target, rt.pointerX, rt.pointerY):
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
    rt.pressMods = ev.mods
    rt.pressHoverSlots = rt.frameLayout.slotsAt(rt.pointerX, rt.pointerY)
    rt.beginListReorder(rt.pressTarget)
    if not rt.beginTableResize(rt.pressTarget):
      rt.beginTableReorder(rt.pressTarget)
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
          let rect = rt.frameLayout.rects[slot]
          let client = TextFieldClient(targetNode.textClient)
          client.insetX = targetNode.pad[3] + targetNode.border[3]
          client.insetY = targetNode.pad[0] + targetNode.border[0]
          if client.fieldPointerSelection(
              float64(rt.pointerX - rect.x), float64(rt.pointerY - rect.y),
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
    if ev.button != 0:
      return false
    let previousHover = rt.hoverSlots
    let previousPressed = rt.pressedSlots
    rt.pointerX = float32(ev.x)
    rt.pointerY = float32(ev.y)
    rt.hasPointer = true
    if rt.scrollbarDrag.state != nil:
      rt.scrollbarDrag.state.scrollbarDragging = false
      rt.scrollbarDrag = ScrollbarDrag()
      rt.refreshPointer()
      rt.requestFrame()
      return true
    if rt.listReorder != nil:
      let state = rt.listReorder
      if state.updateListReorder(rt.pointerX, rt.pointerY):
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
    if rt.tableReorder != nil:
      let state = rt.tableReorder
      discard state.updateTableColumnDrag(rt.frameLayout.owner.nodes,
        rt.frameLayout.rects, rt.pointerX)
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
    let sliderSlot = if rt.pressTarget.owner == rt.frameLayout.owner:
        rt.frameLayout.sliderAncestor(int(rt.pressTarget.slot))
      else:
        -1
    if sliderSlot >= 0:
      let rangeIdentity = rt.frameLayout.owner.rangeSliderIdentity(sliderSlot)
      discard rt.queueSliderPointer(sliderSlot)
      if rangeIdentity != 0:
        rt.frameLayout.owner.rangeSliderDrags.del(rangeIdentity)
    var clickedSlot = -1
    let clicked = rt.frameLayout.dispatchClick(rt.pressTarget,
      rt.pointerX, rt.pointerY, rt.pressMods, clickedSlot)
    result = clicked or sliderSlot >= 0
    rt.clickedSlots.setLen(0)
    if clicked:
      rt.clickedSlots.add(clickedSlot)
    rt.pressTarget = Element()
    rt.pressMods = 0
    rt.splitPointerOffset = 0
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    if result or rt.hoverSlots != previousHover or
        rt.pressedSlots != previousPressed:
      rt.requestFrame()
    return result
  of platform.surfaceBlur:
    let previousPressed = rt.pressedSlots
    let previousFocusVisible = rt.keyboardFocusVisible
    let hadTextInput = rt.hasTextInputState and rt.lastTextInput.active
    let hadScrollbarDrag = rt.scrollbarDrag.state != nil
    let hadListReorder = rt.listReorder != nil
    let hadTableReorder = rt.tableReorder != nil
    if hadScrollbarDrag:
      rt.scrollbarDrag.state.scrollbarDragging = false
      rt.scrollbarDrag = ScrollbarDrag()
    rt.cancelListReorder()
    rt.cancelTableReorder()
    rt.cancelKeyPress()
    rt.keyboardFocusVisible = false
    rt.surfaceFocused = false
    rt.context.owner.focusActive = false
    rt.context.owner.rangeSliderDrags.clear()
    rt.pressTarget = Element()
    rt.pressMods = 0
    rt.splitPointerOffset = 0
    rt.pressHoverSlots.setLen(0)
    rt.refreshPointer()
    rt.updateTextInput()
    if rt.pressedSlots != previousPressed or previousFocusVisible or
        hadTextInput or hadScrollbarDrag or hadListReorder or
        hadTableReorder:
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
          not owner.effectivelyDisabled(slot):
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
          not owner.effectivelyDisabled(slot):
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
    elif ev.action == platform.accessSetValue and ev.id > 0:
      let slot = int(ev.id - 1)
      let owner = rt.frameLayout.owner
      if owner != nil and slot > 0 and slot < owner.nodes.len and
          owner.nodes[slot].textClient != nil and
          not owner.effectivelyDisabled(slot):
        let client = owner.nodes[slot].textClient
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
                   focusGroupLast: initTable[uint64, uint64]())
  rt.context.owner.focusActive = true
  let frameSurface = conn.surface
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
