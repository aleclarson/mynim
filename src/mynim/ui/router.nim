## URL history state for the native UI Router.

type
  RouteEntry = ref object
    location, title: string

  Router* = ref object
    entries: seq[RouteEntry]
    at: int

  RouteParam = tuple[name, value: string]

  Route* = ref object
    router: Router
    entry: RouteEntry
    segments: seq[string]
    params, baseParams: seq[RouteParam]
    rest: int

const routerHistoryLimit = 100

func isHexDigitChar(c: char): bool =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc pathOf(location: string): string =
  try:
    let parsed = uri.parseUri(location)
    let path = uri.decodeUrl(parsed.path, decodePlus = false)
    if path.len == 0: "/" else: path
  except ValueError:
    "/"

proc pathParts(path: string): seq[string] =
  let clean = path.strip(chars = {'/'})
  if clean.len > 0:
    result = clean.split('/')

proc segmentsOf(location: string): seq[string] =
  var parsed: uri.Uri
  try:
    parsed = uri.parseUri(location)
  except ValueError:
    return
  for part in pathParts(parsed.path):
    result.add(uri.decodeUrl(part, decodePlus = false))

proc escapeUriPart(value: string; query: bool): string =
  var i = 0
  while i < value.len:
    let c = value[i]
    if c == '%' and i + 2 < value.len and
        isHexDigitChar(value[i + 1]) and isHexDigitChar(value[i + 2]):
      result.add(value[i..i + 2])
      i += 3
      continue
    let pathPunctuation = {'/', ':', '@', '!', '$', '&', '\'', '(', ')',
      '*', '+', ',', ';', '='}
    let queryPunctuation = pathPunctuation + {'?'}
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'} or
        (if query: c in queryPunctuation else: c in pathPunctuation):
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2))
    inc i

proc cleanPath(path: string): string =
  let absolute = if path.len == 0: "/" elif path[0] == '/': path
    else: "/" & path
  var parts: seq[string]
  for part in absolute.split('/'):
    if part.len == 0:
      continue
    let decoded = uri.decodeUrl(part, decodePlus = false)
    if decoded == ".":
      continue
    if decoded == "..":
      if parts.len > 0:
        parts.setLen(parts.len - 1)
      continue
    parts.add(part)
  result = "/" & parts.join("/")

proc validEscapes(value: string): bool =
  var i = 0
  while i < value.len:
    if value[i] == '%':
      if i + 2 >= value.len or not isHexDigitChar(value[i + 1]) or
          not isHexDigitChar(value[i + 2]):
        return false
      i += 3
    else:
      inc i
  true

proc current(router: Router): RouteEntry =
  if router == nil:
    return RouteEntry(location: "/")
  if router.entries.len == 0:
    router.entries = @[RouteEntry(location: "/")]
    router.at = 0
  router.entries[router.at]

proc resolve(router: Router; target: string):
    tuple[location, path: string, valid: bool] =
  if not target.validEscapes:
    return
  var reference: uri.Uri
  try:
    reference = uri.parseUri(target)
  except ValueError:
    return
  let base = router.current()
  var baseUri: uri.Uri
  try:
    baseUri = uri.parseUri(base.location)
  except ValueError:
    baseUri = uri.parseUri("/")

  var resolvedPath = reference.path
  var query = reference.query
  if reference.scheme.len > 0 or reference.hostname.len > 0:
    if resolvedPath.len == 0:
      resolvedPath = "/"
  elif resolvedPath.len == 0:
    resolvedPath = baseUri.path
    if query.len == 0:
      query = baseUri.query
  elif resolvedPath[0] != '/':
    var directory = baseUri.path
    let slash = directory.rfind('/')
    if slash < 0:
      directory = "/"
    else:
      directory.setLen(slash + 1)
    resolvedPath = directory & resolvedPath

  result.path = cleanPath(resolvedPath)
  result.location = escapeUriPart(result.path, query = false)
  if query.len > 0:
    result.location.add('?')
    result.location.add(escapeUriPart(query, query = true))
  result.valid = true

proc replace*(router: Router; target: string)

proc newRouter*(initialPath = "/"): Router =
  ## Creates a URL history showing initialPath.
  new(result)
  result.replace(initialPath)

proc route*(router: Router): Route =
  ## Returns a route for the current location, for matching path patterns.
  let entry = router.current()
  new(result)
  result.router = router
  result.entry = entry
  result.segments = segmentsOf(entry.location)
  result.rest = -1

func path*(route: Route): string =
  ## Returns the route path, without query; escaped slashes stay in their part
  ## for matching and are decoded in this display value.
  if route == nil: "/" else: "/" & route.segments.join("/")

proc match*(route: Route; pattern: string): bool =
  ## Matches exact path segments, `{name}` wildcards, or a final `{name...}`
  ## wildcard that takes the remaining path. Failed matches keep prior params.
  if route == nil:
    return false
  let parts = pathParts(pattern)
  var params: seq[RouteParam]
  for index, part in parts:
    if part.len >= 2 and part[0] == '{' and part[^1] == '}':
      let name = part[1..^2]
      if name.endsWith("..."):
        if index != parts.high:
          raise newException(ValueError,
            "ui: {" & name & "} does not end the pattern " & pattern)
        let wildcardName = if name.len <= 3: "" else: name[0..<name.len - 3]
        let firstRest = min(index, route.segments.len)
        params.add((wildcardName,
          route.segments[firstRest..<route.segments.len].join("/")))
        route.params = params
        route.rest = min(index, route.segments.len)
        return true
      if index >= route.segments.len:
        return false
      params.add((name, route.segments[index]))
    elif index >= route.segments.len or route.segments[index] != part:
      return false
  if parts.len != route.segments.len:
    return false
  route.params = params
  route.rest = -1
  true

func param*(route: Route; name: string): string =
  ## Returns a wildcard value from the last successful match.
  if route == nil:
    return ""
  for params in [route.params, route.baseParams]:
    if params.len > 0:
      for index in countdown(params.high, 0):
        if params[index].name == name:
          return params[index].value

proc query*(route: Route; name: string): string =
  ## Returns the first decoded value for a query parameter in this route.
  if route == nil or route.entry == nil:
    return ""
  var parsed: uri.Uri
  try:
    parsed = uri.parseUri(route.entry.location)
  except ValueError:
    return ""
  for key, value in uri.decodeQuery(parsed.query):
    if key == name:
      return value

proc title*(route: Route; title: string) =
  ## Sets this page's title for history controls and accessibility.
  if route != nil and route.entry != nil:
    route.entry.title = title

func title*(router: Router): string =
  ## Returns the title set by the current route view.
  if router == nil: "" else: router.current().title

proc push*(router: Router; target: string) =
  ## Navigates to target and adds a history entry; relative paths use the
  ## currently shown page as their base.
  if router == nil:
    return
  let current = router.current()
  let resolved = router.resolve(target)
  if not resolved.valid or resolved.location == current.location:
    return
  let entry = RouteEntry(location: resolved.location)
  if router.at + 1 < router.entries.len:
    router.entries.setLen(router.at + 1)
  router.entries.add(entry)
  if router.entries.len > routerHistoryLimit:
    let excess = router.entries.len - routerHistoryLimit
    router.entries = router.entries[excess..^1]
  router.at = router.entries.high

proc replace*(router: Router; target: string) =
  ## Replaces the current history entry with target.
  if router == nil:
    return
  let resolved = router.resolve(target)
  if not resolved.valid:
    return
  if router.entries.len == 0:
    router.entries = @[RouteEntry(location: resolved.location)]
    router.at = 0
  else:
    let previous = router.entries[router.at]
    if previous.location == resolved.location:
      return
    router.entries[router.at] = RouteEntry(location: resolved.location)

proc go*(router: Router; distance: int) =
  ## Moves distance entries through history, bounded by its first and last.
  if router == nil:
    return
  discard router.current()
  let last = router.entries.high
  let next = if distance < 0:
      (if distance <= -router.at: 0 else: router.at + distance)
    else:
      (if distance >= last - router.at: last else: router.at + distance)
  if next != router.at:
    router.at = next

proc back*(router: Router) =
  ## Shows the previous history entry when one exists.
  router.go(-1)

proc forward*(router: Router) =
  ## Shows the next history entry when one exists.
  router.go(1)

func canGoBack*(router: Router): bool =
  ## Reports whether an earlier history entry exists.
  router != nil and router.at > 0

func canGoForward*(router: Router): bool =
  ## Reports whether a later history entry exists.
  router != nil and router.at < router.entries.len - 1

func location*(router: Router): string =
  ## Returns the escaped path and query of the current history entry.
  if router == nil: "/" else: router.current().location

func path*(router: Router): string =
  ## Returns the decoded path of the current history entry, without query.
  router.location().pathOf()

proc query*(router: Router; name: string): string =
  ## Returns the first decoded value for a query parameter, or an empty string.
  var parsed: uri.Uri
  try:
    parsed = uri.parseUri(router.location())
  except ValueError:
    return ""
  for key, value in uri.decodeQuery(parsed.query):
    if key == name:
      return value
