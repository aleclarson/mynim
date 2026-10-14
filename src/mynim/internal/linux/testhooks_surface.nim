## testhooks_surface.nim: hooks for tests of native UI with input
## methods, file drops and assistive technology.

var
  accessTestsLoaded: bool
  gSignalEmitString: proc(obj, signal, s: pointer) {.cdecl.}
  gtkIMMulticontextGetContextID: proc(im: pointer): pointer {.cdecl.}
  gtkIMMulticontextSetContextID: proc(im, id: pointer) {.cdecl.}
  atkObjectGetNAccessibleChild: proc(obj: pointer): int32 {.cdecl.}
  atkObjectRefAccessibleChild: proc(obj: pointer,
    i: int32): pointer {.cdecl.}
  atkObjectGetRole: proc(obj: pointer): int32 {.cdecl.}
  atkRoleGetName: proc(role: int32): pointer {.cdecl.}
  atkObjectGetName: proc(obj: pointer): pointer {.cdecl.}
  atkObjectRefStateSet: proc(obj: pointer): pointer {.cdecl.}
  atkStateSetContainsState: proc(set: pointer, state: int32):
    bool {.cdecl.}
  atkActionGetNActions: proc(obj: pointer): int32 {.cdecl.}
  atkActionDoAction: proc(obj: pointer, i: int32): bool {.cdecl.}
  atkTextGetText: proc(obj: pointer, start, `end`: int32):
    pointer {.cdecl.}
  atkValueGetValueAndText: proc(obj: pointer, value: ptr float64,
    text: pointer) {.cdecl.}
  atkValueSetValue: proc(obj: pointer, value: float64) {.cdecl.}
  atkEditableTextSetTextContent: proc(obj, text: pointer) {.cdecl.}
  atkComponentGrabFocus: proc(obj: pointer): bool {.cdecl.}

proc surfaceByHandle*(handle: pointer): gtkSurface =
  let w = windowByHandle(handle)
  if not w.isNil:
    return w.surface
  nil

## testSurrounding returns the text around the caret that input methods
## get from a window showing native UI, and the caret's offset in
## runes. GTK's own input method reads it back: others, as fcitx5's,
## keep it to themselves, so the window's input switches to GTK's.
proc testSurrounding*(handle: pointer):
    tuple[text: string, caret: int, ok: bool] =
  let s = surfaceByHandle(handle)
  if s.isNil:
    return ("", 0, false)
  if gtkIMMulticontextSetContextID.isNil:
    mustBind(libGTK,
      cast[ptr pointer](addr gtkIMMulticontextGetContextID),
      "gtk_im_multicontext_get_context_id")
    mustBind(libGTK,
      cast[ptr pointer](addr gtkIMMulticontextSetContextID),
      "gtk_im_multicontext_set_context_id")
  const simple = "gtk-im-context-simple"
  if goStr(gtkIMMulticontextGetContextID(s.im)) != simple:
    gtkIMMulticontextSetContextID(s.im, cs(simple))
  var p: pointer
  var cursor: int32
  if not gtkIMContextGetSurrounding(s.im, addr p, addr cursor):
    return ("", 0, true)
  let text = takeStr(p)
  let caret = runeLen(text[0 ..< max(0, min(int(cursor), text.len))])
  (text, caret, true)

## testComposeOver does what an input method that edits typed text does:
## it deletes length runes from offset from of the text around the
## caret unless from is -1, then composes text with the caret at caret,
## or commits it.
proc testComposeOver*(handle: pointer, text: string, caret: int,
    commit: bool, `from`, length: int): bool =
  let s = surfaceByHandle(handle)
  if s.isNil:
    return false
  if `from` >= 0:
    let (_, cursor, _) = testSurrounding(handle)
    discard gtkIMContextDeleteSurrounding(s.im,
      int32(`from` - cursor), int32(length))
  if commit:
    if gSignalEmitString.isNil:
      mustBind(libGObject, cast[ptr pointer](addr gSignalEmitString),
        "g_signal_emit_by_name")
    gSignalEmitString(s.im, cs("commit"), cs(text))
  else:
    # Input methods compose in contexts out of the test's reach: send
    # what the preedit-changed signal would.
    discard s.send(SurfaceEvent(kind: textComposition, text: text,
      caret: caret))
  true

## testDropFiles drags files to (x, y) of a window showing native UI and
## drops them there, as GTK tells it, and reports whether the content
## took them over there and when dropped.
proc testDropFiles*(handle: pointer, x, y: float64,
    paths: seq[string]): tuple[over, dropped: bool] =
  let s = surfaceByHandle(handle)
  if s.isNil:
    return (false, false)
  let `over` = s.fileDragOver(x, y)
  discard s.send(SurfaceEvent(kind: fileDragLeave))
  (`over`, s.dropFiles(x, y, paths))

## testMoveSurfacePointer sends real XTEST motion to the surface,
## including during GTK's native drag tracker. It is unavailable
## outside X11.
proc testMoveSurfacePointer*(handle: pointer, x, y: float64): bool =
  let s = surfaceByHandle(handle)
  if s.isNil:
    return false
  var origin: proc(win: pointer, x, y: ptr int32): int32 {.cdecl.}
  if not bindFunc(libGDK, cast[ptr pointer](addr origin),
      "gdk_window_get_origin"):
    return false
  var ox, oy: int32
  discard origin(s.eventWindow(), addr ox, addr oy)
  let scale = float64(gtkWidgetGetScaleFactor(s.area))
  testMovePointer(int((float64(ox) + x) * scale),
    int((float64(oy) + y) * scale))

proc testDataDragReady*(handle: pointer): bool =
  let s = surfaceByHandle(handle)
  not s.isNil and not s.lastPointer.isNil

## testStartSerializedDrag simulates another application: the source
## uses GTK's production providers with no token in mynim's local
## registry.
proc testStartSerializedDrag*(handle: pointer, d: transfer.Data,
    ops: transfer.Operation, done: proc(r: transfer.Result)): bool =
  let s = surfaceByHandle(handle)
  if s.isNil or s.lastPointer.isNil:
    return false
  s.startDataDrag(DragRequest(data: d.snapshot(), operations: ops,
    x: 30, y: 30, done: done))
  true

proc testCancelDataDrag*(handle: pointer) =
  let s = surfaceByHandle(handle)
  if not s.isNil:
    s.cancelDataDrag()

proc testDataDragResources*(): int = gtkDataSources.len

## testAccessNode is an element of native UI as assistive technology
## reads it through ATK: the name of its role, its name, and its value.
type
  TestAccessNode* = object
    role*, label*, value*: string
    obj*: pointer

proc loadAccessTests*() =
  let (a, _) = openLib("libatk-1.0.so.0")
  mustBind(a, cast[ptr pointer](addr atkObjectGetNAccessibleChild),
    "atk_object_get_n_accessible_children")
  mustBind(a, cast[ptr pointer](addr atkObjectRefAccessibleChild),
    "atk_object_ref_accessible_child")
  mustBind(a, cast[ptr pointer](addr atkObjectGetRole),
    "atk_object_get_role")
  mustBind(a, cast[ptr pointer](addr atkRoleGetName),
    "atk_role_get_name")
  mustBind(a, cast[ptr pointer](addr atkObjectGetName),
    "atk_object_get_name")
  mustBind(a, cast[ptr pointer](addr atkObjectRefStateSet),
    "atk_object_ref_state_set")
  mustBind(a, cast[ptr pointer](addr atkStateSetContainsState),
    "atk_state_set_contains_state")
  mustBind(a, cast[ptr pointer](addr atkActionGetNActions),
    "atk_action_get_n_actions")
  mustBind(a, cast[ptr pointer](addr atkActionDoAction),
    "atk_action_do_action")
  mustBind(a, cast[ptr pointer](addr atkTextGetText),
    "atk_text_get_text")
  mustBind(a, cast[ptr pointer](addr atkValueGetValueAndText),
    "atk_value_get_value_and_text")
  mustBind(a, cast[ptr pointer](addr atkValueSetValue),
    "atk_value_set_value")
  mustBind(a, cast[ptr pointer](addr atkEditableTextSetTextContent),
    "atk_editable_text_set_text_contents")
  mustBind(a, cast[ptr pointer](addr atkComponentGrabFocus),
    "atk_component_grab_focus")

## testAccessibility reads the elements of a window showing native UI
## as assistive technology does, in order, and reports false when it
## cannot.
proc testAccessibility*(handle: pointer):
    tuple[nodes: seq[TestAccessNode], ok: bool] =
  let s = surfaceByHandle(handle)
  if s.isNil or areaType == 0:
    return (@[], false)
  if not accessTestsLoaded:
    accessTestsLoaded = true
    loadAccessTests()
  var nodes: seq[TestAccessNode]
  proc walk(obj: pointer) {.closure.} =
    let n = atkObjectGetNAccessibleChild(obj)
    for i in 0 ..< n:
      let child = atkObjectRefAccessibleChild(obj, i)
      if child.isNil:
        continue
      var node = TestAccessNode(
        role: goStr(atkRoleGetName(atkObjectGetRole(child))),
        label: goStr(atkObjectGetName(child)),
        obj: child)
      if node.role == "push button":
        node.role = "button" # as older versions of ATK name it
      let states = atkObjectRefStateSet(child)
      if gTypeCheckInstanceIsA(child, atkTextGetType()):
        node.value = takeStr(atkTextGetText(child, 0, -1))
      elif gTypeCheckInstanceIsA(child, atkValueGetType()):
        var v: float64
        atkValueGetValueAndText(child, addr v, nil)
        node.value = formatFloat(v, ffDecimal, -1)
      elif node.role == "check box" or node.role == "radio button":
        node.value = "0"
        if atkStateSetContainsState(states, atkStates.checked):
          node.value = "1"
      gObjectUnref(states)
      nodes.add node
      walk(child)
      gObjectUnref(child) # the tree holds the node
  walk(gtkWidgetGetAccessible(s.area))
  (nodes, true)

## testAccessibilityPerform acts on the element labeled label as
## assistive technology does: "press", "increment", "decrement",
## "focus", or "value" to set its text to value. It reports whether the
## element can.
proc testAccessibilityPerform*(handle: pointer, label, action,
    value: string): bool =
  let (nodes, _) = testAccessibility(handle)
  for n in nodes:
    if n.label != label:
      continue
    case action
    of "press":
      return gTypeCheckInstanceIsA(n.obj, atkActionGetType()) and
        atkActionGetNActions(n.obj) > 0 and
        atkActionDoAction(n.obj, 0)
    of "increment", "decrement":
      if not gTypeCheckInstanceIsA(n.obj, atkValueGetType()):
        return false
      var v: float64
      atkValueGetValueAndText(n.obj, addr v, nil)
      var step = 1.0
      if action == "decrement":
        step = -1
      atkValueSetValue(n.obj, v + step)
      return true
    of "focus":
      return atkComponentGrabFocus(n.obj)
    of "value":
      if not gTypeCheckInstanceIsA(n.obj, atkEditableTextGetType()):
        return false
      atkEditableTextSetTextContent(n.obj, cs(value))
      return true
    else: discard
    return false
  false
