## dock.go: the Dock tile shows progress (Window.SetProgressBar) under
## the app icon. NSProgressIndicator does not draw in a Dock tile,
## which renders its content view offscreen, so the bar is made of two
## custom NSBoxes, which draw themselves.

proc updateDockProgress(b: Backend, state: string, value: float64) =
  let tile = send(b.app, "dockTile")
  let p = addr b.dockProgress
  if state == "":
    if not p.view.isNil:
      discard send(tile, "setContentView:", argu(0))
      for v in [p.view, p.icon, p.track, p.fill]:
        release(v)
      p[] = dockProgress()
      discard send(tile, "display")
    return
  let size = msgSize(tile, sel("size"))
  const height = 14.0
  const inset = 6.0
  if p.view.isNil:
    let frame = NSRect(size: size)
    p.view = alloc("NSView")
    msgSetRect(p.view, sel("setFrame:"), frame)
    p.icon = alloc("NSImageView")
    msgSetRect(p.icon, sel("setFrame:"), frame)
    discard send(p.view, "addSubview:", argu(p.icon))
    let box = proc(fill, border: platform.Color, width: float64): id =
      let v = alloc("NSBox")
      discard send(v, "setBoxType:", argu(4))       ## NSBoxCustom
      discard send(v, "setTitlePosition:", argu(0)) ## NSNoTitle
      discard send(v, "setFillColor:", argu(nsColor(fill)))
      discard send(v, "setBorderColor:", argu(nsColor(border)))
      msgSetFloat(v, sel("setBorderWidth:"), width)
      msgSetFloat(v, sel("setCornerRadius:"), height / 2)
      discard send(p.view, "addSubview:", argu(v))
      v
    p.track = box(platform.Color(r: 40, g: 40, b: 40, a: 200),
                  platform.Color(r: 160, g: 160, b: 160, a: 255), 1.5)
    p.fill = box(platform.Color(r: 51, g: 153, b: 255, a: 255),
                 platform.Color(r: 51, g: 153, b: 255, a: 255), 0)
    discard send(tile, "setContentView:", argu(p.view))
  discard send(p.icon, "setImage:",
               argu(send(b.app, "applicationIconImage")))
  let track = NSRect(origin: NSPoint(x: inset, y: inset),
    size: NSSize(width: size.width - 2 * inset, height: height))
  msgSetRect(p.track, sel("setFrame:"), track)
  var value = value
  if state == "indeterminate":
    value = 1
  var fill = track
  fill.size.width = max(height, track.size.width * value)
  discard send(p.fill, "setHidden:", argu(value <= 0))
  msgSetRect(p.fill, sel("setFrame:"), fill)
  discard send(tile, "display")

proc setDockProgress*(b: Backend, state: string, value: float64) =
  withPool(proc() = b.updateDockProgress(state, value))
