import std/[asyncdispatch, asyncnet, nativesockets, net, os, sequtils,
            strutils, unittest]

import mynim/internal/ctx
import mynim/plugins/websocket/connection as ws

const tlsFixtures = currentSourcePath().parentDir / "fixtures" / "websocket"

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

  test "validates TLS chains and hostnames before sending headers":
    waitFor tlsTransportScenario("localhost", expectedSuccess = true)
    waitFor tlsTransportScenario("127.0.0.1", expectedSuccess = false)
