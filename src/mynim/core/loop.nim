## mygo.go + loop.go — version, the lazy backend, and the main-thread
## queue.

## version is the MyNim version (tracking MyGo's).
const Version* = "0.4.8"

var
  backendLock: Lock
  backendMade: bool
  theBackend: platform.Backend

when defined(emscripten):
  proc newBackend(): platform.Backend =
    platform.Backend(web.newWebBackend())
elif defined(macosx):
  proc newBackend(): platform.Backend =
    platform.Backend(darwin.newBackend())
elif defined(linux):
  proc newBackend(): platform.Backend =
    platform.Backend(linux.newBackend())
elif defined(windows):
  proc newBackend(): platform.Backend = newUnsupportedBackend()
else:
  proc newBackend(): platform.Backend = newUnsupportedBackend()

proc backend(): platform.Backend =
  ## The platform backend, created on first use.
  backendLock.acquire()
  if not backendMade:
    theBackend = newBackend()
    backendMade = true
  result = theBackend
  backendLock.release()

type MainLoop = object
  ## A FIFO of functions waiting to run on the main thread. The backend
  ## drains it (AppHandler.dispatch) whenever it has been signaled.
  mu: Lock
  queue: seq[proc() {.closure.}]
  closed: bool

var loop: MainLoop

proc post(l: var MainLoop; fn: proc() {.closure.}): bool =
  ## Schedules fn on the main thread. It reports false when the event
  ## loop has already shut down and fn will never run.
  l.mu.acquire()
  if l.closed:
    l.mu.release()
    return false
  l.queue.add fn
  let first = l.queue.len == 1
  l.mu.release()
  if first:
    backend().signal()
  true

proc drain(l: var MainLoop) =
  ## Runs queued functions, one at a time, until the queue is empty.
  ## Main thread only. A function running a loop of its own, as a
  ## context menu, a modal dialog or await does, runs those queued
  ## behind it, which it may be waiting for: the backend is signaled
  ## again while some wait.
  while true:
    l.mu.acquire()
    if l.queue.len == 0:
      l.mu.release()
      return
    let fn = l.queue[0]
    l.queue.delete(0)
    let more = l.queue.len > 0
    l.mu.release()
    if more:
      backend().signal()
    fn()

proc stopped(l: var MainLoop): bool =
  ## Whether the loop has shut down.
  l.mu.acquire()
  result = l.closed
  l.mu.release()

proc shutdown(l: var MainLoop) =
  ## Runs whatever is still queued and rejects later posts. The queue
  ## is closed in the same critical section that finds it empty, so no
  ## post is accepted without running.
  while true:
    l.drain()
    l.mu.acquire()
    if l.queue.len == 0:
      l.closed = true
      l.mu.release()
      return
    l.mu.release()

proc isMainThread*(): bool = backend().isMainThread()

proc await*[T](ch: var system.Channel[T]): T =
  ## Blocks until a value arrives on ch. On the main thread it keeps
  ## processing native events so the UI stays responsive and the value
  ## can actually be produced. Whoever sends on ch must call wake
  ## afterwards.
  if not isMainThread():
    return ch.recv()
  while true:
    let (ok, v) = ch.tryRecv()
    if ok: return v
    backend().step()

proc deliver*[T](ch: var system.Channel[T]; v: T) =
  ## Sends v on a buffered channel consumed by await and wakes the main
  ## thread in case it is waiting.
  ch.send(v)
  backend().wake()

proc runOnMain*(fn: proc() {.closure.}) =
  ## Runs fn on the main (UI) thread and waits for it to return. Use it
  ## to call native APIs directly, e.g. through Window.nativeHandle. It
  ## runs fn right away when called on the main thread, and drops it
  ## after the application has quit.
  if isMainThread():
    fn()
    return
  var doneCh: system.Channel[bool]
  doneCh.open()
  let pdone = addr doneCh
  if not loop.post(proc() =
    fn()
    deliver(pdone[], true)):
    doneCh.close()
    return
  discard doneCh.recv()
  doneCh.close()

proc postMain*(fn: proc() {.closure.}): bool =
  ## Runs fn asynchronously on the main thread; false when the loop is
  ## shut down.
  loop.post(fn)

proc onMain(fn: proc() {.closure.}) = runOnMain(fn)

proc onMainValue[T](fn: proc(): T): T =
  ## onMain for functions returning a value.
  var v: T
  let pv = addr v
  onMain(proc() = pv[] = fn())
  v

