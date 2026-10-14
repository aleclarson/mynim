## http.nim — the slice of net/http that protocol.go's public API
## exposes: a request, a response writer, a handler, and the helpers
## handlers rely on (header ops, status text, content-type sniffing,
## media-type parsing).

type
  HttpRequest* = ref object
    ## An incoming request of a custom scheme, as http.Request.
    httpMethod*: string
    url*: Uri
    ## requestUri is the unmodified request-target (RFC 7230), used by
    ## handlers that parse the URL themselves.
    requestUri*: string
    remoteAddr*: string
    header*: HeaderMap
    ## body is nil for requests without a body.
    body*: Stream
    contentLength*: int64
    ## ctx is canceled when the webview no longer needs the response.
    ctx*: CancelCtx

  HttpResponseWriter* = ref object of RootObj
    ## Writes the response of a scheme request, as
    ## http.ResponseWriter.

  ## A request handler, as http.HandlerFunc: the whole http.Handler
  ## interface in one proc.
  HttpHandler* = proc(w: HttpResponseWriter; r: HttpRequest) {.closure.}

method header*(w: HttpResponseWriter): var HeaderMap {.base.} =
  ## The response header map, as ResponseWriter.Header.
  raiseAssert("mynim: header on base HttpResponseWriter")

method writeHeader*(w: HttpResponseWriter; status: int) {.base.} =
  ## Sends the status line, as ResponseWriter.WriteHeader.
  raiseAssert("mynim: writeHeader on base HttpResponseWriter")

method write*(w: HttpResponseWriter; p: seq[byte]):
    tuple[n: int, err: ref CatchableError] {.base.} =
  ## Appends body bytes, as ResponseWriter.Write.
  raiseAssert("mynim: write on base HttpResponseWriter")

method flush*(w: HttpResponseWriter) {.base.} =
  ## Sends buffered data to the page, as http.Flusher.
  discard

proc write*(w: HttpResponseWriter; s: string):
    tuple[n: int, err: ref CatchableError] =
  ## write for strings.
  var b = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(b.addr, s.cstring, s.len)
  w.write(b)

## --- HeaderMap: http.Header with canonical keys ---

proc canonicalHeaderKey(k: string): string =
  ## textproto.CanonicalMIMEHeaderKey: Intn -> Intn, not intn.
  result = k
  var up = true
  for i in 0 ..< result.len:
    let c = result[i]
    if c == '-':
      up = true
    elif up:
      result[i] = chr(ord(c) - (if c in 'a'..'z': 32 else: 0))
      up = false
    else:
      result[i] = chr(ord(c) + (if c in 'A'..'Z': 32 else: 0))

proc hget*(h: HeaderMap; key: string): string =
  ## Header.Get: the first value of key, or "".
  let vs = h.getOrDefault(canonicalHeaderKey(key))
  if vs.len > 0: vs[0] else: ""

proc hset*(h: var HeaderMap; key, v: string) =
  ## Header.Set.
  h[canonicalHeaderKey(key)] = @[v]

proc hadd*(h: var HeaderMap; key, v: string) =
  ## Header.Add.
  let k = canonicalHeaderKey(key)
  h.mgetOrPut(k, @[]).add v

proc hdel*(h: var HeaderMap; key: string) =
  ## Header.Del.
  h.del(canonicalHeaderKey(key))

proc cloneHeader*(h: HeaderMap): HeaderMap =
  ## Header.Clone.
  for k, vs in h.pairs:
    result[k] = @vs

## --- status text ---

proc statusText*(code: int): string =
  ## http.StatusText.
  case code
  of 100: "Continue"
  of 101: "Switching Protocols"
  of 102: "Processing"
  of 200: "OK"
  of 201: "Created"
  of 202: "Accepted"
  of 204: "No Content"
  of 206: "Partial Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 304: "Not Modified"
  of 307: "Temporary Redirect"
  of 308: "Permanent Redirect"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 410: "Gone"
  of 413: "Content Too Large"
  of 416: "Range Not Satisfiable"
  of 418: "I'm a teapot"
  of 422: "Unprocessable Content"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  else: ""

const
  statusOK* = 200
  statusNoContent* = 204
  statusPartialContent* = 206
  statusNotModified* = 304
  statusBadRequest* = 400
  statusForbidden* = 403
  statusNotFound* = 404
  statusMethodNotAllowed* = 405
  statusRangeNotSatisfiable* = 416
  statusInternalServerError* = 500

## --- MIME ---

## mimeTypes is mime.TypeByExtension's table for the types web content
## uses, plus the handful Go ships in its built-in table.
const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".csv": "text/csv; charset=utf-8",
  ".gif": "image/gif",
  ".htm": "text/html; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/vnd.microsoft.icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".mjs": "text/javascript; charset=utf-8",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".xml": "text/xml; charset=utf-8",
  ".zip": "application/zip",
}.toTable()

proc typeByExtension*(ext: string): string =
  ## mime.TypeByExtension; "" for unknown extensions.
  mimeTypes.getOrDefault(ext.toLowerAscii())

## detectContentType is http.DetectContentType's subset: the tag and
## magic-byte signatures a webview distinguishes.
proc detectContentType*(data: openArray[byte]): string =
  let d = @data
  let n = min(d.len, 512)
  if n == 0:
    return "text/plain; charset=utf-8"
  # Magic bytes.
  const magic = [
    (@[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "image/png"),
    (@[0xFF'u8, 0xD8, 0xFF], "image/jpeg"),
    (@[0x47'u8, 0x49, 0x46, 0x38], "image/gif"),
    (@[0x25'u8, 0x50, 0x44, 0x46, 0x2D], "application/pdf"),
    (@[0x00'u8, 0x61, 0x73, 0x6D], "application/wasm"),
    (@[0x50'u8, 0x4B, 0x03, 0x04], "application/zip"),
  ]
  for (sig, mt) in magic:
    if n >= sig.len and d[0 ..< sig.len] == sig:
      return mt
  if n >= 12 and d[0..3] == @[0x52'u8, 0x49, 0x46, 0x46] and
      d[8..11] == @[0x57'u8, 0x45, 0x42, 0x50]:
    return "image/webp"
  # Skip BOMs and leading whitespace for tag sniffing.
  var s = 0
  if n >= 3 and d[0..2] == @[0xEF'u8, 0xBB, 0xBF]:
    s = 3
  while s < n and d[s] in {0x09'u8, 0x0A, 0x0C, 0x0D, 0x20}:
    inc s
  let t = d[s ..< n].mapIt(toLowerAscii(chr(it))).join
  const tags = [
    ("<!doctype html", "text/html; charset=utf-8"),
    ("<html", "text/html; charset=utf-8"),
    ("<head", "text/html; charset=utf-8"),
    ("<script", "text/html; charset=utf-8"),
    ("<body", "text/html; charset=utf-8"),
    ("<style", "text/html; charset=utf-8"),
    ("<title", "text/html; charset=utf-8"),
    ("<!--", "text/html; charset=utf-8"),
    ("<?xml", "text/xml; charset=utf-8"),
    ("<svg", "image/svg+xml"),
  ]
  for (tag, mt) in tags:
    if t.startsWith(tag):
      return mt
  # UTF-8 text is text/plain; the rest is opaque.
  var ok = true
  var i = 0
  while i < n:
    let c = d[i]
    if c < 0x80:
      if c < 0x20 and c notin {0x09'u8, 0x0A, 0x0D} and c != 0x1B:
        ok = false; break
      inc i
    elif c < 0xC0: ok = false; break
    elif c < 0xE0:
      if i + 1 >= n or d[i+1] < 0x80 or d[i+1] > 0xBF: ok = false; break
      i += 2
    elif c < 0xF0:
      if i + 2 >= n: break
      i += 3
    elif c < 0xF8:
      if i + 3 >= n: break
      i += 4
    else: ok = false; break
  if ok: "text/plain; charset=utf-8" else: "application/octet-stream"

## parseMediaType is mime.ParseMediaType: "type/subtype; k=v; k2=\"v\"".
proc parseMediaType*(v: string): tuple[mt: string,
    params: Table[string, string], ok: bool] =
  let parts = v.split(';')
  let mt = parts[0].strip().toLowerAscii()
  if '/' notin mt:
    return ("", initTable[string, string](), false)
  var params = initTable[string, string]()
  for p in parts[1..^1]:
    let eq = p.find('=')
    if eq <= 0: continue
    let k = p[0 ..< eq].strip().toLowerAscii()
    var val = p[eq+1 .. ^1].strip()
    if val.len >= 2 and val[0] == '"' and val[^1] == '"':
      val = val[1 ..< ^1].replace("\\\"", "\"").replace("\\\\", "\\")
    params[k] = val
  (mt, params, true)
