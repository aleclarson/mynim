import std/[assertions, atomics, sequtils]
import core/locks

include ../src/mynim/core/events

block cancellation_prevents_future_calls:
  var listeners: Listeners[proc() {.closure.}]
  listeners.mu.initLock()
  defer: listeners.mu.deinitLock()
  var calls = 0
  let cancel = listeners.add((proc() = inc calls), false)
  listeners.fire()
  doAssert calls == 1
  cancel()
  cancel()
  doAssert listeners.len() == 0
  listeners.fire()
  doAssert calls == 1

block once_listeners_and_clear:
  var listeners: Listeners[proc() {.closure.}]
  listeners.mu.initLock()
  defer: listeners.mu.deinitLock()
  var calls = 0
  let cancel = listeners.add((proc() = inc calls), true)
  listeners.fire()
  listeners.fire()
  doAssert calls == 1
  doAssert listeners.len() == 0
  cancel()
  discard listeners.add((proc() = inc calls), false)
  listeners.clear()
  listeners.fire()
  doAssert calls == 1

proc temporarySubscription(): proc() {.closure.} =
  var listeners: Listeners[proc() {.closure.}]
  listeners.mu.initLock()
  defer: listeners.mu.deinitLock()
  listeners.add((proc() = discard), false)

block cancellation_can_outlive_its_list:
  let cancel = temporarySubscription()
  cancel()
  cancel()
