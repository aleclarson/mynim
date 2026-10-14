## popover.go: a flyout with Flyout.popover shows its web view or
## surface in an NSPopover, which draws the system's material and
## arrow, and animates. AppKit places it against the anchor: the arrow
## points at the anchor's middle, on the side the flyout asks for,
## which AppKit flips where the screen has no room. The popover makes
## its window as it shows: w.win is that window while it shows.

const
  popoverBehaviorApplicationDefined = 0
  popoverBehaviorTransient = 1

## window.go's internals, declared here for the procs below.
proc createContent*(w: macWindow, content: NSRect)
proc register*(w: macWindow)
proc cleanup*(w: macWindow)
proc windowFor*(b: Backend, delegate: id): macWindow
proc adoptPopoverWindow*(w: macWindow)
proc forgetPopoverWindow*(w: macWindow)
proc pressed*(t: tray): bool

const nsViewWidthHeightSizable = 18u ## NSViewWidthSizable|NSViewHeightSizable

proc createPopover*(w: macWindow, content: NSRect) =
  w.delegate = alloc("MyNimWindowDelegate")
  w.createContent(content)
  discard send(w.view, "setAutoresizingMask:", argu(nsViewWidthHeightSizable))
  w.popoverController = alloc("NSViewController")
  discard send(w.popoverController, "setView:", argu(w.view))
  w.popover = alloc("NSPopover")
  discard send(w.popover, "setContentViewController:",
             argu(w.popoverController))
  msgSetSize(w.popover, sel("setContentSize:"), content.size)
  var behavior = popoverBehaviorApplicationDefined.uint
  if w.flyout.focusable:
    behavior = popoverBehaviorTransient.uint
  discard send(w.popover, "setBehavior:", argu(behavior))
  discard send(w.popover, "setDelegate:", argu(w.delegate))
  w.register()

## popoverAnchor returns the view the popover shows from, the anchor in
## it and the edge of it the popover goes to: the parent's content
## view, which is not flipped, or the button of a tray's status item.
## view is nil when there is none.
proc popoverAnchor(w: macWindow): tuple[view: id, r: NSRect, edge: uint] =
  ## NSRectEdge
  let edge = case w.flyout.side
    of sideBottom: 1u
    of sideTop: 3u
    of sideRight: 2u
    of sideLeft: 0u
  if w.flyout.tray of tray:
    let t = tray(w.flyout.tray)
    if t.item.isNil:
      return (nil, default(NSRect), edge)
    return (t.button, msgRect(t.button, sel("bounds")), edge)
  let a = w.flyout.anchor
  let p = w.parent
  var r: NSRect
  if p == nil or p.closed or p.view.isNil:
    return (nil, r, edge)
  let h = msgRect(p.view, sel("bounds")).size.height
  r = NSRect(
    origin: NSPoint(x: float64(a.x),
                    y: h - float64(a.y) - float64(max(a.height, 1))),
    size: NSSize(width: float64(max(a.width, 1)),
                 height: float64(max(a.height, 1))))
  (p.view, r, edge)

proc showPopover*(w: macWindow) =
  let (view, r, edge) = w.popoverAnchor()
  if view.isNil or sendBool(w.popover, "isShown"):
    return
  w.popoverClosing = false
  if w.flyout.tray != nil:
    ## The popover of a menu bar app takes the keyboard of an app the
    ## user did not activate, as AppKit's own status items' do.
    discard send(w.b.app, "activateIgnoringOtherApps:", argu(1))
  msgSetSize(w.popover, sel("setContentSize:"),
             NSSize(width: float64(w.flyoutSize.width),
                    height: float64(w.flyoutSize.height)))
  msgRectIDUint(w.popover,
    sel("showRelativeToRect:ofView:preferredEdge:"), r, view, edge)
  w.adoptPopoverWindow()

## adoptPopoverWindow makes the window the popover shows in the
## flyout's.
proc adoptPopoverWindow*(w: macWindow) =
  let win = send(w.view, "window")
  if win.isNil or win == w.win:
    return
  w.forgetPopoverWindow()
  w.win = win
  w.b.byNSWindow[win] = w
  if w.surface != nil:
    discard send(win, "makeFirstResponder:", argu(w.surface.view))

proc forgetPopoverWindow*(w: macWindow) =
  if w.win.isNil:
    return
  w.b.byNSWindow.del(w.win)
  w.win = nil

## placePopover moves a popover that shows to the anchor, at the size.
proc placePopover*(w: macWindow) =
  if not sendBool(w.popover, "isShown"):
    return
  msgSetSize(w.popover, sel("setContentSize:"),
             NSSize(width: float64(w.flyoutSize.width),
                    height: float64(w.flyoutSize.height)))
  let (_, r, _) = w.popoverAnchor()
  if w.flyout.tray == nil:
    msgSetRect(w.popover, sel("setPositioningRect:"), r)

## hidePopover closes the popover, which shows again with Show, and
## gives the keyboard it had back to the parent.
proc hidePopover*(w: macWindow) =
  if not sendBool(w.popover, "isShown"):
    return
  let key = not w.win.isNil and sendBool(w.win, "isKeyWindow")
  w.popoverClosing = true
  discard send(w.popover, "close")
  let p = w.parent
  if key and p != nil and not p.closed and sendBool(p.win, "isVisible"):
    discard send(p.win, "makeKeyWindow")

## closePopover destroys the flyout, at once.
proc closePopover*(w: macWindow) =
  discard send(w.popover, "setAnimates:", argu(0))
  w.hidePopover()
  w.cleanup()
  w.h.closed()

proc cleanupPopover*(w: macWindow) =
  w.forgetPopoverWindow()
  discard send(w.popover, "setDelegate:", argu(0))
  if sendBool(w.popover, "isShown"):
    discard send(w.popover, "setAnimates:", argu(0))
    discard send(w.popover, "close")
  discard send(w.popover, "setContentViewController:", argu(0))
  release(w.popover)
  release(w.popoverController)

## popoverDelegateMethods: popoverShouldClose runs when the user
## clicked elsewhere, in a transient popover. A press on its own tray
## icon leaves it to the icon's click, which toggles it, rather than
## closing it for the click to open it again.
proc popoverDelegateMethods*(): seq[MethodDef] =
  @[methodDef("popoverShouldClose:",
    cast[pointer](proc(self: id, cmd: SEL, popover: id): bool {.cdecl.} =
      let w = theBackend.windowFor(self)
      if w == nil:
        return true
      if w.flyout.tray of tray and tray(w.flyout.tray).pressed():
        return false
      w.h.shouldClose()),
    "B@:@@"),
  methodDef("popoverDidClose:",
    cast[pointer](proc(self: id, cmd: SEL, n: id) {.cdecl.} =
      let w = theBackend.windowFor(self)
      if w == nil:
        return
      w.forgetPopoverWindow()
      if w.popoverClosing:
        w.popoverClosing = false
        return
      w.cleanup()
      w.h.closed()),
    "v@:@@"),
  ]

## pressed reports whether the event being handled is a press on the
## icon's button.
proc pressed*(t: tray): bool =
  let ev = send(t.b.app, "currentEvent")
  if ev.isNil or t.item.isNil:
    return false
  let ty = sendInt(ev, "type")
  ## NSEventTypeLeftMouseDown, RightMouseDown
  if ty != 1 and ty != 3:
    return false
  let win = send(t.button, "window")
  if win.isNil or send(ev, "window") != win:
    return false
  let p = msgPointFromView(t.button, sel("convertPoint:fromView:"),
                           msgPoint(ev, sel("locationInWindow")), nil)
  let b = msgRect(t.button, sel("bounds"))
  p.x >= b.origin.x and p.y >= b.origin.y and
    p.x < b.origin.x + b.size.width and
    p.y < b.origin.y + b.size.height
