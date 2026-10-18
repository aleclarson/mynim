import std/[asyncdispatch, asynchttpserver, asyncnet, httpcore, strutils]
import mynim as core
import mynim/internal/ctx
import mynim/plugins/fetch as fetchPlugin
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
    if handled >= 6:
      server.close()
  try:
    while handled < 6:
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
