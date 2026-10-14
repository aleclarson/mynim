## watchdriver: the native file watchers of the backends run on one thread
## each: the thread owns the system's handles, adds and removes targets
## between waits, and reports what the system tells it.

import std/[locks, os]
import platform

## Driver is a backend's watcher. Every method but Wake runs on the
## thread of its Watch. Wait blocks until the system reports changes or
## Wake is called; an error it raises ends the watch.
type
  Driver* = ref object of RootObj
  command = object
    target: FileWatchTarget
    remove: uint64
    reply: ptr Channel[ref CatchableError]

method add*(d: Driver, t: FileWatchTarget) {.base, gcsafe.} =
  raiseAssert("Driver.add")
method remove*(d: Driver, id: uint64) {.base, gcsafe.} =
  raiseAssert("Driver.remove")
method wait*(d: Driver): seq[FileWatchNotice] {.base, gcsafe.} =
  raiseAssert("Driver.wait")
method wake*(d: Driver) {.base, gcsafe.} = discard
method close*(d: Driver) {.base, gcsafe.} = discard

## errClosedMsg is the message of what add raises once the watch has
## stopped.
const errClosedMsg* = "file watch closed"

proc errClosed(): ref IOError =
  newException(IOError, errClosedMsg)

## Watch is a platform.FileWatch running a Driver.
type Watch* = ref object of FileWatch
  driver: Driver
  notify: proc(n: FileWatchNotice)
  mu: Lock
  queue: seq[command]
  closed: bool
  finished: Channel[bool]
  thread: Thread[Watch]

proc sendCmd(w: Watch, c: command): bool =
  withLock w.mu:
    if w.closed:
      return false
    w.queue.add c
  w.driver.wake()
  true

proc run(w: Watch) {.thread.} =
  {.gcsafe.}:
    defer:
      w.driver.close()
      var d = true
      w.finished.send(d)
    while true:
      var queue: seq[command]
      var closed: bool
      withLock w.mu:
        queue = w.queue
        w.queue.setLen(0)
        closed = w.closed
      if closed:
        return
      for c in queue:
        if c.reply != nil:
          var err: ref CatchableError = nil
          try:
            w.driver.add(c.target)
          except CatchableError as e:
            err = e
          c.reply[].send(err)
        else:
          w.driver.remove(c.remove)
      var notices: seq[FileWatchNotice]
      var failed: ref CatchableError = nil
      try:
        notices = w.driver.wait()
      except CatchableError as e:
        failed = e
      {.cast(gcsafe).}:
        for n in notices:
          w.notify(n)
      if failed != nil:
        withLock w.mu:
          w.closed = true
        {.cast(gcsafe).}:
          w.notify(FileWatchNotice(err: failed))
        return

## newWatch starts the thread of d, which calls notify with what d
## reports.
proc newWatch*(d: Driver,
               notify: proc(n: FileWatchNotice)): Watch =
  let w = Watch(driver: d, notify: notify)
  w.finished.open()
  createThread(w.thread, run, w)
  w

method add*(w: Watch, t: FileWatchTarget) {.gcsafe.} =
  ## enrolls t and returns once the driver has.
  var reply: Channel[ref CatchableError]
  reply.open()
  if not w.sendCmd(command(target: t, reply: addr reply)):
    raise errClosed()
  # Wait for either the reply or the watch ending.
  while true:
    let (hasErr, err) = reply.tryRecv()
    if hasErr:
      if err != nil:
        raise err
      return
    if w.finished.tryRecv()[0]:
      raise errClosed()
    sleep(1)

method remove*(w: Watch, id: uint64) {.gcsafe.} =
  discard w.sendCmd(command(remove: id))

method close*(w: Watch) {.gcsafe.} =
  withLock w.mu:
    w.closed = true
  w.driver.wake()
  joinThread(w.thread)
