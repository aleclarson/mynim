## channel.go — Channel streams values of type T from a bound method to
## the page that called it, like a response that arrives in parts: the
## lines a command prints, the tokens of a model's answer, the progress
## of a download. The method takes it as a parameter:
##
##   # Tail sends the lines of a command's output as it prints them.
##   method tail(s: Shell; ctx: CancelCtx; command: string;
##       lines: Channel[string]): ref CatchableError {.gcsafe.} =
##     let cmd = execCmdLine(command)
##     ... for each line: check lines.send(line)
##
## and the page passes a Channel of mynim-runtime in its place, whose
## values it iterates or handles with onmessage:
##
##   const lines = new Channel<string>();
##   const done = Shell.tail("ping -c 3 example.com", lines);
##   for await (const line of lines) output.append(line + "\n");
##   await done;
##
## Values arrive in order, and before the call's result. The channel
## closes when the method returns, or earlier with close, which ends
## the page's iteration. The page may close it too, for example by
## breaking out of the loop: send then fails and the context of the
## call is canceled, which stops the work the method passed it to.
## Navigating away and closing the window do the same.
##
## send waits while the page has more than a MiB of values yet to
## take, so a fast producer does not pile them up in memory, except
## on the main thread, which must not wait.
##
## Channels are parameters of bound methods only, never parts of
## other values.

const ErrChannelClosed* = "mynim: channel closed"

## channelWindow is how many bytes of messages with values may wait
## for the page to take them. The page acknowledges what it took when
## a value asks for it, once every half window.
const channelWindow = 1 shl 20

## Who closes a channel.
const
  chanClosedByGo* = 0     ## the method: the page is told
  chanClosedByPage* = 1   ## the page: the call is canceled
  chanClosedByLoss* = 2   ## the page went away

const closeBrace = "}"

proc channelSend(c: ref ChannelObj; p: string): ref CatchableError {.gcsafe.} =
  acquire(c.mu)
  defer: release(c.mu)
  ## Wait while the page is behind, unless that would block the main
  ## thread, which receives its acknowledgments.
  var onMainNow = false
  {.cast(gcsafe).}:
    onMainNow = isMainThread()
  while not c.closed and c.sent - c.taken >= channelWindow and
      not onMainNow:
    wait(c.cond, c.mu)
  ## The call's context may be canceled before it closed the channel.
  if c.closed or c.ctx.done():
    return newException(ValueError, ErrChannelClosed)
  inc c.`seq`
  c.sent += int64(c.head.len + p.len + 2) ## the whole message
  var head = c.head
  if c.sent - c.asked >= channelWindow div 2:
    c.asked = c.sent
    c.asks.add ChannelAsk(`seq`: c.`seq`, sent: c.sent)
    head = c.ackHead
  ## Under the lock, so values are queued in order. enqueue only takes
  ## locks and signals the loop's channel, which is safe from here.
  {.cast(gcsafe).}:
    enqueue(c.w, Message(head: head, value: p, tail: closeBrace), false)

## ack records that the page took the values up to sq.
proc channelAck(c: ref ChannelObj; sq: int64) =
  acquire(c.mu)
  while c.asks.len > 0 and c.asks[0].`seq` <= sq:
    c.taken = c.asks[0].sent
    c.asks.delete(0)
  release(c.mu)
  signal(c.cond)

proc channelClose(c: ref ChannelObj; by: int) =
  acquire(c.mu)
  if by == chanClosedByPage:
    ## Under the lock, before the channel closes: the call's context
    ## is canceled once send fails, and a call that returns as soon as
    ## it is finds the channel closed, not one whose end the page is
    ## told.
    if c.cancel != nil:
      c.cancel()
  if c.closed:
    release(c.mu)
    return
  c.closed = true
  if by == chanClosedByGo:
    ## After the values sent so far.
    let endHead = c.head[0 ..< c.head.len - ""","p":""".len] &
      ""","end":true}"""
    enqueue(c.w, Message(head: endHead), false)
  let stop = c.stop
  release(c.mu)
  signal(c.cond)
  if stop != nil:
    discard stop()
  acquire(c.w.mu)
  if c.w.channels.getOrDefault(c.id) == c:
    c.w.channels.del(c.id)
  release(c.w.mu)

## send sends v to the page. It fails once the channel is closed.
proc send*[T](ch: Channel[T]; v: T): ref CatchableError {.gcsafe.} =
  if ch.c == nil:
    return newException(ValueError, ErrChannelClosed)
  let p = try: $(%v) ## JSON text; v encodes by its fields
    except CatchableError as e:
      return newException(ValueError, "mynim: cannot encode channel value: " & e.msg)
  channelSend(ch.c, p)

## close closes the channel, which ends the page's iteration once it
## took the values sent before. It is called when the method returns.
proc close*[T](ch: Channel[T]) =
  if ch.c != nil:
    channelClose(ch.c, chanClosedByGo)

## newChannel creates the channel id of the page with token for a call
## whose context is ctx, canceled by cancel. page is the context of
## the page that made the call: after a navigation, the channel starts
## closed.
proc newChannel(w: Window; page, ctx: CancelCtx; cancel: proc() {.closure.};
    id: int64; token: string): ref ChannelObj =
  let c = (ref ChannelObj)(w: w, id: id, token: token, ctx: ctx, cancel: cancel)
  c.cond.initCond()
  var head = newStringOfCap(48 + token.len)
  head.add """{"t":"chan","c":"""
  head.add $id
  head.add ""","k":"""
  head.add escapeJson(token)
  c.ackHead = head & ""","a":1,"p":"""
  c.head = head & ""","p":"""

  acquire(w.mu)
  var early = false
  if w.pageCtx == page:
    w.channels[id] = c
    if w.closedEarly.hasKey(id) and w.closedEarly[id] == token:
      w.closedEarly.del(id)
      early = true
  else:
    c.closed = true
  release(w.mu)
  let stop = afterDone(ctx, proc() = channelClose(c, chanClosedByLoss))
  acquire(c.mu)
  c.stop = stop
  let closed = c.closed
  release(c.mu)
  if closed: # the page closed it in the meantime
    discard stop()
  if early:
    channelClose(c, chanClosedByPage)
  c

## maxClosedEarly bounds the channels a page may close before their
## calls made them.
const maxClosedEarly = 1024

## pageClosedChannel closes the channel id that the page with token
## closed. Calls make their channels on threads of their own, so the
## page may close one before its call made it, e.g. by aborting a
## request right after starting it: the call then closes it as soon as
## it makes it.
proc pageClosedChannel(w: Window; id: int64; token: string) =
  acquire(w.mu)
  let c = w.channels.getOrDefault(id)
  if c == nil:
    if w.closedEarly.len < maxClosedEarly:
      w.closedEarly[id] = token
    release(w.mu)
    return
  release(w.mu)
  if c.token == token:
    channelClose(c, chanClosedByPage)

## channel returns the channel id of the current page, if token is the
## page's.
proc channel(w: Window; id: int64; token: string): ref ChannelObj =
  acquire(w.mu)
  defer: release(w.mu)
  let c = w.channels.getOrDefault(id)
  if c != nil and c.token == token: c else: nil
