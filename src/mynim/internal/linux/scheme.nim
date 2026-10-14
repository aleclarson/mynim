## scheme.nim: custom URL schemes of WebKitGTK. A request becomes a
## SchemeRequest for the window's handler; the task streams the response
## through a pipe.

var
  cbScheme*: pointer
  cbHeaderForeach*: pointer
  headerSinks*: Table[pointer, HeaderMap]

proc serveScheme*(b: Backend, req: pointer)
proc releaseTask*(t: gtkSchemeTask)

proc initSchemeCallbacks*() =
  cbScheme = cast[pointer](
    proc(req, data: pointer) {.cdecl.} = theBackend.serveScheme(req))
  cbHeaderForeach = cast[pointer](
    proc(name, value, data: pointer) {.cdecl.} =
      if headerSinks.hasKey(data):
        var h = headerSinks[data]
        h.mgetOrPut(goStr(name), @[]).add goStr(value)
        headerSinks[data] = h)

proc registerScheme*(b: Backend, scheme: string) =
  if b.schemes.getOrDefault(scheme): return
  b.schemes[scheme] = true
  let ctx = webkitWebContextGetDefault()
  webkitWebContextRegisterURIScheme(ctx, cs(scheme), cbScheme, nil, nil)
  let sec = webkitWebContextGetSecurityManager(ctx)
  webkitSecurityManagerRegisterSecure(sec, cs(scheme))
  webkitSecurityManagerRegisterCORS(sec, cs(scheme))

proc readStream(stream: pointer): seq[byte] =
  var buf = newSeq[byte](64 shl 10)
  while true:
    var n: uint
    var gerr: pointer
    let ok = gInputStreamReadAll(stream, addr buf[0], uint(buf.len),
      addr n, nil, addr gerr)
    result.add buf[0 ..< int(n)]
    if not gerr.isNil:
      gErrorFree(gerr)
    if not ok or n < uint(buf.len):
      return

## schemeTask streams a response to WebKit through a pipe, which WebKit
## reads on the main loop. The goroutine serving the request writes the
## body into it (writeBody), waiting while it is full, so the main loop
## never blocks and a response WebKit reads slowly does not pile up in
## memory. The other methods run on the main thread.

var errNoResponse = newException(CatchableError,
  "mynim: the response was not started")

method respond*(t: gtkSchemeTask, status: int, h: HeaderMap) =
  if t.done or t.responded:
    return
  var fds: array[2, cint]
  if pipe2(addr fds[0], cint(O_CLOEXEC)) != 0:
    t.fail(osErrorToCatchable())
    return
  t.responded = true
  let stream = gUnixInputStreamNew(int32(fds[0]), true)
  var length = int64(-1)
  try:
    length = parseBiggestInt(h.getOrDefault("Content-Length", @[""])[0])
  except ValueError:
    discard
  if not webkitURISchemeRequestFinishWithResponse.isNil:
    let resp = webkitURISchemeResponseNew(stream, length)
    webkitURISchemeResponseSetStatus(resp, uint32(status), nil)
    if h.hasKey("Content-Type") and h["Content-Type"][0] != "":
      webkitURISchemeResponseSetContentType(resp, cs(h["Content-Type"][0]))
    let hdrs = soupMessageHeadersNew(1) # SOUP_MESSAGE_HEADERS_RESPONSE
    for k, vs in h:
      for v in vs:
        soupMessageHeadersAppend(hdrs, cs(k), cs(v))
    webkitURISchemeResponseSetHTTPHeaders(resp, hdrs)
    webkitURISchemeRequestFinishWithResponse(t.req, resp)
    gObjectUnref(resp)
  else:
    # WebKitGTK before 2.36 cannot send status codes or headers.
    var ct: cstring
    if h.hasKey("Content-Type") and h["Content-Type"].len > 0:
      ct = optCS(h["Content-Type"][0])
    webkitURISchemeRequestFinish(t.req, stream, length, ct)
  gObjectUnref(stream)
  t.releaseTask()
  t.fd = int(fds[1])

## writeBody writes to the pipe, blocking while it is full.
method writeBody*(t: gtkSchemeTask, p: seq[byte]) =
  if t.fd < 0:
    raise errNoResponse
  var p = p
  while p.len > 0:
    let n = posix.write(cint(t.fd), unsafeAddr p[0], p.len)
    if n < 0 and osLastError().cint == EINTR:
      continue
    if n < 0:
      # The page no longer wants the response.
      t.cancel()
      raiseOSError(osLastError())
    p = p[int(n) .. ^1]

method supportsWriteBody*(t: gtkSchemeTask): bool = true

method write*(t: gtkSchemeTask, p: openArray[byte]) = discard

method finish*(t: gtkSchemeTask) =
  if t.done:
    return
  if not t.responded:
    t.respond(200, HeaderMap())
  t.done = true
  if t.fd >= 0:
    discard posix.close(cint(t.fd)) # the end of the body
    t.fd = -1

method fail*(t: gtkSchemeTask, err: ref CatchableError) =
  if t.done:
    return
  if not t.responded:
    t.responded = true
    let gerr = gErrorNewLiteral(gQuarkFromString(cs("mynim")), 1,
      cs(err.msg))
    webkitURISchemeRequestFinishError(t.req, gerr)
    gErrorFree(gerr)
    t.releaseTask()
  t.finish()

proc releaseTask*(t: gtkSchemeTask) =
  if not t.req.isNil:
    gObjectUnref(t.req)
    t.req = nil

proc serveScheme*(b: Backend, req: pointer) =
  discard gObjectRef(req)
  let (ctx, cancel) = newCtx().withCancel()
  let t = gtkSchemeTask(req: req, cancel: cancel, fd: -1)
  let w = b.byWebView.getOrDefault(webkitURISchemeRequestGetWebView(req))
  if w.isNil or w.closed:
    t.fail(newCanceled())
    return
  var r = SchemeRequest(
    context: ctx,
    httpMethod: "GET",
    url: goStr(webkitURISchemeRequestGetURI(req)),
    header: HeaderMap(),
    responder: t)
  if not webkitURISchemeRequestGetHTTPMethod.isNil:
    let m = goStr(webkitURISchemeRequestGetHTTPMethod(req))
    if m != "": r.httpMethod = m
  if not webkitURISchemeRequestGetHTTPHeaders.isNil:
    let hdrs = webkitURISchemeRequestGetHTTPHeaders(req)
    if not hdrs.isNil:
      let key = cast[pointer](headerSinks.len + 1)
      headerSinks[key] = r.header
      soupMessageHeadersForeach(hdrs, cbHeaderForeach, key)
      r.header = headerSinks.getOrDefault(key)
      headerSinks.del(key)
  if not webkitURISchemeRequestGetHTTPBody.isNil:
    let stream = webkitURISchemeRequestGetHTTPBody(req)
    if not stream.isNil:
      r.body = streamOf(readStream(stream))
      gObjectUnref(stream)
  w.h.schemeRequest(r)
