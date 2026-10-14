## scheme.go: WKURLSchemeHandler: a custom protocol's request becomes a
## platform.SchemeRequest whose platform.SchemeResponder talks to the
## WKURLSchemeTask.

var theSchemeHandler: id

proc schemeHandler(): id =
  if theSchemeHandler.isNil:
    theSchemeHandler = alloc("MyNimSchemeHandler")
  theSchemeHandler

## readStream drains an NSInputStream.
proc readStream(stream: id): seq[byte] =
  discard send(stream, "open")
  defer: discard send(stream, "close")
  var buf = newSeq[byte](64 shl 10)
  while true:
    let n = sendInt(stream, "read:maxLength:",
                    argu(buf[0].addr), argu(buf.len))
    if n <= 0:
      return result
    result.add buf[0 ..< n]

proc readRequest(task: id): SchemeRequest =
  var header = HeaderMap()
  let req = SchemeRequest(header: header)
  withPool(proc() =
    let r = send(task, "request")
    req.url = goString(send(send(r, "URL"), "absoluteString"))
    req.httpMethod = goString(send(r, "HTTPMethod"))
    if req.httpMethod == "":
      req.httpMethod = "GET"
    let fields = send(r, "allHTTPHeaderFields")
    for k in arrayItems(send(fields, "allKeys")):
      let key = goString(k)
      header.mgetOrPut(key, @[]).add(
        goString(send(fields, "objectForKey:", argu(k))))
    let data = send(r, "HTTPBody")
    if not data.isNil:
      req.body = streamOf(goBytes(data))
    else:
      let stream = send(r, "HTTPBodyStream")
      if not stream.isNil:
        req.body = streamOf(readStream(stream)))
  req

## schemeDispositions records the Content-Disposition of the latest
## custom scheme responses by URL, which the navigation policy needs to
## recognize attachments.
var schemeDispositions = initTable[string, string]()

proc releaseSchemeTask(st: schemeTask) =
  if st.done:
    return
  st.done = true
  schemeTasks.del(st.task)
  release(st.task)

method respond*(st: schemeTask, status: int, header: HeaderMap) =
  if st.stopped or st.done or st.responded:
    return
  st.responded = true
  withPool(proc() =
    if schemeDispositions.len > 64:
      schemeDispositions.clear()
    let key = goString(send(send(send(st.task, "request"), "URL"),
                            "absoluteString"))
    let dispo = (block:
      let vs = header.getOrDefault("Content-Disposition")
      if vs.len > 0: vs[0] else: "")
    schemeDispositions[key] = dispo
    let fields = send(`class`("NSMutableDictionary"), "dictionary")
    for k, vs in header:
      discard send(fields, "setObject:forKey:",
                   argu(nsString(vs.join(", "))), argu(nsString(k)))
    let url = send(send(st.task, "request"), "URL")
    let resp = send(send(`class`("NSHTTPURLResponse"), "alloc"),
      "initWithURL:statusCode:HTTPVersion:headerFields:",
      argu(url), argu(status), argu(nsString("HTTP/1.1")), argu(fields))
    discard send(st.task, "didReceiveResponse:", argu(resp))
    release(resp))

method write*(st: schemeTask, p: openArray[byte]) =
  if st.stopped or st.done or p.len == 0:
    return
  if not st.responded:
    st.respond(200, HeaderMap())
  let bytes = @p
  withPool(proc() =
    discard send(st.task, "didReceiveData:", argu(nsData(bytes))))

method finish*(st: schemeTask) =
  if st.stopped or st.done:
    return
  if not st.responded:
    st.respond(200, HeaderMap())
  discard send(st.task, "didFinish")
  st.releaseSchemeTask()

method fail*(st: schemeTask, err: ref CatchableError) =
  if st.stopped or st.done:
    return
  withPool(proc() =
    let info = send(`class`("NSMutableDictionary"), "dictionary")
    discard send(info, "setObject:forKey:", argu(nsString(err.msg)),
                 argu(nsString("NSLocalizedDescription")))
    let nserr = send(`class`("NSError"), "errorWithDomain:code:userInfo:",
      argu(nsString("mynim")), argu(high(uint)), argu(info))
    discard send(st.task, "didFailWithError:", argu(nserr)))
  st.releaseSchemeTask()

proc registerSchemeHandler*() =
  discard classDef("MyNimSchemeHandler", "NSObject",
    @["WKURLSchemeHandler"], @[
    methodDef("webView:startURLSchemeTask:",
      cast[pointer](proc(self: id, cmd: SEL, web, task: id) {.cdecl.} =
        let w = theBackend.byWebView.getOrDefault(web)
        let (ctx, cancel) = withCancel(newCtx())
        let st = schemeTask(task: retain(task), cancel: cancel)
        schemeTasks[task] = st
        if w == nil or w.closed:
          st.respond(503, HeaderMap())
          st.finish()
          return
        let req = readRequest(task)
        req.context = ctx
        req.responder = st
        w.h.schemeRequest(req)),
      "v@:@@"),
    methodDef("webView:stopURLSchemeTask:",
      cast[pointer](proc(self: id, cmd: SEL, web, task: id) {.cdecl.} =
        let st = schemeTasks.getOrDefault(task)
        if st != nil:
          st.stopped = true
          st.cancel()
          st.releaseSchemeTask()),
      "v@:@@"),
  ])
