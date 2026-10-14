## surface.nim: the canvas of a window, drawn with WebGL 2, or in memory
## and shown with a 2D context where the browser has no WebGL 2. A
## textarea out of sight has the keyboard while the window has: input
## methods compose in it, at the caret of the content, and its clipboard
## events carry the clipboard. Its inputmode is "none" while nothing in
## the content takes text, so that touch devices, which show their
## keyboard for a focused textarea, show it only for a text input.

proc devicePixelRatio(): float64
proc unpremul*(c, a: byte): byte
proc measure*(s: webSurface): bool
proc focus*(s: webSurface)
proc point*(s: webSurface, e: JsValue): tuple[x, y: float64]
proc mods*(s: webSurface, e: JsValue): Modifiers
proc buttonOf*(b: int): int
proc keyOf*(name, code: string): Key
proc codeKey*(code: string): Key

## lineHeight is how many DIPs a line of a wheel scrolls.
const lineHeight = 16

proc send*(s: webSurface, ev: SurfaceEvent): bool =
  s.w.h.surfaceEvent(ev)

proc listen*(s: webSurface)
proc key*(s: webSurface, e: JsValue, down: bool)
proc copy*(s: webSurface, e: JsValue, cmd: string)
proc drawFrame*(s: webSurface)

proc newWebSurface*(w: webWindow): webSurface =
  let doc = jsGet(jsGlobal(), "document")
  result = webSurface(w: w, scale: 1)
  result.canvas = jsCall(doc, "createElement", [jsValueOf("canvas")])
  jsSet(result.canvas, "tabIndex", jsValueOf(-1))
  result.input = jsCall(doc, "createElement", [jsValueOf("textarea")])
  for kv in [("autocomplete", "off"), ("autocorrect", "off"),
             ("autocapitalize", "off"), ("spellcheck", "false"),
             ("tabindex", "-1"), ("inputmode", "none")]:
    discard jsCall(result.input, "setAttribute",
                   [jsValueOf(kv[0]), jsValueOf(kv[1])])
  discard jsCall(w.el, "appendChild", [result.canvas])
  discard jsCall(w.el, "appendChild", [result.input])
  # A WebGL 2 context where the browser has it, a 2D one elsewhere.
  let gl2 = jsCall(result.canvas, "getContext",
                   [jsValueOf("webgl2")])
  if jsIsNull(gl2) or jsIsUndefined(gl2):
    # Drawing in memory; the GL renderer's context lands here when it
    # is ported (internal/gpu/gl).
    result.ctx2d = jsCall(result.canvas, "getContext",
                          [jsValueOf("2d")])
    result.gl = nil
  else:
    result.gl = cast[pointer](1) # WebGL present; GL context pending
    result.ctx2d = gl2
  let self = result
  result.frame = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    w.b.sync(proc() = self.drawFrame())
    jsUndef)
  result.listen()

## on adds a listener of the browser's events to target, which handles
## them on the main thread.
proc on*(s: webSurface, target: JsValue, event: string, passive: bool,
         fn: proc(e: JsValue)) =
  let f = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    s.w.b.sync(proc() =
      if not s.closed:
        fn(args[0]))
    jsUndef)
  s.funcs.add f
  let opts = jsObj()
  jsSet(opts, "passive", jsValueOf(passive))
  discard jsCall(target, "addEventListener",
                 [jsValueOf(event), f, opts])
  # Listeners on window and document go with the surface.
  if jsEqual(target, jsGlobal()) or
      jsEqual(target, jsGet(jsGlobal(), "document")):
    s.globalListeners.add webListener(target: target, event: event, fn: f)

proc listen*(s: webSurface) =
  let c = s.canvas
  let `in` = s.input
  let ro = jsGet(jsGlobal(), "ResizeObserver")
  if not jsIsUndefined(ro):
    let f = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
      s.w.b.sync(proc() =
        if not s.closed and s.measure():
          s.requestFrame())
      jsUndef)
    s.funcs.add f
    s.observer = jsNew(ro, [f])
    discard jsCall(s.observer, "observe", [c])
  s.on(jsGlobal(), "resize", true, proc(e: JsValue) =
    if s.measure():
      s.requestFrame())
  s.on(jsGet(jsGlobal(), "document"), "visibilitychange", true,
       proc(e: JsValue) =
    if not s.occluded():
      discard s.send(SurfaceEvent(kind: surfaceShown))
      s.requestFrame())
  if not s.gl.isNil:
    s.on(c, "webglcontextlost", false, proc(e: JsValue) =
      discard jsCall(e, "preventDefault", []))
    s.on(c, "webglcontextrestored", true, proc(e: JsValue) =
      # The GL renderer renews its context; surfaceRenew tells the
      # content.
      discard s.send(SurfaceEvent(kind: surfaceRenew)))

  s.on(c, "pointermove", true, proc(e: JsValue) =
    let (x, y) = s.point(e)
    discard s.send(SurfaceEvent(kind: pointerMove, x: x, y: y,
                                mods: s.mods(e))))

  s.on(c, "pointerdown", false, proc(e: JsValue) =
    discard jsCall(e, "preventDefault", [])
    s.focus()
    let (x, y) = s.point(e)
    let button = jsInt(jsGet(e, "button"))
    case button
    of 3, 4:
      var k = keyBack
      if button == 4:
        k = keyForward
      discard s.send(SurfaceEvent(kind: keyPressed, key: k,
                                  mods: s.mods(e)))
      discard s.send(SurfaceEvent(kind: keyReleased, key: k,
                                  mods: s.mods(e)))
      return
    else: discard
    discard jsCall(c, "setPointerCapture", [jsGet(e, "pointerId")])
    let b = buttonOf(button)
    let now = getMonoTime()
    if b == s.downButton and
        now - s.downAt < initDuration(milliseconds = 500) and
        abs(x - s.downX) < 5 and abs(y - s.downY) < 5:
      inc s.clicks
    else:
      s.clicks = 1
    s.downAt = now
    s.downX = x
    s.downY = y
    s.downButton = b
    discard s.send(SurfaceEvent(kind: pointerDown, x: x, y: y,
                                button: b, clicks: s.clicks,
                                mods: s.mods(e))))

  s.on(c, "pointerup", true, proc(e: JsValue) =
    let button = jsInt(jsGet(e, "button"))
    if button == 3 or button == 4:
      return
    let (x, y) = s.point(e)
    discard s.send(SurfaceEvent(kind: pointerUp, x: x, y: y,
                                button: buttonOf(button),
                                clicks: s.clicks, mods: s.mods(e))))

  s.on(c, "pointercancel", true, proc(e: JsValue) =
    let (x, y) = s.point(e)
    discard s.send(SurfaceEvent(kind: pointerUp, x: x, y: y,
                                button: buttonOf(jsInt(jsGet(e, "button"))),
                                mods: s.mods(e))))

  s.on(c, "pointerleave", true, proc(e: JsValue) =
    discard s.send(SurfaceEvent(kind: pointerLeave)))

  # iOS sends a tap's mouse events even though its pointerdown was
  # canceled: the mousedown would move the focus to the canvas, and the
  # touch keyboard would hide as soon as it showed.
  s.on(c, "mousedown", false, proc(e: JsValue) =
    discard jsCall(e, "preventDefault", []))
  s.on(c, "contextmenu", false, proc(e: JsValue) =
    discard jsCall(e, "preventDefault", []))

  s.on(c, "wheel", false, proc(e: JsValue) =
    discard jsCall(e, "preventDefault", [])
    let (x, y) = s.point(e)
    var dx = jsFloat(jsGet(e, "deltaX"))
    var dy = jsFloat(jsGet(e, "deltaY"))
    var precise = true
    case jsInt(jsGet(e, "deltaMode"))
    of 1: # lines
      dx = dx * lineHeight
      dy = dy * lineHeight
      precise = false
    of 2: # pages
      dx = dx * s.width
      dy = dy * s.height
      precise = false
    else:
      # A wheel's notches, which browsers give as pixels too.
      let w = jsGet(e, "wheelDeltaY")
      if jsType(w) == jsNumber and jsInt(w) != 0 and jsInt(w) mod 120 == 0:
        precise = false
    discard s.send(SurfaceEvent(kind: pointerScroll, x: x, y: y,
                                dx: dx, dy: dy, precise: precise,
                                mods: s.mods(e))))

  # Files dragged over the canvas, and dropped: their bytes are read,
  # as browsers give them, before the drop goes to the content
  # (files.nim). The browser opens no file dropped on the window, which
  # would leave the app, whether the content takes it or not.
  proc files(e: JsValue): bool =
    let types = jsGet(jsGet(e, "dataTransfer"), "types")
    not jsIsNull(types) and not jsIsUndefined(types) and
      jsBool(jsCall(types, "includes", [jsValueOf("Files")]))
  proc over(e: JsValue) =
    if not files(e):
      return
    discard jsCall(e, "preventDefault", [])
    let (x, y) = s.point(e)
    var effect = "none"
    if s.send(SurfaceEvent(kind: fileDragOver, x: x, y: y)):
      effect = "copy"
    jsSet(jsGet(e, "dataTransfer"), "dropEffect", jsValueOf(effect))
  s.on(c, "dragenter", false, over)
  s.on(c, "dragover", false, over)
  s.on(c, "dragleave", true, proc(e: JsValue) =
    if files(e):
      discard s.send(SurfaceEvent(kind: fileDragLeave)))
  s.on(c, "drop", false, proc(e: JsValue) =
    if not files(e):
      return
    discard jsCall(e, "preventDefault", [])
    let (x, y) = s.point(e)
    let list = jsGet(jsGet(e, "dataTransfer"), "files")
    var names = newSeq[string](jsLen(list))
    var reads = newSeq[JsValue](names.len)
    for i in 0 ..< names.len:
      let f = jsGetIx(list, i)
      names[i] = jsString(jsGet(f, "name"))
      reads[i] = jsCall(f, "arrayBuffer", [])
    var done: JsValue
    done = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
      jsFuncRelease(done)
      let results = args[0]
      s.w.b.sync(proc() =
        # Folders have no bytes to read: they are left out.
        var kept: seq[string]
        var data: seq[seq[byte]]
        for i, name in names:
          let r = jsGetIx(results, i)
          if jsString(jsGet(r, "status")) != "fulfilled":
            continue
          let buf = jsNew(jsGet(jsGlobal(), "Uint8Array"),
                          [jsGet(r, "value")])
          var b = newSeq[byte](jsLen(buf))
          jsCopyFromJS(b, buf)
          kept.add name
          data.add b
        if s.closed:
          return
        if kept.len == 0:
          discard s.send(SurfaceEvent(kind: fileDragLeave))
          return
        discard s.send(SurfaceEvent(kind: fileDrop, x: x, y: y,
                                    files: drops.add(kept, data))))
      jsUndef)
    discard jsCall(jsCall(jsGet(jsGlobal(), "Promise"), "allSettled",
                          [jsArrayOf(reads)]), "then", [done]))

  s.on(`in`, "focus", true, proc(e: JsValue) =
    s.w.focused = true
    s.w.h.focused()
    discard s.send(SurfaceEvent(kind: surfaceFocus)))
  s.on(`in`, "blur", true, proc(e: JsValue) =
    s.w.focused = false
    discard s.send(SurfaceEvent(kind: surfaceBlur))
    s.w.h.blurred())
  s.on(`in`, "keydown", false, proc(e: JsValue) = s.key(e, true))
  s.on(`in`, "keyup", false, proc(e: JsValue) = s.key(e, false))
  s.on(`in`, "beforeinput", false, proc(e: JsValue) =
    case jsString(jsGet(e, "inputType"))
    of "insertText":
      if not jsBool(jsGet(e, "isComposing")) and not s.composing:
        discard jsCall(e, "preventDefault", [])
        let t = jsGet(e, "data")
        if jsType(t) == jsStringT and jsString(t) != "":
          discard s.send(SurfaceEvent(kind: textInput,
                                      text: jsString(t)))
    of "insertCompositionText", "deleteCompositionText",
       "insertFromComposition":
      discard
    else:
      # Keys did what the rest do (Enter, Backspace, …); a paste comes
      # as its own event.
      discard jsCall(e, "preventDefault", []))
  s.on(`in`, "compositionstart", true, proc(e: JsValue) =
    s.composing = true)
  s.on(`in`, "compositionupdate", true, proc(e: JsValue) =
    let t = jsString(jsGet(e, "data"))
    discard s.send(SurfaceEvent(kind: textComposition, text: t,
                                caret: t.runeLen)))
  s.on(`in`, "compositionend", true, proc(e: JsValue) =
    s.composing = false
    discard s.send(SurfaceEvent(kind: textComposition))
    let t = jsGet(e, "data")
    if jsType(t) == jsStringT and jsString(t) != "":
      discard s.send(SurfaceEvent(kind: textInput, text: jsString(t)))
    jsSet(`in`, "value", jsValueOf("")))
  s.on(`in`, "copy", false, proc(e: JsValue) = s.copy(e, "copy"))
  s.on(`in`, "cut", false, proc(e: JsValue) = s.copy(e, "cut"))
  s.on(`in`, "paste", false, proc(e: JsValue) =
    discard jsCall(e, "preventDefault", [])
    let data = jsGet(e, "clipboardData")
    if jsIsNull(data) or jsIsUndefined(data):
      return
    # The text formats pasted: plain text, HTML, and those of apps.
    var reps: seq[Representation]
    let types = jsGet(data, "types")
    for i in 0 ..< jsLen(types):
      let f = jsString(jsGetIx(types, i))
      if f == "Files":
        continue
      let v = jsString(jsCall(data, "getData", [jsValueOf(f)]))
      if v != "":
        reps.add bytes(Format(f), v)
    s.w.b.clip = jsString(jsCall(data, "getData",
                                 [jsValueOf("text/plain")]))
    s.w.b.clipData = Data()
    if reps.len > 0:
      s.w.b.clipData = newData(newItem(reps))
    discard s.send(SurfaceEvent(kind: surfaceCommand, text: "paste")))

## copy has the content copy, or cut, its selection, and gives the
## browser the text, which the clipboard event carries to the system's
## clipboard.
proc copy*(s: webSurface, e: JsValue, cmd: string) =
  discard jsCall(e, "preventDefault", [])
  if not s.copied:
    discard s.send(SurfaceEvent(kind: surfaceCommand, text: cmd))
  s.copied = false
  let text = s.w.b.clip
  let all = s.w.b.clipData
  let data = jsGet(e, "clipboardData")
  if not jsIsNull(data) and not jsIsUndefined(data) and text != "":
    discard jsCall(data, "setData",
                   [jsValueOf("text/plain"), jsValueOf(text)])
    # The other text formats copied, as a rich text's HTML.
    for f in all.formats():
      if f == Text or f == FileList or f == PNG:
        continue
      let (b, e2) = all.read(f)
      if e2.isNil:
        discard jsCall(data, "setData",
                       [jsValueOf(string(f)),
                        jsValueOf(bytesToString(b))])

proc buttonOf*(b: int): int =
  case b
  of 1: 2
  of 2: 1
  else: 0

## point returns where a pointer event happened in the canvas, in DIPs.
proc point*(s: webSurface, e: JsValue): tuple[x, y: float64] =
  let r = jsCall(s.canvas, "getBoundingClientRect", [])
  (jsFloat(jsGet(e, "clientX")) - jsFloat(jsGet(r, "left")),
   jsFloat(jsGet(e, "clientY")) - jsFloat(jsGet(r, "top")))

## mods returns the modifiers of an event. Command is Control on a Mac,
## as the shortcuts of package ui, which take a browser for another
## system than macOS, expect Control where Macs have Command.
proc mods*(s: webSurface, e: JsValue): Modifiers =
  var m: Modifiers = 0
  if jsBool(jsGet(e, "shiftKey")):
    m = m or modShift
  if jsBool(jsGet(e, "altKey")):
    m = m or modAlt
  var ctrl = jsBool(jsGet(e, "ctrlKey"))
  var meta = jsBool(jsGet(e, "metaKey"))
  if s.w.b.mac:
    swap(ctrl, meta)
  if ctrl:
    m = m or modCtrl
  if meta:
    m = m or modSuper
  m

## key handles a key going down or up in the textarea. Keys that type
## text come as text from beforeinput, after this, and keys an input
## method takes are its own. The browser does nothing of its own with
## keys but those typing text, copying and pasting, and those of its own
## (F5, F11, F12, …).
proc key*(s: webSurface, e: JsValue, down: bool) =
  if down:
    s.copied = false
  if jsBool(jsGet(e, "isComposing")) or jsInt(jsGet(e, "keyCode")) == 229:
    return
  let name = jsString(jsGet(e, "key"))
  let mods = s.mods(e)
  case name
  of "Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph":
    discard s.send(SurfaceEvent(kind: modifiersChanged, mods: mods))
    return
  of "Dead", "Process", "Unidentified", "Compose":
    return
  else: discard
  let code = jsString(jsGet(e, "code"))
  let k = keyOf(name, code)
  let physical = codeKey(code)
  let primary = (mods and modCtrl) != 0
  if down and primary and (mods and (modAlt or modShift)) == 0:
    case k
    of keyV:
      # The paste event brings the clipboard's text.
      return
    of keyC, keyX:
      # The content copies now, and the copy event that follows gives
      # the browser the text.
      discard s.send(SurfaceEvent(kind: keyPressed, key: k,
        physicalKey: physical, mods: mods,
        repeat: jsBool(jsGet(e, "repeat"))))
      s.copied = true
      return
    else: discard
  let kind = if down: keyPressed else: keyReleased
  discard s.send(SurfaceEvent(kind: kind, key: k, physicalKey: physical,
                              mods: mods,
                              repeat: jsBool(jsGet(e, "repeat"))))
  if not down:
    return
  if name == "F5" or name == "F11" or name == "F12":
    discard
  elif name.runeLen > 1 or primary:
    discard jsCall(e, "preventDefault", [])

const
  webNamedKeys* = {
    "Enter": keyEnter, "Escape": keyEscape, "Backspace": keyBackspace,
    "Tab": keyTab, " ": keySpace, "Delete": keyDelete,
    "Insert": keyInsert, "Home": keyHome, "End": keyEnd,
    "PageUp": keyPageUp, "PageDown": keyPageDown,
    "ArrowLeft": keyLeft, "ArrowRight": keyRight,
    "ArrowUp": keyUp, "ArrowDown": keyDown,
    "ContextMenu": keyContextMenu,
    "BrowserBack": keyBack, "BrowserForward": keyForward,
    "F1": keyF1, "F2": keyF2, "F3": keyF3, "F4": keyF4, "F5": keyF5,
    "F6": keyF6, "F7": keyF7, "F8": keyF8, "F9": keyF9, "F10": keyF10,
    "F11": keyF11, "F12": keyF12,
  }.toTable

  webCodeKeys* = {
    "Minus": keyMinus, "Equal": keyEqual, "Comma": keyComma,
    "Period": keyPeriod, "Slash": keySlash, "Semicolon": keySemicolon,
    "Quote": keyQuote, "BracketLeft": keyBracketLeft,
    "BracketRight": keyBracketRight, "Backslash": keyBackslash,
    "Backquote": keyBackquote, "Space": keySpace,
  }.toTable

## keyOf returns the key of a KeyboardEvent's key and code: letters and
## digits by what they type, as other systems tell them.
proc keyOf*(name, code: string): Key =
  if name.runeLen == 1:
    let k = keyForRune(name.runeAt(0).int32)
    if k != keyUnknown:
      return k
  if webNamedKeys.hasKey(name):
    return webNamedKeys[name]
  codeKey(code)

## codeKey returns the key at a KeyboardEvent's code: its position on an
## ANSI US keyboard (SurfaceEvent.physicalKey).
proc codeKey*(code: string): Key =
  if code.len == 4 and code[0 ..< 3] == "Key":
    return keyA + Key(ord(code[3]) - ord('A'))
  if code.len == 6 and code[0 ..< 5] == "Digit":
    return key0 + Key(ord(code[5]) - ord('0'))
  if webCodeKeys.hasKey(code):
    return webCodeKeys[code]
  keyUnknown

## focus gives the window the keyboard: its textarea.
proc focus*(s: webSurface) =
  let opts = jsObj()
  jsSet(opts, "preventScroll", jsTrueV)
  discard jsCall(s.input, "focus", [opts])

## measure takes the canvas's size and the device pixel ratio, and tells
## the content when they changed.
proc measure*(s: webSurface): bool =
  let r = jsCall(s.canvas, "getBoundingClientRect", [])
  let w = jsFloat(jsGet(r, "width"))
  let h = jsFloat(jsGet(r, "height"))
  let scale = devicePixelRatio()
  if w == s.width and h == s.height and scale == s.scale:
    return false
  s.width = w
  s.height = h
  s.scale = scale
  discard s.send(SurfaceEvent(kind: surfaceResize))
  true

## pixels returns the size of frames, as package ui computes it.
proc pixels*(s: webSurface): tuple[w, h: int] =
  (int(ceil(float64(float32(s.width) * float32(s.scale)))),
   int(ceil(float64(float32(s.height) * float32(s.scale)))))

## drawFrame handles a frame of the browser's, when the content asked
## for one, with the canvas as large as the frame and WebGL's context
## current.
proc drawFrame*(s: webSurface) =
  s.pending = false
  if s.closed or not s.w.visible:
    return
  discard s.measure()
  let (pw, ph) = s.pixels()
  if jsInt(jsGet(s.canvas, "width")) != pw or
      jsInt(jsGet(s.canvas, "height")) != ph:
    jsSet(s.canvas, "width", jsValueOf(pw))
    jsSet(s.canvas, "height", jsValueOf(ph))
  # The GL context becomes current here once internal/gpu/gl is ported.
  discard s.send(SurfaceEvent(kind: surfaceFrame))

method native*(s: webSurface): SurfaceNative = SurfaceNative()

method size*(s: webSurface): tuple[width, height, scale: float64] =
  (s.width, s.height, s.scale)

method requestFrame*(s: webSurface) =
  if s.pending or s.closed:
    return
  s.pending = true
  s.request = jsCall(jsGlobal(), "requestAnimationFrame", [s.frame])

## refreshRate is unknown: browsers do not tell it.
method refreshRate*(s: webSurface): float64 = 0

## occluded reports whether the page is hidden, as in a tab in the
## background, where browsers give no frames.
method occluded*(s: webSurface): bool =
  jsBool(jsGet(jsGet(jsGlobal(), "document"), "hidden"))

method presentPixels*(s: webSurface, pix: openArray[byte],
                      stride, width, height: int) =
  if not s.gl.isNil:
    # presenter.present once internal/gpu/gl lands.
    return
  if jsIsUndefined(s.ctx2d) or jsIsNull(s.ctx2d) or
      width <= 0 or height <= 0:
    return
  # ImageData holds straight RGBA; frames are premultiplied BGRA.
  let n = 4 * width * height
  if s.rgba.len < n:
    s.rgba = newSeq[byte](n)
  for y in 0 ..< height:
    for x in countup(0, 4 * width - 4, 4):
      let so = y * stride + x
      let b = pix[so]
      let g = pix[so + 1]
      var r = pix[so + 2]
      let a = pix[so + 3]
      var rr = r
      var gg = g
      var bb = b
      if a != 0 and a != 255:
        rr = unpremul(r, a)
        gg = unpremul(g, a)
        bb = unpremul(b, a)
      let dst = 4 * width * y + x
      s.rgba[dst] = rr
      s.rgba[dst + 1] = gg
      s.rgba[dst + 2] = bb
      s.rgba[dst + 3] = a
  if jsIsUndefined(s.image) or jsInt(jsGet(s.image, "width")) != width or
      jsInt(jsGet(s.image, "height")) != height:
    s.image = jsCall(s.ctx2d, "createImageData",
                     [jsValueOf(width), jsValueOf(height)])
  jsCopyToJS(jsGet(s.image, "data"), s.rgba)
  discard jsCall(s.ctx2d, "putImageData",
                 [s.image, jsValueOf(0), jsValueOf(0)])

proc unpremul*(c, a: byte): byte =
  byte(min(255, (int(c) * 255 + int(a) div 2) div int(a)))

const webCursors: array[Cursor, string] = [
  cursorDefault: "default", cursorPointer: "pointer",
  cursorText: "text", cursorMove: "move",
  cursorResizeEW: "ew-resize", cursorResizeNS: "ns-resize",
  cursorResizeNWSE: "nwse-resize", cursorResizeNESW: "nesw-resize",
  cursorNotAllowed: "not-allowed", cursorCrosshair: "crosshair",
  cursorGrab: "grab", cursorGrabbing: "grabbing",
  cursorResizeN: "n-resize", cursorResizeE: "e-resize",
  cursorResizeS: "s-resize", cursorResizeW: "w-resize",
  cursorResizeColumn: "col-resize", cursorResizeRow: "row-resize",
  cursorVerticalText: "vertical-text", cursorCopy: "copy",
  cursorAlias: "alias", cursorContextMenu: "context-menu",
  cursorNone: "none",
]

method setCursor*(s: webSurface, c: Cursor) =
  var name = "default"
  if webCursors[c] != "":
    name = webCursors[c]
  jsSet(jsGet(s.canvas, "style"), "cursor", jsValueOf(name))

## setTextInput moves the textarea to the caret, where input methods show
## their candidates, and lets touch devices show their keyboard while an
## element takes text: browsers show it, or hide it, as the inputmode of
## the focused textarea changes. Keys of a hardware keyboard come either
## way.
method setTextInput*(s: webSurface, t: TextInputState) =
  if t.active != s.text.active:
    discard jsCall(s.input, "setAttribute",
      [jsValueOf("inputmode"),
       jsValueOf(if t.active: "text" else: "none")])
  s.text = t
  let st = jsGet(s.input, "style")
  if not t.active:
    jsSet(st, "left", jsValueOf("0"))
    jsSet(st, "top", jsValueOf("0"))
    return
  jsSet(st, "left", jsValueOf($t.caret.x & "px"))
  jsSet(st, "top", jsValueOf($t.caret.y & "px"))
  jsSet(st, "height", jsValueOf($max(t.caret.h, 1.0) & "px"))

method updateAccessibility*(s: webSurface, tree: AccessTree) = discard
method startDataDrag*(s: webSurface, r: DragRequest) = discard
method cancelDataDrag*(s: webSurface) = discard
method setDropFormats*(s: webSurface, formats: seq[Format]) = discard
method placeWebViews*(s: webSurface, views: seq[WebViewPlacement]) = discard

method newWebView*(s: webSurface, opts: WindowOptions,
                   h: WindowHandler): tuple[w: WebView, err: ref CatchableError] =
  (nil, errWeb())

proc surfaceClosed*(s: webSurface) =
  s.closed = true
  if s.pending:
    discard jsCall(jsGlobal(), "cancelAnimationFrame", [s.request])
  if not jsIsUndefined(s.observer):
    discard jsCall(s.observer, "disconnect", [])
  for l in s.globalListeners:
    discard jsCall(l.target, "removeEventListener",
                   [jsValueOf(l.event), l.fn])
  # The functions may still be called back once: they find the surface
  # closed. They are released after the frame.
  let funcs = s.funcs
  let frame = s.frame
  var release: JsValue
  release = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    for f in funcs:
      jsFuncRelease(f)
    jsFuncRelease(frame)
    jsFuncRelease(release)
    jsUndef)
  discard jsCall(jsGlobal(), "setTimeout", [release, jsValueOf(1000)])
