## Page building and navigation controls for the native UI Router.

proc identityWithin(owner: ElementOwner; identity, ancestor: uint64): bool =
  if owner == nil or identity == 0 or ancestor == 0:
    return false
  var current = identity
  var remaining = owner.identityParents.len + 1
  while current != 0 and remaining > 0:
    if current == ancestor:
      return true
    current = owner.identityParents.getOrDefault(current)
    dec remaining

proc identityWithinCurrentTree(owner: ElementOwner; identity,
                               ancestor: uint64): bool =
  if owner == nil or identity == 0 or ancestor == 0:
    return false
  var slot = -1
  for index, node in owner.nodes:
    if node.identity == identity:
      slot = index
      break
  while slot > 0 and slot < owner.nodes.len:
    if owner.nodes[slot].identity == ancestor:
      return true
    slot = int(owner.nodes[slot].parent)
  false

proc queuePageFocus(owner: ElementOwner; identity: uint64) =
  if owner != nil and identity != 0:
    owner.focusRequests.add(HandleFocusRequest(identity: identity))

proc stateForView(router: Router; scope: uint64): RouteViewState =
  if router == nil:
    return nil
  if not router.views.hasKey(scope):
    router.views[scope] = RouteViewState()
  router.views[scope]

proc samePrefix(a, b: seq[string]): bool =
  if a.len > b.len:
    return false
  for index, part in a:
    if part != b[index]:
      return false
  true

proc transitionDirection(oldEntry, currentEntry: RouteEntry;
                         offset: int): int =
  let oldParts = segmentsOf(oldEntry.location)
  let currentParts = segmentsOf(currentEntry.location)
  let oldRest = if offset < oldParts.len: oldParts[offset..^1] else: @[]
  let currentRest = if offset < currentParts.len:
      currentParts[offset..^1]
    else:
      @[]
  if currentRest.len > oldRest.len and oldRest.samePrefix(currentRest):
    return 1
  if oldRest.len > currentRest.len and currentRest.samePrefix(oldRest):
    return -1
  0

proc prepareView(c: Context; router: Router; state: RouteViewState;
                 entry: RouteEntry; level, offset: int) =
  let currentPage = router.pageIdentity(entry, level)
  if state.shown == nil:
    state.shown = entry
    return
  let oldPage = router.pageIdentity(state.shown, level)
  if oldPage == currentPage:
    state.shown = entry
    return

  let previous = state.shown
  let owner = c.owner
  if owner.identityWithin(owner.focusIdentity, state.shownPageIdentity):
    previous.focusIdentity = owner.focusIdentity
  state.focusing = router.pendingPageFocus or owner.focusIdentity == 0 or
    owner.identityWithin(owner.focusIdentity, state.containerIdentity)
  state.announcing = not state.focusing
  state.leaving = nil
  state.direction = 0
  state.resetProgress = false
  case router.transitionMode
  of Transition.None:
    discard
  of Transition.Fade:
    state.leaving = previous
  of Transition.Auto:
    state.leaving = previous
    if not owner.reduceMotion:
      state.direction = transitionDirection(previous, entry, offset)
  state.resetProgress = state.leaving != nil
  state.shown = entry

proc transitionProgress(box: Element; router: Router;
                        state: RouteViewState): float32 =
  result = 1
  if state == nil or state.leaving == nil:
    return
  const progressKey = "router-transition-progress"
  if state.resetProgress:
    discard box.jump(progressKey, 0)
    state.resetProgress = false
  let animation = if router.hasTransitionAnimation:
      router.transitionAnimation
    else:
      Animation(duration: initDuration(milliseconds =
        if state.direction == 0: 150 else: 250))
  result = min(max(box.animate(progressKey, 1, animation), 0'f32), 1'f32)
  if box.settled(progressKey):
    state.leaving = nil

proc backdrop(c: Context; box: Element): Color =
  var slot = int(box.slot)
  while slot >= 0 and slot < c.owner.nodes.len:
    let node = c.owner.nodes[slot]
    if node.background.a > 0:
      return node.background
    slot = int(node.parent)
  c.theme.background

proc routePage(c: Context; router: Router; entry: RouteEntry; level,
              offset: int; baseParams: seq[RouteParam];
              build: proc(route: Route) {.closure.}; inert,
              takeFocus: bool): Element =
  let pageId = router.pageIdentity(entry, level)
  result = c.key("router-page:" & $pageId).column().grow(1)
    .minWidth(0).minHeight(0).focusable()
  let page = result
  let pageNode = page.node
  if pageNode != nil:
    pageNode[].routeRouterIdentity = router.identity
    pageNode[].routePageIdentity = pageId
    let parent = int(pageNode[].parent)
    if parent > 0 and parent < c.owner.nodes.len:
      pageNode[].routeViewIdentity = c.owner.nodes[parent].identity
  let requestPageFocus = takeFocus or (level == 0 and not inert and
    entry == router.current() and router.pendingPageFocus)
  if pageNode != nil:
    if inert:
      pageNode[].inert = true
    if requestPageFocus:
      c.owner.queuePageFocus(pageNode[].identity)
  discard page.children(proc() =
    let previousRouter = c.routeRouter
    c.routeRouter = router
    try:
      let segments = segmentsOf(entry.location)
      let startAt = min(offset, segments.len)
      let route = Route(router: router, entry: entry,
        segments: segments[startAt..<segments.len], rest: -1,
        level: level, offset: offset, baseParams: baseParams)
      if build != nil:
        build(route)
    finally:
      c.routeRouter = previousRouter
  )
  if requestPageFocus and pageNode != nil and entry.focusIdentity != 0:
    for slot, node in c.owner.nodes:
      if node.identity == entry.focusIdentity and
          (node.focusable or node.clickHandler != nil) and
          c.owner.identityWithinCurrentTree(entry.focusIdentity,
            pageNode[].identity) and
          not c.owner.effectivelyDisabled(slot):
        c.owner.queuePageFocus(entry.focusIdentity)
        break
  if pageNode != nil and level == 0:
    entry.viewIdentity = pageNode[].identity
  discard page.label(entry.title)

proc dimPage(c: Context; page: Element; amount: float32) =
  let overlay = c.box().absolute().fill().top(0).left(0)
    .background(rgba(0, 0, 0, 0.06'f32 * amount))
  let node = overlay.node
  if node != nil:
    node[].passThrough = true
    node[].accessHidden = true
  discard page.children(proc() = discard overlay)

proc keepRouterPages(c: Context; router: Router; state: RouteViewState;
                     box: Element; entry: RouteEntry; level: int) =
  if c == nil or c.owner == nil or router == nil or entry == nil:
    return
  let boxNode = box.node
  if boxNode == nil:
    return
  let viewIdentity = boxNode[].identity
  let shownPage = router.pageIdentity(entry, level)
  var kept = 0
  var distance = 1
  while kept < routerKeptPageLimit and
      (router.at - distance >= 0 or
       router.at + distance < router.entries.len):
    for index in [router.at - distance, router.at + distance]:
      if index < 0 or index >= router.entries.len or
          kept == routerKeptPageLimit:
        continue
      let candidate = router.entries[index]
      if candidate.pages.len <= level:
        continue
      if level > 0 and (entry.pages.len < level or
          candidate.pages[level - 1] != entry.pages[level - 1]):
        continue
      let page = candidate.pages[level]
      if page == shownPage:
        continue
      if state != nil and state.leaving != nil and state.direction != 0 and
          state.leaving.pages.len > level and
          page == state.leaving.pages[level]:
        continue
      let key = (router.identity, viewIdentity, page)
      if key in c.owner.retainedRouterPages:
        continue
      c.owner.retainRouterPageState(router.identity, viewIdentity, page)
      inc kept
    inc distance

proc buildRouteView(c: Context; router: Router; state: RouteViewState;
                    box: Element; entry: RouteEntry; level, offset: int;
                    baseParams: seq[RouteParam];
                    build: proc(route: Route) {.closure.}): Element =
  c.prepareView(router, state, entry, level, offset)
  let progress = box.transitionProgress(router, state)
  var shownPage: Element
  discard box.children(proc() =
    if state.leaving == nil:
      shownPage = c.routePage(router, entry, level, offset, baseParams, build,
        inert = false, takeFocus = state.focusing)
    elif state.direction == 0:
      shownPage = c.routePage(router, entry, level, offset, baseParams, build,
        inert = false, takeFocus = state.focusing).opacity(progress)
    else:
      discard box.clip()
      let pageBackdrop = c.backdrop(box)
      let oldPage = c.routePage(router, state.leaving, level, offset,
        baseParams, build, inert = true, takeFocus = false)
      let newPage = c.routePage(router, entry, level, offset, baseParams,
        build, inert = false, takeFocus = state.focusing)
      shownPage = newPage
      let shown = if state.direction > 0: progress else: 1 - progress
      let upper = if state.direction > 0: newPage else: oldPage
      let lower = if state.direction > 0: oldPage else: newPage
      discard upper.absolute().top(0).fill().background(pageBackdrop)
        .startPercent(100 * (1 - shown))
        .shadow(0, 0, 16, 0, rgba(0, 0, 0, 0.15'f32))
      discard lower.background(pageBackdrop).startPercent(-30 * shown)
      c.dimPage(lower, shown)
  )
  let shownNode = shownPage.node
  state.shownPageIdentity = if shownNode != nil: shownNode[].identity else: 0
  let node = box.node
  if node != nil:
    state.containerIdentity = node[].identity
  if state.announcing:
    state.announcing = false
    c.announce(entry.title)
  state.focusing = false
  c.keepRouterPages(router, state, box, entry, level)
  result = box

proc view*(router: Router; c: Context;
           build: proc(route: Route) {.closure.}): Element =
  ## Builds the current page, retaining entry state and animating page changes.
  ## Navigation from within the page restores its focus when possible; when
  ## focus is outside the Router, it stays there and the new title is announced.
  if router == nil:
    raise newException(ValueError, "ui: cannot view a nil Router")
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: Router.View outside a frame build")

  let owner = c.owner
  var attached = false
  for existing in owner.routers:
    if existing != nil and existing.identity == router.identity:
      attached = true
      break
  if not attached:
    owner.routers.add(router)
  let shownEntry = router.current()
  router.onChanged = proc() =
    let currentEntry = router.current()
    if currentEntry != shownEntry:
      if pathOf(currentEntry.location) != pathOf(shownEntry.location):
        let withinPage = owner.identityWithin(owner.focusIdentity,
          shownEntry.viewIdentity)
        if withinPage:
          shownEntry.focusIdentity = owner.focusIdentity
        router.pendingPageFocus = withinPage
      else:
        router.pendingPageFocus = false
    if owner != nil and not owner.closed and owner.invalidate != nil:
      owner.invalidate()

  let entry = shownEntry
  let state = router.stateForView(0)
  result = c.key("router:" & $router.identity).column().grow(1)
    .minWidth(0).minHeight(0)
  let root = result
  let rootNode = root.node
  if rootNode != nil:
    rootNode[].keyHandler = proc(key: platform.Key;
        mods: platform.Modifiers; focusSlot: var int): bool =
      discard focusSlot
      if mods == 0 and key == platform.keyBack:
        router.back()
        return true
      if mods == 0 and key == platform.keyForward:
        router.forward()
        return true
      when defined(macosx):
        if mods == platform.modSuper and key == platform.keyBracketLeft:
          router.back()
          return true
        if mods == platform.modSuper and key == platform.keyBracketRight:
          router.forward()
          return true
      else:
        if mods == platform.modAlt and key == platform.keyLeft:
          router.back()
          return true
        if mods == platform.modAlt and key == platform.keyRight:
          router.forward()
          return true
      false
  discard c.buildRouteView(router, state, root, entry, 0, 0, @[], build)
  router.pendingPageFocus = false

proc view*(route: Route; c: Context;
           build: proc(route: Route) {.closure.}): Element =
  ## Builds the remainder of a final `{name...}` match as a nested layout.
  if route == nil or route.router == nil or route.entry == nil:
    raise newException(ValueError, "ui: Route.View without a route")
  if route.rest < 0:
    raise newException(ValueError,
      "ui: Route.View with no {name...} in the pattern matched")
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    raise newException(ValueError, "ui: Route.View outside a frame build")

  let pathEnd = route.offset + route.rest
  while route.entry.layouts.len <= route.level:
    route.entry.layouts.add(-1)
  route.entry.layouts[route.level] = pathEnd
  let baseParams = route.baseParams & route.params
  let scope = route.router.pageIdentity(route.entry, route.level)
  let state = route.router.stateForView(scope)
  let box = c.key("router-view:" & $route.router.identity & ":" & $scope)
    .column().grow(1).minWidth(0).minHeight(0)
  result = c.buildRouteView(route.router, state, box, route.entry,
    route.level + 1, pathEnd, baseParams, build)

proc router*(c: Context): Router =
  ## Returns the Router whose page is currently being built, or nil outside it.
  if c == nil: nil else: c.routeRouter

proc historyButton(c: Context; router: Router; backward: bool): Element =
  let label = if backward: "Back" else: "Forward"
  let enabled = if router == nil: false
    elif backward: router.canGoBack() else: router.canGoForward()
  result = c.button(label).label(label).disabled(not enabled)
    .onClick(proc() =
      if router != nil:
        if backward: router.back() else: router.forward()
    )
  discard result.contextMenu(proc(menu: Menu) =
    if router == nil:
      return
    for distance in 1..15:
      let index = if backward: router.at - distance
        else: router.at + distance
      if index < 0 or index >= router.entries.len:
        break
      let entry = router.entries[index]
      let title = if entry.title.len > 0: entry.title else: entry.location
      if menu.item(title).chosen:
        router.go(if backward: -distance else: distance)
  )

proc backButton*(c: Context; router: Router): Element =
  ## Creates a button that returns to the previous Router history entry.
  c.historyButton(router, backward = true)

proc backButton*(c: Context): Element =
  ## Creates a Back button for the Router whose page is being built.
  c.historyButton(c.routeRouter, backward = true)

proc forwardButton*(c: Context; router: Router): Element =
  ## Creates a button that advances to the next Router history entry.
  c.historyButton(router, backward = false)

proc forwardButton*(c: Context): Element =
  ## Creates a Forward button for the Router whose page is being built.
  c.historyButton(c.routeRouter, backward = false)
