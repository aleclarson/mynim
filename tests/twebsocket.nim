import std/[asyncdispatch, asyncnet, base64, envvars, httpclient, nativesockets,
            net, os, sequtils, strutils, uri, unittest]

import mynim/internal/ctx
import mynim/plugins/websocket/connection as ws

const tlsFixtures = currentSourcePath().parentDir / "fixtures" / "websocket"

type SavedEnv = tuple[name: string, existed: bool, value: string]

proc saveEnvironment(names: openArray[string]): seq[SavedEnv] =
  for name in names:
    result.add (name, existsEnv(name), getEnv(name))

proc restoreEnvironment(values: openArray[SavedEnv]) =
  for value in values:
    if value.existed: putEnv(value.name, value.value)
    else: delEnv(value.name)

proc readExact(socket: AsyncSocket; count: int): Future[string] {.async.} =
  while result.len < count:
    let part = await socket.recv(count - result.len)
    if part.len == 0: raise newException(IOError, "peer closed")
    result.add part

proc serverScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  var request = ""
  while not request.endsWith("\r\n\r\n"):
    request.add await client.recv(1)
  check "GET /live HTTP/1.1" in request
  check "authorization: bearer local-test" in request.toLowerAscii()
  check "sec-websocket-protocol: prices.v1" in request.toLowerAscii()
  var key = ""
  for line in request.split("\r\n"):
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', maxsplit = 1)[1].strip()
  let response = "HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n" &
    "Sec-WebSocket-Protocol: prices.v1\r\n\r\n" &
    "\x89\x04ping\x81\x01x"
  await client.send(response)

  let header = await client.readExact(2)
  check header[0].byte == 0x8a'u8
  check (header[1].byte and 0x80) != 0
  let length = int(header[1].byte and 0x7f)
  let mask = await client.readExact(4)
  let payload = await client.readExact(length)
  var pong = newString(length)
  for i in 0..<length:
    pong[i] = char(payload[i].byte xor mask[i mod 4].byte)
  check pong == "ping"
  client.close()

proc cookieJarScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  var request = ""
  while not request.endsWith("\r\n\r\n"):
    request.add await client.recv(1)
  check "cookie: explicit=yes" in request.toLowerAscii()
  check "cookie: jar=from-app" in request.toLowerAscii()
  var key = ""
  for line in request.split("\r\n"):
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', maxsplit = 1)[1].strip()
  await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n" &
    "Set-Cookie: session=abc; Path=/; HttpOnly\r\n" &
    "Set-Cookie: theme=dark; SameSite=Lax\r\n\r\n" &
    "\x81\x01c")
  discard await client.recv(1)
  client.close()

proc cookieRejectedScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  var request = ""
  while not request.endsWith("\r\n\r\n"):
    request.add await client.recv(1)
  await client.send("HTTP/1.1 403 Forbidden\r\n" &
    "Set-Cookie: rejected=stored; Path=/\r\n" &
    "Content-Length: 0\r\nConnection: close\r\n\r\n")
  client.close()

proc httpProxyScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  var request = ""
  while not request.endsWith("\r\n\r\n"):
    request.add await client.recv(1)
  check "GET http://example.invalid/live HTTP/1.1" in request
  check "host: example.invalid" in request.toLowerAscii()
  check ("proxy-authorization: basic " & encode("user:pass")).toLowerAscii() in
    request.toLowerAscii()
  var key = ""
  for line in request.split("\r\n"):
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', maxsplit = 1)[1].strip()
  await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n\r\n" &
    "\x81\x01x")
  discard await client.recv(1)
  client.close()

proc socks5ProxyScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  check (await client.readExact(4)) == "\x05\x02\x00\x02"
  await client.send("\x05\x02")
  let authHead = await client.readExact(2)
  check authHead == "\x01\x04"
  check (await client.readExact(4)) == "user"
  check (await client.readExact(1)) == "\x04"
  check (await client.readExact(4)) == "pass"
  await client.send("\x01\x00")
  let connectHead = await client.readExact(5)
  check connectHead == "\x05\x01\x00\x03\x0f"
  check (await client.readExact(15)) == "example.invalid"
  check (await client.readExact(2)) == "\x00\x50"
  await client.send("\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")

  var request = ""
  while not request.endsWith("\r\n\r\n"):
    request.add await client.recv(1)
  check "GET /live HTTP/1.1" in request
  check "host: example.invalid" in request.toLowerAscii()
  var key = ""
  for line in request.split("\r\n"):
    if line.toLowerAscii().startsWith("sec-websocket-key:"):
      key = line.split(':', maxsplit = 1)[1].strip()
  await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n\r\n" &
    "\x81\x01x")
  discard await client.recv(1)
  client.close()

proc httpsForwardProxyScenario(server: AsyncSocket): Future[void] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  let context = newContext(certFile = tlsFixtures / "localhost.crt",
    keyFile = tlsFixtures / "localhost.key", verifyMode = CVerifyNone)
  try:
    context.wrapConnectedSocket(client, handshakeAsServer)
    var request = ""
    while not request.endsWith("\r\n\r\n"):
      request.add await client.recv(1)
    check "GET http://example.invalid/live HTTP/1.1" in request
    check "host: example.invalid" in request.toLowerAscii()
    var key = ""
    for line in request.split("\r\n"):
      if line.toLowerAscii().startsWith("sec-websocket-key:"):
        key = line.split(':', maxsplit = 1)[1].strip()
    await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
      "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
      "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n\r\n" &
      "\x81\x01h")
    discard await client.recv(1)
  except CatchableError as error:
    check error.msg.len == 0
  client.close()

proc tlsProxyScenario(server: AsyncSocket; port: Port): Future[string] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  var connectRequest = await client.recv(1)
  if connectRequest != "C":
    check connectRequest == "C"
    client.close()
    return
  while not connectRequest.endsWith("\r\n\r\n"):
    connectRequest.add await client.recv(1)
  check ("CONNECT localhost:" & $int(port) & " HTTP/1.1") in connectRequest
  check ("proxy-authorization: basic " & encode("user:pass")).toLowerAscii() in
    connectRequest.toLowerAscii()
  await client.send("HTTP/1.1 200 Connection established\r\n\r\n")

  let context = newContext(certFile = tlsFixtures / "localhost.crt",
    keyFile = tlsFixtures / "localhost.key", verifyMode = CVerifyNone)
  try:
    context.wrapConnectedSocket(client, handshakeAsServer)
    result = await client.recv(4096)
    if result.len > 0:
      check "cookie: secure=wss" in result.toLowerAscii()
      var key = ""
      for line in result.split("\r\n"):
        if line.toLowerAscii().startsWith("sec-websocket-key:"):
          key = line.split(':', maxsplit = 1)[1].strip()
      await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
        "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n" &
        "Set-Cookie: secure=stored; Path=/; Secure\r\n\r\n" &
        "\x81\x02ok")
  except CatchableError:
    result = ""
  client.close()

proc tlsServerScenario(server: AsyncSocket): Future[string] {.async.} =
  let accepted = await server.acceptAddr()
  let client = accepted.client
  let context = newContext(
    certFile = tlsFixtures / "localhost.crt",
    keyFile = tlsFixtures / "localhost.key",
    verifyMode = CVerifyNone)
  try:
    context.wrapConnectedSocket(client, handshakeAsServer)
    result = await client.recv(4096)
    if result.len > 0:
      var key = ""
      for line in result.split("\r\n"):
        if line.toLowerAscii().startsWith("sec-websocket-key:"):
          key = line.split(':', maxsplit = 1)[1].strip()
      let response = "HTTP/1.1 101 Switching Protocols\r\n" &
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
        "Sec-WebSocket-Accept: " & ws.acceptKey(key) & "\r\n\r\n" &
        "\x81\x02ok"
      await client.send(response)
  except CatchableError:
    result = ""
  client.close()

proc transportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = serverScenario(server)

  var options = ws.defaultOptions()
  options.maxMessageSize = 1
  options.allow = proc(request: ws.HandshakeRequest): bool =
    request.url.startsWith("ws://127.0.0.1:") and
      request.headers.anyIt(it.name.toLowerAscii() == "authorization" and
                            it.value == "Bearer local-test")
  let request = ws.HandshakeRequest(
    url: "ws://127.0.0.1:" & $address[1] & "/live",
    headers: @[ws.Header(name: "Authorization", value: "Bearer local-test")])
  let connection = await ws.dialAsync(options, request, @["prices.v1"], newCtx())
  check connection.protocol == "prices.v1"
  let message = await connection.readMessage()
  check message.opcode == 1'u8
  check message.payload == @[byte('x')]
  await serving
  connection.terminate()
  server.close()

proc cookieJarTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = cookieJarScenario(server)
  var askedUrls: seq[Uri]
  var storedUrls: seq[Uri]
  var storedCookies: seq[seq[string]]
  var options = ws.defaultOptions()
  options.cookieJar = ws.CookieJar(
    cookies: proc(url: Uri): seq[string] =
      askedUrls.add url
      @[
        "jar=from-app",
      ],
    store: proc(url: Uri; setCookieHeaders: seq[string]) =
      storedUrls.add url
      storedCookies.add setCookieHeaders
  )
  options.allow = proc(request: ws.HandshakeRequest): bool =
    for header in request.headers:
      check "jar=from-app" notin header.value
    true
  let request = ws.HandshakeRequest(
    url: "ws://127.0.0.1:" & $address[1] & "/cookie",
    headers: @[ws.Header(name: "Cookie", value: "explicit=yes")])
  let connection = await ws.dialAsync(options, request, @[], newCtx())
  check (await connection.readMessage()).payload == @[byte('c')]
  connection.terminate()
  await serving
  check askedUrls.len == 1
  check askedUrls[0].scheme == "http"
  check askedUrls[0].path == "/cookie"
  check storedUrls == askedUrls
  check storedCookies == @[@[
    "session=abc; Path=/; HttpOnly",
    "theme=dark; SameSite=Lax",
  ]]
  server.close()

proc rejectedCookieJarTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = cookieRejectedScenario(server)
  var storedCookies: seq[string]
  var options = ws.defaultOptions()
  options.cookieJar = ws.CookieJar(
    cookies: proc(url: Uri): seq[string] = @[],
    store: proc(url: Uri; setCookieHeaders: seq[string]) =
      storedCookies = setCookieHeaders
  )
  var connection: ws.WebSocketConn
  try:
    connection = await ws.dialAsync(options,
      ws.HandshakeRequest(url: "ws://127.0.0.1:" & $address[1] & "/rejected"),
      @[], newCtx())
  except CatchableError:
    discard
  check connection == nil
  await serving
  check storedCookies == @["rejected=stored; Path=/"]
  server.close()

proc customTransportScenario(): Future[void] {.async.} =
  var calls = 0
  var observed: ws.TransportRequest
  var askedUrl: Uri
  var storedCookies: seq[string]
  var incoming = "\x81\x01r"
  var outgoing = ""
  var closed = false
  let receive = proc(maxBytes: int; ctx: CancelCtx): Future[string] {.async.} =
    if incoming.len == 0: return ""
    let count = min(maxBytes, incoming.len)
    result = incoming[0..<count]
    incoming.delete(0..<count)
  let send = proc(data: string; ctx: CancelCtx): Future[void] {.async.} =
    outgoing.add data
  let closeStreamCallback = proc() = closed = true
  let stream = ws.newDuplexStream(receive, send, closeStreamCallback)
  var options = ws.defaultOptions()
  options.proxy = newProxy("https://127.0.0.1:1")
  options.cookieJar = ws.CookieJar(
    cookies: proc(url: Uri): seq[string] =
      askedUrl = url
      @["jar=custom"],
    store: proc(url: Uri; setCookieHeaders: seq[string]) =
      storedCookies = setCookieHeaders
  )
  options.allow = proc(request: ws.HandshakeRequest): bool =
    for header in request.headers:
      check "jar=custom" notin header.value
    true
  let roundTrip = proc(request: ws.TransportRequest; ctx: CancelCtx):
      Future[ws.TransportResponse] {.async.} =
    inc calls
    observed = request
    var key = ""
    for header in request.headers:
      if header.name.toLowerAscii() == "sec-websocket-key": key = header.value
    ws.TransportResponse(statusCode: 101, statusText: "Switching Protocols",
      headers: @[
        ws.Header(name: "Upgrade", value: "websocket"),
        ws.Header(name: "Connection", value: "keep-alive, Upgrade"),
        ws.Header(name: "Sec-WebSocket-Accept", value: ws.acceptKey(key)),
        ws.Header(name: "Sec-WebSocket-Protocol", value: "custom.v1"),
        ws.Header(name: "Set-Cookie", value: "server=custom; Path=/"),
      ], stream: stream, readBuffer: "\x81\x01b")
  options.transport = roundTrip

  let request = ws.HandshakeRequest(
    url: "wss://example.invalid/custom?mode=1",
    headers: @[ws.Header(name: "X-Client", value: "mynim")])
  let connection = await ws.dialAsync(options, request, @["custom.v1"], newCtx())
  check calls == 1
  check observed.httpMethod == "GET"
  check observed.url.scheme == "https"
  check observed.url.hostname == "example.invalid"
  check observed.url.path == "/custom"
  check observed.host == "example.invalid"
  check observed.headers.anyIt(it.name.toLowerAscii() == "x-client" and
    it.value == "mynim")
  check observed.headers.anyIt(it.name.toLowerAscii() == "cookie" and
    it.value == "jar=custom")
  check askedUrl.scheme == "https"
  check storedCookies == @["server=custom; Path=/"]
  check connection.protocol == "custom.v1"
  check (await connection.readMessage()).payload == @[byte('b')]
  check (await connection.readMessage()).payload == @[byte('r')]
  await connection.close(1000)
  check outgoing.len >= 6
  connection.terminate()
  check closed

proc customTransportCancellationScenario(): Future[void] {.async.} =
  let ctx = newCtx()
  let pendingRead = newFuture[string]("custom transport read")
  var closed = false
  let receive = proc(maxBytes: int; readCtx: CancelCtx): Future[string] =
    pendingRead
  let send = proc(data: string; sendCtx: CancelCtx): Future[void] {.async.} =
    discard
  let closeStreamCallback = proc() =
    closed = true
    if not pendingRead.finished:
      pendingRead.fail(newException(IOError, "custom stream closed"))
  let stream = ws.newDuplexStream(receive, send, closeStreamCallback)
  var options = ws.defaultOptions()
  options.transport = proc(request: ws.TransportRequest; roundTripCtx: CancelCtx):
      Future[ws.TransportResponse] {.async.} =
    var key = ""
    for header in request.headers:
      if header.name.toLowerAscii() == "sec-websocket-key": key = header.value
    ws.TransportResponse(statusCode: 101,
      headers: @[
        ws.Header(name: "Upgrade", value: "websocket"),
        ws.Header(name: "Connection", value: "Upgrade"),
        ws.Header(name: "Sec-WebSocket-Accept", value: ws.acceptKey(key)),
      ], stream: stream)
  let connection = await ws.dialAsync(options,
    ws.HandshakeRequest(url: "ws://example.invalid/cancel"), @[], ctx)
  let cancelLater = proc(): Future[void] {.async.} =
    await sleepAsync(20)
    ctx.cancel()
  asyncCheck cancelLater()
  var canceled = false
  try:
    discard await connection.readMessage()
  except ValueError as error:
    canceled = "canceled" in error.msg
  check canceled
  check closed

proc httpProxyTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = httpProxyScenario(server)
  let saved = saveEnvironment(["http_proxy", "HTTP_PROXY", "https_proxy",
    "HTTPS_PROXY", "no_proxy", "NO_PROXY", "REQUEST_METHOD"])
  defer: restoreEnvironment(saved)
  putEnv("http_proxy", "http://user:pass@127.0.0.1:" & $address[1])
  putEnv("HTTP_PROXY", "")
  putEnv("https_proxy", "")
  putEnv("HTTPS_PROXY", "")
  putEnv("no_proxy", "")
  putEnv("NO_PROXY", "")
  putEnv("REQUEST_METHOD", "")
  var options = ws.defaultOptions()
  let request = ws.HandshakeRequest(url: "ws://example.invalid/live")
  let connection = await ws.dialAsync(options, request, @[], newCtx())
  let message = await connection.readMessage()
  check message.payload == @[byte('x')]
  connection.terminate()
  await serving
  server.close()

proc socks5ProxyTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = socks5ProxyScenario(server)
  var options = ws.defaultOptions()
  options.proxy = newProxy("socks5://user:pass@127.0.0.1:" & $address[1])
  let request = ws.HandshakeRequest(url: "ws://example.invalid/live")
  let connection = await ws.dialAsync(options, request, @[], newCtx())
  let message = await connection.readMessage()
  check message.payload == @[byte('x')]
  connection.terminate()
  await serving
  server.close()

proc httpsProxyTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = httpsForwardProxyScenario(server)
  var options = ws.defaultOptions()
  options.proxy = newProxy("https://localhost:" & $address[1])
  options.tlsContext = newContext(caFile = tlsFixtures / "localhost.crt")
  let connection = await ws.dialAsync(options,
    ws.HandshakeRequest(url: "ws://example.invalid/live"), @[], newCtx())
  check (await connection.readMessage()).payload == @[byte('h')]
  connection.terminate()
  await serving
  server.close()

proc wssHttpProxyTransportScenario(): Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = tlsProxyScenario(server, address[1])
  var options = ws.defaultOptions()
  options.proxy = newProxy("http://user:pass@127.0.0.1:" & $address[1])
  options.tlsContext = newContext(caFile = tlsFixtures / "localhost.crt")
  var askedUrl: Uri
  var storedCookies: seq[string]
  options.cookieJar = ws.CookieJar(
    cookies: proc(url: Uri): seq[string] =
      askedUrl = url
      @["secure=wss"],
    store: proc(url: Uri; setCookieHeaders: seq[string]) =
      storedCookies = setCookieHeaders
  )
  let request = ws.HandshakeRequest(
    url: "wss://localhost:" & $address[1] & "/live",
    headers: @[ws.Header(name: "Authorization", value: "Bearer proxy-test")])
  let connection = await ws.dialAsync(options, request, @[], newCtx())
  check (await connection.readMessage()).payload == @[byte('o'), byte('k')]
  connection.terminate()
  let received = await serving
  check "authorization: bearer proxy-test" in received.toLowerAscii()
  check askedUrl.scheme == "https"
  check askedUrl.path == "/live"
  check storedCookies == @["secure=stored; Path=/; Secure"]
  server.close()

proc tlsTransportScenario(host: string; expectedSuccess: bool):
    Future[void] {.async.} =
  let server = newAsyncSocket(domain = AF_INET, buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let address = server.getLocalAddr()
  let serving = tlsServerScenario(server)

  var options = ws.defaultOptions()
  options.tlsContext = newContext(caFile = tlsFixtures / "localhost.crt")
  let request = ws.HandshakeRequest(
    url: "wss://" & host & ":" & $address[1] & "/live",
    headers: @[ws.Header(name: "Authorization", value: "Bearer secret")])
  var connection: ws.WebSocketConn
  try:
    connection = await ws.dialAsync(options, request, @[], newCtx())
  except CatchableError:
    discard

  let received = await serving
  if expectedSuccess:
    check connection != nil
    check "Authorization: Bearer secret" in received
    let message = await connection.readMessage()
    check message.payload == @[byte('o'), byte('k')]
    connection.terminate()
  else:
    check connection == nil
    check "authorization:" notin received.toLowerAscii()
  server.close()

suite "WebSocket transport":
  test "validates the RFC accept key and close codes":
    check ws.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    check ws.validCloseCode(1000)
    check ws.validCloseCode(3001)
    check not ws.validCloseCode(1006)
    check ws.parseClose([]).code == 1005

  test "opens a local connection, checks headers, and answers a ping":
    waitFor transportScenario()

  test "delegates handshakes to a caller-supplied round trip":
    waitFor customTransportScenario()
    waitFor customTransportCancellationScenario()

  test "uses app-managed cookie jars for handshake requests and responses":
    waitFor cookieJarTransportScenario()
    waitFor rejectedCookieJarTransportScenario()

  test "uses authenticated HTTP and SOCKS proxies for ws and wss":
    waitFor httpProxyTransportScenario()
    waitFor socks5ProxyTransportScenario()
    waitFor httpsProxyTransportScenario()
    waitFor wssHttpProxyTransportScenario()

  test "validates TLS chains and hostnames before sending headers":
    waitFor tlsTransportScenario("localhost", expectedSuccess = true)
    waitFor tlsTransportScenario("127.0.0.1", expectedSuccess = false)
