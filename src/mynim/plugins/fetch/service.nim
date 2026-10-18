## HTTP requests made by the app for pages, with streamed response chunks.

import std/[asyncdispatch, asyncstreams, base64, httpclient, httpcore, json,
            options, strutils, uri]

import mynim as core
import mynim/plugins/fetch/env_proxy as fetchEnvProxy

type
  Header* = object
    name*, value*: string

  Request* = object
    ## The incoming fetch request. Body contains raw bytes in a Nim string.
    url*, httpMethod*: string
    headers*: seq[Header]
    body*: string
    hasBody*: bool
    redirect*: string

  Part* = object
    ## The response head first, followed by parts with raw body bytes.
    status*: int
    statusText*, url*: string
    redirected*: bool
    headers*: seq[Header]
    chunk*: string

  SendPart* = proc(part: Part): ref CatchableError {.closure.}
  AllowRequest* = proc(request: Request): bool {.closure.}

  CookieJar* = object
    ## Returns `name=value` pairs to send for a request URL.
    cookies*: proc(url: Uri): seq[string] {.closure.}
    ## Receives each raw Set-Cookie field from a response for this URL.
    store*: proc(url: Uri; setCookieHeaders: seq[string]) {.closure.}

  Options* = object
    ## Creates a new client per fetch call. The plugin closes it afterward.
    ## Leave nil to use Nim's default client. A custom factory must set
    ## maxRedirects=0. A custom factory configures its own proxy and does not
    ## use this option's environment-based proxy selection.
    clientFactory*: proc(): AsyncHttpClient {.closure.}
    ## Explicit proxy override. Nil uses HTTP_PROXY/HTTPS_PROXY and NO_PROXY.
    proxy*: Proxy
    ## Optional cookie policy. The jar decides matching, expiry, and storage.
    cookieJar*: CookieJar
    ## Refuses a request before it leaves the app when it returns false.
    allow*: AllowRequest
    ## Maximum redirects followed in "follow" mode.
    maxRedirects*: Option[int]

const
  chunkSize = 64 shl 10
  defaultRedirectLimit = 20
  cancelPollMs = 10

proc defaultOptions*(): Options =
  ## Returns the default Fetch policy.
  Options(maxRedirects: none(int))

proc readRequest(node: JsonNode): Request =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "fetch: request must be an object")
  result.url = node["url"].getStr()
  result.httpMethod = node["method"].getStr("GET")
  result.redirect = node["redirect"].getStr("follow")
  if node.hasKey("body") and node["body"].kind == JString:
    result.body = decode(node["body"].getStr())
    result.hasBody = true
  if node.hasKey("headers") and node["headers"].kind == JArray:
    for pair in node["headers"].getElems():
      if pair.kind != JArray or pair.len != 2 or
          pair[0].kind != JString or pair[1].kind != JString:
        raise newException(ValueError, "fetch: each header must be a name/value pair")
      result.headers.add Header(name: pair[0].getStr(), value: pair[1].getStr())

proc headerArray(headers: openArray[Header]): JsonNode =
  result = newJArray()
  for header in headers:
    var pair = newJArray()
    pair.add %header.name
    pair.add %header.value
    result.add pair

proc json(part: Part): JsonNode =
  result = newJObject()
  if part.status != 0: result["status"] = %part.status
  if part.statusText.len > 0: result["statusText"] = %part.statusText
  if part.url.len > 0: result["url"] = %part.url
  if part.redirected: result["redirected"] = %true
  if part.headers.len > 0: result["headers"] = headerArray(part.headers)
  if part.chunk.len > 0: result["chunk"] = %encode(part.chunk)

proc toHttpHeaders(headers: openArray[Header]): HttpHeaders =
  result = newHttpHeaders()
  for header in headers:
    case header.name.toLowerAscii()
    of "content-length": discard # The HTTP client calculates it from the body.
    else: result.add(header.name, header.value)

proc copyHeaders(headers: HttpHeaders): HttpHeaders =
  result = newHttpHeaders()
  if headers != nil:
    for name, value in headers.pairs:
      result.add(name, value)

proc addJarCookies(headers: HttpHeaders; jar: CookieJar; url: Uri) =
  if jar.cookies == nil:
    return
  var value = ""
  for existing in seq[string](headers.getOrDefault("cookie")):
    if value.len > 0: value.add "; "
    value.add existing
  for cookie in jar.cookies(url):
    if '\r' in cookie or '\n' in cookie:
      raise newException(ValueError, "fetch: cookie jar returned an invalid cookie")
    if value.len > 0: value.add "; "
    value.add cookie
  if value.len > 0:
    headers["cookie"] = value

proc responseHeaders(response: AsyncResponse): seq[Header] =
  for name, value in response.headers.pairs:
    if name.toLowerAscii() != "set-cookie":
      result.add Header(name: name.toLowerAscii(), value: value)

proc statusText(response: AsyncResponse): string =
  let code = $int(response.code)
  if response.status.len > code.len:
    result = response.status[code.len .. ^1].strip()

proc isRedirect(status: int): bool = status in [301, 302, 303, 307, 308]

proc isSameOrSubdomain(host, parent: string): bool =
  let normalizedHost = host.toLowerAscii()
  let normalizedParent = parent.toLowerAscii()
  if normalizedHost == normalizedParent:
    return true
  if normalizedHost.len <= normalizedParent.len or
      ':' in normalizedHost or '%' in normalizedHost:
    return false
  normalizedHost.endsWith(normalizedParent) and
    normalizedHost[normalizedHost.len - normalizedParent.len - 1] == '.'

proc sameProxy(left, right: Proxy): bool =
  if left == nil or right == nil:
    return left == nil and right == nil
  left.url.scheme.toLowerAscii() == right.url.scheme.toLowerAscii() and
    left.url.hostname.toLowerAscii() == right.url.hostname.toLowerAscii() and
    left.url.port == right.url.port and left.url.username == right.url.username and
    left.url.password == right.url.password

proc httpMethod(value: string): HttpMethod =
  ## Maps the request methods supported by Nim's HTTP client.
  case value.toUpperAscii()
  of "GET": HttpGet
  of "HEAD": HttpHead
  of "POST": HttpPost
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  of "TRACE": HttpTrace
  of "OPTIONS": HttpOptions
  of "CONNECT": HttpConnect
  of "PATCH": HttpPatch
  else:
    raise newException(ValueError,
      "fetch: unsupported HTTP method " & value.escape())

proc redirectUrl(base: Uri; location: string): Uri =
  let reference = parseUri(location)
  if reference.scheme.len == 0:
    result = combine(base, reference)
  else:
    result = reference
  if result.scheme notin ["http", "https"]:
    raise newException(ValueError,
      "fetch: unsupported redirect URL scheme " & result.scheme.escape())

proc waitCancelable[T](future: Future[T]; client: AsyncHttpClient;
                       ctx: core.CancelCtx): Future[T] {.async.} =
  ## AsyncHttpClient has no cancellation API. Poll on its owning thread so
  ## closing the socket also unregisters it from the right event dispatcher.
  while not future.finished:
    if ctx.done():
      client.close()
      raise (if ctx.err() != nil: ctx.err() else:
        newException(ValueError, "fetch: request canceled"))
    await sleepAsync(cancelPollMs)
  if ctx.done():
    client.close()
    raise (if ctx.err() != nil: ctx.err() else:
      newException(ValueError, "fetch: request canceled"))
  return future.read()

proc readAndDiscard(response: AsyncResponse; client: AsyncHttpClient;
                    ctx: core.CancelCtx) {.async.} =
  while true:
    let (hasValue, _) = await waitCancelable(response.bodyStream.read(), client, ctx)
    if not hasValue:
      return

proc sendBody(response: AsyncResponse; send: SendPart;
              client: AsyncHttpClient; ctx: core.CancelCtx) {.async.} =
  var chunk = newStringOfCap(chunkSize)
  while true:
    let (hasValue, data) =
      await waitCancelable(response.bodyStream.read(), client, ctx)
    if not hasValue:
      break
    var offset = 0
    while offset < data.len:
      let count = min(chunkSize - chunk.len, data.len - offset)
      chunk.add data[offset ..< offset + count]
      offset += count
      if chunk.len == chunkSize:
        let err = send(Part(chunk: chunk))
        if err != nil: raise err
        chunk.setLen(0)
  if chunk.len > 0 and not ctx.done():
    let err = send(Part(chunk: chunk))
    if err != nil: raise err

proc fetchAsync(options: Options; request: Request; ctx: core.CancelCtx;
                 send: SendPart) {.async.} =
  var current = parseUri(request.url)
  let initialHost = current.hostname
  if current.scheme notin ["http", "https"]:
    raise newException(ValueError,
      "fetch: unsupported URL scheme " & current.scheme.escape())
  if request.httpMethod.len == 0:
    raise newException(ValueError, "fetch: method cannot be empty")
  if request.redirect notin ["follow", "manual", "error"]:
    raise newException(ValueError,
      "fetch: invalid redirect mode " & request.redirect.escape())
  if request.hasBody and request.httpMethod.toUpperAscii() in ["GET", "HEAD"]:
    raise newException(ValueError,
      "fetch: a " & request.httpMethod.toUpperAscii() & " request cannot have a body")
  if options.allow != nil and not options.allow(request):
    var safeUrl = current
    safeUrl.password = ""
    raise newException(ValueError,
      "the app does not allow requests to " & $safeUrl)

  if ctx.done():
    raise (if ctx.err() != nil: ctx.err() else:
      newException(ValueError, "fetch: request canceled"))

  let usesDefaultClient = options.clientFactory == nil
  let environment = if usesDefaultClient and options.proxy == nil:
      fetchEnvProxy.fromEnvironment()
    else:
      default(fetchEnvProxy.EnvironmentProxy)
  proc proxyFor(url: Uri): Proxy =
    if options.proxy != nil:
      options.proxy
    elif usesDefaultClient:
      fetchEnvProxy.proxyForUrl(url, environment)
    else:
      nil
  var activeProxy = if usesDefaultClient: proxyFor(current) else: nil
  var client = if usesDefaultClient:
      newAsyncHttpClient(maxRedirects = 0, proxy = activeProxy)
    else:
      options.clientFactory()
  if client == nil:
    raise newException(ValueError, "fetch: client factory returned nil")
  defer: client.close()

  var headers = toHttpHeaders(request.headers)
  var httpVerb = request.httpMethod
  var body = if request.hasBody: request.body else: ""
  var redirected = false
  var redirects = 0
  let redirectLimit =
    if options.maxRedirects.isSome: max(options.maxRedirects.get(), 0)
    else: defaultRedirectLimit
  var response: AsyncResponse
  while true:
    if ctx.done():
      raise (if ctx.err() != nil: ctx.err() else:
        newException(ValueError, "fetch: request canceled"))
    var requestHeaders = copyHeaders(headers)
    addJarCookies(requestHeaders, options.cookieJar, current)
    response = await waitCancelable(
      client.request(current, httpMethod(httpVerb), body, requestHeaders), client, ctx)
    let status = int(response.code)
    if options.cookieJar.store != nil:
      var setCookieHeaders: seq[string]
      for value in seq[string](response.headers.getOrDefault("set-cookie")):
        setCookieHeaders.add value
      if setCookieHeaders.len > 0:
        options.cookieJar.store(current, setCookieHeaders)
    if not isRedirect(status):
      break
    if request.redirect == "manual":
      break
    if request.redirect == "error":
      await readAndDiscard(response, client, ctx)
      raise newException(ValueError,
        "redirected with redirect mode \"error\"")
    let location = response.headers.getOrDefault("location")
    if location.len == 0:
      break
    if redirects >= redirectLimit:
      await readAndDiscard(response, client, ctx)
      raise newException(ValueError, "fetch: too many redirects")
    let next = redirectUrl(current, location)
    let nextProxy = if usesDefaultClient: proxyFor(next) else: activeProxy
    let switchProxy = usesDefaultClient and not sameProxy(activeProxy, nextProxy)
    let hostChanged =
      next.hostname.toLowerAscii() != current.hostname.toLowerAscii()
    if not isSameOrSubdomain(next.hostname, initialHost):
      for sensitive in ["authorization", "www-authenticate", "cookie", "cookie2"]:
        headers.del(sensitive)
    if hostChanged or next.port != current.port:
      headers.del("host")
    if status in [301, 302, 303] and httpVerb.toUpperAscii() notin ["GET", "HEAD"]:
      httpVerb = "GET"
      body = ""
      headers.del("content-type")
      headers.del("transfer-encoding")
    await readAndDiscard(response, client, ctx)
    if switchProxy:
      client.close()
      client = newAsyncHttpClient(maxRedirects = 0, proxy = nextProxy)
      activeProxy = nextProxy
    current = next
    redirected = true
    inc redirects

  var headerValues = responseHeaders(response)
  let head = Part(status: int(response.code), statusText: response.statusText(),
    url: $current, redirected: redirected, headers: headerValues)
  let headError = send(head)
  if headError != nil: raise headError
  await sendBody(response, send, client, ctx)

proc fetch*(options: Options; request: Request; ctx: core.CancelCtx;
            send: SendPart): ref CatchableError =
  ## Makes an HTTP request and sends its head and body chunks in order.
  ## The context is canceled when the page closes its response channel.
  try:
    waitFor fetchAsync(options, request, ctx, send)
  except CatchableError as error:
    result = error

proc fetchMethod(options: Options): core.BoundMethod =
  result = proc(c: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len == 0:
        raise newException(ValueError, "fetch: missing request")
      let request = readRequest(args[0])
      let channel = core.channelArg[JsonNode](c, 0)
      let sendPart: SendPart = proc(part: Part): ref CatchableError =
        channel.send(part.json())
      let err = fetch(options, request, c.ctx, sendPart)
      if err != nil: return (newJNull(), err)
      (newJNull(), nil)
    except CatchableError as error:
      (newJNull(), error)

proc newFetchPlugin*(options: Options): core.Plugin =
  ## Creates an optional plugin named "fetch" for app.use.
  result.name = "fetch"
  result.service = @[("Fetch", fetchMethod(options))]
  result.setup = proc(): ref CatchableError =
    core.bindChannels("plugin:fetch", "Fetch", [1])
    nil

proc newFetchPlugin*(): core.Plugin =
  ## Creates the default Fetch plugin.
  newFetchPlugin(defaultOptions())
