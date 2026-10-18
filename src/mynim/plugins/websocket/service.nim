## Page-owned WebSocket connections and their IPC wire format.

import std/[asyncdispatch, base64, json, net, strutils, tables]
import core/locks

import mynim as core
import ./connection as ws

type
  Options* = ws.Options

  ConnectionKey = tuple[page: pointer, id: string]

  PendingEvent = object
    value: string
    stop: bool

  EventSender = object
    channel: core.Channel[JsonNode]
    queue: system.Channel[PendingEvent]
    mutex: Lock
    worker: Thread[ptr EventSender]
    completed: bool
    error: ref CatchableError

  Service = ref object
    options: ws.Options
    mutex: Lock
    connections: Table[ConnectionKey, ws.WebSocketConn]

const
  closeGoingAway = 1001
  closeAbnormal = 1006
  opText = 1'u8
  opBinary = 2'u8
  opClose = 8'u8

proc stringField(node: JsonNode; name, description: string): string =
  if node == nil or node.kind != JObject or not node.hasKey(name) or
      node[name].kind != JString:
    raise newException(ValueError, "websocket: " & description & " must be a string")
  node[name].getStr()

proc parseConnect(node: JsonNode): tuple[id: string, request: ws.HandshakeRequest,
                                         protocols: seq[string]] =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "websocket: connect options must be an object")
  result.id = stringField(node, "id", "connection id")
  result.request.url = stringField(node, "url", "URL")
  if node.hasKey("protocols"):
    if node["protocols"].kind != JArray:
      raise newException(ValueError, "websocket: protocols must be an array")
    for value in node["protocols"].getElems():
      if value.kind != JString:
        raise newException(ValueError, "websocket: protocols must be strings")
      result.protocols.add value.getStr()
  if node.hasKey("headers"):
    if node["headers"].kind != JArray:
      raise newException(ValueError, "websocket: headers must be an array")
    for pair in node["headers"].getElems():
      if pair.kind != JArray or pair.len != 2 or pair[0].kind != JString or
          pair[1].kind != JString:
        raise newException(ValueError, "websocket: each header must be a name/value pair")
      result.request.headers.add ws.Header(name: pair[0].getStr(),
        value: pair[1].getStr())

proc event(kind: string; protocol = ""; text = ""; data = ""; code = 0;
           reason = ""; clean = false; error = ""): JsonNode =
  result = newJObject()
  result["type"] = %kind
  if protocol.len > 0: result["protocol"] = %protocol
  if text.len > 0: result["text"] = %text
  if data.len > 0: result["data"] = %data
  if code != 0: result["code"] = %code
  if reason.len > 0: result["reason"] = %reason
  if clean: result["clean"] = %true
  if error.len > 0: result["error"] = %error

proc sendClose(channel: core.Channel[JsonNode]; message: string) =
  discard channel.send(event("close", code = closeAbnormal, error = message))

proc eventSenderWorker(state: ptr EventSender) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let pending = state.queue.recv()
      if pending.stop: break
      let error = state.channel.send(parseJson(pending.value))
      state.mutex.acquire()
      state.error = error
      state.completed = true
      state.mutex.release()

proc start(sender: var EventSender; channel: core.Channel[JsonNode]) =
  sender.channel = channel
  sender.mutex.initLock()
  sender.queue.open(1)
  createThread(sender.worker, eventSenderWorker, addr sender)

proc send(sender: ptr EventSender; connection: ws.WebSocketConn;
          value: JsonNode): Future[bool] {.async.} =
  sender.mutex.acquire()
  sender.completed = false
  sender.error = nil
  sender.mutex.release()
  sender.queue.send(PendingEvent(value: $value))
  while true:
    sender.mutex.acquire()
    let completed = sender.completed
    let failed = sender.error != nil
    sender.mutex.release()
    if completed: return not failed
    await connection.flushOutgoing()
    await sleepAsync(10)

proc stop(sender: var EventSender) =
  sender.queue.send(PendingEvent(stop: true))
  joinThread(sender.worker)
  sender.queue.close()

proc key(context: core.CallContext; id: string): ConnectionKey =
  (cast[pointer](context.page), id)

proc findConnection(service: Service; connectionKey: ConnectionKey): ws.WebSocketConn =
  service.mutex.acquire()
  result = service.connections.getOrDefault(connectionKey)
  service.mutex.release()

proc removeConnection(service: Service; connectionKey: ConnectionKey) =
  service.mutex.acquire()
  service.connections.del(connectionKey)
  service.mutex.release()

proc readMessage(value: JsonNode): tuple[kind, text: string, data: seq[byte],
                                          code: int, reason: string] =
  if value == nil or value.kind != JObject:
    raise newException(ValueError, "websocket: message must be an object")
  result.kind = stringField(value, "type", "message type")
  case result.kind
  of "text": result.text = stringField(value, "text", "text message")
  of "binary":
    let encoded = stringField(value, "data", "binary message")
    let bytes = decode(encoded)
    result.data = newSeq[byte](bytes.len)
    for i, ch in bytes: result.data[i] = byte(ch)
  of "close":
    if not value.hasKey("code") or value["code"].kind != JInt:
      raise newException(ValueError, "websocket: close code must be an integer")
    result.code = value["code"].getInt()
    result.reason = value.getOrDefault("reason").getStr("")
  of "skip": discard
  else:
    raise newException(ValueError, "websocket: unknown message type " &
      result.kind.escape())

proc connectMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    let channel = core.channelArg[JsonNode](context, 0)
    if channel == nil:
      return (newJNull(), newException(ValueError, "websocket: missing event channel"))
    var options: tuple[id: string, request: ws.HandshakeRequest,
                       protocols: seq[string]]
    try:
      if args.len == 0: raise newException(ValueError, "websocket: missing connect options")
      options = parseConnect(args[0])
    except CatchableError as error:
      sendClose(channel, error.msg)
      return (newJNull(), nil)

    var connection: ws.WebSocketConn
    try:
      connection = waitFor ws.dialAsync(service.options, options.request,
        options.protocols, context.ctx)
    except CatchableError as error:
      sendClose(channel, error.msg)
      return (newJNull(), nil)

    let connectionKey = key(context, options.id)
    service.mutex.acquire()
    let duplicate = service.connections.hasKey(connectionKey)
    if not duplicate: service.connections[connectionKey] = connection
    service.mutex.release()
    if duplicate:
      connection.terminate()
      sendClose(channel, "connection " & options.id.escape() & " is already open")
      return (newJNull(), nil)

    defer:
      service.removeConnection(connectionKey)
      connection.terminate()

    var sender: EventSender
    sender.start(channel)
    defer: sender.stop()

    if not waitFor send(addr sender, connection,
        event("open", protocol = connection.protocol)):
      waitFor connection.close(closeGoingAway)
      return (newJNull(), nil)

    while true:
      try:
        let received = waitFor connection.readMessage()
        if received.opcode == opClose:
          let closing = ws.parseClose(received.payload)
          if not connection.closing():
            waitFor connection.close(closing.code)
          discard channel.send(event("close", code = closing.code,
            reason = closing.reason, clean = true))
          break
        var sent = true
        if received.opcode == opText:
          var text = newString(received.payload.len)
          for i, value in received.payload: text[i] = char(value)
          sent = waitFor send(addr sender, connection,
            event("text", text = text))
        elif received.opcode == opBinary:
          var bytes = newString(received.payload.len)
          for i, value in received.payload: bytes[i] = char(value)
          sent = waitFor send(addr sender, connection,
            event("binary", data = encode(bytes)))
        if not sent:
          waitFor connection.close(closeGoingAway)
          break
      except CatchableError as error:
        var code = closeAbnormal
        var message = error.msg
        if error of ws.ProtocolFailure:
          let protocolError = cast[ref ws.ProtocolFailure](error)
          try: waitFor connection.close(protocolError.closeCode)
          except CatchableError: discard
        elif connection.closing():
          message = ""
        discard waitFor send(addr sender, connection,
          event("close", code = code, error = message))
        break
    (newJNull(), nil)

proc sendMethod(service: Service): core.BoundMethod =
  result = proc(context: core.CallContext; args: seq[JsonNode]):
      tuple[v: JsonNode, err: ref CatchableError] =
    try:
      if args.len < 3:
        raise newException(ValueError, "websocket: missing send arguments")
      let id = if args[0].kind == JString: args[0].getStr()
        else: raise newException(ValueError, "websocket: connection id must be a string")
      if args[1].kind != JInt:
        raise newException(ValueError, "websocket: message sequence must be an integer")
      let message = readMessage(args[2])
      let connection = service.findConnection(key(context, id))
      if connection == nil:
        raise newException(ValueError, "websocket: connection closed")
      let error = connection.send(args[1].getBiggestInt(), message.kind,
        message.text, message.data, message.code, message.reason)
      if error != nil: return (newJNull(), error)
      (newJNull(), nil)
    except CatchableError as error:
      (newJNull(), error)

proc newWebSocketPlugin*(options: ws.Options): core.Plugin =
  ## Creates a page WebSocket plugin with configurable handshake policy and limits.
  var configured = options
  if configured.maxMessageSize <= 0: configured.maxMessageSize = 64'i64 shl 20
  if configured.closeTimeoutMs <= 0: configured.closeTimeoutMs = 5000
  when defined(ssl):
    if configured.tlsContext == nil: configured.tlsContext = newContext()
  let service = Service(options: configured,
    connections: initTable[ConnectionKey, ws.WebSocketConn]())
  service.mutex.initLock()
  result.name = "websocket"
  result.service = @[
    ("Connect", connectMethod(service)),
    ("Send", sendMethod(service)),
  ]
  result.setup = proc(): ref CatchableError =
    core.bindChannels("plugin:websocket", "Connect", [1])
    nil

proc newWebSocketPlugin*(): core.Plugin =
  ## Creates a WebSocket plugin with the 64 MiB limit and five-second close timeout.
  newWebSocketPlugin(ws.defaultOptions())
