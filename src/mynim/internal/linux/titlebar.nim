## titlebar.nim: a window with a hidden title bar has no decorations, as
## a frameless one, and the outer pixels of its page resize it. GTK's
## own title buttons go over the page, in an overlay: a header bar for
## each side of the desktop's button layout (gtk-decoration-layout)
## that has buttons, with its background cleared. They look and act as
## the buttons of the desktop's header bars do, and only those the
## layout names show: GNOME, KDE and Xfce keep it in step with their
## window managers, and users of tiling window managers empty it to
## have none.
##
## A Wayland compositor that decorates windows itself gets no buttons at
## all. KWin, Hyprland and Sway say so with the default mode of
## org_kde_kwin_server_decoration_manager, and GTK then asks them to
## decorate a window without decorations too. The compositor's title bar
## has the buttons, and a tiling compositor, which draws none, wants
## none, whatever the button layout says: GTK reads it from GNOME's
## settings on Wayland, and their default shows close.

# controlsCSS clears the bars around the buttons. With TitleBarHeight,
# the bars take that height instead of the theme's.
const controlsCSS = """headerbar.mynim-window-controls { background: none; border: none; box-shadow: none; }
headerbar.mynim-window-controls.mynim-sized { min-height: 0; }"""


proc measureControls*(w: gtkWindow)
proc newControlsBar*(w: gtkWindow, side: int): pointer
proc buttonLayout(): tuple[start, `end`: string]
proc windowButtons(side: string): string

proc cbControlsAllocated*(widget, alloc, data: pointer) {.cdecl.} =
  ## surface.nim's allocated() applies to it too: measure on it.
  let w = theBackend.window(data)
  if not w.isNil and not w.controls.isNil:
    w.measureControls()

## newControls puts an overlay, whose bars hold the title buttons, where
## the web view goes. It comes before the web view, whose first page is
## told the room the buttons take.
proc newControls*(w: gtkWindow) =
  if not controlsStyled:
    let provider = gtkCssProviderNew()
    discard gtkCssProviderLoadFromData(provider, cs(controlsCSS),
      int32(controlsCSS.len), nil)
    gtkStyleContextAddProviderForScreen(gtkWidgetGetScreen(w.win),
      provider, 600) # GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
    gObjectUnref(provider)
    controlsStyled = true
  w.controls = windowControls(overlay: gtkOverlayNew())
  # In the window before the bars: a header bar shows window buttons
  # only inside one.
  gtkBoxPackStart(w.box, w.controls.overlay, true, true, 0)
  w.layoutControls()

## layoutControls gives the bars the buttons of the desktop's layout:
## GTK shows each only when the window can do it (maximize when it is
## resizable, close when it is deletable).
proc layoutControls*(w: gtkWindow) =
  let c = w.controls
  var (start, `end`) = buttonLayout()
  if w.b.compositorDecorates:
    start = ""
    `end` = ""
  for side, buttons in [start, `end`]:
    var bar = c.bars[side]
    if buttons == "":
      if not bar.isNil:
        gtkWidgetDestroy(bar)
        c.bars[side] = nil
      continue
    if bar.isNil:
      bar = w.newControlsBar(side)
      c.bars[side] = bar
    var layout = buttons & ":"
    if side == 1:
      layout = ":" & buttons
    # Also rebuilds the buttons for the window's state.
    gtkHeaderBarSetDecorationLayout(bar, cs(layout))
    gtkWidgetShowAll(bar)
    gtkWidgetSetVisible(bar, (w.state and stateFullscreen) == 0)
  w.measureControls()

proc newControlsBar*(w: gtkWindow, side: int): pointer =
  let bar = gtkHeaderBarNew()
  gtkHeaderBarSetShowCloseButton(bar, true) # the window buttons
  gtkHeaderBarSetHasSubtitle(bar, false)
  let style = gtkWidgetGetStyleContext(bar)
  gtkStyleContextAddClass(style, cs("mynim-window-controls"))
  if w.opts.titleBarHeight > 0:
    gtkStyleContextAddClass(style, cs("mynim-sized"))
    gtkWidgetSetSizeRequest(bar, -1, int32(w.opts.titleBarHeight))
  const alignStart = 1'i32
  const alignEnd = 2'i32
  var align = alignEnd
  if side == 0:
    align = alignStart
  gtkWidgetSetHalign(bar, align)
  gtkWidgetSetValign(bar, alignStart)
  gtkOverlayAddOverlay(w.controls.overlay, bar)
  discard connect(bar, "size-allocate", cast[pointer](cbControlsAllocated),
    cast[pointer](w.id))
  bar

## measureControls takes note of the room the bars take, from their
## allocations once GTK laid them out and from their natural sizes
## before, and tells the core when it changed.
proc measureControls*(w: gtkWindow) =
  let c = w.controls
  var room = platform.TitleBar(height: w.opts.titleBarHeight)
  for side, bar in c.bars:
    if bar.isNil: continue
    var a: gdkRectangle
    gtkWidgetGetAllocation(bar, addr a)
    var width = a.width
    var height = a.height
    if width <= 1: # not allocated yet
      var minimum: int32
      gtkWidgetGetPreferredWidth(bar, addr minimum, addr width)
      gtkWidgetGetPreferredHeight(bar, addr minimum, addr height)
    if side == 0:
      room.left = int(width)
    else:
      room.right = int(width)
    if w.opts.titleBarHeight == 0:
      room.height = max(room.height, int(height))
  if room != c.room:
    c.room = room
    w.h.titleBarChanged()

## fullScreenChanged hides the buttons in full screen, and shows them
## after.
proc fullScreenChanged*(w: gtkWindow) =
  for bar in w.controls.bars:
    if not bar.isNil:
      gtkWidgetSetVisible(bar, (w.state and stateFullscreen) == 0)
  w.h.titleBarChanged()

method titleBar*(w: gtkWindow): platform.TitleBar =
  if w.controls.isNil or (w.state and stateFullscreen) != 0:
    return platform.TitleBar()
  w.controls.room

## titleBarScript tells the first page the room of the title buttons, at
## document start.
proc titleBarScript*(w: gtkWindow): string =
  bridge.titleBarScript(w.titleBar(), w.opts.zoom)

## buttonLayout returns the window buttons that gtk-decoration-layout
## puts at the start and at the end of a title bar, such as
## "close,minimize" and "minimize,maximize,close", without the icon and
## menu it may name.
proc buttonLayout(): tuple[start, `end`: string] =
  var p: pointer
  gObjectGetPtr(gtkSettingsGetDefault(), cs("gtk-decoration-layout"),
    unsafeAddr p, nil)
  let s = takeStr(p)
  let i = s.find(':')
  var before, after: string
  if i >= 0:
    before = s[0 ..< i]
    after = s[i + 1 .. ^1]
  else:
    before = s
  (windowButtons(before), windowButtons(after))

proc windowButtons(side: string): string =
  var kept: seq[string]
  for b in side.split(','):
    case b.strip
    of "minimize", "maximize", "close":
      kept.add b.strip
    else: discard
  kept.join(",")
