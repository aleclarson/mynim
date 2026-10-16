## Search navigation controls for an app-provided text search.

proc findBarState(c: Context; identity: uint64): FindBarState =
  result = c.owner.findBarStates.getOrDefault(identity)
  if result == nil:
    new(result)
    result.focus = newHandle()
    c.owner.findBarStates[identity] = result

proc queueFindBarStep(owner: ElementOwner; state: FindBarState; step: int;
                      matches: int) =
  if owner == nil or owner.closed or state == nil:
    return
  if matches <= 0:
    return
  state.pendingStep += step
  if owner.invalidate != nil:
    owner.invalidate()

proc findBar*(c: Context; open: var bool; query: var string;
              matches: int; current: var int): Element =
  ## Builds a localized find bar while open. The app searches query, supplies
  ## the match count, and uses current as the zero-based selected match.
  ## Opening focuses and selects the query. Enter, Next, Cmd+G on macOS, and
  ## F3 elsewhere move forward; Shift+Enter, Previous, and the shifted
  ## shortcuts move backward. Navigation wraps. Escape and Done close the bar.
  ## The returned element's changed() reports match navigation.
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: FindBar outside a frame build")

  let theme = c.theme
  let messages = l10n.`in`(c.localeTag)
  result = c.key("find bar").row().gap(theme.space(2))
    .padding(theme.space(1.5), theme.space(3))
    .alignItems(Align.Center).background(theme.surface)
    .borderWidth(0, 0, 1, 0).borderColor(theme.border).shrink(0)
  let bar = result
  let barSlot = int(bar.slot)
  let barNode = bar.node
  if barNode == nil:
    return
  let state = c.findBarState(barNode[].identity)
  var changed = false
  if state.pendingClose:
    open = false
    state.pendingClose = false
  if not open:
    state.wasOpen = false
    state.pendingStep = 0
    barNode[].absolute = true
    barNode[].accessHidden = true
    discard bar.size(0, 0)
    barNode[].changed = false
    return

  barNode[].accessRole = platform.roleToolbar
  barNode[].accessRoleSet = true
  barNode[].label = messages.find()
  barNode[].changed = false
  current = max(0, min(current, matches - 1))
  if state.pendingStep != 0:
    if matches > 0:
      let target = (current + state.pendingStep) mod matches
      current = if target < 0: target + matches else: target
      changed = true
    state.pendingStep = 0

  let opening = not state.wasOpen
  state.wasOpen = true
  # Element.children evaluates this builder synchronously. Keep pointers only
  # for that call; event actions retain FindBarState, never caller variables.
  let openPtr = addr open
  let queryPtr = addr query
  let currentPtr = addr current
  discard bar.children(proc() =
    let magnifier = c.text("⌕").textColor(theme.textMuted).shrink(0)
    let magnifierNode = magnifier.node
    if magnifierNode != nil:
      magnifierNode[].accessHidden = true

    let input = c.textInput(queryPtr[]).grow(1).minWidth(theme.space(25))
      .maxWidth(theme.space(90)).placeholder(messages.find())
      .label(messages.find())
    let owner = c.owner
    if state.lastQuery != queryPtr[]:
      state.lastQuery = queryPtr[]
      if owner.invalidate != nil:
        owner.invalidate()
    let inputNode = input.node
    if inputNode != nil:
      inputNode[].accessExtraStates = inputNode[].accessExtraStates or
        platform.accessSearch
    discard input.bindHandle(state.focus)
    discard input.onSubmit(proc() = discard)
    if opening:
      state.focus.focus(c)
      discard input.setTextSelection(0, queryPtr[].runeLen)

    discard input.onShortcut(0, platform.keyEscape, proc() =
      state.pendingClose = true
      if owner.invalidate != nil:
        owner.invalidate()
    )
    discard input.onShortcut(platform.modShift, platform.keyEnter,
      proc() = owner.queueFindBarStep(state, -1, matches))
    when defined(macosx):
      discard input.onShortcut(platform.modSuper, platform.keyG, proc() =
        owner.queueFindBarStep(state, 1, matches)
      )
      discard input.onShortcut(platform.modSuper or platform.modShift,
        platform.keyG, proc() = owner.queueFindBarStep(state, -1, matches))
    else:
      discard input.onShortcut(0, platform.keyF3, proc() =
        owner.queueFindBarStep(state, 1, matches)
      )
      discard input.onShortcut(platform.modShift, platform.keyF3, proc() =
        owner.queueFindBarStep(state, -1, matches)
      )

    var status = ""
    if queryPtr[].len > 0:
      if matches > 0:
        status = messages.matches($(currentPtr[] + 1), $matches)
      else:
        status = messages.noMatches()
    let count = c.text(status).textColor(theme.textMuted)
      .minWidth(theme.space(18))
    let countSlot = int(count.slot)
    let countNode = count.node
    if countNode != nil:
      countNode[].accessRole = platform.roleStatus
      countNode[].accessRoleSet = true

    let previous = c.button("↑").label(messages.previous())
      .disabled(matches <= 0)
    if previous.clicked() and matches > 0:
      let target = (currentPtr[] - 1) mod matches
      currentPtr[] = if target < 0: target + matches else: target
      changed = true

    let next = c.button("↓").label(messages.next())
      .disabled(matches <= 0)
    if next.clicked() and matches > 0:
      currentPtr[] = (currentPtr[] + 1) mod matches
      changed = true

    if input.submitted() and matches > 0:
      currentPtr[] = (currentPtr[] + 1) mod matches
      changed = true

    if countSlot > 0 and countSlot < owner.nodes.len and queryPtr[].len > 0:
      owner.nodes[countSlot].textValue = if matches > 0:
        messages.matches($(currentPtr[] + 1), $matches)
      else:
        messages.noMatches()

    let done = c.button(messages.done())
    if done.clicked():
      openPtr[] = false
      state.wasOpen = false
      if owner.invalidate != nil:
        owner.invalidate()
  )

  if changed and barSlot > 0 and barSlot < c.owner.nodes.len:
    c.owner.nodes[barSlot].changed = true
