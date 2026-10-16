## Page building and navigation controls for the native UI Router.

proc routePage(c: Context; router: Router; entry: RouteEntry; level,
              offset: int; baseParams: seq[RouteParam];
              build: proc(route: Route) {.closure.}): Element =
  let pageId = router.pageIdentity(entry, level)
  result = c.key("router-page:" & $pageId).column().grow(1)
    .minWidth(0).minHeight(0)
  let page = result
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
  discard page.label(entry.title)

proc view*(router: Router; c: Context;
           build: proc(route: Route) {.closure.}): Element =
  ## Builds the current page and retains each history entry's element state.
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
  router.onChanged = proc() =
    if owner != nil and not owner.closed and owner.invalidate != nil:
      owner.invalidate()

  result = c.key("router:" & $router.identity).column().grow(1)
    .minWidth(0).minHeight(0)
  let root = result
  let rootNode = root.node
  if rootNode != nil:
    rootNode[].keyHandler = proc(key: platform.Key; mods: platform.Modifiers;
        focusSlot: var int): bool =
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

  discard root.children(proc() =
    discard routePage(c, router, router.current(), 0, 0, @[], build)
  )

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
  result = routePage(c, route.router, route.entry,
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
