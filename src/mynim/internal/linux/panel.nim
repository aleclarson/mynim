## panel.nim: initPanel makes a new window a panel (WindowOptions.panel),
## before it shows, as launchers make theirs (Albert, Ulauncher): a
## utility window on every workspace, out of the pager, which the window
## manager neither minimizes nor maximizes (the Motif hints GDK sets).
## The options keep it above other windows and out of the taskbar.

var
  panelBound: bool
  gdkWindowSetFunctions*: proc(w: pointer, functions: uint32) {.cdecl.}
  gtkWindowSetTypeHint*: proc(w: pointer, hint: int32) {.cdecl.}
    ## bound by loadFlyouts (flyout.nim)
  gtkWindowSetSkipPagerHint*: proc(w: pointer, v: bool) {.cdecl.}

proc loadFlyouts*() ## flyout.nim

# GdkWMFunction: what the window manager lets the user do to a panel.
const
  funcResize = 1'u32 shl 1
  funcMove = 1'u32 shl 2
  funcClose = 1'u32 shl 5

const typeHintUtility* = 5 # GDK_WINDOW_TYPE_HINT_UTILITY

proc initPanel*(w: gtkWindow) =
  if w.layer:
    return # initLayer made it a layer surface
  loadFlyouts()
  if not panelBound:
    panelBound = true
    mustBind(libGDK, cast[ptr pointer](addr gdkWindowSetFunctions),
      "gdk_window_set_functions")
  gtkWindowSetTypeHint(w.win, typeHintUtility)
  gtkWindowSetSkipPagerHint(w.win, true)
  gtkWindowStick(w.win)
  gtkWidgetRealize(w.win)
  gdkWindowSetFunctions(gtkWidgetGetWindow(w.win),
    funcResize or funcMove or funcClose)
