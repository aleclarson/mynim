## protocol.go — Protocol serves custom URL schemes such as app:// from
## Nim.

const
  ## Schemes the platform owns or pages navigate with; Handle cannot
  ## take them.
  reservedSchemes = ["http", "https", "file", "about", "data", "blob",
    "javascript", "ws", "wss", "ftp", "mailto", "webkit"].toHashSet()

## --- ProtocolModule (protocol.go) ---

proc handle*(p: ProtocolModule; scheme: string; handler: HttpHandler):
    ref CatchableError =
  ## Serves requests for scheme with a handler, for example files
  ## generated at run time:
  ##
  ##   discard protocol.handle("thumbs", fileServer(dirFs(cacheDir)))
  ##   win.page().loadURL("thumbs://localhost/")
  ##
  ## Pages served this way are loaded like regular web pages: they can
  ## use fetch, ES modules and relative URLs. Schemes must be
  ## registered before the windows that use them are created. Handlers
  ## run on their own threads and responses are streamed to the page.
  ##
  ## The mygo scheme serves the app's frontend (see setFrontend)
  ## unless it is handled here.
  let scheme = scheme.toLowerAscii()
  if not validScheme(scheme):
    return newException(ValueError,
      "mynim: invalid scheme " & scheme.escape())
  if scheme in reservedSchemes:
    return newException(ValueError,
      "mynim: scheme " & scheme.escape() & " is reserved")
  acquire(p.mu)
  p.handlers[scheme] = handler
  release(p.mu)

## handleFunc is an alias of handle, matching Go's API shape.
proc handleFunc*(p: ProtocolModule; scheme: string; fn: HttpHandler):
    ref CatchableError = p.handle(scheme, fn)

proc unhandle*(p: ProtocolModule; scheme: string) =
  ## Removes the handler of scheme. Pages requesting it get an error.
  acquire(p.mu)
  p.handlers.del(scheme.toLowerAscii())
  release(p.mu)

proc isHandled*(p: ProtocolModule; scheme: string): bool =
  ## Whether scheme has a handler.
  acquire(p.mu)
  result = p.handlers.hasKey(scheme.toLowerAscii())
  release(p.mu)

proc schemes*(p: ProtocolModule): seq[string] =
  ## The schemes windows must handle: the registered ones and the
  ## frontend's.
  acquire(p.mu)
  for s in p.handlers.keys:
    result.add s
  if not p.handlers.hasKey(frontendScheme):
    result.add frontendScheme
  release(p.mu)

proc validScheme(s: string): bool =
  if s == "" or s[0] < 'a' or s[0] > 'z':
    return false
  for c in s:
    if not (c in 'a'..'z' or c in '0'..'9' or c in {'+', '-', '.'}):
      return false
  true

## --- serving (serveScheme, schemeWriter) ---

const
  schemeChunk = 256 shl 10
  ## A handler faster than the main thread waits once this many
  ## chunks wait for it, so a large body does not pile up in memory.
  schemeQueued = 4

type
  SchemeWriter = ref object of HttpResponseWriter
    ## The HttpResponseWriter for custom scheme requests. Body bytes
    ## are buffered and handed to the main thread in chunks, or
    ## written to backends that take them on this thread.
    req: platform.SchemeRequest
    header0: HeaderMap
    status: int
    wroteHeader, chunked, sentHeader, finished: bool
    buf: seq[byte]
    ## body, when not nil, takes the body from this thread, once
    ## respond ran (platform's writeBody path).
    body: platform.SchemeResponder
    err: ref CatchableError
    ## Flow control for the main thread's writes.
    qmu: Lock
    qcond: Cond
    queuedN: int

method header*(w: SchemeWriter): var HeaderMap = w.header0

method writeHeader*(w: SchemeWriter; status: int) =
  if w.wroteHeader: return
  w.wroteHeader = true
  w.status = status

## writeErr reports why the body can no longer be written.
method writeErr(w: SchemeWriter): ref CatchableError {.base.} =
  if w.err != nil: return w.err
  w.req.context.err()

method flush*(w: SchemeWriter) =
  if not w.wroteHeader:
    w.writeHeader(statusOK)
  if not w.sentHeader:
    w.sentHeader = true
    if w.header0.hget("Content-Type") == "" and
        w.status != statusNoContent and w.status != statusNotModified:
      w.header0.hset("Content-Type", detectContentType(w.buf))
    let
      status = w.status
      header = cloneHeader(w.header0)
      resp = w.req.responder
    if resp.supportsWriteBody():
      ## The body goes to the backend from here, once it responded.
      onMain(proc() = resp.respond(status, header))
      w.body = resp
    else:
      discard postMain(proc() = resp.respond(status, header))
  if w.buf.len == 0:
    return
  if w.body != nil:
    if w.err == nil:
      try:
        w.body.writeBody(w.buf)
      except CatchableError as e:
        w.err = e
    w.buf.setLen(0) ## written: the buffer is free again
    return
  let chunk = w.buf
  w.buf = @[]
  acquire(w.qmu)
  while w.queuedN >= schemeQueued:
    wait(w.qcond, w.qmu)
  inc w.queuedN
  release(w.qmu)
  let resp = w.req.responder
  let qw = w
  if not postMain(proc() =
      resp.write(chunk)
      acquire(qw.qmu)
      dec qw.queuedN
      signal(qw.qcond)
      release(qw.qmu)):
    acquire(w.qmu)
    dec w.queuedN
    signal(w.qcond)
    release(w.qmu)

method write*(w: SchemeWriter; p: seq[byte]):
    tuple[n: int, err: ref CatchableError] =
  let e = w.writeErr()
  if e != nil:
    return (0, e)
  if not w.wroteHeader:
    w.writeHeader(statusOK)
  var n = 0
  while n < p.len:
    if w.buf.len == 0 and w.chunked:
      w.buf = newSeqOfCap[byte](schemeChunk)
    let k = min(p.len - n, schemeChunk - w.buf.len)
    w.buf.add p[n ..< n + k]
    n += k
    if w.buf.len == schemeChunk:
      w.chunked = true
      w.flush()
      let e = w.writeErr()
      if e != nil:
        return (n, e)
  (p.len, nil)

## finish ends the response, once.
proc finish(w: SchemeWriter) =
  if w.finished: return
  w.finished = true
  w.flush()
  let resp = w.req.responder
  discard postMain(proc() = resp.finish())

## serve runs on the main thread when the webview requests a custom
## scheme.
proc serve(p: ProtocolModule; w: Window; req: platform.SchemeRequest) =
  let scheme = req.url.split(':', 1)[0].toLowerAscii()
  acquire(p.mu)
  let h = p.handlers.getOrDefault(scheme)
  release(p.mu)
  let handler = if h != nil: h
    elif scheme == frontendScheme: frontendHandler()
    else: nil
  goAsyncUnsafe(proc() = serveScheme(w, handler, req))

## allowCORS lets the app's own pages read responses of custom
## schemes, which are other origins than theirs: the frontend,
## another scheme, or the dev server fetching thumbs://localhost/ for
## example. It sets the CORS headers for those origins, which
## handlers may still override, and reports whether the request is a
## preflight it answered. Pages of other sites get no CORS headers,
## unless the window trusts them (PageOptions.trustedOrigins).
proc allowCORS(win: Window; header: var HeaderMap; r: HttpRequest): bool =
  let origin = r.header.hget("Origin")
  if origin == "" or origin == "null" or not win.isTrusted(appOrigin(origin)):
    return false
  header.hset("Access-Control-Allow-Origin", origin)
  header.hset("Access-Control-Expose-Headers", "*")
  header.hadd("Vary", "Origin")
  let meth = r.header.hget("Access-Control-Request-Method")
  if r.httpMethod != "OPTIONS" or meth == "":
    return false
  header.hset("Access-Control-Allow-Methods", meth)
  let h = r.header.hget("Access-Control-Request-Headers")
  if h != "":
    header.hset("Access-Control-Allow-Headers", h)
  header.hset("Access-Control-Max-Age", "600")
  true

## schemeHosts is set where the webview serves custom schemes at
## http://<scheme>.localhost (WebView2). Elsewhere, such an origin is
## a server on the loopback interface, not the app's.
const schemeHosts = defined(windows)

## appOrigin maps the origin WebView2 gives pages of a custom scheme,
## http://<scheme>.localhost, back to <scheme>://localhost, as the
## rest of MyNim names it.
proc appOrigin(origin: string): string =
  if not schemeHosts:
    return origin
  let u = try: parseUri(origin) except CatchableError: return origin
  if u.scheme != "http" or u.port != "":
    return origin
  let host = u.hostname.toLowerAscii()
  if not host.endsWith(".localhost"):
    return origin
  let scheme = host[0 ..< host.len - ".localhost".len]
  if scheme != frontendScheme and not protocol.isHandled(scheme):
    return origin
  scheme & "://localhost"

proc serveScheme(win: Window; h: HttpHandler; req: platform.SchemeRequest) =
  ## Runs the handler on its own thread and streams the response.
  var rw = SchemeWriter(req: req, header0: initTable[string, seq[string]]())
  rw.qmu.initLock()
  rw.qcond.initCond()
  defer:
    let e = getCurrentException()
    if e != nil:
      stderr.writeLine("mynim: panic serving " & req.url & ": " & e.msg)
      if not rw.wroteHeader:
        rw.header0 = initTable[string, seq[string]]()
        rw.writeHeader(statusInternalServerError)
    rw.finish()
  if h == nil:
    rw.writeHeader(statusNotFound)
    return
  var r = HttpRequest(
    httpMethod: req.httpMethod,
    requestUri: "",
    remoteAddr: "mygo:" & $win.id,
    header: req.header,
    body: req.body,
    ctx: req.context)
  try:
    r.url = parseUri(req.url)
    r.requestUri = r.url.path & (if r.url.query.len > 0: "?" & r.url.query else: "")
  except CatchableError:
    rw.writeHeader(statusBadRequest)
    return
  if r.header.len == 0:
    r.header = initTable[string, seq[string]]()
  let cl = r.header.hget("Content-Length")
  if cl != "":
    r.contentLength = parseBiggestInt(cl)
  if allowCORS(win, rw.header0, r):
    rw.writeHeader(statusNoContent) ## a preflight, answered here
    return
  h(rw, r)

## --- downloads (SchemeDownload) ---

type
  DownloadWriter = ref object of HttpResponseWriter
    ## Writes a response into the file onWillDownload chose.
    h: WindowHandlerObj
    url: string
    header0: HeaderMap
    wrote: bool
    path: string
    file: File
    err: ref CatchableError

method header*(w: DownloadWriter): var HeaderMap = w.header0

method writeHeader*(w: DownloadWriter; status: int) =
  if w.wrote: return
  w.wrote = true
  if status >= 400:
    w.err = newException(ValueError,
      "mynim: downloading " & w.url & ": " & $status & " " &
      statusText(status))
    return
  var name = ""
  let (_, params, ok) = parseMediaType(w.header0.hget("Content-Disposition"))
  if ok:
    name = params.getOrDefault("filename")
  if name == "":
    let u = try: parseUri(w.url) except CatchableError: Uri()
    name = lastPathPart(u.path)
  let h = w.h
  w.path = onMainValue(proc(): string = h.downloadStarted(w.url, name))
  if w.path == "":
    return
  try:
    w.file = open(w.path, fmWrite)
  except CatchableError as e:
    w.err = e

method write*(w: DownloadWriter; p: seq[byte]):
    tuple[n: int, err: ref CatchableError] =
  w.writeHeader(statusOK)
  if w.file == nil or w.err != nil:
    return (p.len, nil) ## canceled: drain
  try:
    result = (w.file.writeBytes(p, 0, p.len), nil)
  except CatchableError as e:
    w.err = e
    result = (0, e)

## downloadScheme serves a URL of a custom scheme into a download.
proc downloadScheme(h: WindowHandlerObj; rawURL: string) =
  let scheme = rawURL.split(':', 1)[0].toLowerAscii()
  acquire(protocol.mu)
  var handler = protocol.handlers.getOrDefault(scheme)
  release(protocol.mu)
  if handler == nil and scheme == frontendScheme:
    handler = frontendHandler()
  proc finish(path: string; err: ref CatchableError) =
    discard postMain(proc() = h.downloadFinished(rawURL, path, err))
  let parsed = try: parseUri(rawURL) except CatchableError: Uri()
  if parsed.scheme == "" or handler == nil:
    finish("", newException(ValueError, "mynim: cannot download " & rawURL))
    return
  var rw = DownloadWriter(h: h, url: rawURL,
    header0: initTable[string, seq[string]]())
  handler(rw, HttpRequest(httpMethod: "GET", url: parsed,
    requestUri: rawURL, header: initTable[string, seq[string]]()))
  rw.writeHeader(statusOK) ## nothing written
  if rw.file == nil:
    if rw.err != nil:
      finish("", rw.err)
    return ## canceled
  try:
    rw.file.close()
  except CatchableError as e:
    if rw.err == nil: rw.err = e
  if rw.err != nil:
    removeFile(rw.path)
  finish(rw.path, rw.err)

## --- fileServer ---

## serveFileContent serves size bytes from read with content type,
## ETag-free Last-Modified and single-range support, as
## http.ServeContent does.
proc serveFileContent(w: HttpResponseWriter; r: HttpRequest;
    name: string; mtime: Time; size: int64;
    read: proc(offset: int64; length: int): seq[byte]) =
  var ctype = w.header.hget("Content-Type")
  if ctype == "":
    ctype = typeByExtension(splitFile(name).ext)
    if ctype == "":
      ctype = detectContentType(read(0, min(size, 512).int))
    w.header.hset("Content-Type", ctype)
  w.header.hset("Accept-Ranges", "bytes")
  if mtime != Time():
    w.header.hset("Last-Modified", mtime.utc.format(
      "ddd, dd MMM yyyy HH:mm:ss 'GMT'"))
  ## A single range, as browsers use for media.
  var offset = 0.int64
  var length = size
  var status = statusOK
  let rng = r.header.hget("Range")
  if rng.startsWith("bytes="):
    let spec = rng[6 .. ^1]
    let dash = spec.find('-')
    if dash > 0:
      var lo, hi: int64
      let tail = spec[dash+1 .. ^1]
      if spec[0 ..< dash] == "":
        ## Suffix range: last N bytes.
        if parseBiggestInt(tail) > 0:
          hi = size - 1
          lo = max(0.int64, size - parseBiggestInt(tail))
      else:
        lo = parseBiggestInt(spec[0 ..< dash])
        hi = if tail == "": size - 1 else: parseBiggestInt(tail)
      if lo < size and lo <= hi:
        offset = lo
        length = min(hi, size - 1) - lo + 1
        status = statusPartialContent
        w.header.hset("Content-Range",
          "bytes " & $lo & "-" & $(offset + length - 1) & "/" & $size)
      else:
        w.header.hset("Content-Range", "bytes */" & $size)
        w.writeHeader(statusRangeNotSatisfiable)
        return
  w.header.hset("Content-Length", $length)
  w.writeHeader(status)
  if r.httpMethod == "HEAD":
    return
  var done = 0.int64
  while done < length:
    let chunk = read(offset + done, min(length - done, 128 shl 10).int)
    if chunk.len == 0: break
    let (_, err) = w.write(chunk)
    if err != nil: return
    done += chunk.len

type
  FsReader = ref object
    ## Reads regions of a file of a vfs.Fs.
    fsys: Fs
    name: string
    all: seq[byte] ## cached, so range reads do not reopen

proc readAt(fr: FsReader; offset: int64; length: int): seq[byte] =
  if fr.all.len == 0:
    let (d, err) = fr.fsys.readFile(fr.name)
    if err != nil: return @[]
    fr.all = d
  let n = min(length.int64, fr.all.len.int64 - offset).int
  if n <= 0: return @[]
  fr.all[offset.int ..< offset.int + n]

## fileServer serves files from fsys and falls back to index.html for
## unknown paths without an extension, so client side routers work.
## Files are served with their content type and support range
## requests.
proc fileServer*(fsys: Fs): HttpHandler =
  proc(w: HttpResponseWriter; r: HttpRequest) =
    var name = r.url.path
    if name.startsWith("/"): name = name[1 .. ^1]
    ## path.Clean("/" + p) without the leading slash.
    name = normalizedPath("/" & name)[1 .. ^1].replace("\\", "/")
    if name == "": name = "."
    let (size, mtime, isDir, ok) = fsys.stat(name)
    if not ok and splitFile(name).ext == "":
      let (index, err) = fsys.readFile("index.html")
      if err != nil:
        w.header.hset("Content-Type", "text/plain; charset=utf-8")
        w.writeHeader(statusNotFound)
        discard w.write("404 page not found")
        return
      w.header.hset("Content-Type", "text/html; charset=utf-8")
      discard w.write(cast[string](index))
      return
    if not ok or isDir:
      w.header.hset("Content-Type", "text/plain; charset=utf-8")
      w.writeHeader(statusNotFound)
      discard w.write("404 page not found")
      return
    let fr = FsReader(fsys: fsys, name: name)
    serveFileContent(w, r, name, mtime, size,
      proc(offset: int64; length: int): seq[byte] =
        fr.readAt(offset, length))

## frontendHandler serves mygo:// when the app has no handler of its
## own.
proc frontendHandler(): HttpHandler =
  var fsys = frontendFs()
  if fsys == nil and isDev():
    ## `nim-xplat dev` without a dev server: the files on disk.
    let dir = getEnv("MYGO_FRONTEND_DIST")
    if dir != "":
      fsys = dirFs(dir)
  if fsys == nil:
    return proc(w: HttpResponseWriter; r: HttpRequest) =
      w.header.hset("Content-Type", "text/html; charset=utf-8")
      w.writeHeader(statusNotFound)
      discard w.write("""<!doctype html>
<meta charset="utf-8">
<title>No frontend</title>
<style>body{font:15px/1.5 system-ui,sans-serif;margin:3em;color:#444}code{font-size:90%}</style>
<h1>No frontend</h1>
<p>Run the app with <code>nim-xplat dev</code>, which loads <code>devUrl</code> from mygo.config.ts,
or build it with <code>nim-xplat build</code>, which embeds <code>frontendDist</code>.</p>
""")
  fileServer(fsys)
