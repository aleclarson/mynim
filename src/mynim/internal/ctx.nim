## Package ctx is the subset of Go's context.Context the port needs: a
## cancellation tree with typed values looked up by key. Canceled when a
## call's page navigates or the window closes (callcontext.PageKey and
## friends).

import std/[tables, atomics]
import core/locks

type
  CancelCtx* = ref object
    ## A context: cancellation plus key/value lookup through the
    ## parent chain, like Go's context.Context.
    mu: Lock
    cv: Cond
    parent: CancelCtx
    dead: bool
    err: ref CatchableError
    children: seq[CancelCtx]
    waiters: seq[proc() {.closure.}]
    ## vals maps a key identity (the address of a key's global) to a
    ## value, as context.WithValue does.
    vals: Table[pointer, RootRef]

proc newCtx*(): CancelCtx =
  ## The background context: never canceled, holds no values.
  let c = CancelCtx()
  c.mu.initLock()
  c.cv.initCond()
  c

proc initCtx(c: CancelCtx) =
  c.mu.initLock()
  c.cv.initCond()

proc done*(c: CancelCtx): bool =
  ## Whether the context is canceled.
  if c == nil: return false
  c.mu.acquire()
  result = c.dead
  c.mu.release()

proc err*(c: CancelCtx): ref CatchableError =
  ## Why the context ended, or nil.
  if c == nil: return nil
  c.mu.acquire()
  result = c.err
  c.mu.release()

proc waitDone*(c: CancelCtx) =
  ## Blocks until the context is canceled, as <-ctx.Done() does.
  if c == nil: return
  c.mu.acquire()
  while not c.dead:
    c.cv.wait(c.mu)
  c.mu.release()

proc afterDone*(c: CancelCtx; w: proc() {.closure.}): proc(): bool {.closure.} =
  ## Runs w once the context is done — right away when it already is.
  ## The result stops the waiting, reporting whether w had run: it is
  ## context.AfterFunc's stop function.
  let ran = new(Atomic[bool])
  ran[].store(false)
  ## The stored callback checks ran, so a stopped waiter stays a
  ## no-op — removing it from the context would take identity, which
  ## closures do not carry.
  proc wrapped() {.closure.} =
    if not ran[].exchange(true):
      w()
  proc stopProc(): bool {.closure.} =
    not ran[].exchange(true)
  if c == nil:
    wrapped()
    return stopProc
  c.mu.acquire()
  let dead = c.dead
  if not dead:
    c.waiters.add wrapped
  c.mu.release()
  if dead:
    wrapped()
  stopProc

proc cancel*(c: CancelCtx; err: ref CatchableError = nil) =
  ## Cancels the context and its children.
  if c == nil: return
  var kids: seq[CancelCtx]
  var ws: seq[proc() {.closure.}]
  c.mu.acquire()
  if c.dead:
    c.mu.release()
    return
  c.dead = true
  c.err = err
  kids = c.children
  c.children.setLen(0)
  ws = c.waiters
  c.waiters.setLen(0)
  c.cv.broadcast()
  c.mu.release()
  for w in ws:
    w()
  for k in kids:
    k.cancel(err)

proc withCancel*(c: CancelCtx): (CancelCtx, proc() {.closure.}) =
  ## A child context canceled with it or by the returned proc.
  let child = CancelCtx(parent: c)
  child.initCtx()
  if c != nil:
    c.mu.acquire()
    if c.dead:
      c.mu.release()
      child.cancel()
      return (child, proc() = discard)
    c.children.add child
    c.mu.release()
  let ch = child
  (child, proc() = ch.cancel())

proc withValue*(c: CancelCtx; key: pointer; v: RootRef): CancelCtx =
  ## A child context where key looks up v.
  let child = CancelCtx(parent: c)
  child.initCtx()
  if c != nil:
    c.mu.acquire()
    c.children.add child
    c.mu.release()
  child.vals[key] = v
  child

proc value*(c: CancelCtx; key: pointer): RootRef =
  ## Looks key up the parent chain, as context.Value does.
  var cur = c
  while cur != nil:
    cur.mu.acquire()
    if cur.vals.hasKey(key):
      result = cur.vals[key]
      cur.mu.release()
      return
    let p = cur.parent
    cur.mu.release()
    cur = p
  nil

type CanceledError* = object of CatchableError
  ## Raised when a context is canceled mid-call.

proc newCanceled*(msg = "mynim: context canceled"): ref CanceledError =
  newException(CanceledError, msg)
