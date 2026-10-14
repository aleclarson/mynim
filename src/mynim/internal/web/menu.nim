## menu.nim: context menus, which the page draws with HTML: browsers
## show no menus of a page's own.

const menuCSS = """
.mygo-menu{position:fixed;z-index:2147483647;min-width:180px;padding:5px;box-sizing:border-box;border-radius:8px;
font:13px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#1d1d1f;background:rgba(246,246,246,.96);
-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 8px 24px rgba(0,0,0,.18);
user-select:none;-webkit-user-select:none;cursor:default;outline:none}
.mygo-menu-item{display:flex;align-items:center;gap:16px;height:22px;padding:0 10px 0 22px;border-radius:4px;position:relative;white-space:nowrap}
.mygo-menu-item[data-checked]::before{content:"✓";position:absolute;left:7px;font-size:11px}
.mygo-menu-item>.label{flex:1}
.mygo-menu-item>.accel{opacity:.5}
.mygo-menu-item.on{background:#0a64d6;color:#fff}
.mygo-menu-item.on>.accel{opacity:.8}
.mygo-menu-item[aria-disabled=true]{opacity:.35}
.mygo-menu-separator{height:1px;margin:5px 10px;background:rgba(0,0,0,.12)}
@media (prefers-color-scheme:dark){.mygo-menu{color:#f5f5f7;background:rgba(40,40,42,.96);box-shadow:0 0 0 .5px rgba(255,255,255,.18),0 8px 24px rgba(0,0,0,.4)}
.mygo-menu-separator{background:rgba(255,255,255,.14)}}
"""

var menuStyled: bool

proc on*(p: webPopup, el: JsValue, event: string, fn: proc(e: JsValue))
proc accelText*(a: string, mac: bool): string

## listen adds a listener for the life of the menu, capturing, so that
## the window's own listeners do not see what the menu takes.
proc listen*(p: webPopup, target: JsValue, event: string,
             fn: proc(e: JsValue)) =
  let f = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    p.b.sync(proc() = fn(args[0]))
    jsUndef)
  p.funcs.add f
  discard jsCall(target, "addEventListener",
                 [jsValueOf(event), f, jsTrueV])
  p.removers.add proc() =
    discard jsCall(target, "removeEventListener",
                   [jsValueOf(event), f, jsTrueV])

proc inside*(p: webPopup, el: JsValue): bool =
  for m in p.menus:
    if jsBool(jsCall(m, "contains", [el])):
      return true
  false

## open shows menu m with its top left at (x, y), page pixels, as the
## menu of depth level, closing deeper ones.
proc open*(p: webPopup, m: Menu, x, y: float64, level: int,
           choose: proc(id: int)) =
  while p.menus.len > level:
    discard jsCall(p.menus[^1], "remove", [])
    p.menus.setLen(p.menus.len - 1)
  let doc = jsGet(jsGlobal(), "document")
  let el = jsCall(doc, "createElement", [jsValueOf("div")])
  jsSet(el, "className", jsValueOf("mygo-menu"))
  discard jsCall(el, "setAttribute",
               [jsValueOf("role"), jsValueOf("menu")])
  if p.rtl:
    discard jsCall(el, "setAttribute",
                   [jsValueOf("dir"), jsValueOf("rtl")])
  for it in m.items:
    if not it.visible:
      continue
    if it.`type` == menuItemSeparator:
      let sep = jsCall(doc, "createElement", [jsValueOf("div")])
      jsSet(sep, "className", jsValueOf("mygo-menu-separator"))
      discard jsCall(sep, "setAttribute",
                     [jsValueOf("role"), jsValueOf("separator")])
      discard jsCall(el, "appendChild", [sep])
      continue
    let row = jsCall(doc, "createElement", [jsValueOf("div")])
    jsSet(row, "className", jsValueOf("mygo-menu-item"))
    discard jsCall(row, "setAttribute",
                   [jsValueOf("role"), jsValueOf("menuitem")])
    discard jsCall(row, "setAttribute",
      [jsValueOf("aria-disabled"),
       jsValueOf(if it.enabled: "false" else: "true")])
    if it.checked and (it.`type` == menuItemCheckbox or
                       it.`type` == menuItemRadio):
      discard jsCall(row, "setAttribute",
                     [jsValueOf("data-checked"), jsValueOf("")])
    let label = jsCall(doc, "createElement", [jsValueOf("span")])
    jsSet(label, "className", jsValueOf("label"))
    jsSet(label, "textContent",
          jsValueOf(it.label.replace("&", "")))
    discard jsCall(row, "appendChild", [label])
    let accel = jsCall(doc, "createElement", [jsValueOf("span")])
    jsSet(accel, "className", jsValueOf("accel"))
    if it.`type` == menuItemSubmenu:
      jsSet(accel, "textContent",
            jsValueOf(if p.rtl: "‹" else: "›"))
    else:
      jsSet(accel, "textContent",
            jsValueOf(accelText(it.accelerator, p.b.mac)))
    discard jsCall(row, "appendChild", [accel])
    discard jsCall(el, "appendChild", [row])
    let item = it
    p.on(row, "pointerenter", proc(e: JsValue) =
      let children = jsGet(el, "children")
      for k in 0 ..< jsLen(children):
        discard jsCall(jsGet(jsGetIx(children, k), "classList"),
                       "remove", [jsValueOf("on")])
      if not item.enabled:
        return
      discard jsCall(jsGet(row, "classList"), "add",
                     [jsValueOf("on")])
      if item.`type` == menuItemSubmenu and not item.submenu.isNil:
        let r = jsCall(row, "getBoundingClientRect", [])
        var x2 = jsFloat(jsGet(r, "right")) + 2
        if p.rtl:
          x2 = jsFloat(jsGet(r, "left")) - 2
        p.open(item.submenu, x2, jsFloat(jsGet(r, "top")) - 5,
               level + 1, choose)
      else:
        p.open(Menu(items: @[]), 0, 0, level + 1, choose))
    p.on(row, "pointerup", proc(e: JsValue) =
      if item.enabled and item.`type` != menuItemSubmenu:
        choose(item.id)
        p.done = true)
  if jsLen(jsGet(el, "children")) == 0:
    return
  discard jsCall(jsGet(doc, "body"), "appendChild", [el])
  # Kept on the page.
  let vw = jsFloat(jsGet(jsGlobal(), "innerWidth"))
  let vh = jsFloat(jsGet(jsGlobal(), "innerHeight"))
  let r = jsCall(el, "getBoundingClientRect", [])
  var xx = x
  var yy = y
  if p.rtl:
    # Its top right corner at x.
    xx = max(xx - jsFloat(jsGet(r, "width")), 4)
  if xx + jsFloat(jsGet(r, "width")) > vw:
    xx = max(vw - jsFloat(jsGet(r, "width")) - 4, 0)
  if yy + jsFloat(jsGet(r, "height")) > vh:
    yy = max(vh - jsFloat(jsGet(r, "height")) - 4, 0)
  let st = jsGet(el, "style")
  jsSet(st, "left", jsValueOf($xx & "px"))
  jsSet(st, "top", jsValueOf($yy & "px"))
  p.menus.add el

## on adds a listener to an element of the menu.
proc on*(p: webPopup, el: JsValue, event: string, fn: proc(e: JsValue)) =
  let f = jsFuncOf(proc(this: JsValue, args: seq[JsValue]): JsValue =
    p.b.sync(proc() =
      if not p.done:
        fn(args[0]))
    jsUndef)
  p.funcs.add f
  discard jsCall(el, "addEventListener", [jsValueOf(event), f])

## accelText writes an accelerator as menus show it: with the symbols of
## macOS on a Mac.
proc accelText*(a: string, mac: bool): string =
  if a == "":
    return ""
  let parts = a.split("+")
  var b: string
  for i, part in parts:
    let last = i == parts.len - 1
    case part.toLowerAscii()
    of "cmdorctrl", "commandorcontrol":
      b.add(if mac: "⌘" else: "Ctrl+")
    of "cmd", "command", "super", "meta":
      b.add(if mac: "⌘" else: "Win+")
    of "ctrl", "control":
      b.add(if mac: "⌃" else: "Ctrl+")
    of "alt", "option":
      b.add(if mac: "⌥" else: "Alt+")
    of "shift":
      b.add(if mac: "⇧" else: "Shift+")
    else:
      if last:
        b.add(part[0 ..< 1].toUpperAscii() & part[1 .. ^1])
  b

## popupMenu shows m at pos in w's content, or where the pointer last
## pressed, and waits until the user chooses an item or dismisses it,
## handling events meanwhile.
method popupMenu*(b: webBackend, m: Menu, pw: Window, pos: ref Point) =
  var w: webWindow
  if not pw.isNil and pw of webWindow:
    w = webWindow(pw)
    if b.windows.len > 0:
      w = b.windows[^1]
  if w.isNil or w.closed or m.isNil or m.items.len == 0:
    return
  let doc = jsGet(jsGlobal(), "document")
  if not menuStyled:
    menuStyled = true
    let style = jsCall(doc, "createElement", [jsValueOf("style")])
    jsSet(style, "textContent", jsValueOf(menuCSS))
    discard jsCall(jsGet(doc, "head"), "appendChild", [style])
  var x = w.s.downX
  var y = w.s.downY
  if not pos.isNil:
    x = float64(pos.x)
    y = float64(pos.y)
  let r = jsCall(w.s.canvas, "getBoundingClientRect", [])
  x += jsFloat(jsGet(r, "left"))
  y += jsFloat(jsGet(r, "top"))

  let p = webPopup(b: b, w: w, rtl: m.rightToLeft)
  var chosen = 0
  let choose = proc(id: int) = chosen = id
  p.open(m, x, y, 0, choose)
  # Dismissed by a press elsewhere, Escape, or the page losing focus.
  p.listen(doc, "pointerdown", proc(e: JsValue) =
    if p.inside(jsGet(e, "target")):
      # The window keeps the keyboard.
      discard jsCall(e, "preventDefault", [])
      return
    p.done = true)
  p.listen(doc, "keydown", proc(e: JsValue) =
    if jsString(jsGet(e, "key")) == "Escape":
      discard jsCall(e, "preventDefault", [])
      discard jsCall(e, "stopPropagation", [])
      p.done = true)
  p.listen(jsGlobal(), "blur", proc(e: JsValue) =
    # The page's, not an element's, which capturing sees too.
    if jsEqual(jsGet(e, "target"), jsGlobal()):
      p.done = true)
  while not p.done and not w.closed:
    b.step()
  for el in p.menus:
    discard jsCall(el, "remove", [])
  for remove in p.removers:
    remove()
  for l in p.funcs:
    jsFuncRelease(l)
  w.s.focus()
  if chosen != 0:
    w.h.menuItemClicked(chosen)

