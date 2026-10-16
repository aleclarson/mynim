## A deterministic, in-memory driver for native UI views.

type
  Tester* = ref object
    surface: TesterSurface
    conn: surface.Conn
    clipboard: TesterClipboard

  TesterSurface = ref object of platform.Surface
    lock: Lock
    width, height: int
    scale: float64
    requested: bool
    cursorValue: platform.Cursor
    textInput: platform.TextInputState
    access: platform.AccessTree
    announced: seq[string]
    later: seq[proc() {.closure.}]
    opened: seq[string]
    menu: platform.Menu
    chooseMenu: proc(id: int) {.closure.}
    dark: bool
    prefs: platform.Preferences
    lang: string
    reg: i18n.Region
    rtl: bool
    bar: platform.TitleBar
    showsVibrancy: bool
    openError: ref CatchableError

  TesterClipboard = ref object of platform.Clipboard
    data: transfer.Data
    released: proc() {.closure.}

method size(s: TesterSurface): tuple[width, height, scale: float64] =
  (float64(s.width), float64(s.height), s.scale)

method requestFrame(s: TesterSurface) =
  s.lock.acquire()
  s.requested = true
  s.lock.release()

proc clearRequest(s: TesterSurface) =
  s.lock.acquire()
  s.requested = false
  s.lock.release()

proc needsFrame(s: TesterSurface): bool =
  s.lock.acquire()
  result = s.requested
  s.lock.release()

proc queue(s: TesterSurface; callback: proc() {.closure.}) =
  s.lock.acquire()
  s.later.add(callback)
  s.requested = true
  s.lock.release()

proc takeLater(s: TesterSurface): seq[proc() {.closure.}] =
  s.lock.acquire()
  result = move(s.later)
  s.later = @[]
  s.lock.release()

proc hasLater(s: TesterSurface): bool =
  s.lock.acquire()
  result = s.later.len > 0
  s.lock.release()

method setCursor(s: TesterSurface; value: platform.Cursor) =
  s.cursorValue = value

method setTextInput(s: TesterSurface; value: platform.TextInputState) =
  s.textInput = value

method updateAccessibility(s: TesterSurface; tree: platform.AccessTree) =
  s.access = tree
  s.announced.add(tree.announcements)

method formats(c: TesterClipboard): seq[transfer.Format] =
  c.data.formats()

method readData(c: TesterClipboard; formats: seq[transfer.Format]):
    tuple[d: transfer.Data, err: ref CatchableError] =
  var requested = formats
  if requested.len == 0:
    requested = c.data.formats()
    if requested.len == 0:
      return (transfer.Data(), nil)
  let (data, err) = c.data.materialize(requested)
  (d: data, err: err)

method writeData(c: TesterClipboard; data: transfer.Data;
                 released: proc() {.closure.}) =
  let previous = c.released
  c.data = data.snapshot()
  c.released = released
  if previous != nil:
    previous()

method flush(c: TesterClipboard) =
  if c.released != nil:
    let released = c.released
    c.released = nil
    released()

method close(c: TesterClipboard) =
  if c.released != nil:
    let released = c.released
    c.released = nil
    released()
  c.data = transfer.Data()

method readText(c: TesterClipboard): string =
  let (bytes, _) = c.data.read(transfer.Text)
  transfer.bytesToString(bytes)

method writeText(c: TesterClipboard; value: string) =
  c.writeData(transfer.textData(value), nil)

method readHTML(c: TesterClipboard): string =
  let (bytes, _) = c.data.read(transfer.HTML)
  transfer.bytesToString(bytes)

method writeHTML(c: TesterClipboard; value: string) =
  c.writeData(transfer.newData(transfer.newItem(
    transfer.bytes(transfer.HTML, value))), nil)

method readImage(c: TesterClipboard): seq[byte] =
  let (bytes, _) = c.data.read(transfer.PNG)
  bytes

method writeImage(c: TesterClipboard; value: seq[byte]) =
  c.writeData(transfer.newData(transfer.newItem(
    transfer.bytes(transfer.PNG, value))), nil)

method clear(c: TesterClipboard) =
  c.writeData(transfer.Data(), nil)

method availableFormats(c: TesterClipboard): seq[string] =
  for format in c.formats():
    result.add($format)

proc settle(t: Tester) =
  ## Builds frames until no frame or posted callback remains, up to 20 frames.
  if t == nil or t.conn == nil or t.conn.event == nil:
    return
  for _ in 0 ..< 20:
    t.surface.clearRequest()
    for callback in t.surface.takeLater():
      callback()
    t.surface.clearRequest()
    discard t.conn.event(platform.SurfaceEvent(kind: platform.surfaceFrame))
    if not t.surface.needsFrame() and not t.surface.hasLater():
      return

proc send(t: Tester; event: platform.SurfaceEvent) =
  if t != nil and t.conn != nil and t.conn.event != nil:
    discard t.conn.event(event)
    t.settle()

proc newTester*(view: View; width, height: int): Tester =
  ## Runs view without a native window, rendering frames in memory.
  if view == nil:
    raise newException(ValueError, "ui: NewTester needs a view")
  result = Tester(
    surface: TesterSurface(width: max(width, 0), height: max(height, 0),
                            scale: 1),
    clipboard: TesterClipboard(data: transfer.Data()))
  let tester = result
  initLock(tester.surface.lock)
  tester.surface.prefs = platform.Preferences(textScale: 1)
  let host = tester.surface
  tester.conn = surface.Conn(
    surface: host,
    clipboard: tester.clipboard,
    isDark: proc(): bool = host.dark,
    preferences: proc(): platform.Preferences = host.prefs,
    locale: proc(): string = host.lang,
    region: proc(): i18n.Region = host.reg,
    rightToLeft: proc(): bool = host.rtl,
    titleBar: proc(): platform.TitleBar = host.bar,
    vibrancy: proc(): bool = host.showsVibrancy,
    post: proc(callback: proc() {.closure.}) =
      if callback != nil:
        host.queue(callback),
    openURL: proc(url: string; done: proc(err: ref CatchableError)) =
      host.opened.add(url)
      if done != nil:
        let err = host.openError
        host.queue(proc() = done(err)),
    popupMenu: proc(menu: platform.Menu; x, y: float64;
                    chosen: proc(id: int)) =
      host.menu = menu
      host.chooseMenu = chosen)
  let content = newContent(view)
  content.attachContent(tester.conn)
  tester.settle()
  tester.send(platform.SurfaceEvent(kind: platform.accessibilityOn))

proc close*(t: Tester) =
  ## Releases in-memory runtime and clipboard state.
  if t == nil:
    return
  if t.conn != nil:
    let conn = t.conn
    if conn.detach != nil:
      conn.detach()
    conn.event = nil
    conn.changed = nil
    conn.themeChanged = nil
    conn.titleBarChanged = nil
    conn.localeChanged = nil
    conn.capture = nil
    conn.detach = nil
    conn.openURL = nil
    conn.post = nil
    conn.popupMenu = nil
    t.conn = nil
    t.surface.lock.acquire()
    t.surface.later.setLen(0)
    t.surface.lock.release()
    t.surface.menu = nil
    t.surface.chooseMenu = nil
  if t.clipboard != nil:
    t.clipboard.close()

proc setSize*(t: Tester; width, height: int) =
  t.surface.width = max(width, 0)
  t.surface.height = max(height, 0)
  t.settle()

proc setScale*(t: Tester; scale: float64) =
  t.surface.scale = if classify(scale) in {fcNan, fcInf, fcNegInf} or scale <= 0:
      1 else: scale
  t.settle()

proc setDark*(t: Tester; dark: bool) =
  t.surface.dark = dark
  if t.conn.themeChanged != nil:
    t.conn.themeChanged()
  t.settle()

proc setPreferences*(t: Tester; prefs: platform.Preferences) =
  t.surface.prefs = prefs
  if t.conn.themeChanged != nil:
    t.conn.themeChanged()
  t.settle()

proc setLocale*(t: Tester; tag: string) =
  t.surface.lang = tag
  if t.conn.localeChanged != nil:
    t.conn.localeChanged()
  t.settle()

proc setRegion*(t: Tester; region: i18n.Region) =
  t.surface.reg = region
  if t.conn.localeChanged != nil:
    t.conn.localeChanged()
  t.settle()

proc setDirection*(t: Tester; direction: Direction) =
  t.surface.rtl = direction == Direction.RightToLeft
  t.settle()

proc setTitleBar*(t: Tester; bar: platform.TitleBar) =
  t.surface.bar = bar
  t.settle()

proc setVibrancy*(t: Tester; shows: bool) =
  t.surface.showsVibrancy = shows
  t.settle()

proc frame*(t: Tester) =
  t.settle()

proc image*(t: Tester): sourceImage.RgbaImage =
  ## Returns the last frame in premultiplied RGBA pixels.
  if t == nil or t.conn == nil or t.conn.capture == nil:
    return sourceImage.newRgba(sourceImage.rect(0, 0, 0, 0))
  let frame = t.conn.capture()
  result = sourceImage.newRgba(sourceImage.rect(0, 0, frame.width, frame.height))
  for i, value in frame.rgba:
    result.pix[i] = uint8(value)

proc find*(t: Tester; text: string): tuple[rect: Rect, found: bool] =
  ## Finds the first accessible element showing or labeled with text.
  if t == nil:
    return
  for node in t.surface.access.nodes:
    if node.label == text or node.value == text:
      let bounds = node.bounds
      return (Rect(x: float32(bounds.x), y: float32(bounds.y),
                   w: float32(bounds.w), h: float32(bounds.h)), true)

proc texts*(t: Tester): seq[string] =
  ## Returns accessible labels from the last frame in tree order.
  if t == nil:
    return
  for node in t.surface.access.nodes:
    if node.label.len > 0:
      result.add(node.label)
    elif node.value.len > 0:
      result.add(node.value)

proc hasText*(t: Tester; text: string): bool =
  if t == nil:
    return false
  for node in t.surface.access.nodes:
    if text in node.label or text in node.value:
      return true

proc clickAtWith*(t: Tester; mods: platform.Modifiers; x, y: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerDown, x: x, y: y, mods: mods))
  t.send(platform.SurfaceEvent(kind: platform.pointerUp, x: x, y: y, mods: mods))

proc clickAt*(t: Tester; x, y: float32) =
  t.clickAtWith(0, x, y)

proc clickWith*(t: Tester; mods: platform.Modifiers;
                text: string): ref CatchableError =
  let (bounds, found) = t.find(text)
  if not found:
    return newException(ValueError,
      "ui: no element shows \"" & escape(text) & "\"")
  t.clickAtWith(mods, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2)

proc click*(t: Tester; text: string): ref CatchableError =
  t.clickWith(0, text)

proc rightClickAtWith*(t: Tester; mods: platform.Modifiers; x, y: float32)

proc rightClickAt*(t: Tester; x, y: float32) =
  t.rightClickAtWith(0, x, y)

proc rightClickAtWith*(t: Tester; mods: platform.Modifiers; x, y: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerDown, x: x, y: y,
                                button: 1, mods: mods))
  t.send(platform.SurfaceEvent(kind: platform.pointerUp, x: x, y: y,
                                button: 1, mods: mods))

proc rightClickWith*(t: Tester; mods: platform.Modifiers;
                     text: string): ref CatchableError =
  let (bounds, found) = t.find(text)
  if not found:
    return newException(ValueError,
      "ui: no element shows \"" & escape(text) & "\"")
  t.rightClickAtWith(mods, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2)

proc rightClick*(t: Tester; text: string): ref CatchableError =
  t.rightClickWith(0, text)

proc press*(t: Tester; x, y: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerDown, x: x, y: y))

proc release*(t: Tester; x, y: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerUp, x: x, y: y))

proc move*(t: Tester; x, y: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerMove, x: x, y: y))

proc scroll*(t: Tester; x, y, dx, dy: float32) =
  t.send(platform.SurfaceEvent(kind: platform.pointerScroll, x: x, y: y,
    dx: dx, dy: dy))

proc holdModifiers*(t: Tester; mods: platform.Modifiers) =
  t.send(platform.SurfaceEvent(kind: platform.modifiersChanged, mods: mods))

proc key*(t: Tester; mods: platform.Modifiers; key: platform.Key) =
  t.send(platform.SurfaceEvent(kind: platform.keyPressed, key: key, mods: mods))
  t.send(platform.SurfaceEvent(kind: platform.keyReleased, key: key, mods: mods))

proc keyDown*(t: Tester; key: platform.Key) =
  t.send(platform.SurfaceEvent(kind: platform.keyPressed, key: key))

proc keyUp*(t: Tester; key: platform.Key) =
  t.send(platform.SurfaceEvent(kind: platform.keyReleased, key: key))

proc keyAt*(t: Tester; mods: platform.Modifiers; physical: platform.Key) =
  t.send(platform.SurfaceEvent(kind: platform.keyPressed, physicalKey: physical,
                                mods: mods))
  t.send(platform.SurfaceEvent(kind: platform.keyReleased, physicalKey: physical,
                                mods: mods))

proc typeKey*(t: Tester; mods: platform.Modifiers; key: platform.Key;
              text: string) =
  t.send(platform.SurfaceEvent(kind: platform.keyPressed, key: key, mods: mods))
  t.send(platform.SurfaceEvent(kind: platform.textInput, text: text))
  t.send(platform.SurfaceEvent(kind: platform.keyReleased, key: key, mods: mods))

proc typeText*(t: Tester; text: string) =
  t.send(platform.SurfaceEvent(kind: platform.textInput, text: text))

proc setFocused*(t: Tester; focused: bool) =
  let kind = if focused: platform.surfaceFocus else: platform.surfaceBlur
  t.send(platform.SurfaceEvent(kind: kind))

proc compose*(t: Tester; text: string; caret: int) =
  t.send(platform.SurfaceEvent(kind: platform.textComposition, text: text,
                                caret: caret))

proc command*(t: Tester; name: string) =
  t.send(platform.SurfaceEvent(kind: platform.surfaceCommand, text: name))

proc textCaret*(t: Tester): tuple[rect: Rect, active: bool] =
  if t == nil:
    return
  let caret = t.surface.textInput.caret
  (Rect(x: float32(caret.x), y: float32(caret.y), w: float32(caret.w),
        h: float32(caret.h)), t.surface.textInput.active)

proc textInputActive*(t: Tester): bool =
  t != nil and t.surface.textInput.active

proc clipboard*(t: Tester): string =
  if t != nil:
    result = t.clipboard.readText()

proc setClipboard*(t: Tester; text: string) =
  if t != nil:
    t.clipboard.writeText(text)

proc clipboardData*(t: Tester): transfer.Data =
  if t != nil:
    return t.clipboard.data.snapshot()

proc setClipboardData*(t: Tester; data: transfer.Data) =
  if t == nil:
    return
  t.clipboard.writeData(data, nil)

proc cursor*(t: Tester): platform.Cursor =
  if t == nil: platform.cursorDefault else: t.surface.cursorValue

proc openedUrls*(t: Tester): seq[string] =
  if t != nil: result = t.surface.opened

proc failOpenUrl*(t: Tester; error: ref CatchableError) =
  if t != nil: t.surface.openError = error

proc announcements*(t: Tester): seq[string] =
  if t == nil:
    return
  result = t.surface.announced
  t.surface.announced.setLen(0)

proc focused*(t: Tester; text: string): bool =
  if t == nil:
    return false
  for index, node in t.surface.access.nodes:
    if node.label == text or node.value == text:
      var parent = index
      while parent >= 0:
        let current = t.surface.access.nodes[parent]
        if current.id == t.surface.access.focus:
          return true
        parent = current.parent

proc menu*(t: Tester): seq[string] =
  if t == nil or t.surface.menu == nil:
    return
  for item in t.surface.menu.items:
    if item.`type` == platform.menuItemSeparator:
      result.add("-")
    else:
      result.add(item.label)

proc chooseMenuItem*(t: Tester; path: varargs[string]): ref CatchableError =
  if t == nil or t.surface.menu == nil:
    return newException(ValueError, "ui: no context menu is shown")
  if path.len == 0:
    return newException(ValueError, "ui: no item to choose")
  var current = t.surface.menu
  var selected: platform.MenuItem
  for index, label in path:
    selected = nil
    for item in current.items:
      if item.label == label and item.`type` != platform.menuItemSeparator:
        selected = item
        break
    let prefix = path[0 .. index].join(" > ")
    if selected == nil:
      return newException(ValueError, "ui: context menu has no item \"" &
        escape(prefix) & "\"")
    if not selected.enabled:
      return newException(ValueError, "ui: item is disabled \"" &
        escape(prefix) & "\"")
    if index < path.high:
      if selected.submenu == nil:
        return newException(ValueError, "ui: item has no submenu \"" &
          escape(prefix) & "\"")
      current = selected.submenu
  if selected.`type` == platform.menuItemSubmenu:
    return newException(ValueError, "ui: item opens a submenu \"" &
      escape(path.join(" > ")) & "\"")
  let choose = t.surface.chooseMenu
  t.surface.menu = nil
  t.surface.chooseMenu = nil
  if choose != nil:
    choose(selected.id)
  t.settle()

proc closeMenu*(t: Tester) =
  if t != nil:
    t.surface.menu = nil
    t.surface.chooseMenu = nil
