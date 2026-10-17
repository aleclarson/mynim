## events.go — preventable events and the generic listener list.

type
  Preventable* = object
    ## Embedded in events whose default action listeners can cancel.
    prevented: bool

  CloseEvent* = object
    ## Passed to Window.onClose listeners. Preventing it keeps the
    ## window open.
    preventable*: Preventable
    window*: ref RootObj ## filled in by window.nim: the closing Window

  QuitEvent* = object
    ## Passed to Application.onBeforeQuit and onWillQuit listeners.
    ## Preventing it cancels the quit.
    preventable*: Preventable

  NavigateEvent* = object
    ## Passed to Page.onWillNavigate listeners. Preventing it cancels
    ## the navigation.
    preventable*: Preventable
    url*: string
    ## userInitiated is true when the navigation was triggered by a
    ## user gesture such as clicking a link.
    userInitiated*: bool

  TitleEvent* = object
    ## Passed to Page.onPageTitleUpdated listeners. Preventing it keeps
    ## the native window title unchanged.
    preventable*: Preventable
    title*: string

  FileDropEvent* = object
    ## Passed to Window.onFileDrop listeners, and to the page's
    ## onFileDrop listeners.
    ## paths of the dropped files and directories.
    paths*: seq[string]
    ## x and y are where the files were dropped, in CSS pixels from the
    ## top-left corner of the page's viewport, like a DOM event's
    ## clientX and clientY.
    x*, y*: int

proc preventDefault*(p: var Preventable) = p.prevented = true
  ## Cancels the default action of the event.
proc defaultPrevented*(p: Preventable): bool = p.prevented
  ## Whether preventDefault was called.

proc preventDefault*(e: var CloseEvent) = e.preventable.prevented = true
proc defaultPrevented*(e: CloseEvent): bool = e.preventable.prevented
proc preventDefault*(e: var QuitEvent) = e.preventable.prevented = true
proc defaultPrevented*(e: QuitEvent): bool = e.preventable.prevented
proc preventDefault*(e: var NavigateEvent) = e.preventable.prevented = true
proc defaultPrevented*(e: NavigateEvent): bool = e.preventable.prevented
proc preventDefault*(e: var TitleEvent) = e.preventable.prevented = true
proc defaultPrevented*(e: TitleEvent): bool = e.preventable.prevented

## fileDropEvent is the name of the page event of dropped files. Names
## starting with "mygo:" are MyNim's own.
const fileDropEvent* = "mygo:file-drop"

type
  ListenerCancellation = ref object
    cancelled: Atomic[bool]

  Listener[T] = object
    cancellation: ListenerCancellation
    fn: T
    once: bool

  Listeners[T] = object
    ## A thread-safe list of event listeners of type T (a proc type).
    mu: Lock
    list: seq[Listener[T]]

proc add[T](l: var Listeners[T]; fn: T; once: bool): proc() {.closure.} =
  ## Registers fn and returns a function that removes it again.
  let cancellation = ListenerCancellation()
  l.mu.acquire()
  l.list.keepItIf(not it.cancellation.cancelled.load())
  l.list.add Listener[T](cancellation: cancellation, fn: fn, once: once)
  l.mu.release()
  # A cancellation may outlive the list that registered it.
  proc() =
    cancellation.cancelled.store(true)

proc snapshot[T](l: var Listeners[T]): seq[T] =
  ## The current listeners, dropping once-listeners from the list, so
  ## they can be called without holding the lock.
  l.mu.acquire()
  var kept: seq[Listener[T]]
  for e in l.list:
    if not e.cancellation.cancelled.load():
      result.add e.fn
      if not e.once:
        kept.add e
  l.list = kept
  l.mu.release()

proc len[T](l: var Listeners[T]): int =
  l.mu.acquire()
  for listener in l.list:
    if not listener.cancellation.cancelled.load():
      inc result
  l.mu.release()

proc clear[T](l: var Listeners[T]) =
  l.mu.acquire()
  l.list.setLen(0)
  l.mu.release()

proc fire*(l: var Listeners[proc() {.closure.}]) =
  ## Calls listeners of an event without arguments.
  for fn in l.snapshot(): fn()

proc fire1*[A](l: var Listeners[proc(a: A) {.closure.}]; a: A) =
  ## Calls listeners of an event with one argument.
  for fn in l.snapshot(): fn(a)

proc fire1*[A](l: var Listeners[proc(a: var A) {.closure.}]; a: var A) =
  ## Calls listeners of an event with one mutable argument (as Go's
  ## fire1 does with *Event).
  for fn in l.snapshot(): fn(a)
