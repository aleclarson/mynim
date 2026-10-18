## RFC 6455 client transport used by the page WebSocket plugin.

import std/[asyncdispatch, asyncnet, base64, httpclient, monotimes, net, sha1,
            strutils, sysrand, tables, times, unicode, uri, dynlib]
import core/locks
import mynim/internal/ctx
import mynim/plugins/fetch/env_proxy as fetchEnvProxy

when defined(ssl):
  import std/openssl
  proc sslCtxGetVerifyMode(context: SslCtx): cint {.
    cdecl, dynlib: DLLSSLName, importc: "SSL_CTX_get_verify_mode".}

type
  Header* = object
    name*, value*: string

  HandshakeRequest* = object
    url*: string
    headers*: seq[Header]

  AllowHandshake* = proc(request: HandshakeRequest): bool {.closure.} ## Approves a handshake before network I/O.

  CookieJar* = object ## Supplies request cookies and receives response cookies.
    cookies*: proc(url: Uri): seq[string] {.closure.} ## Returns `name=value` cookies for an HTTP(S) URL.
    store*: proc(url: Uri; setCookieHeaders: seq[string]) {.closure.} ## Receives raw response Set-Cookie fields.

  Options* = object ## Configures WebSocket handshakes and connections.
    allow*: AllowHandshake ## Optional app policy for the outgoing handshake.
    cookieJar*: CookieJar ## Optional app-managed cookie callbacks.
    maxMessageSize*: int64 ## Maximum incoming message size; defaults to 64 MiB.
    closeTimeoutMs*: int ## Close handshake timeout in milliseconds; defaults to 5 seconds.
    tlsContext*: SslContext ## Optional verified TLS context for secure connections.
    proxy*: Proxy ## Overrides HTTP_PROXY/HTTPS_PROXY and NO_PROXY when set.

  ProtocolFailure* = object of CatchableError
    closeCode*: int

  Outgoing = ref object
    seq: int64
    kind: string
    text: string
    data: seq[byte]
    code: int
    reason: string
    completed: bool
    error: ref CatchableError

  WebSocketConn* = ref object
    socket: AsyncSocket
    ctx: CancelCtx
    maxMessageSize: int64
    closeTimeoutMs: int
    mutex: Lock
    changed: Cond
    nextSeq: int64
    outgoing: seq[Outgoing]
    done: bool
    closeSent: bool
    closeStarted: MonoTime
    protocol*: string
    readBuffer: string

const
  opContinuation = 0x0'u8
  opText = 0x1'u8
  opBinary = 0x2'u8
  opClose = 0x8'u8
  opPing = 0x9'u8
  opPong = 0xa'u8
  closeNormal = 1000
  closeGoingAway = 1001
  closeProtocolError = 1002
  closeNoStatus = 1005
  closeInvalidData = 1007
  closeTooBig = 1009
  readPollMs = 10
  maxHandshakeBytes = 64 * 1024

proc failure(code: int; message: string): ref ProtocolFailure =
  result = newException(ProtocolFailure, message)
  result.closeCode = code

proc acceptKey*(key: string): string =
  let digest = cast[Sha1Digest](secureHash(key &
    "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  encode(digest)

proc validCloseCode*(code: int): bool =
  code in 1000..1003 or code in 1007..1014 or code in 3000..4999

proc parseClose*(payload: openArray[byte]): tuple[code: int, reason: string] =
  if payload.len == 0: return (closeNoStatus, "")
  if payload.len == 1:
    raise failure(closeProtocolError, "invalid close frame")
  let code = (int(payload[0]) shl 8) or int(payload[1])
  if not validCloseCode(code):
    raise failure(closeProtocolError, "invalid close code " & $code)
  var reason = newString(payload.len - 2)
  for i in 2..<payload.len: reason[i - 2] = char(payload[i])
  if reason.validateUtf8() >= 0:
    raise failure(closeInvalidData, "close reason is not valid UTF-8")
  (code, reason)

proc defaultOptions*(): Options =
  result.maxMessageSize = 64'i64 shl 20
  result.closeTimeoutMs = 5000
  when defined(ssl):
    result.tlsContext = newContext()

when defined(ssl):
  proc verifyTlsPeer(socket: AsyncSocket; context: SslContext; host: string) =
    ## asyncnet performs the TLS handshake but does not verify the peer name.
    ## Require chain verification and check the leaf certificate before any
    ## WebSocket handshake headers (which may contain credentials) are sent.
    let verifyMode = sslCtxGetVerifyMode(context.context)
    if (verifyMode and SSL_VERIFY_PEER) == 0:
      raise newException(IOError,
        "websocket: TLS context must verify peer certificates")
    let ssl = socket.sslHandle()
    if SSL_get_verify_result(ssl) != X509_V_OK:
      raise newException(IOError, "websocket: TLS certificate chain verification failed")
    let sslLib = loadLibPattern(DLLSSLName)
    let cryptoLib = loadLibPattern(DLLUtilName)
    if sslLib == nil or cryptoLib == nil:
      if sslLib != nil: unloadLib(sslLib)
      if cryptoLib != nil: unloadLib(cryptoLib)
      raise newException(IOError, "websocket: could not load TLS certificate helpers")
    defer:
      unloadLib(sslLib)
      unloadLib(cryptoLib)
    var getCertificateSym = symAddr(sslLib, "SSL_get_peer_certificate")
    if getCertificateSym == nil:
      getCertificateSym = symAddr(sslLib, "SSL_get1_peer_certificate")
    let checkHostSym = symAddr(cryptoLib, "X509_check_host")
    let checkIpSym = symAddr(cryptoLib, "X509_check_ip_asc")
    let freeCertSym = symAddr(cryptoLib, "X509_free")
    if getCertificateSym == nil or checkHostSym == nil or checkIpSym == nil or
        freeCertSym == nil:
      raise newException(IOError, "websocket: TLS library lacks certificate-name checks")
    let getCertificate = cast[proc(ssl: SslPtr): PX509 {.cdecl.}](getCertificateSym)
    let checkHost = cast[proc(cert: PX509; name: cstring; length: cint;
        flags: cuint; peerName: cstring): cint {.cdecl.}](checkHostSym)
    let checkIp = cast[proc(cert: PX509; address: cstring;
        flags: cuint): cint {.cdecl.}](checkIpSym)
    let freeCert = cast[proc(cert: PX509) {.cdecl.}](freeCertSym)
    let certificate = getCertificate(ssl)
    if certificate == nil:
      raise newException(IOError, "websocket: TLS peer did not provide a certificate")
    defer: freeCert(certificate)
    const X509_CHECK_FLAG_NEVER_CHECK_SUBJECT = 0x20'u32
    let match = if isIpAddress(host):
      checkIp(certificate, host.cstring, 0)
    else:
      checkHost(certificate, host.cstring, host.len.cint,
        X509_CHECK_FLAG_NEVER_CHECK_SUBJECT, nil)
    if match != 1:
      raise newException(IOError, "websocket: TLS certificate does not match hostname")

  proc beginTlsHandshake(socket: AsyncSocket; context: SslContext; host: string;
                         ctx: CancelCtx): Future[Future[string]] {.async.} =
    ## asyncnet has no explicit async handshake API. A pending read drives
    ## SSL_do_handshake without sending application data; retain that read for
    ## the HTTP upgrade response after the request is written.
    if (sslCtxGetVerifyMode(context.context) and SSL_VERIFY_PEER) == 0:
      raise newException(IOError,
        "websocket: TLS context must verify peer certificates")
    let pendingRead = socket.recv(4096)
    var started = false
    while true:
      if ctx.done():
        socket.close()
        raise newException(ValueError, "websocket: TLS handshake canceled")
      await sleepAsync(readPollMs)
      if pendingRead.failed:
        discard pendingRead.read() # propagate the TLS or socket error
      if pendingRead.finished:
        let unexpected = pendingRead.read()
        if unexpected.len > 0:
          raise newException(IOError,
            "websocket: server sent data before the upgrade request")
        raise newException(IOError, "websocket: server closed during TLS handshake")
      if SSL_in_init(socket.sslHandle()) == 0:
        # Give the SSL read operation at least one event-loop turn to start
        # before treating SSL's initial state as a completed handshake.
        if started:
          verifyTlsPeer(socket, context, host)
          return pendingRead
        started = true

proc hasToken(header, token: string): bool =
  for item in header.split(','):
    if item.strip().toLowerAscii() == token.toLowerAscii(): return true

proc validHeaderName(name: string): bool =
  if name.len == 0: return false
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'',
                 '*', '+', '-', '.', '^', '_', '`', '|', '~'}:
      return false
  true

proc urlParts(rawUrl: string): tuple[host, hostHeader, resource: string,
                                     port: Port, secure: bool, url: Uri] =
  var url = parseUri(rawUrl)
  case url.scheme.toLowerAscii()
  of "ws", "http": result.secure = false
  of "wss", "https": result.secure = true
  else:
    raise newException(ValueError, "websocket: unsupported URL scheme " &
      url.scheme.escape())
  if url.hostname.len == 0:
    raise newException(ValueError, "websocket: URL must include a hostname")
  if url.username.len > 0 or url.password.len > 0:
    raise newException(ValueError, "websocket: URL credentials are not supported")
  result.host = url.hostname
  let defaultPort = if result.secure: "443" else: "80"
  let portText = if url.port.len > 0: url.port else: defaultPort
  var portNumber: int
  try: portNumber = parseInt(portText)
  except ValueError:
    raise newException(ValueError, "websocket: invalid URL port")
  if portNumber < 1 or portNumber > 65535:
    raise newException(ValueError, "websocket: invalid URL port")
  result.port = Port(portNumber)
  result.hostHeader = if ':' in result.host: "[" & result.host & "]"
                      else: result.host
  if url.port.len > 0 and portText != defaultPort:
    result.hostHeader.add ":" & portText
  result.resource = if url.path.len > 0: url.path else: "/"
  if url.query.len > 0: result.resource.add "?" & url.query
  url.anchor = ""
  result.url = url

proc normalizedHeaders(request: HandshakeRequest; protocols: openArray[string];
                       key: string): tuple[host: string, wire: string,
                       values: seq[Header]] =
  result.host = ""
  for header in request.headers:
    if not validHeaderName(header.name) or '\r' in header.value or
        '\n' in header.value or '\0' in header.value:
      raise newException(ValueError, "websocket: invalid handshake header")
    let lower = header.name.toLowerAscii()
    if lower == "host":
      result.host = header.value
    elif lower notin ["upgrade", "connection", "sec-websocket-key",
                      "sec-websocket-version", "sec-websocket-protocol",
                      "sec-websocket-extensions"]:
      result.values.add header
  result.values.add Header(name: "Upgrade", value: "websocket")
  result.values.add Header(name: "Connection", value: "Upgrade")
  result.values.add Header(name: "Sec-WebSocket-Key", value: key)
  result.values.add Header(name: "Sec-WebSocket-Version", value: "13")
  if protocols.len > 0:
    result.values.add Header(name: "Sec-WebSocket-Protocol",
      value: protocols.join(", "))
  for header in result.values:
    result.wire.add header.name & ": " & header.value & "\r\n"

proc socketSend(socket: AsyncSocket; data: string; ctx: CancelCtx) {.async.} =
  let future = socket.send(data)
  while not future.finished:
    if ctx.done():
      socket.close()
      raise newException(ValueError, "websocket: connection canceled")
    await sleepAsync(readPollMs)
  future.read()

proc socketReadExact(socket: AsyncSocket; count: int; ctx: CancelCtx):
    Future[string] {.async.} =
  while result.len < count:
    let pending = socket.recv(count - result.len)
    while not pending.finished:
      if ctx.done():
        socket.close()
        raise newException(ValueError, "websocket: connection canceled")
      await sleepAsync(readPollMs)
    let part = pending.read()
    if part.len == 0:
      raise newException(IOError, "websocket: proxy closed the connection")
    result.add part

proc socketPort(value: string; defaultPort: int): Port =
  var number = defaultPort
  if value.len > 0:
    try: number = parseInt(value)
    except ValueError:
      raise newException(ValueError, "websocket: invalid proxy port")
  if number < 1 or number > 65535:
    raise newException(ValueError, "websocket: invalid proxy port")
  Port(number)

proc proxyPort(proxy: Proxy): Port =
  let defaultPort = case proxy.url.scheme.toLowerAscii()
    of "https": 443
    of "socks5", "socks5h": 1080
    else: 80
  socketPort(proxy.url.port, defaultPort)

proc proxyFor(options: Options; parts: tuple[host, hostHeader, resource: string,
                     port: Port, secure: bool, url: Uri]): Proxy =
  if options.proxy != nil:
    return options.proxy
  var target = parts.url
  target.scheme = if parts.secure: "https" else: "http"
  fetchEnvProxy.proxyForUrl(target, fetchEnvProxy.fromEnvironment())

proc socks5Connect(socket: AsyncSocket; proxy: Proxy; host: string;
                   port: Port; ctx: CancelCtx) {.async.} =
  let username = proxy.url.username
  let password = proxy.url.password
  if username.len > 255 or password.len > 255:
    raise newException(ValueError, "websocket: SOCKS5 credentials are too long")
  let methods = if username.len == 0: "\x05\x01\x00"
                else: "\x05\x02\x00\x02"
  await socketSend(socket, methods, ctx)
  let selected = await socketReadExact(socket, 2, ctx)
  if selected[0] != '\x05':
    raise newException(IOError, "websocket: invalid SOCKS5 greeting")
  case selected[1]
  of '\x00':
    if username.len > 0:
      raise newException(IOError, "websocket: SOCKS5 proxy refused authentication")
  of '\x02':
    if username.len == 0:
      raise newException(IOError, "websocket: SOCKS5 proxy requires credentials")
    var auth = "\x01" & char(username.len) & username & char(password.len) & password
    await socketSend(socket, auth, ctx)
    let authReply = await socketReadExact(socket, 2, ctx)
    if authReply[0] != '\x01' or authReply[1] != '\x00':
      raise newException(IOError, "websocket: SOCKS5 authentication failed")
  else:
    raise newException(IOError, "websocket: SOCKS5 proxy selected an unsupported method")

  var connect = "\x05\x01\x00"
  var address: IpAddress
  try:
    address = parseIpAddress(host)
    if address.family == IpAddressFamily.IPv4:
      connect.add '\x01'
      for octet in address.address_v4: connect.add char(octet)
    else:
      connect.add '\x04'
      for octet in address.address_v6: connect.add char(octet)
  except ValueError:
    if host.len > 255:
      raise newException(ValueError, "websocket: SOCKS5 target hostname is too long")
    connect.add '\x03' & char(host.len) & host
  let portNumber = int(port)
  connect.add char((portNumber shr 8) and 0xff)
  connect.add char(portNumber and 0xff)
  await socketSend(socket, connect, ctx)
  let response = await socketReadExact(socket, 4, ctx)
  if response[0] != '\x05' or response[2] != '\x00':
    raise newException(IOError, "websocket: invalid SOCKS5 connection response")
  if response[1] != '\x00':
    raise newException(IOError,
      "websocket: SOCKS5 connection failed with code " & $ord(response[1]))
  case response[3]
  of '\x01': discard await socketReadExact(socket, 4, ctx)
  of '\x04': discard await socketReadExact(socket, 16, ctx)
  of '\x03':
    let size = await socketReadExact(socket, 1, ctx)
    discard await socketReadExact(socket, ord(size[0]), ctx)
  else:
    raise newException(IOError, "websocket: invalid SOCKS5 address type")
  discard await socketReadExact(socket, 2, ctx)

proc readHandshake(socket: AsyncSocket; ctx: CancelCtx;
                   firstRead: Future[string]): Future[string] {.async.}

proc connectHttpProxy(socket: AsyncSocket; parts: tuple[host, hostHeader, resource: string,
                           port: Port, secure: bool, url: Uri]; proxy: Proxy;
                       ctx: CancelCtx) {.async.} =
  let targetHost = if ':' in parts.host: "[" & parts.host & "]" else: parts.host
  let authority = targetHost & ":" & $int(parts.port)
  var wire = "CONNECT " & authority & " HTTP/1.1\r\nHost: " & authority & "\r\n"
  if proxy.url.username.len > 0:
    wire.add "Proxy-Authorization: Basic " &
      encode(proxy.url.username & ":" & proxy.url.password) & "\r\n"
  wire.add "\r\n"
  await socketSend(socket, wire, ctx)
  let response = await readHandshake(socket, ctx, nil)
  let lineEnd = response.find("\r\n")
  if lineEnd < 0:
    raise newException(IOError, "websocket: malformed proxy CONNECT response")
  let status = strutils.splitWhitespace(response[0..<lineEnd])
  if status.len < 2 or status[1] != "200":
    raise newException(IOError, "websocket: proxy CONNECT failed with " &
      (if status.len > 1: status[1] else: "an invalid response"))

proc dialSocket(host: string; port: Port; ctx: CancelCtx):
    Future[AsyncSocket] {.async.} =
  let pending = asyncnet.dial(host, port, buffered = false)
  while not pending.finished:
    if ctx.done():
      pending.addCallback(proc(future: Future[AsyncSocket]) {.gcsafe.} =
        if not future.failed: future.read().close())
      raise newException(ValueError, "websocket: connection canceled")
    await sleepAsync(readPollMs)
  return pending.read()

proc readHandshake(socket: AsyncSocket; ctx: CancelCtx;
                    firstRead: Future[string]): Future[string] {.async.} =
  var response = ""
  var pendingRead = firstRead
  while response.len < maxHandshakeBytes:
    if pendingRead == nil: pendingRead = socket.recv(4096)
    while not pendingRead.finished:
      if ctx.done():
        socket.close()
        raise newException(ValueError, "websocket: handshake canceled")
      await sleepAsync(readPollMs)
    let part = pendingRead.read()
    pendingRead = nil
    if part.len == 0:
      raise newException(IOError, "websocket: server closed during handshake")
    response.add part
    if response.find("\r\n\r\n") >= 0: return response
  raise newException(ValueError, "websocket: handshake headers are too large")

proc responseCookies(response: string): seq[string] =
  let headerEnd = response.find("\r\n\r\n")
  if headerEnd < 0: return
  let lines = response[0..<headerEnd].split("\r\n")
  if lines.len == 0: return
  let status = strutils.splitWhitespace(lines[0])
  if status.len < 2 or not status[0].startsWith("HTTP/") or
      status[1].len != 3:
    return
  for digit in status[1]:
    if digit notin {'0'..'9'}: return
  for i in 1..<lines.len:
    let colon = lines[i].find(':')
    if colon <= 0 or not validHeaderName(lines[i][0..<colon]):
      return @[]
    if lines[i][0..<colon].toLowerAscii() == "set-cookie":
      result.add lines[i][colon + 1..^1].strip()

proc parseHandshake(response: string; key: string;
    protocols: openArray[string]): tuple[headerEnd: int, protocol: string] =
  let headerEnd = response.find("\r\n\r\n")
  if headerEnd < 0: raise newException(ValueError, "websocket: invalid handshake response")
  let lines = response[0..<headerEnd].split("\r\n")
  let statusParts = strutils.splitWhitespace(lines[0])
  if statusParts.len < 2:
    raise newException(ValueError, "websocket: invalid handshake status")
  if statusParts[1] != "101":
    let status = if statusParts.len > 2: statusParts[1..^1].join(" ")
                 else: statusParts[1]
    raise newException(ValueError,
      "websocket: server answered handshake with " & status)
  var headers = initTable[string, string]()
  for line in lines[1..^1]:
    let colon = line.find(':')
    if colon <= 0:
      raise newException(ValueError, "websocket: malformed handshake header")
    let name = line[0..<colon].toLowerAscii()
    let value = line[colon + 1..^1].strip()
    if headers.hasKey(name): headers[name].add ", " & value
    else: headers[name] = value
  if headers.getOrDefault("upgrade").toLowerAscii() != "websocket" or
      not hasToken(headers.getOrDefault("connection"), "upgrade"):
    raise newException(ValueError, "websocket: server did not upgrade the connection")
  if headers.getOrDefault("sec-websocket-accept") != acceptKey(key):
    raise newException(ValueError, "websocket: wrong Sec-WebSocket-Accept")
  result.protocol = headers.getOrDefault("sec-websocket-protocol")
  if result.protocol.len > 0 and result.protocol notin protocols:
    raise newException(ValueError, "websocket: server chose unrequested protocol " &
      result.protocol.escape())
  if headers.getOrDefault("sec-websocket-extensions").len > 0:
    raise newException(ValueError, "websocket: server chose unrequested extensions")
  result.headerEnd = headerEnd + 4

proc dialAsync*(options: Options; request: HandshakeRequest;
                protocols: seq[string]; ctx: CancelCtx):
                Future[WebSocketConn] {.async.} =
  let parts = urlParts(request.url)
  let proxy = options.proxyFor(parts)
  let proxyScheme = if proxy == nil: "" else: proxy.url.scheme.toLowerAscii()
  if proxy != nil and proxy.url.hostname.len == 0:
    raise newException(ValueError, "websocket: proxy URL must include a hostname")
  if parts.secure and proxyScheme == "https":
    raise newException(ValueError,
      "websocket: secure WebSocket over an HTTPS proxy is unsupported")
  if proxyScheme notin ["", "http", "https", "socks5", "socks5h"]:
    raise newException(ValueError,
      "websocket: unsupported proxy scheme " & proxyScheme.escape())
  var nonce = urandom(16)
  let key = encode(nonce)
  let headers = normalizedHeaders(request, protocols, key)
  var hostHeader = if headers.host.len > 0: headers.host else: parts.hostHeader
  if '\r' in hostHeader or '\n' in hostHeader:
    raise newException(ValueError, "websocket: invalid Host header")
  var handshakeRequest = HandshakeRequest(url: request.url,
    headers: headers.values)
  if options.allow != nil and not options.allow(handshakeRequest):
    raise newException(ValueError,
      "the app does not allow connections to " & request.url)

  var cookieUrl = parts.url
  cookieUrl.scheme = if parts.secure: "https" else: "http"
  var jarCookies: seq[string]
  if options.cookieJar.cookies != nil:
    for cookie in options.cookieJar.cookies(cookieUrl):
      if '\r' in cookie or '\n' in cookie or '\0' in cookie:
        raise newException(ValueError, "websocket: cookie jar returned an invalid cookie")
      if cookie.len > 0: jarCookies.add cookie

  var socket: AsyncSocket
  var firstRead: Future[string]
  try:
    let dialHost = if proxy == nil: parts.host else: proxy.url.hostname
    let dialPort = if proxy == nil: parts.port else: proxy.proxyPort()
    socket = await dialSocket(dialHost, dialPort, ctx)
    if proxyScheme in ["socks5", "socks5h"]:
      await socks5Connect(socket, proxy, parts.host, parts.port, ctx)
    elif proxyScheme == "http" and parts.secure:
      await connectHttpProxy(socket, parts, proxy, ctx)
    elif proxyScheme == "https":
      when defined(ssl):
        var tlsContext = options.tlsContext
        if tlsContext == nil: tlsContext = newContext()
        tlsContext.wrapConnectedSocket(socket, handshakeAsClient,
          proxy.url.hostname)
        if not isIpAddress(proxy.url.hostname) and
            SSL_set_tlsext_host_name(socket.sslHandle(),
              proxy.url.hostname.cstring) != 1:
          raise newException(IOError,
            "websocket: could not set proxy TLS server name")
        firstRead = await beginTlsHandshake(socket, tlsContext,
          proxy.url.hostname, ctx)
      else:
        raise newException(ValueError,
          "websocket: this build does not include TLS support")
    if parts.secure:
      when defined(ssl):
        var tlsContext = options.tlsContext
        if tlsContext == nil: tlsContext = newContext()
        tlsContext.wrapConnectedSocket(socket, handshakeAsClient, parts.host)
        if not isIpAddress(parts.host) and
            SSL_set_tlsext_host_name(socket.sslHandle(), parts.host.cstring) != 1:
          raise newException(IOError, "websocket: could not set TLS server name")
        firstRead = await beginTlsHandshake(socket, tlsContext, parts.host, ctx)
      else:
        raise newException(ValueError,
          "websocket: this build does not include TLS support")

    var requestTarget = parts.resource
    if proxy != nil and not parts.secure and proxyScheme in ["http", "https"]:
      var absoluteUrl = parts.url
      absoluteUrl.scheme = "http"
      requestTarget = $absoluteUrl
    var wire = "GET " & requestTarget & " HTTP/1.1\r\nHost: " & hostHeader & "\r\n"
    wire.add headers.wire
    for cookie in jarCookies:
      wire.add "Cookie: " & cookie & "\r\n"
    if proxy != nil and not parts.secure and proxyScheme in ["http", "https"] and
        proxy.url.username.len > 0:
      var hasProxyAuthorization = false
      for header in headers.values:
        if header.name.toLowerAscii() == "proxy-authorization":
          hasProxyAuthorization = true
          break
      if not hasProxyAuthorization:
        wire.add "Proxy-Authorization: Basic " &
          encode(proxy.url.username & ":" & proxy.url.password) & "\r\n"
    wire.add "\r\n"
    await socketSend(socket, wire, ctx)
    let response = await readHandshake(socket, ctx, firstRead)
    let setCookieHeaders = responseCookies(response)
    if options.cookieJar.store != nil and setCookieHeaders.len > 0:
      options.cookieJar.store(cookieUrl, setCookieHeaders)
    let parsed = parseHandshake(response, key, protocols)
    result = WebSocketConn(socket: socket, ctx: ctx,
      maxMessageSize: max(1'i64, options.maxMessageSize),
      closeTimeoutMs: max(1, options.closeTimeoutMs),
      nextSeq: 1, protocol: parsed.protocol,
      readBuffer: response[parsed.headerEnd..^1])
    result.mutex.initLock()
    result.changed.initCond()
  except:
    if socket != nil: socket.close()
    raise

proc writeFrame(conn: WebSocketConn; opcode: uint8; payload: seq[byte]):
    Future[void] {.async.} =
  acquire(conn.mutex)
  let closed = conn.done or (conn.closeSent and opcode != opClose)
  if opcode == opClose: conn.closeSent = true
  release(conn.mutex)
  if closed: raise newException(IOError, "websocket: connection closed")
  if opcode >= opClose and payload.len > 125:
    raise failure(closeProtocolError, "invalid control frame")

  var frame = newStringOfCap(payload.len + 14)
  frame.add char(0x80'u8 or opcode)
  if payload.len <= 125:
    frame.add char(0x80'u8 or uint8(payload.len))
  elif payload.len <= 0xffff:
    frame.add char(0x80'u8 or 126'u8)
    frame.add char((payload.len shr 8) and 0xff)
    frame.add char(payload.len and 0xff)
  else:
    frame.add char(0x80'u8 or 127'u8)
    for shift in countdown(56, 0, 8):
      frame.add char((payload.len.uint64 shr shift) and 0xff)
  let mask = urandom(4)
  for value in mask: frame.add char(value)
  for i, value in payload: frame.add char(value xor mask[i mod 4])
  await conn.socket.send(frame)

proc writeClose(conn: WebSocketConn; code: int; reason: string): Future[void] {.async.} =
  if code != closeNoStatus and not validCloseCode(code):
    raise newException(ValueError, "websocket: invalid close code " & $code)
  if reason.len > 123:
    raise newException(ValueError, "websocket: close reason over 123 bytes")
  if reason.validateUtf8() >= 0:
    raise newException(ValueError, "websocket: close reason is not valid UTF-8")
  if code == closeNoStatus and reason.len > 0:
    raise newException(ValueError,
      "websocket: a close reason requires a close code")
  var payload: seq[byte]
  if code != closeNoStatus:
    payload.add byte((code shr 8) and 0xff)
    payload.add byte(code and 0xff)
    for ch in reason: payload.add byte(ch)
  await conn.writeFrame(opClose, payload)
  acquire(conn.mutex)
  if not conn.closeSent:
    conn.closeSent = true
    conn.closeStarted = getMonoTime()
  elif conn.closeStarted.ticks == 0:
    conn.closeStarted = getMonoTime()
  release(conn.mutex)

proc flushOutgoing*(conn: WebSocketConn): Future[void] {.async.} =
  while true:
    acquire(conn.mutex)
    var message: Outgoing
    for i, pending in conn.outgoing:
      if pending.seq == conn.nextSeq:
        message = pending
        conn.outgoing.delete(i)
        break
    let isDone = conn.done
    release(conn.mutex)
    if message == nil or isDone: return
    var error: ref CatchableError
    try:
      case message.kind
      of "text":
        var bytes = newSeq[byte](message.text.len)
        for i, ch in message.text: bytes[i] = byte(ch)
        await conn.writeFrame(opText, bytes)
      of "binary": await conn.writeFrame(opBinary, message.data)
      of "skip": discard
      of "close": await conn.writeClose(message.code, message.reason)
      else: raise newException(ValueError, "websocket: unknown message type")
    except CatchableError as e:
      error = e
    acquire(conn.mutex)
    message.error = error
    message.completed = true
    inc conn.nextSeq
    if error != nil: conn.done = true
    conn.changed.broadcast()
    release(conn.mutex)
    if error != nil: return

proc send*(conn: WebSocketConn; seq: int64; kind, text: string;
           data: seq[byte]; code: int; reason: string): ref CatchableError =
  if conn == nil: return newException(ValueError, "websocket: connection closed")
  if kind == "close":
    if code != closeNoStatus and code != closeNormal and
        (code < 3000 or code > 4999):
      return newException(ValueError, "websocket: invalid close code " & $code)
    if reason.len > 123:
      return newException(ValueError, "websocket: close reason over 123 bytes")
    if reason.validateUtf8() >= 0:
      return newException(ValueError, "websocket: close reason is not valid UTF-8")
  acquire(conn.mutex)
  if seq < conn.nextSeq:
    release(conn.mutex)
    return newException(ValueError, "websocket: duplicate message sequence")
  while not conn.done and seq != conn.nextSeq:
    conn.changed.wait(conn.mutex)
  if conn.done:
    release(conn.mutex)
    return newException(ValueError, "websocket: connection closed")
  let pending = Outgoing(seq: seq, kind: kind, text: text, data: data,
    code: code, reason: reason)
  conn.outgoing.add pending
  conn.changed.broadcast()
  while not pending.completed and not conn.done:
    conn.changed.wait(conn.mutex)
  result = pending.error
  release(conn.mutex)

proc readExact(conn: WebSocketConn; count: int; control = false):
    Future[seq[byte]] {.async.} =
  let limit = if control: 139'u64 else: uint64(conn.maxMessageSize) + 14
  if count < 0 or uint64(count) > limit:
    raise failure(closeTooBig, "invalid frame length")
  if count == 0: return @[]
  if conn.readBuffer.len > 0:
    let take = min(count, conn.readBuffer.len)
    for i in 0..<take: result.add byte(conn.readBuffer[i])
    conn.readBuffer.delete(0 ..< take)
  while result.len < count:
    let future = conn.socket.recv(count - result.len)
    while not future.finished:
      await conn.flushOutgoing()
      if conn.ctx.done():
        try: await conn.writeClose(closeGoingAway, "")
        except CatchableError: discard
        conn.socket.close()
        raise newException(ValueError, "websocket: connection canceled")
      acquire(conn.mutex)
      let closeSent = conn.closeSent
      let closeStarted = conn.closeStarted
      release(conn.mutex)
      if closeSent and closeStarted.ticks != 0 and
          (getMonoTime() - closeStarted).inMilliseconds >= conn.closeTimeoutMs:
        conn.socket.close()
      await sleepAsync(readPollMs)
    let piece = future.read()
    if piece.len == 0: raise newException(IOError, "websocket: connection closed")
    for ch in piece: result.add byte(ch)

proc readFrame(conn: WebSocketConn): Future[tuple[fin: bool, opcode: uint8,
    payload: seq[byte]]] {.async.} =
  let head = await conn.readExact(2)
  let fin = (head[0] and 0x80) != 0
  let opcode = head[0] and 0x0f
  if (head[0] and 0x70) != 0:
    raise failure(closeProtocolError, "reserved bits set in a frame")
  if (head[1] and 0x80) != 0:
    raise failure(closeProtocolError, "server frame is masked")
  var size = uint64(head[1] and 0x7f)
  if size == 126:
    let extended = await conn.readExact(2)
    size = (uint64(extended[0]) shl 8) or uint64(extended[1])
    if size < 126:
      raise failure(closeProtocolError, "noncanonical frame length")
  elif size == 127:
    let extended = await conn.readExact(8)
    size = 0
    for value in extended: size = (size shl 8) or uint64(value)
    if (size shr 63) != 0:
      raise failure(closeProtocolError, "invalid frame length")
    if size < 65536:
      raise failure(closeProtocolError, "noncanonical frame length")
  if opcode >= opClose and (not fin or size > 125):
    raise failure(closeProtocolError, "invalid control frame")
  if (opcode < opClose and size > uint64(conn.maxMessageSize)) or
      size > uint64(high(int)):
    raise failure(closeTooBig, "message over " & $conn.maxMessageSize & " bytes")
  let payload = await conn.readExact(size.int, control = opcode >= opClose)
  (fin, opcode, payload)

proc readMessage*(conn: WebSocketConn): Future[tuple[opcode: uint8,
    payload: seq[byte]]] {.async.} =
  var messageOpcode = 0'u8
  while true:
    let frame = await conn.readFrame()
    case frame.opcode
    of opPing:
      await conn.writeFrame(opPong, frame.payload)
      continue
    of opPong: continue
    of opClose: return (opClose, frame.payload)
    of opContinuation:
      if messageOpcode == 0:
        raise failure(closeProtocolError, "unexpected continuation frame")
    of opText, opBinary:
      if messageOpcode != 0:
        raise failure(closeProtocolError, "new message before previous message ended")
      messageOpcode = frame.opcode
    else:
      raise failure(closeProtocolError, "unknown opcode " & $frame.opcode)
    if result.payload.len + frame.payload.len > conn.maxMessageSize:
      raise failure(closeTooBig, "message over " & $conn.maxMessageSize & " bytes")
    result.payload.add frame.payload
    if frame.fin:
      result.opcode = messageOpcode
      if messageOpcode == opText:
        var text = newString(result.payload.len)
        for i, value in result.payload: text[i] = char(value)
        if text.validateUtf8() >= 0:
          raise failure(closeInvalidData, "text message is not valid UTF-8")
      return

proc terminate*(conn: WebSocketConn) =
  if conn == nil: return
  acquire(conn.mutex)
  if not conn.done: conn.done = true
  conn.changed.broadcast()
  release(conn.mutex)
  conn.socket.close()

proc closing*(conn: WebSocketConn): bool =
  acquire(conn.mutex)
  result = conn.closeSent
  release(conn.mutex)

proc close*(conn: WebSocketConn; code = closeGoingAway; reason = ""):
    Future[void] {.async.} =
  await conn.writeClose(code, reason)
