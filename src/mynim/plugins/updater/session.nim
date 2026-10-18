## Thread-safe prompt session shared by the updater and its native window.

import std/locks

import mynim as app
import mynim/plugins/updater/frontend as frontend
import mynim/plugins/updater/window as window

type
  Response* = object
    action*: frontend.Action
    automaticDownloads*: bool

  Session* = ref object
    guard: Lock
    changed: Cond
    user, shown, ended: bool
    current: frontend.View
    response: Response
    responseReady: bool
    texts: frontend.Texts
    iconPng: seq[byte]
    window: window.UpdaterWindow

proc newSession*(texts: frontend.Texts; user: bool;
                 iconPng: seq[byte] = @[]): Session =
  ## Creates an update session before it has a view or window.
  result = Session(texts: texts, user: user, iconPng: iconPng)
  initLock(result.guard)
  initCond(result.changed)

proc current*(state: Session): frontend.View =
  ## Returns the current view.
  if state == nil:
    return
  acquire(state.guard)
  result = state.current
  release(state.guard)

proc user*(state: Session): bool =
  ## Reports whether the user asked for this update check.
  if state == nil:
    return false
  acquire(state.guard)
  result = state.user
  release(state.guard)

proc isShown*(state: Session): bool =
  ## Reports whether the session has opened its update window.
  if state == nil:
    return false
  acquire(state.guard)
  result = state.shown
  release(state.guard)

proc isEnded*(state: Session): bool =
  ## Reports whether the session or its window has ended.
  if state == nil:
    return true
  acquire(state.guard)
  result = state.ended
  release(state.guard)

proc setView*(state: Session; view: frontend.View) =
  ## Updates the view and advances the prompt when its buttons change.
  if state == nil:
    return
  acquire(state.guard)
  if state.ended:
    release(state.guard)
    return
  var next = view
  next.prompt = state.current.prompt
  if next.buttons != state.current.buttons:
    inc next.prompt
  state.current = next
  let updateWindow = state.window != nil
  release(state.guard)
  if updateWindow:
    discard app.postMain(proc() =
      acquire(state.guard)
      let nativeWindow = state.window
      let current = state.current
      release(state.guard)
      if nativeWindow != nil:
        nativeWindow.setView(current)
    )

proc respond*(state: Session; prompt: int; action: frontend.Action;
              automaticDownloads: bool) =
  ## Accepts one enabled button response for the current prompt.
  if state == nil:
    return
  acquire(state.guard)
  if state.ended or state.responseReady or prompt != state.current.prompt:
    release(state.guard)
    return
  var valid = false
  for button in state.current.buttons:
    if button.action == action and not button.disabled:
      valid = true
      break
  if not valid:
    release(state.guard)
    return

  inc state.current.prompt
  if action == frontend.Cancel:
    state.ended = true
  else:
    state.response = Response(action: action,
      automaticDownloads: automaticDownloads)
    state.responseReady = true
  broadcast(state.changed)
  release(state.guard)

proc wait*(state: Session): Response =
  ## Waits for a prompt response or for the session to end.
  if state == nil:
    return Response(action: frontend.Close)
  acquire(state.guard)
  while not state.ended and not state.responseReady:
    wait(state.changed, state.guard)
  if state.ended:
    result = Response(action: frontend.Close)
  else:
    result = state.response
    state.responseReady = false
  release(state.guard)

proc cancel*(state: Session) =
  ## Ends the session and wakes a waiter.
  if state == nil:
    return
  acquire(state.guard)
  state.ended = true
  let win = state.window
  broadcast(state.changed)
  release(state.guard)
  if win != nil:
    win.close()

proc close*(state: Session) =
  ## Ends the session and closes its window.
  state.cancel()

proc show*(state: Session) =
  ## Opens the native window, or promotes an existing session to foreground.
  if state == nil:
    return
  app.runOnMain(proc() =
    acquire(state.guard)
    if state.ended:
      release(state.guard)
      return
    let foreground = state.user
    if state.window == nil:
      state.window = window.newUpdaterWindow(state.texts, state.current,
        proc(prompt: int; action: frontend.Action; automaticDownloads: bool) =
          state.respond(prompt, action, automaticDownloads), foreground,
        proc() = state.cancel(), state.iconPng)
    let nativeWindow = state.window
    let current = state.current
    state.shown = true
    release(state.guard)
    nativeWindow.setView(current)
    discard nativeWindow.open(foreground)
  )

proc promote*(state: Session) =
  ## Marks a background check as user-requested and brings its window forward.
  if state == nil:
    return
  acquire(state.guard)
  state.user = true
  release(state.guard)
  state.show()

proc fit*(state: Session; width, height: int) =
  ## Resizes the session window to fit its content within updater limits.
  if state == nil:
    return
  acquire(state.guard)
  let nativeWindow = state.window
  let releaseView = state.current.release
  release(state.guard)
  if nativeWindow == nil:
    return
  let fitted = frontend.fitSize(releaseView, width, height)
  app.runOnMain(proc() =
    let native = nativeWindow.open(false)
    native.setContentSize(fitted.width, fitted.height)
  )
