## ipc.go — typed calls between the pages and the app, and typed
## events the other way.
##
## Go binds services by reflection; Nim binds them by registration:
## `bind` takes the service's name and its methods, each of which
## receives a CallContext (the calling window and page, and the call's
## cancellation context) and the call's arguments as JSON, and returns
## its result as JSON or an error. Since that handler signature does not
## retain Nim argument types, `bindTypeScript` supplies optional client
## signatures; unannotated methods remain `unknown` in the generated client.

type
  CallContext* = ref object
    ## The context of a call of a bound method.
    window*: Window ## the window whose page called (its top window)
    page*: Page     ## the page that called (a web view's counts)
    pageCtx*: CancelCtx ## canceled when the page navigates
    ctx*: CancelCtx ## the call's context: the page's, canceled too
                    ## when a channel of the call closes
    token*: string  ## the page's secret (for its channels)
    chanArgs: seq[ref ChannelObj]

  BoundMethod* = proc(c: CallContext; args: seq[JsonNode]):
    tuple[v: JsonNode, err: ref CatchableError] {.closure.}
    ## Runs on a call thread: shared state it touches is its own to
    ## guard.

  TypeScriptParam* = object
    ## Type metadata for one argument of a bound method. Supply the
    ## TypeScript type expression used by the generated client.
    name*: string
      ## The argument name; empty uses `argN`.
    tsType*: string
      ## The TypeScript type expression, e.g. `string` or `{ id: number }`.
    channel*: bool
      ## Wraps the type in `Channel<...>` and marks the IPC argument as a channel.

  IpcMethod = object
    service*, name*: string
    fn*: BoundMethod
    ## chans marks the parameters that are channels (Channel[T]), if
    ## any is (streams).
    chans: seq[bool]
    streams: bool
    tsParams: seq[TypeScriptParam]
    tsResult: string
    hasTsSignature: bool

  IpcService = object
    name*: string
    methods*: seq[ref IpcMethod]
    internal*: bool

  EventInfo = object
    name: string
    tsType: string

var ipcMu: Lock
var ipcServices: seq[ref IpcService]
var ipcMethods: Table[string, ref IpcMethod]
var ipcEvents: seq[ref EventInfo]
initLock(ipcMu)

## bind exposes the methods of a service to the frontend. The generated
## TypeScript client (see `mynim generate`) turns
##
##   proc greet*(g: Greeter; name: string): tuple[v: JsonNode, err: ...]
##
## into a typed `Greeter.greet(name: string): Promise<string>` call.
##
## Arguments and results are encoded as JSON. A method receives the
## call's CallContext: ctx is canceled when the calling page navigates
## away or its window closes, and callerWindow returns the calling
## window from it. A non-nil error rejects the promise on the
## JavaScript side. Calls run on their own threads.
##
## The service is named by name; bind raises if the name is taken.
## (Written `bind` like Go's Bind; the backticks escape the Nim
## keyword.)
proc `bind`*(name: string; methods: openArray[tuple[name: string,
    fn: BoundMethod]]; internal = false) =
  ## Registers methods under the service's name.
  if name == "":
    raise newException(ValueError, "mynim: cannot bind: service has no name")
  if methods.len == 0:
    raise newException(ValueError, "mynim: " & name & " has no methods to bind")
  var svc = (ref IpcService)(name: name, internal: internal)
  acquire(ipcMu)
  defer: release(ipcMu)
  for x in ipcServices:
    if x.name == name:
      raise newException(ValueError,
        "mynim: a service named " & name & " is already bound")
  for m in methods:
    var mi = (ref IpcMethod)(service: name, name: m.name, fn: m.fn)
    svc.methods.add mi
    ipcMethods[name & "." & m.name] = mi
  ipcServices.add svc

## bindChannelParam declares which parameters of methods are channels:
## their positions (after any leading context), in call order. The page
## passes the id of its Channel for them; the method gets a Channel[T]
## through channelArg.
proc bindChannels*(service, meth: string; positions: openArray[int]) =
  acquire(ipcMu)
  defer: release(ipcMu)
  let mi = ipcMethods.getOrDefault(service & "." & meth)
  if mi == nil: return
  var chans: seq[bool]
  for p in positions:
    if p < 0:
      raise newException(ValueError, "mynim: channel argument position cannot be negative")
    if mi.hasTsSignature and p >= mi.tsParams.len:
      raise newException(ValueError,
        "mynim: channel argument position is outside the TypeScript signature")
    if p >= chans.len:
      chans.setLen(p + 1)
    chans[p] = true
  if mi.hasTsSignature:
    chans.setLen(mi.tsParams.len)
    for i in 0 ..< mi.tsParams.len:
      mi.tsParams[i].channel = chans[i]
  mi.chans = chans
  mi.streams = positions.len > 0

proc bindTypeScript*(service, meth: string;
    params: openArray[TypeScriptParam]; resultType = "void") =
  ## Adds TypeScript parameter and result types to a method registered
  ## with `bind`. The values are TypeScript type expressions; this API
  ## is needed because a BoundMethod's JSON signature does not retain
  ## the Nim types behind its handler.
  if resultType.strip().len == 0:
    raise newException(ValueError, "mynim: TypeScript result type cannot be empty")
  var chans = newSeq[bool](params.len)
  for i, p in params.pairs:
    if p.tsType.strip().len == 0:
      raise newException(ValueError,
        "mynim: TypeScript parameter " & $i & " type cannot be empty")
    chans[i] = p.channel
  acquire(ipcMu)
  defer: release(ipcMu)
  let mi = ipcMethods.getOrDefault(service & "." & meth)
  if mi == nil:
    raise newException(ValueError,
      "mynim: cannot set TypeScript signature for unbound method " &
      service & "." & meth)
  mi.tsParams = @params
  mi.tsResult = resultType
  mi.hasTsSignature = true
  mi.chans = chans
  mi.streams = chans.anyIt(it)

proc lookupMethod(name: string): ref IpcMethod =
  acquire(ipcMu)
  result = ipcMethods.getOrDefault(name)
  release(ipcMu)

## channelArg gives the method the channel the page passed as argument
## i, for methods bound with bindChannels.
proc channelArg*[T](c: CallContext; i: int): Channel[T] =
  if i < 0 or i >= c.chanArgs.len:
    return nil
  Channel[T](c: c.chanArgs[i])

## --- worker threads ---

## Calls run off the main thread, as Go's `go handleCall(...)` does.
## Nim closures cannot travel a raw Thread, so the closure is kept in
## the registry the worker keys into.

var
  callWorkersMu: Lock
  callWorkers: seq[Thread[int]]
  callQueue: system.Channel[int]
  callQueueOpen: bool
  callNext: int
  callTasks: Table[int, proc() {.closure.}]

proc callWorker(id0: int) {.thread.} =
  {.gcsafe.}:
    while true:
      let id = callQueue.recv()
      callWorkersMu.acquire()
      let f = callTasks.getOrDefault(id)
      if callTasks.hasKey(id):
        callTasks.del(id)
      callWorkersMu.release()
      if f != nil:
        try:
          cast[proc() {.gcsafe.}](f)()
        except CatchableError:
          discard

proc goAsync(fn: proc() {.closure.}) =
  ## Runs fn on a call thread, as `go fn()` does. Callers keep their
  ## shared state behind locks; the worker casts the proc into the
  ## gcsafe frame the thread needs.
  callWorkersMu.acquire()
  if not callQueueOpen:
    callQueue.open()
    callQueueOpen = true
    for _ in 0 ..< 8:
      var t: Thread[int]
      createThread(t, callWorker, 0)
      callWorkers.add t
  inc callNext
  let id = callNext
  callTasks[id] = fn
  callWorkersMu.release()
  callQueue.send(id)

## goAsyncUnsafe is goAsync at call sites whose body was written for
## a non-gcsafe frame; the work it runs is the same.
proc goAsyncUnsafe(fn: proc() {.closure.}) = goAsync(fn)

## --- message framing ---

proc messageLen(m: Message): int = m.head.len + m.value.len + m.tail.len

proc appendBytes(b: var seq[byte]; s: string) =
  if s.len > 0:
    let n = b.len
    b.setLen(n + s.len)
    copyMem(b[n].addr, s.cstring, s.len)

proc messageAppendTo(m: Message; b: var seq[byte]) =
  b.appendBytes m.head
  b.appendBytes m.value
  b.appendBytes m.tail

proc encodeReply(id: int64; token: string; v: JsonNode;
    err0: ref CatchableError): Message =
  var err = err0
  var b = newStringOfCap(96)
  b.add """{"t":"reply","id":"""
  b.add $id
  b.add ""","k":"""
  b.add escapeJson(token)
  if err == nil:
    var payload: string
    try:
      payload = if v == nil: "null" else: $v
    except CatchableError as e:
      err = newException(ValueError, "cannot encode result: " & e.msg)
    if err == nil:
      return Message(head: b & ""","ok":true,"v":""",
        value: payload, tail: closeBrace)
  b.add ""","ok":false,"e":"""
  b.add escapeJson(if err != nil: err.msg else: "unknown")
  Message(head: b & "}")

proc encodeEvent(name: string; payload: JsonNode):
    tuple[msg: Message, err: ref CatchableError] =
  var p: string
  try:
    p = if payload == nil: "null" else: $payload
  except CatchableError as e:
    return (Message(), newException(ValueError,
      "mynim: cannot encode event " & name.escape() & ": " & e.msg))
  var b = newStringOfCap(name.len + 32)
  b.add """{"t":"event","n":"""
  b.add escapeJson(name)
  b.add ""","p":"""
  (Message(head: b, value: p,
    tail: closeBrace), nil)

## decodeResult decodes the JSON result of eval into a JsonNode.
proc decodeResult(raw: seq[byte]): tuple[v: JsonNode,
    err: ref CatchableError] =
  if raw.len == 0:
    return (nil, nil)
  var s = newString(raw.len)
  if raw.len > 0:
    copyMem(s.cstring, raw[0].addr, raw.len)
  try:
    (parseJson(s), nil)
  except CatchableError as e:
    (nil, e)

## --- caller identity ---

## callerKey and pageKey identify the values resetPage puts in a
## page's context, as Go's empty-struct context keys do: their
## addresses are the keys.
var callerKey: byte
var pageKey: byte


## callerWindow returns the window whose page called a bound method,
## given the CallContext passed to it: for the page of a web view, the
## window it is in.
proc callerWindow*(c: CallContext): Window =
  if c == nil: nil else: c.window

## callerPage returns the page that called a bound method: the page of
## the calling window, or of a web view in it, whose window
## callerWindow returns.
proc callerPage*(c: CallContext): Page =
  if c == nil: nil else: c.page

## --- dispatch ---

## call calls the method for the page of w whose context is page and
## whose token is token.
proc ipcCall(mi: ref IpcMethod; w: Window; page: CancelCtx;
    token: string; args: seq[JsonNode]): tuple[v: JsonNode,
    err: ref CatchableError] =
  var ctx = page
  var cancel: proc() = nil
  var chans: seq[ref ChannelObj]
  let c = CallContext(window: w.top(), page: w.pg, pageCtx: page,
      token: token)
  if mi.streams:
    ## The page closing a channel cancels the call. The channels close
    ## when it returns, before its result is sent.
    (ctx, cancel) = withCancel(page)
    c.ctx = ctx
    defer:
      for ch in chans:
        channelClose(ch, chanClosedByGo)
      if cancel != nil:
        cancel()
  else:
    c.ctx = page
  var callArgs = args
  if mi.streams:
    ## Channel parameters carry the page's channel id.
    var real = newSeq[JsonNode]()
    for i, a in args.pairs:
      if i < mi.chans.len and mi.chans[i]:
        let id = if a == nil or a.kind != JInt: 0 else: a.getBiggestInt()
        if id <= 0:
          return (nil, newException(ValueError,
            "invalid argument " & $(i+1) & ": not a Channel"))
        let ch = newChannel(w, page, ctx, cancel, id, token)
        chans.add ch
        c.chanArgs.add ch
        real.add a ## keep the id for the record
      else:
        real.add a
    callArgs = real
  try:
    mi.fn(c, callArgs)
  except CatchableError as e:
    (nil, newException(ValueError, "panic: " & e.msg))

## handleCall decodes and runs a call from the page on a call thread,
## then queues the reply. Calls from untrusted pages are rejected.
proc handleCall(w: Window; ctx: CancelCtx; raw: string; trusted: bool) =
  var m: JsonNode
  try:
    m = parseJson(raw)
  except CatchableError as e:
    stderr.writeLine("mynim: malformed call from window " & $w.id &
      ": " & e.msg)
    return
  let
    id = m{"id"}.getBiggestInt(0)
    token = m{"k"}.getStr("")
    name = m{"m"}.getStr("")
  var args: seq[JsonNode]
  if m{"a"} != nil and m{"a"}.kind == JArray:
    args = m{"a"}.getElems()
  var result: JsonNode
  var err: ref CatchableError
  if not trusted:
    err = newException(ValueError,
      "this page is not allowed to call methods (see PageOptions.trustedOrigins)")
  else:
    let mi = lookupMethod(name)
    if mi == nil:
      err = newException(ValueError, name & " is not bound")
    else:
      (result, err) = ipcCall(mi, w, ctx, token, args)
  w.enqueue(encodeReply(id, token, result, err), false)

## --- Event[T] ---

## Event is a typed event the app sends to pages. Declare events at
## module level so `mynim generate` includes them in the TypeScript
## client:
##
##   var Progress* = newEvent[JsonNode]("progress")
##   Progress.emit(win, %*{"done": 1, "total": 3})
##
## and subscribe in the frontend with `events.progress.on(p => ...)`.
proc newEvent*[T](name: string; typeScriptType = "unknown"): Event[T] =
  ## Declares an event with payload type T. Names must be unique;
  ## those starting with "mynim:" are reserved. `typeScriptType` is
  ## used for the payload type in the generated TypeScript client.
  if name.startsWith("mynim:") or name.startsWith("mygo:"):
    raise newException(ValueError, "mynim: event " & name.escape() &
      ": names starting with \"mynim:\" are reserved")
  if typeScriptType.strip().len == 0:
    raise newException(ValueError, "mynim: TypeScript event type cannot be empty")
  acquire(ipcMu)
  defer: release(ipcMu)
  for e in ipcEvents:
    if e.name == name:
      raise newException(ValueError, "mynim: event " & name.escape() &
        " is already declared")
  ipcEvents.add (ref EventInfo)(name: name, tsType: typeScriptType)
  Event[T](name: name)

proc name*[T](e: Event[T]): string = e.name

## emit sends the event to the page shown in w, or to the pages of the
## web views of a window showing native UI (WebView). Events sent
## before the page's DOM is ready are delivered once it is.
proc emit*[T](e: Event[T]; w: Window; payload: T): ref CatchableError =
  let (msg, err) = encodeEvent(e.name, `%`(payload))
  if err != nil:
    return err
  if w.isDestroyed():
    return newException(ValueError, "mynim: window has been destroyed")
  if w.content != nil:
    windows.mu.acquire()
    let views = w.webViews
    windows.mu.release()
    for v in views:
      v.enqueue(msg, true)
    return nil
  w.enqueue(msg, true)

## emitPage sends the event to a page: of a window, or of a web view
## (WebView.page).
proc emitPage*[T](e: Event[T]; p: Page; payload: T): ref CatchableError =
  let (msg, err) = encodeEvent(e.name, `%`(payload))
  if err != nil:
    return err
  if p == nil or p.w.isDestroyed():
    return newException(ValueError, "mynim: window has been destroyed")
  p.w.enqueue(msg, true)

## broadcast sends the event to every window, and the web views in
## them.
proc broadcast*[T](e: Event[T]; payload: T): ref CatchableError =
  let (msg, err) = encodeEvent(e.name, `%`(payload))
  if err != nil:
    return err
  for w in pageWindows():
    w.enqueue(msg, true)

## --- window.mygo.window ---

## The internal service backing window.mygo.window in the page.
proc bindWindowControls() =
  proc ctrl(fn: proc(w: Window)): BoundMethod =
    proc(c: CallContext; a: seq[JsonNode]):
        tuple[v: JsonNode, err: ref CatchableError] {.closure.} =
      fn(callerWindow(c))
      (nil, nil)
  `bind`("mynim:window", [
    ("minimize", ctrl(proc(w: Window) = w.minimize())),
    ("maximize", ctrl(proc(w: Window) = w.maximize())),
    ("unmaximize", ctrl(proc(w: Window) = w.unmaximize())),
    ("toggleMaximize", ctrl(proc(w: Window) = w.toggleMaximize())),
    ("isMaximized", proc(c: CallContext; a: seq[JsonNode]):
        tuple[v: JsonNode, err: ref CatchableError] {.closure.} =
      (%callerWindow(c).isMaximized(), nil)),
    ("toggleFullScreen", ctrl(proc(w: Window) = w.toggleFullScreen())),
    ("close", ctrl(proc(w: Window) = w.close())),
    ("setTitle", proc(c: CallContext; a: seq[JsonNode]):
        tuple[v: JsonNode, err: ref CatchableError] {.closure.} =
      callerWindow(c).setTitle(if a.len > 0: a[0].getStr() else: "")
      (nil, nil)),
  ], internal = true)
