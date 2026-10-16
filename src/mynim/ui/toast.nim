## Timed status messages built over the window's overlay layer.

const
  toastDuration = initDuration(seconds = 4)
  toastActionDuration = initDuration(seconds = 8)
  toastVisibleLimit = 3

type ToastParts* = object ## A toast's unstyled controls and remaining time.
  root*: Element
  left*: Duration
  context: Context
  toastId: string

proc addToast*(c: Context; toast: Toast): string

proc life(toast: Toast): Duration =
  if toast.timeout < initDuration():
    return initDuration()
  if toast.timeout == initDuration():
    return toastDuration
  toast.timeout

proc toastIndex(owner: ElementOwner; id: string): int =
  for index, entry in owner.toasts:
    if entry.toast.id == id:
      return index
  -1

proc toastAge(owner: ElementOwner; entry: ToastEntry; now: MonoTime): Duration =
  if owner.toastsPaused:
    entry.spent
  else:
    entry.spent + (now - entry.started)

proc pauseToasts(owner: ElementOwner; paused: bool; now: MonoTime) =
  if owner.toastsPaused == paused:
    return
  for entry in owner.toasts.mitems:
    if paused:
      entry.spent += now - entry.started
    else:
      entry.started = now
  owner.toastsPaused = paused

proc expireToasts(owner: ElementOwner; now: MonoTime) =
  var kept: seq[ToastEntry]
  var closed: seq[proc() {.closure.}]
  for entry in owner.toasts:
    let life = entry.toast.life()
    if life > initDuration() and owner.toastAge(entry, now) >= life:
      if entry.toast.onClose != nil:
        closed.add(entry.toast.onClose)
    else:
      kept.add(entry)
  owner.toasts = kept
  for callback in closed:
    callback()

proc toast*(c: Context; message: string) =
  ## Shows a four-second toast with message as both its ID and title.
  discard c.addToast(Toast(id: message, title: message))

proc toastAction*(c: Context; message, label: string;
                  action: proc() {.closure.}) =
  ## Shows a toast with an action button for eight seconds.
  discard c.addToast(Toast(id: message, title: message,
    timeout: toastActionDuration, action: label, onAction: action))

proc addToast*(c: Context; toast: Toast): string =
  ## Adds or updates a toast and returns its ID. Empty IDs are generated.
  if c == nil or c.owner == nil or c.owner.closed:
    return
  let owner = c.owner
  inc owner.nextToastIdentity
  var value = toast
  if value.id.len == 0:
    value.id = "toast-" & $owner.nextToastIdentity
  var entry = ToastEntry(toast: value,
    identity: owner.nextToastIdentity,
    started: if owner.inBuild: owner.frameNow else: getMonoTime())
  let index = owner.toastIndex(value.id)
  if index >= 0:
    entry.identity = owner.toasts[index].identity
    owner.toasts[index] = entry
  else:
    owner.toasts.add(entry)
  c.announce(value.title)
  c.announce(value.description)
  if owner.invalidate != nil:
    owner.invalidate()
  value.id

proc closeToast*(c: Context; id: string) =
  ## Closes the toast with id, or every toast when id is empty.
  if c == nil or c.owner == nil or c.owner.closed:
    return
  let owner = c.owner
  var kept: seq[ToastEntry]
  var closed: seq[proc() {.closure.}]
  for entry in owner.toasts:
    if id.len > 0 and entry.toast.id != id:
      kept.add(entry)
    elif entry.toast.onClose != nil:
      closed.add(entry.toast.onClose)
  owner.toasts = kept
  if owner.invalidate != nil:
    owner.invalidate()
  for callback in closed:
    callback()

proc focusedWithin(owner: ElementOwner; slot: int): bool =
  if not owner.focusActive or owner.focusIdentity == 0:
    return false
  var focusedSlot = -1
  for index in 1..<owner.nodes.len:
    if owner.nodes[index].identity == owner.focusIdentity:
      focusedSlot = index
      break
  while focusedSlot > 0:
    if focusedSlot == slot:
      return true
    focusedSlot = int(owner.nodes[focusedSlot].parent)
  false

proc toastBase*(c: Context; toast: Toast): ToastParts =
  ## Creates an unstyled status toast with Escape, action, and close support.
  result.context = c
  result.toastId = toast.id
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  let owner = c.owner
  let index = owner.toastIndex(toast.id)
  result.root = c.row()
  if index >= 0:
    discard result.root.key(owner.toasts[index].identity)
  else:
    discard result.root.key(toast.id)
  let node = result.root.node
  if node == nil:
    return
  node[].accessRole = platform.roleStatus
  node[].accessRoleSet = true
  owner.toastState.hovered = owner.toastState.hovered or result.root.hovered()
  owner.toastState.focused = owner.toastState.focused or
    owner.focusedWithin(int(result.root.slot))
  if index >= 0:
    let entry = owner.toasts[index]
    let age = owner.toastAge(entry, owner.frameNow)
    let life = entry.toast.life()
    if life > initDuration():
      result.left = max(life - age, initDuration())
  owner.actions.add(UiAction(identity: node[].identity,
    generation: owner.generation, kind: actionShortcut,
    key: platform.keyEscape, action: proc() = c.closeToast(toast.id)))

proc actionButton*(parts: ToastParts): Element =
  ## Creates a button that runs the toast's action and closes it.
  if parts.context == nil or parts.context.owner == nil or
      not parts.context.owner.inBuild:
    return
  result = parts.context.buttonBase()
  if result.clicked():
    let owner = parts.context.owner
    let index = owner.toastIndex(parts.toastId)
    if index >= 0 and owner.toasts[index].toast.onAction != nil:
      owner.toasts[index].toast.onAction()
    parts.context.closeToast(parts.toastId)

proc closeButton*(parts: ToastParts): Element =
  ## Creates a button that closes the toast.
  if parts.context == nil or parts.context.owner == nil or
      not parts.context.owner.inBuild:
    return
  result = parts.context.buttonBase()
  if result.clicked():
    parts.context.closeToast(parts.toastId)

proc toastViewport(c: Context; keepEmpty: bool;
                   build: proc(viewport: Element; toasts: seq[Toast])
                     {.closure.}): Element =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  let owner = c.owner
  if owner.toastViewportGeneration == owner.generation:
    return
  owner.toastViewportGeneration = owner.generation
  owner.toastState = ToastState()
  owner.expireToasts(owner.frameNow)
  if owner.toasts.len == 0 and not keepEmpty:
    owner.toastsPaused = false
    return

  var visible: seq[Toast]
  let first = max(0, owner.toasts.len - toastVisibleLimit)
  for index in first..<owner.toasts.len:
    visible.add(owner.toasts[index].toast)

  let previousParent = owner.parent
  owner.parent = 0
  try:
    let viewportElement = c.column().absolute().left(0).top(0).right(0).bottom(0)
      .justify(Align.End)
    result = viewportElement
    discard viewportElement.children(proc() =
      if build != nil:
        build(viewportElement, visible)
    )
  finally:
    owner.parent = previousParent

  let paused = not owner.focusActive or owner.toastState.hovered or
    owner.toastState.focused
  owner.pauseToasts(paused, owner.frameNow)
  if not paused:
    for entry in owner.toasts:
      if entry.toast.life() > initDuration():
        owner.animating = true
        break

proc toastViewportBase*(c: Context;
                        build: proc(viewport: Element; toasts: seq[Toast])
                          {.closure.}): Element =
  ## Builds a custom viewport, retaining its full-window layer when empty.
  c.toastViewport(true, build)

proc buildToasts(c: Context) =
  if c == nil or c.owner == nil or c.owner.closed or not c.owner.inBuild:
    return
  let theme = c.theme
  let fill = if theme.inverse.a == 0: theme.text else: theme.inverse
  let foreground = if theme.inverseText.a == 0:
      theme.background
    else:
      theme.inverseText
  discard c.toastViewport(false, proc(viewport: Element; toasts: seq[Toast]) =
    discard viewport.bottom(theme.space(6)).alignItems(Align.Center)
      .gap(theme.space(2))
    for value in toasts:
      let toast = value
      let parts = c.toastBase(toast)
      let box = parts.root.alignItems(Align.Center)
        .gap(theme.space(4)).padding(theme.space(2.5), theme.space(4))
        .radius(theme.space(2)).maxWidth(theme.space(80))
        .background(fill)
      discard box.shadow(0, 6, 20, 0, rgba(0, 0, 0, 0.25'f32))
      let fade = if c.reduceMotion: initDuration()
        else: initDuration(milliseconds = 200)
      var opacity = 1'f32
      if fade > initDuration():
        let index = c.owner.toastIndex(toast.id)
        if index >= 0:
          let entry = c.owner.toasts[index]
          let age = c.owner.toastAge(entry, c.owner.frameNow)
          if age < fade:
            opacity = age.inNanoseconds.float32 / fade.inNanoseconds.float32
            c.owner.animating = true
          elif parts.left > initDuration() and parts.left < fade:
            opacity = parts.left.inNanoseconds.float32 / fade.inNanoseconds.float32
            c.owner.animating = true
      discard box.opacity(opacity)
      discard box.children(proc() =
        if toast.description.len == 0:
          discard c.text(toast.title).textColor(foreground)
        else:
          discard c.column().shrink(1).gap(theme.space(0.5))
            .children(proc() =
              discard c.text(toast.title).textWeight(600)
                .textColor(foreground)
              discard c.text(toast.description)
                .textColor(foreground.alpha(0.75'f32))
            )
        if toast.action.len > 0:
          let button = parts.actionButton().label(toast.action)
            .padding(theme.space(1),
            theme.space(2.5)).radius(theme.radius)
          discard button.children(proc() =
            discard c.text(toast.action)
              .textColor(theme.accent.mix(foreground, 0.35'f32))
              .textWeight(600)
          )
      )
  )
