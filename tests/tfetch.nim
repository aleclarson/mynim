import std/[asyncdispatch, asynchttpserver, asyncnet, envvars, httpclient,
            httpcore, strutils, uri]
import mynim as core
import mynim/internal/ctx
import mynim/plugins/fetch as fetchPlugin
import mynim/plugins/fetch/env_proxy
import mynim/plugins/fetch/service

var
  ready: system.Channel[uint16]
  finished: system.Channel[bool]
  slowRelease: system.Channel[bool]
  cancelParts: system.Channel[Part]
  cancelDone: system.Channel[bool]
  serverPort: uint16

type CancelArgs = object
  ctx: CancelCtx
  port: uint16

type SavedEnvironmentVariable = object
  name: string
  existed: bool
  value: string

proc saveEnvironment(names: openArray[string]): seq[SavedEnvironmentVariable] =
  for name in names:
    result.add SavedEnvironmentVariable(name: name, existed: existsEnv(name),
      value: getEnv(name))

proc restoreEnvironment(values: openArray[SavedEnvironmentVariable]) =
  for value in values:
    if value.existed: putEnv(value.name, value.value)
    else: delEnv(value.name)

proc serveLoop() {.async.} =
  var server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  ready.send(server.getPort().uint16)
  var handled = 0
  proc respond(request: asynchttpserver.Request): Future[void] {.async, gcsafe.} =
    inc handled
    case request.url.path
    of "/redirect":
      await request.respond(Http302, "", newHttpHeaders([("Location", "/stream")]))
    of "/stream":
      await request.respond(Http200, repeat("abc123", 24000),
        newHttpHeaders([("Content-Type", "text/plain"),
          ("X-Check", "ok"), ("Set-Cookie", "hidden=yes")]))
    of "/echo":
      await request.respond(Http201,
        $request.reqMethod & ":" & request.body & ":" &
          request.headers.getOrDefault("X-Check"),
        newHttpHeaders([("Content-Type", "text/plain")]))
    of "/proxy":
      let target = if request.url.scheme.len == 0:
          "relative:" & request.url.path
        else:
          request.url.scheme & "://" & request.url.hostname & request.url.path
      await request.respond(Http200,
        target,
        newHttpHeaders([("Content-Type", "text/plain")]))
    of "/jar-redirect":
      await request.respond(Http302, "",
        newHttpHeaders([("Location", "/jar"),
          ("Set-Cookie", "redirect=yes; Path=/")]))
    of "/jar-external-redirect":
      await request.respond(Http302, "",
        newHttpHeaders([("Location", "http://other.invalid/jar-external-final"),
          ("Set-Cookie", "redirect=yes; Path=/")]))
    of "/jar-external-final":
      let cookieHeader: string = request.headers.getOrDefault("Cookie")
      let authorization: string = request.headers.getOrDefault("Authorization")
      await request.respond(Http200, cookieHeader & "|" & authorization,
        newHttpHeaders([("Set-Cookie", "final=yes; Path=/")]))
    of "/jar":
      var cookieHeader = ""
      for value in seq[string](request.headers.getOrDefault("Cookie")):
        if cookieHeader.len > 0: cookieHeader.add "; "
        cookieHeader.add value
      await request.respond(Http200, cookieHeader,
        newHttpHeaders([("Set-Cookie", "server=session; Path=/"),
          ("Set-Cookie", "theme=dark; HttpOnly")]))
    of "/slow":
      await request.client.send(
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n")
      discard slowRelease.recv()
      try:
        await request.client.send("0123456789")
      except CatchableError:
        discard
    else:
      await request.respond(Http404, "missing")
    if handled >= 13:
      server.close()
  try:
    while handled < 13:
      await server.acceptRequest(respond)
  except CatchableError:
    discard

proc runServer() {.thread.} =
  try:
    waitFor serveLoop()
  except CatchableError:
    discard
  finished.send(true)

proc fetchUntilCanceled(args: CancelArgs) {.thread.} =
  {.cast(gcsafe).}:
    let err = fetch(defaultOptions(),
      service.Request(url: "http://127.0.0.1:" & $args.port & "/slow",
        httpMethod: "GET", redirect: "follow"), args.ctx,
      proc(part: Part): ref CatchableError =
        cancelParts.send(part)
        nil
    )
    cancelDone.send(err != nil)

proc run(request: service.Request; options = defaultOptions()): tuple[
    parts: seq[Part], error: ref CatchableError] =
  var parts: seq[Part]
  result.error = fetch(options, request, newCtx(), proc(part: Part): ref CatchableError =
    parts.add(part)
    nil
  )
  result.parts = parts

ready.open()
finished.open()
slowRelease.open()
cancelParts.open()
cancelDone.open()
var serverThread: Thread[void]
createThread(serverThread, runServer)
serverPort = ready.recv()
let port = serverPort
let origin = "http://127.0.0.1:" & $port

block environment_proxy_selection_honors_scheme_and_no_proxy:
  let environment = EnvironmentProxy(
    httpProxy: "proxy.example:8080",
    httpsProxy: "https://secure-proxy.example:8443",
    noProxy: "example.com,.internal.example,192.168.0.0/16,10.0.0.1:80"
  )
  let httpProxy = proxyForUrl(parseUri("http://outside.example/"), environment)
  doAssert httpProxy != nil
  doAssert httpProxy.url.scheme == "http"
  doAssert httpProxy.url.hostname == "proxy.example"
  doAssert httpProxy.url.port == "8080"
  let httpsProxy = proxyForUrl(parseUri("https://outside.example/"), environment)
  doAssert httpsProxy != nil
  doAssert httpsProxy.url.hostname == "secure-proxy.example"
  doAssert proxyForUrl(parseUri("http://example.com/"), environment) == nil
  doAssert proxyForUrl(parseUri("http://api.example.com/"), environment) == nil
  doAssert proxyForUrl(parseUri("http://internal.example/"), environment) != nil
  doAssert proxyForUrl(parseUri("http://api.internal.example/"), environment) == nil
  doAssert proxyForUrl(parseUri("http://192.168.4.5/"), environment) == nil
  doAssert proxyForUrl(parseUri("http://10.0.0.1/"), environment) == nil
  doAssert proxyForUrl(parseUri("https://10.0.0.1/"), environment) != nil
  doAssert proxyForUrl(parseUri("http://127.0.0.1/"), environment) == nil
  doAssertRaises ValueError:
    discard proxyForUrl(parseUri("http://outside.example/"),
      EnvironmentProxy(httpProxy: "proxy.example", cgi: true))

block environment_proxy_is_used_and_loopback_is_bypassed:
  let saved = saveEnvironment(["http_proxy", "HTTP_PROXY", "https_proxy",
    "HTTPS_PROXY", "no_proxy", "NO_PROXY", "REQUEST_METHOD"])
  defer: restoreEnvironment(saved)
  putEnv("http_proxy", origin)
  putEnv("HTTP_PROXY", "")
  putEnv("https_proxy", "")
  putEnv("HTTPS_PROXY", "")
  putEnv("no_proxy", "")
  putEnv("NO_PROXY", "")
  putEnv("REQUEST_METHOD", "")

  let (proxyParts, proxyError) = run(service.Request(
    url: "http://example.invalid/proxy", httpMethod: "GET", redirect: "follow"))
  doAssert proxyError == nil
  doAssert proxyParts.len == 2
  doAssert proxyParts[1].chunk == "http://example.invalid/proxy"

  let (directParts, directError) = run(service.Request(
    url: origin & "/proxy", httpMethod: "GET", redirect: "follow"))
  doAssert directError == nil
  doAssert directParts.len == 2
  doAssert directParts[1].chunk == "relative:/proxy"

block follow_streams_body_and_exposes_response_metadata:
  let (parts, err) = run(service.Request(url: origin & "/redirect", httpMethod: "GET",
    redirect: "follow"))
  doAssert err == nil
  doAssert parts.len >= 3
  doAssert parts[0].status == 200
  doAssert parts[0].url == origin & "/stream"
  doAssert parts[0].redirected
  doAssert Header(name: "x-check", value: "ok") in parts[0].headers
  doAssert not (Header(name: "set-cookie", value: "hidden=yes") in parts[0].headers)
  var body = ""
  for part in parts[1 .. ^1]:
    doAssert part.chunk.len <= 64 shl 10
    body.add part.chunk
  doAssert body == repeat("abc123", 24000)

block manual_redirect_returns_the_redirect_response:
  let (parts, err) = run(service.Request(url: origin & "/redirect", httpMethod: "GET",
    redirect: "manual"))
  doAssert err == nil
  doAssert parts.len == 1
  doAssert parts[0].status == 302
  doAssert not parts[0].redirected
  doAssert Header(name: "location", value: "/stream") in parts[0].headers

block redirect_error_mode_rejects:
  let (parts, err) = run(service.Request(url: origin & "/redirect", httpMethod: "GET",
    redirect: "error"))
  doAssert parts.len == 0
  doAssert err != nil
  doAssert "redirect mode" in err.msg

block request_body_and_headers_are_sent:
  let (parts, err) = run(service.Request(url: origin & "/echo", httpMethod: "PATCH",
    headers: @[Header(name: "X-Check", value: "sent")],
    body: "payload", hasBody: true, redirect: "follow"))
  doAssert err == nil
  doAssert parts.len == 2
  doAssert parts[0].status == 201
  doAssert parts[1].chunk == "PATCH:payload:sent"

block configured_proxy_receives_absolute_http_target:
  let proxied = Options(proxy: newProxy(origin))
  let (parts, err) = run(service.Request(url: "http://example.invalid/proxy",
    httpMethod: "GET", redirect: "follow"), proxied)
  doAssert err == nil
  doAssert parts.len == 2
  doAssert parts[0].status == 200
  doAssert parts[1].chunk == "http://example.invalid/proxy",
    "proxy target was " & repr(parts[1].chunk)

block cookie_jar_sends_and_stores_response_cookies:
  var askedUrls: seq[Uri]
  var storedUrls: seq[Uri]
  var storedCookies: seq[seq[string]]
  var receivedRedirectCookie = false
  let jar = CookieJar(
    cookies: proc(url: Uri): seq[string] =
      askedUrls.add url
      if url.path == "/jar-redirect":
        @["jar=initial"]
      elif receivedRedirectCookie:
        @["jar=updated"]
      else:
        @[],
    store: proc(url: Uri; setCookieHeaders: seq[string]) =
      storedUrls.add url
      storedCookies.add setCookieHeaders
      if url.path == "/jar-redirect":
        receivedRedirectCookie = true
  )
  let withJar = Options(cookieJar: jar)
  let (parts, err) = run(service.Request(url: origin & "/jar-redirect", httpMethod: "GET",
    headers: @[Header(name: "Cookie", value: "explicit=yes")], redirect: "follow"),
    withJar)
  doAssert err == nil
  doAssert parts.len == 2
  doAssert parts[0].status == 200
  doAssert parts[0].redirected
  doAssert parts[1].chunk == "explicit=yes; jar=updated"
  doAssert askedUrls.len == 2
  doAssert askedUrls[0].path == "/jar-redirect"
  doAssert askedUrls[1].path == "/jar"
  doAssert storedUrls.len == 2
  doAssert storedUrls[0].path == "/jar-redirect"
  doAssert storedUrls[1].path == "/jar"
  doAssert storedCookies == @[
    @["redirect=yes; Path=/"],
    @["server=session; Path=/", "theme=dark; HttpOnly"]]

block cross_domain_redirect_recalculates_jar_and_drops_explicit_credentials:
  var askedHosts: seq[string]
  let jar = CookieJar(
    cookies: proc(url: Uri): seq[string] =
      askedHosts.add url.hostname
      if url.hostname == "example.invalid": @["jar=origin"]
      else: @["jar=destination"],
    store: proc(url: Uri; setCookieHeaders: seq[string]) = discard
  )
  let options = Options(proxy: newProxy(origin), cookieJar: jar)
  let (parts, err) = run(service.Request(
    url: "http://example.invalid/jar-external-redirect", httpMethod: "GET",
    headers: @[Header(name: "Cookie", value: "private=secret"),
      Header(name: "Authorization", value: "Bearer secret")],
    redirect: "follow"), options)
  doAssert err == nil
  doAssert parts.len == 2
  doAssert parts[0].redirected
  doAssert parts[1].chunk == "jar=destination|"
  doAssert askedHosts == @["example.invalid", "other.invalid"]

block allow_callback_can_refuse_without_sending:
  let denied = Options(allow: proc(request: service.Request): bool = false)
  let (parts, err) = run(service.Request(url: "http://127.0.0.1/never", httpMethod: "GET",
    redirect: "follow"), denied)
  doAssert parts.len == 0
  doAssert err != nil
  doAssert "does not allow requests" in err.msg

block cancel_closes_an_inflight_response:
  let ctx = newCtx()
  var fetchThread: Thread[CancelArgs]
  createThread(fetchThread, fetchUntilCanceled, CancelArgs(ctx: ctx, port: port))
  let head = cancelParts.recv()
  doAssert head.status == 200
  ctx.cancel()
  doAssert cancelDone.recv()
  joinThread(fetchThread)
  slowRelease.send(true)

doAssert finished.recv()
joinThread(serverThread)
core.use(fetchPlugin.Plugin)
doAssert fetchPlugin.Plugin.name == "fetch"
slowRelease.close()
cancelParts.close()
cancelDone.close()
finished.close()
ready.close()
