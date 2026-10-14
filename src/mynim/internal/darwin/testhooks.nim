proc msgSetMarkedText*(obj: id, s: SEL, text: id,
                       selected, replacement: nsRange)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}
proc msgInsertText*(obj: id, s: SEL, text: id, replacement: nsRange)
  {.importc: "objc_msgSend", dynlib: libObjC, cdecl.}

## testhooks.go: drives native UI the way a user would, for the GUI
## tests in internal/e2e. All of it must run on the main thread.

## testPerformMenuItem activates an item of the application menu, found
## by the titles along its path.
proc testPerformMenuItem*(path: varargs[string]):
    ref CatchableError =
  var err: ref CatchableError
  withPool(proc() =
    var menu = send(theBackend.app, "mainMenu")
    for i, title in path:
      if menu == nil:
        err = newException(ValueError,
          "mynim: menu has no submenu")
        return
      let index = sendInt(menu, "indexOfItemWithTitle:",
        argu(nsString(title)))
      if index < 0:
        err = newException(ValueError,
          "mynim: no menu item " & title)
        return
      if i == path.len - 1:
        discard send(menu, "performActionForItemAtIndex:",
          argu(index))
        return
      menu = send(send(menu, "itemAtIndex:", argu(index)),
        "submenu"))
  err

## testPerformKeyEquivalent sends a key press with the Command key (and
## shift when requested) to the application menu and reports whether an
## item handled it.
proc testPerformKeyEquivalent*(key: string, shift: bool): bool =
  var handled = false
  withPool(proc() =
    var flags = uint(1 shl 20)
    if shift:
      flags = flags or (1 shl 17)
    let ev = msgKeyEvent(`class`("NSEvent"),
      sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
      10, NSPoint(), flags, 0, 0, nil, nsString(key), nsString(key),
      false, 0)
    handled = sendBool(send(theBackend.app, "mainMenu"),
      "performKeyEquivalent:", argu(ev)))
  handled

## testOnScreen reports whether some of a window shows on screen, as the
## window server reports once it put the window there.
proc testOnScreen*(handle: uint): bool =
  const occlusionStateVisible = 1 shl 1
  (sendInt(cast[id](handle), "occlusionState") and
    occlusionStateVisible) != 0

## testEndSheet ends the sheet attached to a window as if its first
## button was clicked, and reports whether there was one.
proc testEndSheet*(handle: uint): bool =
  let sheet = send(cast[id](handle), "attachedSheet")
  if sheet == nil:
    return false
  discard send(cast[id](handle), "endSheet:returnCode:",
    argu(sheet), argu(nsAlertFirstButtonReturn))
  true

proc testMouse(handle: uint, x, y: float64, viaApp: bool,
               types: openArray[uint]) =
  withPool(proc() =
    let win = cast[id](handle)
    let content = msgRect(send(win, "contentView"), sel("frame"))
    let loc = NSPoint(x: x, y: content.size.height - y)
    let number = sendInt(win, "windowNumber")
    for typ in types:
      let ev = msgMouseEvent(`class`("NSEvent"),
        sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        typ, loc, 0, 0, number, nil, 0, 1, 1)
      if viaApp:
        discard send(theBackend.app, "postEvent:atStart:",
          argu(ev), argu(0))
      else:
        discard send(win, "sendEvent:", argu(ev)))

## testClick sends a left mouse down and up at a point of a window's
## content (top-left origin, in points), like a user click.
proc testClick*(handle: uint, x, y: float64) =
  testMouse(handle, x, y, false, [1'u, 2])

## testAppClick is testClick through the application's event queue,
## where event monitors see the click as they see the user's, as those
## of transient popovers that close on clicks elsewhere.
proc testAppClick*(handle: uint, x, y: float64) =
  testMouse(handle, x, y, true, [1'u, 2])

## testAppPress is half of testAppClick: the left mouse down, or the up,
## which a user's click handles apart, a frame or more later.
proc testAppPress*(handle: uint, x, y: float64, down: bool) =
  var typ = 2'u # NSEventTypeLeftMouseUp
  if down:
    typ = 1 # NSEventTypeLeftMouseDown
  testMouse(handle, x, y, true, [typ])

## testDrag presses the primary button at the first of points, in points
## from the top-left corner of a window's content, drags the pointer
## through the others, and releases it at the last.
proc testDrag*(handle: uint, points: openArray[tuple[x, y: float64]]) =
  withPool(proc() =
    let win = cast[id](handle)
    let content = msgRect(send(win, "contentView"), sel("frame"))
    let number = sendInt(win, "windowNumber")
    for i, p in points:
      var typ = 6'u # NSEventTypeLeftMouseDragged
      if i == 0:
        typ = 1 # NSEventTypeLeftMouseDown
      elif i == points.len - 1:
        typ = 2 # NSEventTypeLeftMouseUp
      let ev = msgMouseEvent(`class`("NSEvent"),
        sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        typ, NSPoint(x: p.x, y: content.size.height - p.y), 0, 0,
        number, nil, 0, 1, 1)
      discard send(win, "sendEvent:", argu(ev)))

## testControlClick Control-clicks (x, y), in points from the top-left
## corner of a window's content.
proc testControlClick*(handle: uint, x, y: float64) =
  withPool(proc() =
    let win = cast[id](handle)
    let content = msgRect(send(win, "contentView"), sel("frame"))
    let loc = NSPoint(x: x, y: content.size.height - y)
    let number = sendInt(win, "windowNumber")
    for typ in [1'u, 2]: # NSEventTypeLeftMouseDown, LeftMouseUp
      let ev = msgMouseEvent(`class`("NSEvent"),
        sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        typ, loc, 1 shl 18, 0, number, nil, 0, 1, 1)
      discard send(win, "sendEvent:", argu(ev)))

## testSideButton presses and releases a mouse's back or forward button
## (buttons 3 and 4) in a window showing native UI.
proc testSideButton*(handle: uint, back: bool): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return false
  var button = int64(4)
  if back:
    button = 3
  withPool(proc() =
    let number = sendInt(w.win, "windowNumber")
    for typ in [25'u, 26]: # NSEventTypeOtherMouseDown, OtherMouseUp
      var ev = msgMouseEvent(`class`("NSEvent"),
        sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        typ, NSPoint(x: 10, y: 10), 0, 0, number, nil, 0, 1, 1)
      # NSEvent makes other buttons the middle one: number it.
      let cg = send(ev, "CGEvent")
      cgEventSetIntegerValueField(cg, 3, button)
        # kCGMouseEventButtonNumber
      ev = send(`class`("NSEvent"), "eventWithCGEvent:", argu(cg))
      let name = if typ == 26: "otherMouseUp:" else: "otherMouseDown:"
      discard send(w.surface.view, name, argu(ev)))
  true

## testTrafficLights returns where the top-left corner of a window's
## close button is, in points from the top-left corner of the window.
proc testTrafficLights*(handle: uint): tuple[x, y: float64] =
  let win = cast[id](handle)
  let btn = send(win, "standardWindowButton:", argu(0))
  let f = msgRect(btn, sel("frame"))
  let parent = send(btn, "superview")
  let a = msgPointFromView(parent, sel("convertPoint:toView:"),
    f.origin, nil)
  let b = msgPointFromView(parent, sel("convertPoint:toView:"),
    NSPoint(x: f.origin.x + f.size.width,
            y: f.origin.y + f.size.height), nil)
  (min(a.x, b.x),
   msgRect(win, sel("frame")).size.height - max(a.y, b.y))

## testSetWindowAppearance gives a window its own dark or light
## appearance, apart from the application's.
proc testSetWindowAppearance*(handle: uint, dark: bool) =
  var name = "NSAppearanceNameAqua"
  if dark:
    name = "NSAppearanceNameDarkAqua"
  withPool(proc() =
    discard send(cast[id](handle), "setAppearance:",
      argu(send(`class`("NSAppearance"), "appearanceNamed:",
        argu(nsString(name))))))

## testWebViewAttached reports whether a window's web view is in its
## view hierarchy.
proc testWebViewAttached*(handle: uint): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  w != nil and send(w.web, "window") == w.win

## testIsFrontmost reports whether the application is the frontmost one,
## which NSApp's isActive does not tell while a nonactivating panel is
## the key window: it reports the app active then.
proc testIsFrontmost*(): bool =
  var front = false
  withPool(proc() =
    let app = send(send(`class`("NSWorkspace"), "sharedWorkspace"),
      "frontmostApplication")
    front = app != nil and
      sendInt(app, "processIdentifier") == getCurrentProcessId())
  front

## testCollectionBehavior returns a window's
## NSWindowCollectionBehavior.
proc testCollectionBehavior*(handle: uint): uint =
  uint(sendInt(cast[id](handle), "collectionBehavior"))

## testDockInspector opens the web inspector of a window docked to it,
## and reports whether the window has one.
proc testDockInspector*(handle: uint): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil:
    return false
  let ins = w.inspector()
  if ins == nil:
    return false
  discard send(ins, "show")
  discard send(ins, "attach")
  true

## testInspectorPlace reports where the docked inspector of a window is:
## "content" in its content view, "frame" elsewhere in the window, ""
## when the window has none.
proc testInspectorPlace*(handle: uint): string =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil:
    return ""
  proc find(view: id): id =
    if view != w.web and sendBool(view, "isKindOfClass:",
        argu(`class`("WKWebView"))):
      return view
    for sub in arrayItems(send(view, "subviews")):
      let found = find(sub)
      if found != nil:
        return found
    nil
  let content = send(w.win, "contentView")
  let ins = find(send(content, "superview"))
  if ins == nil:
    ""
  elif sendBool(ins, "isDescendantOf:", argu(content)):
    "content"
  else:
    "frame"

## testSetDroppedFiles makes paths the files of the next drop on a
## window's page, as if they had been dragged there.
proc testSetDroppedFiles*(handle: uint, paths: seq[string]) =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w != nil:
    w.dropped = paths

## testDockTileImage renders the content of the Dock tile offscreen, as
## the Dock does, to PNG; nil when the tile shows the plain application
## icon.
proc testDockTileImage*(): seq[byte] =
  var data: seq[byte]
  withPool(proc() =
    let view = send(send(theBackend.app, "dockTile"), "contentView")
    if view == nil:
      return
    let bounds = msgRect(view, sel("bounds"))
    let rep = msgInitRect(view,
      sel("bitmapImageRepForCachingDisplayInRect:"), bounds)
    discard msgInitRectID(view,
      sel("cacheDisplayInRect:toBitmapImageRep:"), bounds, rep)
    data = goBytes(send(rep, "representationUsingType:properties:",
      argu(4), argu(send(`class`("NSDictionary"), "dictionary")))))
  data

## testDockMenu returns the titles of the Dock menu the app delegate
## returns, and clicks the item at click unless it is -1.
proc testDockMenu*(click: int): seq[string] =
  var titles: seq[string]
  withPool(proc() =
    let menu = send(send(theBackend.app, "delegate"),
      "applicationDockMenu:", argu(theBackend.app))
    if menu == nil:
      return
    for it in arrayItems(send(menu, "itemArray")):
      titles.add(goString(send(it, "title")))
    if click >= 0:
      discard send(menu, "performActionForItemAtIndex:", argu(click)))
  titles

## testRecentDocuments returns the paths of the documents the app
## recorded with App.addRecentDocument and did not clear, in the order
## the system keeps them.
proc testRecentDocuments*(): seq[string] =
  var paths: seq[string]
  withPool(proc() =
    for u in arrayItems(send(
        send(`class`("NSDocumentController"),
             "sharedDocumentController"), "recentDocumentURLs")):
      paths.add(goString(send(u, "path"))))
  paths

## testFullScreenHidesToolbar reports whether a window asks to hide its
## toolbar with the menu bar when it enters full screen.
proc testFullScreenHidesToolbar*(handle: uint): bool =
  let win = cast[id](handle)
  let delegate = send(win, "delegate")
  if not respondsTo(delegate,
      "window:willUseFullScreenPresentationOptions:"):
    return false
  let options = send(delegate,
    "window:willUseFullScreenPresentationOptions:", argu(win),
    argu(uint(presentationFullScreen or presentationAutoHideMenuBar)))
  (cast[uint](options) and uint(presentationAutoHideToolbar)) != 0

## keyboardLayoutSelected reports whether the input source is a keyboard
## layout, which inserts what keys type, rather than an input method,
## which composes it.
proc keyboardLayoutSelected(): bool =
  let src = tisCopyCurrentKeyboardInputSource()
  if src == nil:
    return false
  defer: cfRelease(src)
  let typ = tisGetInputSourceProperty(src, kTISPropertyInputSourceType)
  typ != nil and cfEqual(typ, kTISTypeKeyboardLayout)

## testClickAndType clicks (x, y) in a window showing native UI and
## types text there at once, before the window draws another frame,
## with key events that go through the input method as a keyboard's do.
## It reports false for a window showing a web page, and while the
## input source is an input method, which would compose the keys rather
## than insert them.
proc testClickAndType*(handle: uint, x, y: float64,
                       text: string): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil or not keyboardLayoutSelected():
    return false
  testClick(handle, x, y)
  withPool(proc() =
    let number = sendInt(w.win, "windowNumber")
    for r in text.runes:
      let chars = nsString($r)
      for typ in [10'u, 11]: # NSEventTypeKeyDown, KeyUp
        let ev = msgKeyEvent(`class`("NSEvent"),
          sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
          typ, NSPoint(), 0, 0, number, nil, chars, chars, false, 0)
        discard send(w.win, "sendEvent:", argu(ev)))
  true

## testKey presses and releases the key of virtual key code code, typing
## chars, in a window showing native UI, as the keyboard does: the
## events go through the window to its first responder, the surface and
## its input method or a web view.
proc testKeyShift*(handle: uint, code: uint16, chars: string,
                   shift: bool): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return false
  var flags = 0'u
  if shift:
    flags = 1 shl 17 # NSEventModifierFlagShift
  withPool(proc() =
    let number = sendInt(w.win, "windowNumber")
    let s = nsString(chars)
    for typ in [10'u, 11]: # NSEventTypeKeyDown, KeyUp
      let ev = msgKeyEvent(`class`("NSEvent"),
        sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
        typ, NSPoint(), flags, 0, number, nil, s, s, false, code)
      discard send(w.win, "sendEvent:", argu(ev)))
  true

proc testKey*(handle: uint, code: uint16, chars: string): bool =
  testKeyShift(handle, code, chars, false)

## testAppKey posts a key down and up to the application's event queue,
## which sends it to the key window as it does the user's keys, to a
## page or native UI.
proc testAppKey*(code: uint16, chars: string) =
  withPool(proc() =
    let number = sendInt(send(theBackend.app, "keyWindow"),
      "windowNumber")
    let s = nsString(chars)
    for typ in [10'u, 11]: # NSEventTypeKeyDown, KeyUp
      let ev = msgKeyEvent(`class`("NSEvent"),
        sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
        typ, NSPoint(), 0, 0, number, nil, s, s, false, code)
      discard send(theBackend.app, "postEvent:atStart:",
        argu(ev), argu(0)))

## testCompose does what an input method does to a window showing
## native UI: it shows text as the composition, its caret at rune
## caret, or with commit, inserts it. It reports false for a window
## showing a web page.
proc testComposeOver*(handle: uint, text: string, caret: int,
                      commit: bool, `from`, length: int): bool =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return false
  withPool(proc() =
    var replace = nsRange(location: nsNotFound)
    if `from` >= 0:
      replace = nsRange(location: uint(`from`), length: uint(length))
    if commit:
      msgInsertText(w.surface.view,
        sel("insertText:replacementRange:"), nsString(text), replace)
      return
    let runes = toRunes(text)
    let caretAt = nsRange(location: uint(utf16Len($runes[0 ..< caret])))
    msgSetMarkedText(w.surface.view,
      sel("setMarkedText:selectedRange:replacementRange:"),
      nsString(text), caretAt, replace))
  true

proc testCompose*(handle: uint, text: string, caret: int,
                  commit: bool): bool =
  testComposeOver(handle, text, caret, commit, -1, 0)

## testInputClient returns what a window's surface tells input methods:
## the selected range and the whole text of their document.
proc testInputClient*(handle: uint):
    tuple[selected: tuple[a, b: int], document: string] =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return ((-1, 0), "")
  let r = w.surface.selectedRange()
  var document: string
  withPool(proc() =
    let (doc, _, _) = w.surface.document()
    var actual: nsRange
    var length = uint(units(doc))
    if w.surface.input.client != nil:
      length = (1 shl 31) - 1
    document = stringOf(w.surface.substring(
      nsRange(length: length), actual, true)))
  ((int(r.location), int(r.length)), document)

var
  testDragInfo: id
  testDragAt: NSPoint
  testDragPB: id
  testDragMask: uint = 1
  testDragRegistered = false

proc registerTestDragInfo() =
  if testDragRegistered:
    return
  testDragRegistered = true
  discard classDef("MyNimTestDraggingInfo", "NSObject", @[], @[
    methodDef("draggingLocation",
      cast[pointer](proc(self: id, cmd: SEL): NSPoint {.cdecl.} =
        testDragAt), "{CGPoint=dd}@:"),
    methodDef("draggingPasteboard",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
        testDragPB), "@@:"),
    methodDef("draggingSourceOperationMask",
      cast[pointer](proc(self: id, cmd: SEL): uint {.cdecl.} =
        testDragMask), "Q@:"),
  ])
  testDragInfo = send(send(`class`("MyNimTestDraggingInfo"), "alloc"),
    "init")
  testDragPB = retain(send(`class`("NSPasteboard"),
    "pasteboardWithUniqueName"))

## testDropFiles drags files over (x, y), in points from the top-left
## corner of a window's content, and drops them there, as Finder would:
## it calls the surface's dragging methods with an NSDraggingInfo of its
## own, and puts on the pasteboard the file reference URLs of the files
## that exist at those paths, with no symbolic links. It reports
## whether the surface took the files over that point and whether it
## took the drop.
proc testDropFiles*(handle: uint, x, y: float64,
                    paths: seq[string]): tuple[over, dropped: bool] =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return (false, false)
  registerTestDragInfo()
  var over = false
  var dropped = false
  withPool(proc() =
    let content = msgRect(send(w.win, "contentView"), sel("frame"))
    testDragMask = 1
    testDragAt = NSPoint(x: x, y: content.size.height - y)
    discard send(testDragPB, "clearContents")
    var urls: seq[id]
    for p in paths:
      var u = fileURL(p)
      let ref0 = send(u, "fileReferenceURL")
      if ref0 != nil and goString(send(send(ref0, "filePathURL"),
          "path")) == p:
        u = ref0
      urls.add(u)
    discard send(testDragPB, "writeObjects:", argu(nsArray(urls)))
    let v = w.surface.view
    over = send(v, "draggingEntered:", argu(testDragInfo)) != nil
    over = send(v, "draggingUpdated:", argu(testDragInfo)) != nil and over
    if not over:
      discard send(v, "draggingExited:", argu(testDragInfo))
      return
    dropped = sendBool(v, "prepareForDragOperation:",
      argu(testDragInfo)) and sendBool(v, "performDragOperation:",
      argu(testDragInfo)))
  (over, dropped)

## testDropData exercises native source pasteboard providers and the
## destination protocol with serialized data (no core session token).
proc testDropData*(handle: uint, x, y: float64, data: transfer.Data,
                   operations: transfer.Operation):
    tuple[operation: transfer.Operation, dropped: bool] =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return
  discard testDropFiles(handle, -1, -1, @[])
  var operation: transfer.Operation
  var dropped = false
  withPool(proc() =
    testDragMask = macOperations(operations)
    let content = msgRect(send(w.win, "contentView"), sel("frame"))
    testDragAt = NSPoint(x: x, y: content.size.height - y)
    let src = macDataSource(r: DragRequest(data: data.snapshot()))
    discard send(testDragPB, "clearContents")
    discard send(testDragPB, "writeObjects:",
      argu(nsArray(src.pasteboardItems())))
    let v = w.surface.view
    operation = goOperations(cast[uint](send(v, "draggingEntered:",
      argu(testDragInfo))))
    if operation != transfer.None:
      dropped = sendBool(v, "performDragOperation:",
        argu(testDragInfo))
    discard send(v, "draggingExited:", argu(testDragInfo))
    discard send(testDragPB, "clearContents")
    for p in src.providers:
      macDragProviders.del(p)
      release(p))
  (operation, dropped)

## TestAccessNode is an element of native UI as assistive technology
## reads it through NSAccessibility.
type TestAccessNode* = object
  role*, subrole*, label*, value*: string
  ## frame is in points of the screen, its origin at the bottom left.
  frame*: array[4, float64]
  focused*: bool
  depth*: int
  children*: int
  obj*: id

## testAccessibility reads the elements of a window showing native UI
## as assistive technology does, depth first.
proc testAccessibility*(handle: uint): seq[TestAccessNode] =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return @[]
  var out0: seq[TestAccessNode]
  withPool(proc() =
    proc walk(obj: id, depth: int) =
      let kids = arrayItems(send(obj, "accessibilityChildren"))
      if depth > 0:
        var n = TestAccessNode(
          role: goString(send(obj, "accessibilityRole")),
          subrole: goString(send(obj, "accessibilitySubrole")),
          label: goString(send(obj, "accessibilityLabel")) &
                 goString(send(obj, "accessibilityTitle")),
          focused: sendBool(obj, "isAccessibilityFocused"),
          depth: depth,
          children: kids.len,
          obj: obj)
        let v = send(obj, "accessibilityValue")
        if v != nil:
          n.value = goString(send(v, "description"))
        let f = msgRect(obj, sel("accessibilityFrame"))
        n.frame = [f.origin.x, f.origin.y, f.size.width,
                   f.size.height]
        out0.add(n)
      for k in kids:
        walk(k, depth + 1)
    walk(w.surface.view, 0))
  out0

## testAccessibilityPerform performs action ("press", "increment",
## "decrement", "focus" or "value" with value) on the element of a
## window showing native UI labeled label, as assistive technology
## does, and reports whether there was such an element that allowed it.
proc testAccessibilityPerform*(handle: uint, label, action,
                               value: string): bool =
  for n in testAccessibility(handle):
    if n.label != label:
      continue
    var ok = false
    withPool(proc() =
      let selector = case action
        of "press": "accessibilityPerformPress"
        of "increment": "accessibilityPerformIncrement"
        of "decrement": "accessibilityPerformDecrement"
        of "focus": "setAccessibilityFocused:"
        else: "setAccessibilityValue:"
      if not sendBool(n.obj, "isAccessibilitySelectorAllowed:",
          argu(sel(selector))):
        return
      case action
      of "focus":
        discard send(n.obj, selector, argu(1))
      of "value":
        discard send(n.obj, selector, argu(nsString(value)))
      else:
        discard sendBool(n.obj, selector)
      ok = true)
    return ok
  false

## testAccessibilityAttribute reads an attribute of the element labeled
## label through AppKit's older API, as assistive technology does: its
## value, whether it is settable, and whether the element names it.
proc testAccessibilityAttribute*(handle: uint, label, attr: string):
    tuple[value: string, settable, named, ok: bool] =
  for n in testAccessibility(handle):
    if n.label != label:
      continue
    var value: string
    var settable, named = false
    withPool(proc() =
      let name = nsString(attr)
      let v = send(n.obj, "accessibilityAttributeValue:", argu(name))
      if v != nil:
        value = goString(send(v, "description"))
      settable = sendBool(n.obj,
        "accessibilityIsAttributeSettable:", argu(name))
      for a in arrayItems(send(n.obj,
          "accessibilityAttributeNames")):
        named = named or goString(a) == attr)
    return (value, settable, named, true)
  ("", false, false, false)

## testObserve has key-value observing watch the view of a window
## showing native UI and the elements of it that assistive technology
## reads, as other code may: the runtime gives each a generated
## subclass of its class, whose methods reach the overrides of MyNim's
## classes. stop ends it.
proc testObserve*(handle: uint): proc() =
  let w = theBackend.byNSWindow.getOrDefault(cast[id](handle))
  if w == nil or w.surface == nil:
    return proc() = discard
  type Observed = tuple[obj: id, key: string]
  var list = @[Observed((w.surface.view, "frame"))]
  for n in testAccessibility(handle):
    list.add(Observed((n.obj, "accessibilityValue")))
  withPool(proc() =
    for o in list:
      # Kept until stop: an object observed must not go away.
      discard retain(o.obj)
      discard send(o.obj, "addObserver:forKeyPath:options:context:",
        argu(w.delegate), argu(nsString(o.key)), argu(0), argu(0)))
  proc() =
    withPool(proc() =
      for o in list:
        discard send(o.obj, "removeObserver:forKeyPath:",
          argu(w.delegate), argu(nsString(o.key)))
        release(o.obj))

## testDocumentChrome describes what a window's title bar shows of its
## document: the title, the file of the proxy icon, whether the icon
## shows, and the dot of an edited document.
proc testDocumentChrome*(handle: uint):
    tuple[title, file: string, icon, edited: bool] =
  var title, file: string
  var icon, edited: bool
  withPool(proc() =
    let w = cast[id](handle)
    title = goString(send(w, "title"))
    let u = send(w, "representedURL")
    if u != nil:
      file = goString(send(u, "path"))
    const documentIconButton = 4 # NSWindowDocumentIconButton
    let b = send(w, "standardWindowButton:",
      argu(documentIconButton))
    if b != nil:
      icon = not sendBool(b, "isHidden")
    edited = sendBool(w, "isDocumentEdited"))
  (title, file, icon, edited)

## testSheet returns the texts of the alert attached to a window as a
## sheet, and its button titles in the order the alert was given them
## (their tags), which testEndSheetButton takes.
proc testSheet*(handle: uint):
    tuple[texts, buttons: seq[string], ok: bool] =
  var texts, buttons: seq[string]
  var ok = false
  withPool(proc() =
    let sheet = send(cast[id](handle), "attachedSheet")
    if sheet == nil:
      return
    ok = true
    var tagged = initTable[int, string]()
    proc walk(v: id) =
      if sendBool(v, "isKindOfClass:", argu(`class`("NSButton"))):
        let t = goString(send(v, "title"))
        if t != "":
          tagged[sendInt(v, "tag") - nsAlertFirstButtonReturn] = t
      elif sendBool(v, "isKindOfClass:", argu(`class`("NSTextField"))):
        let t = goString(send(v, "stringValue"))
        if t != "":
          texts.add(t)
      for sub in arrayItems(send(v, "subviews")):
        walk(sub)
    walk(send(sheet, "contentView"))
    for i in 0 ..< tagged.len:
      buttons.add(tagged.getOrDefault(i)))
  (texts, buttons, ok)

## testEndSheetButton ends the alert attached to a window as a sheet as
## if its button i, in the order the alert was given them, was clicked.
proc testEndSheetButton*(handle: uint, i: int): bool =
  let sheet = send(cast[id](handle), "attachedSheet")
  if sheet == nil:
    return false
  discard send(cast[id](handle), "endSheet:returnCode:", argu(sheet),
    argu(nsAlertFirstButtonReturn + i))
  true
