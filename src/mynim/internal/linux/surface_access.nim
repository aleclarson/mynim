## surface_access.nim: assistive technology, such as Orca, reads
## applications through AT-SPI, which GTK bridges to ATK. The widget of
## a surface is a subclass of GtkDrawingArea whose accessible, a
## subclass of GtkWidgetAccessible, has the nodes of the content's tree
## below it: ATK objects of types registered here, which answer from
## the last tree and turn what assistive technology does into
## accessAction events. The page of a web view is inside the node
## standing for it: the node's child is the web view's accessible, an
## AtkSocket the web process's tree is embedded in, which the overlay
## holding the web views and the surface (a subclass) does not list
## beside the content.
##
## Registering types writes functions into ATK's class and interface
## structures at offsets of its headers. The class's size is checked
## against the one GObject reports, and the interfaces' layout against
## ATK's version; native UI goes without accessibility rather than
## write past them.

## accessTree is what assistive technology sees of a surface.
type
  accessTree* = ref object
    s*: gtkSurface
    root*: pointer ## the surface's accessible
    nodes*: Table[uint64, accessNode]
    top*: seq[accessNode]
    focus*: uint64
    quiet*: bool ## building the tree assistive technology asked for

  ## accessNode is a node of the tree, with its ATK object.
  accessNode* = ref object
    obj*: pointer ## owned
    typ*: uint
    tree*: accessTree
    parent*: accessNode
    children*: seq[accessNode]
    n*: platform.AccessNode
    ## chosen are the rows a list choosing its rows chose, among those
    ## built.
    chosen*: seq[uint64]
    ## page is the accessible of the web view's page the node stands
    ## for, its only child.
    page*: pointer

proc hash*(an: accessNode): Hash = hash(cast[pointer](an))
var
  accessOnce: bool

  # The types: the drawing area, its accessible, and the nodes', by
  # the interfaces they implement.
  areaType, glAreaType, rootType, nodeType, rangeType, textType,
    editableType, selectionType: uint
  overlayType, overlayAccessType: uint

  gTypeRegisterStaticSimple: proc(parent: uint, name: pointer,
    classSize: uint32, classInit: pointer, instanceSize: uint32,
    instanceInit: pointer, flags: uint32): uint {.cdecl.}
  gTypeAddInterfaceStatic: proc(instanceType, ifaceType: uint,
    info: ptr gInterfaceInfo) {.cdecl.}
  gTypeQuery: proc(t: uint, q: ptr gTypeQueryInfo) {.cdecl.}
  gObjectNew: proc(t: uint, `end`: pointer): pointer {.cdecl.}
  gValueInit: proc(v: pointer, t: uint): pointer {.cdecl.}
  gValueSetDouble: proc(v: pointer, d: float64) {.cdecl.}
  gStrdup: proc(s: pointer): pointer {.cdecl.}
  gMalloc0: proc(n: uint): pointer {.cdecl.}
  gSlistAppend: proc(list, data: pointer): pointer {.cdecl.}
  gSignalEmitChild: proc(obj: pointer, signal: pointer,
    cbIndex: uint32, cbChild: pointer) {.cdecl.}
  gSignalEmitText: proc(obj: pointer, signal: pointer, pos,
    length: int32, text: pointer) {.cdecl.}
  gSignalEmitInt: proc(obj: pointer, signal: pointer,
    v: int32) {.cdecl.}
  gSignalEmit: proc(obj: pointer, signal: pointer) {.cdecl.}
  gObjectNotify: proc(obj: pointer, property: pointer) {.cdecl.}
  ## gSignalEmitAnnouncement emits AtkObject's announcement signal,
  ## which ATK has had since 2.46: announces is set where it has.
  gSignalLookup: proc(name: pointer, t: uint): uint32 {.cdecl.}
  gSignalEmitAnnouncement: proc(obj: pointer, signal,
    text: pointer) {.cdecl.}
  announces: bool

  gtkWidgetAccessibleGetType: proc(): uint {.cdecl.}
  gtkDrawingAreaGetType: proc(): uint {.cdecl.}
  gtkGLAreaGetType: proc(): uint {.cdecl.}
  gtkWidgetClassSetAccessibleType: proc(class: pointer,
    t: uint) {.cdecl.}
  gtkWidgetClassSetAccessibleRole: proc(class: pointer,
    role: int32) {.cdecl.}
  gtkAccessibleGetWidget: proc(accessible: pointer): pointer {.cdecl.}
  gtkWidgetGetAccessible: proc(widget: pointer): pointer {.cdecl.}
  gtkOverlayGetType: proc(): uint {.cdecl.}
  gtkContainerAccessibleGetType: proc(): uint {.cdecl.}
  atkSocketGetType: proc(): uint {.cdecl.}

  atkGetMajorVersion, atkGetMinorVersion: proc(): uint32 {.cdecl.}
  atkObjectGetType, atkComponentGetType, atkActionGetType:
    proc(): uint {.cdecl.}
  atkValueGetType, atkTextGetType, atkEditableTextGetType:
    proc(): uint {.cdecl.}
  atkSelectionGetType: proc(): uint {.cdecl.}
  atkRoleForName, atkStateTypeForName: proc(name: pointer):
    int32 {.cdecl.}
  atkObjectSetName, atkObjectSetDescription: proc(obj,
    name: pointer) {.cdecl.}
  atkObjectSetRole: proc(obj: pointer, role: int32) {.cdecl.}
  atkObjectSetParent: proc(obj, parent: pointer) {.cdecl.}
  atkObjectNotifyStateChange: proc(obj: pointer, state: uint64,
    value: bool) {.cdecl.}
  atkStateSetNew: proc(): pointer {.cdecl.}
  atkStateSetAddState: proc(set: pointer, state: int32): bool {.cdecl.}
  atkRangeNew: proc(lower, upper: float64,
    description: pointer): pointer {.cdecl.}
  atkComponentGetExtents: proc(obj: pointer, x, y, w, h: ptr int32,
    coords: int32) {.cdecl.}

  cbAreaClassInit, cbRootClassInit, cbNodeClassInit, cbRootComponent,
    cbComponentInit, cbActionInit, cbValueInit, cbTextInit,
    cbEditableInit, cbSelectionInit, cbOverlayClassInit,
    cbOverlayAccessClassInit: pointer

  ## rootParentIndex is GtkWidgetAccessible's get_index_in_parent.
  rootParentIndex: pointer

  atkRoles: Table[platform.AccessRole, int32]
  atkRole: tuple[panel, text, password, listBox: int32]
  atkStates: tuple[
    enabled, sensitive, visible, showing, focusable, focused,
    checkable, checked, indeterminate,
    expandable, expanded, editable, readOnly, multiLine, singleLine,
    selectableText, defunct,
    selectable, selected, multiselectable, hasPopup, invalidEntry,
    vertical, horizontal: int32]

  # The trees of surfaces, by the surface and by its accessible, and
  # the nodes, by their ATK object.
  surfaceTrees: Table[gtkSurface, accessTree]
  accessTrees: Table[pointer, accessTree]
  accessObjects: Table[pointer, accessNode]

  # Static strings of actions: cstring literals live forever.
  clickName = cast[pointer](cstring"click")
  expandName = cast[pointer](cstring"expand or contract")
  emptyName = cast[pointer](cstring"")

const
  atkObjectClassSize = 352'u32 # GObjectClass, 26 functions and a pad
  gTypeDouble = 15'u shl 2
  atkXYParent = 2'i32

# Offsets of the functions of AtkObjectClass.
const
  atkGetNChildren = 160
  atkRefChild = 168
  atkGetIndexInParent = 176
  atkRefStateSet = 216
  atkGetAttributes = 328
  gTypeInterfaceHeader = 16'u
    # the functions of interfaces follow a GTypeInterface

proc registerAccess*() ## below

proc loadAccessNames*() ## below
proc release*(an: accessNode) ## below
proc update*(t: accessTree, tree: AccessTree) ## below

proc stateList*(n: platform.AccessNode, focused: bool): seq[int32] ## below
proc graft*(t: accessTree, list: seq[accessNode]) ## below
proc textRunAt*(runs: seq[platform.AccessTextRun], i, n: int):
  tuple[run: platform.AccessTextRun, a, b: int] ## below
proc textAttributeSet*(r: platform.AccessTextRun): pointer ## below

## newSurfaceArea creates the widget of a surface, a GtkGLArea or a
## drawing area, that assistive technology sees the content of when
## ATK allows it.
proc newSurfaceArea*(gl: bool): pointer =
  if not accessOnce:
    accessOnce = true
    registerAccess()
  if gl and glAreaType != 0:
    return gObjectNew(glAreaType, nil)
  if gl:
    return gtkGLAreaNew()
  if areaType != 0:
    return gObjectNew(areaType, nil)
  gtkDrawingAreaNew()

## slot returns the address of a function pointer in a C structure.
proc slot*(p: pointer, offset: uint): ptr pointer =
  cast[ptr pointer](cast[uint](p) + offset)

proc setIface*(iface: pointer, fns: Table[int, pointer]) =
  for i, fn in fns:
    slot(iface, gTypeInterfaceHeader + uint(i) * 8)[] = fn

proc registerAccess*() =
  let (libATK, e) = openLib("libatk-1.0.so.0")
  if not e.isNil:
    return
  let a = libATK
  let o = libGObject
  let g = libGLib
  let t = libGTK
  var ok = bindFunc(a, cast[ptr pointer](addr atkGetMajorVersion),
    "atk_get_major_version") and
    bindFunc(a, cast[ptr pointer](addr atkGetMinorVersion),
      "atk_get_minor_version")
  let binds = [
    (o, cast[ptr pointer](addr gTypeRegisterStaticSimple),
      "g_type_register_static_simple"),
    (o, cast[ptr pointer](addr gTypeAddInterfaceStatic),
      "g_type_add_interface_static"),
    (o, cast[ptr pointer](addr gTypeQuery), "g_type_query"),
    (o, cast[ptr pointer](addr gObjectNew), "g_object_new"),
    (o, cast[ptr pointer](addr gValueInit), "g_value_init"),
    (o, cast[ptr pointer](addr gValueSetDouble),
      "g_value_set_double"),
    (g, cast[ptr pointer](addr gStrdup), "g_strdup"),
    (g, cast[ptr pointer](addr gMalloc0), "g_malloc0"),
    (g, cast[ptr pointer](addr gSlistAppend), "g_slist_append"),
    (o, cast[ptr pointer](addr gSignalEmitChild),
      "g_signal_emit_by_name"),
    (o, cast[ptr pointer](addr gSignalEmitText),
      "g_signal_emit_by_name"),
    (o, cast[ptr pointer](addr gSignalEmitInt),
      "g_signal_emit_by_name"),
    (o, cast[ptr pointer](addr gSignalEmit), "g_signal_emit_by_name"),
    (o, cast[ptr pointer](addr gObjectNotify), "g_object_notify"),
    (t, cast[ptr pointer](addr gtkWidgetAccessibleGetType),
      "gtk_widget_accessible_get_type"),
    (t, cast[ptr pointer](addr gtkDrawingAreaGetType),
      "gtk_drawing_area_get_type"),
    (t, cast[ptr pointer](addr gtkWidgetClassSetAccessibleType),
      "gtk_widget_class_set_accessible_type"),
    (t, cast[ptr pointer](addr gtkWidgetClassSetAccessibleRole),
      "gtk_widget_class_set_accessible_role"),
    (t, cast[ptr pointer](addr gtkAccessibleGetWidget),
      "gtk_accessible_get_widget"),
    (t, cast[ptr pointer](addr gtkWidgetGetAccessible),
      "gtk_widget_get_accessible"),
    (a, cast[ptr pointer](addr atkObjectGetType),
      "atk_object_get_type"),
    (a, cast[ptr pointer](addr atkComponentGetType),
      "atk_component_get_type"),
    (a, cast[ptr pointer](addr atkActionGetType),
      "atk_action_get_type"),
    (a, cast[ptr pointer](addr atkValueGetType),
      "atk_value_get_type"),
    (a, cast[ptr pointer](addr atkTextGetType), "atk_text_get_type"),
    (a, cast[ptr pointer](addr atkEditableTextGetType),
      "atk_editable_text_get_type"),
    (a, cast[ptr pointer](addr atkSelectionGetType),
      "atk_selection_get_type"),
    (a, cast[ptr pointer](addr atkRoleForName), "atk_role_for_name"),
    (a, cast[ptr pointer](addr atkStateTypeForName),
      "atk_state_type_for_name"),
    (a, cast[ptr pointer](addr atkObjectSetName),
      "atk_object_set_name"),
    (a, cast[ptr pointer](addr atkObjectSetRole),
      "atk_object_set_role"),
    (a, cast[ptr pointer](addr atkObjectSetDescription),
      "atk_object_set_description"),
    (a, cast[ptr pointer](addr atkObjectSetParent),
      "atk_object_set_parent"),
    (a, cast[ptr pointer](addr atkObjectNotifyStateChange),
      "atk_object_notify_state_change"),
    (a, cast[ptr pointer](addr atkStateSetNew), "atk_state_set_new"),
    (a, cast[ptr pointer](addr atkStateSetAddState),
      "atk_state_set_add_state"),
    (a, cast[ptr pointer](addr atkRangeNew), "atk_range_new"),
    (a, cast[ptr pointer](addr atkComponentGetExtents),
      "atk_component_get_extents"),
  ]
  for (lib, fn, name) in binds:
    ok = ok and bindFunc(lib, fn, name)
  # The value and text functions written below arrived in ATK 2.12.
  if not ok or atkGetMajorVersion() < 2 or
      (atkGetMajorVersion() == 2 and atkGetMinorVersion() < 12):
    return
  var q: gTypeQueryInfo
  gTypeQuery(atkObjectGetType(), addr q)
  if q.classSize != atkObjectClassSize:
    return
  loadAccessNames()
  initAccessCallbacks()
  announces = bindFunc(o, cast[ptr pointer](addr gSignalLookup),
    "g_signal_lookup") and
    bindFunc(o, cast[ptr pointer](addr gSignalEmitAnnouncement),
      "g_signal_emit_by_name") and
    gSignalLookup(cs("announcement"), atkObjectGetType()) != 0
  proc register(parent: uint, name: string,
      classInit: pointer): uint =
    var q: gTypeQueryInfo
    gTypeQuery(parent, addr q)
    gTypeRegisterStaticSimple(parent, cs(name), q.classSize,
      classInit, q.instanceSize, nil, 0)
  proc implement(t, iface: uint, init: pointer) =
    var info = gInterfaceInfo(init: init)
    gTypeAddInterfaceStatic(t, iface, addr info)
  rootType = register(gtkWidgetAccessibleGetType(),
    "MyNimSurfaceAccessible", cbRootClassInit)
  nodeType = register(atkObjectGetType(), "MyNimAccessible",
    cbNodeClassInit)
  if rootType == 0 or nodeType == 0:
    return
  rangeType = register(nodeType, "MyNimAccessibleRange", nil)
  textType = register(nodeType, "MyNimAccessibleText", nil)
  editableType = register(textType, "MyNimAccessibleEditable", nil)
  selectionType = register(nodeType, "MyNimAccessibleSelection", nil)
  if rangeType == 0 or textType == 0 or editableType == 0 or
      selectionType == 0:
    return
  implement(rootType, atkComponentGetType(), cbRootComponent)
  implement(nodeType, atkComponentGetType(), cbComponentInit)
  implement(nodeType, atkActionGetType(), cbActionInit)
  implement(rangeType, atkValueGetType(), cbValueInit)
  implement(textType, atkTextGetType(), cbTextInit)
  implement(editableType, atkEditableTextGetType(), cbEditableInit)
  implement(selectionType, atkSelectionGetType(), cbSelectionInit)
  areaType = register(gtkDrawingAreaGetType(), "MyNimSurfaceArea",
    cbAreaClassInit)
  # GtkGLArea came in GTK 3.16.
  if bindFunc(t, cast[ptr pointer](addr gtkGLAreaGetType),
      "gtk_gl_area_get_type"):
    glAreaType = register(gtkGLAreaGetType(), "MyNimSurfaceGLArea",
      cbAreaClassInit)
  # The overlay holding web views lists the surface alone, whose nodes
  # hold the pages.
  if bindFunc(t, cast[ptr pointer](addr gtkOverlayGetType),
      "gtk_overlay_get_type") and
      bindFunc(t, cast[ptr pointer](addr gtkContainerAccessibleGetType),
        "gtk_container_accessible_get_type") and
      bindFunc(a, cast[ptr pointer](addr atkSocketGetType),
        "atk_socket_get_type"):
    overlayAccessType = register(gtkContainerAccessibleGetType(),
      "MyNimSurfaceOverlayAccessible", cbOverlayAccessClassInit)
    if overlayAccessType != 0:
      overlayType = register(gtkOverlayGetType(),
        "MyNimSurfaceOverlay", cbOverlayClassInit)

## newOverlay creates the overlay putting a surface's area over its
## web views.
proc newOverlay*(): pointer =
  if overlayType != 0:
    return gObjectNew(overlayType, nil)
  gtkOverlayNew()

## layersOf returns the surface whose web views the overlay holds.
proc layersOf*(overlay: pointer): gtkSurface =
  for s in surfaceAreas.values:
    if s.layers == overlay and not overlay.isNil:
      return s

## pageAccessible returns the accessible of a web view, the AtkSocket
## its page's tree is embedded in, or nil.
proc pageAccessible*(w: gtkWindow): pointer =
  if atkSocketGetType.isNil or w.web.isNil:
    return nil
  let acc = gtkWidgetGetAccessible(w.web)
  if not acc.isNil and
      gTypeCheckInstanceIsA(acc, atkSocketGetType()):
    return acc
  nil

## loadAccessNames finds ATK's roles and states by name, which, unlike
## their numbers, do not change between versions.
proc loadAccessNames*() =
  proc role(names: varargs[string]): int32 =
    for n in names:
      let r = atkRoleForName(cs(n))
      if r != 0:
        return r
    0
  atkRole.panel = role("panel")
  atkRole.text = role("text")
  atkRole.password = role("password text")
  atkRole.listBox = role("list box")
  let roleNames = {
    roleGroup: @["panel"], roleText: @["label"],
    roleButton: @["push button", "button"],
    roleLink: @["link"], roleCheckBox: @["check box"],
    roleRadio: @["radio button"],
    roleSwitch: @["switch", "toggle button"],
    roleSlider: @["slider"],
    roleProgress: @["progress bar"], roleTextField: @["entry"],
    roleImage: @["image"],
    roleList: @["list"], roleScroll: @["scroll pane"],
    roleDialog: @["dialog"],
    rolePopup: @["popup menu"], roleTooltip: @["tool tip"],
    rolePopUpButton: @["combo box"],
    roleTabList: @["page tab list"], roleTab: @["page tab"],
    roleSplitter: @["separator"],
    roleStatus: @["notification", "status bar"],
    roleTable: @["table"], roleRow: @["table row"],
    roleCell: @["table cell"],
    roleColumnHeader: @["column header", "table column header"],
    roleTree: @["tree", "tree table"],
    roleTreeItem: @["tree item", "list item"],
    roleListItem: @["list item"],
    roleMenuButton: @["push button menu", "push button", "button"],
    roleToolbar: @["tool bar"], roleRadioGroup: @["panel"],
    roleToggleButton: @["toggle button"],
    roleComboBox: @["combo box"], roleDisclosure: @["toggle button"],
    roleMeter: @["level bar", "progress bar"],
    roleStepper: @["spin button"],
    roleColorWell: @["push button", "button"],
    roleAlertDialog: @["alert", "dialog"],
    roleMenu: @["menu"], roleMenuBar: @["menu bar"],
    roleMenuItem: @["menu item"],
    roleMenuItemCheckBox: @["check menu item", "menu item"],
    roleMenuItemRadio: @["radio menu item", "menu item"],
    roleHeading: @["heading", "label"],
  }.toTable
  for r, names in roleNames:
    atkRoles[r] = role(names)
  let stateNames = [
    (addr atkStates.enabled, "enabled"),
    (addr atkStates.sensitive, "sensitive"),
    (addr atkStates.visible, "visible"),
    (addr atkStates.showing, "showing"),
    (addr atkStates.focusable, "focusable"),
    (addr atkStates.focused, "focused"),
    (addr atkStates.checkable, "checkable"),
    (addr atkStates.checked, "checked"),
    (addr atkStates.indeterminate, "indeterminate"),
    (addr atkStates.expandable, "expandable"),
    (addr atkStates.expanded, "expanded"),
    (addr atkStates.editable, "editable"),
    (addr atkStates.readOnly, "read-only"),
    (addr atkStates.multiLine, "multi-line"),
    (addr atkStates.singleLine, "single-line"),
    (addr atkStates.selectableText, "selectable-text"),
    (addr atkStates.defunct, "defunct"),
    (addr atkStates.selectable, "selectable"),
    (addr atkStates.selected, "selected"),
    (addr atkStates.multiselectable, "multiselectable"),
    (addr atkStates.hasPopup, "has-popup"),
    (addr atkStates.invalidEntry, "invalid-entry"),
    (addr atkStates.vertical, "vertical"),
    (addr atkStates.horizontal, "horizontal"),
  ]
  for (p, name) in stateNames:
    p[] = atkStateTypeForName(cs(name))

## chooses reports whether a node is the row of a list, a table or an
## outline that its list chooses.
proc chooses*(n: platform.AccessNode): bool =
  (n.role == roleListItem or n.role == roleRow or
    n.role == roleTreeItem) and
    (n.states and accessSelectable) != AccessStates(0)

## chosenRows returns the rows of a list or table that are chosen.
proc chosenRows*(an: accessNode): seq[accessNode] =
  for c in an.children:
    if chooses(c.n) and (c.n.states and accessChecked) != AccessStates(0):
      result.add c

## rootTree returns the tree below a surface's accessible, asking the
## content for it while it has none, as before its first frame.
proc rootTree*(root: pointer): accessTree =
  var t = accessTrees.getOrDefault(root)
  if t.isNil:
    let s = surfaceAreas.getOrDefault(gtkAccessibleGetWidget(root))
    if s.isNil or s.w.closed:
      return nil
    t = accessTree(s: s, root: root,
      nodes: initTable[uint64, accessNode]())
    accessTrees[root] = t
    surfaceTrees[s] = t
  if t.top.len == 0:
    t.quiet = true
    discard t.s.send(SurfaceEvent(kind: accessibilityOn))
    t.quiet = false
  t

method updateAccessibility*(s: gtkSurface, tree: AccessTree) =
  ## shows assistive technology the content's last frame, and tells it
  ## what changed.
  if surfaceTrees.hasKey(s) and tree.nodes.len > 0:
    surfaceTrees[s].update(tree)

proc destroyAccess*(s: gtkSurface) =
  if not surfaceTrees.hasKey(s):
    return
  let t = surfaceTrees[s]
  surfaceTrees.del(s)
  accessTrees.del(t.root)
  t.graft(@[])
  for an in t.nodes.values:
    an.release()
  t.nodes.clear()
  t.top = @[]

## release lets go of a node that left the tree.
proc release*(an: accessNode) =
  atkObjectNotifyStateChange(an.obj, uint64(atkStates.defunct), true)
  accessObjects.del(an.obj)
  gObjectUnref(an.obj)

proc accessType*(n: platform.AccessNode): uint =
  case n.role
  of roleSlider, roleProgress, roleMeter, roleStepper:
    return rangeType
  of roleTextField, roleComboBox:
    return editableType
  of roleText:
    return textType
  of roleList, roleTable, roleTree:
    if (n.states and accessSelectable) != AccessStates(0):
      return selectionType # choosing its rows
  else: discard
  nodeType

proc role*(an: accessNode): int32 =
  var r = atkRoles.getOrDefault(an.n.role)
  if an.n.role == roleList and
      (an.n.states and accessSelectable) != AccessStates(0) and
      atkRole.listBox != 0:
    r = atkRole.listBox # choosing its items
  if an.n.role == roleTextField:
    if (an.n.states and accessPassword) != AccessStates(0):
      r = atkRole.password
    elif (an.n.states and accessMultiline) != AccessStates(0):
      r = atkRole.text
  if r == 0:
    r = atkRole.panel
  r

proc notifyChanges*(an: accessNode, prev: platform.AccessNode) ## below


proc update*(t: accessTree, tree: AccessTree) =
  let notify = not t.quiet
  var old = t.nodes
  t.nodes = initTable[uint64, accessNode]()
  var list = newSeq[accessNode](tree.nodes.len)
  var prev = newSeq[platform.AccessNode](tree.nodes.len)
  var fresh = newSeq[bool](tree.nodes.len)
  var oldKids = initTable[accessNode, seq[accessNode]]()
  oldKids[nil] = t.top
  for i, n in tree.nodes:
    let typ = accessType(n)
    var an = old.getOrDefault(n.id)
    if not an.isNil and an.typ == typ:
      old.del(n.id)
      oldKids[an] = an.children
      prev[i] = an.n
    else:
      an = accessNode(obj: gObjectNew(typ, nil), typ: typ, tree: t)
      accessObjects[an.obj] = an
      fresh[i] = true
    an.n = n
    an.children = @[]
    t.nodes[n.id] = an
    list[i] = an
  t.top = @[]
  for i, an in list:
    var parent: accessNode = nil
    var parentObj = t.root
    if an.n.parent >= 0:
      parent = list[an.n.parent]
      parentObj = parent.obj
      parent.children.add an
    else:
      t.top.add an
    if fresh[i] or an.parent != parent:
      atkObjectSetParent(an.obj, parentObj)
    an.parent = parent
    const roleStates = accessPassword or accessMultiline or
      accessSelectable or accessMultiselectable
    if fresh[i] or prev[i].role != an.n.role or
        (prev[i].states and roleStates) != (an.n.states and roleStates):
      atkObjectSetRole(an.obj, an.role())
    if fresh[i] or prev[i].label != an.n.label:
      atkObjectSetName(an.obj, cs(an.n.label))
    if fresh[i] or prev[i].description != an.n.description:
      atkObjectSetDescription(an.obj, cs(an.n.description))
  if notify:
    # Children that left their parent, then those that joined it, for
    # the parents that were in the tree before.
    for parent, kids in oldKids:
      var obj = t.root
      var now = t.top
      if not parent.isNil:
        obj = parent.obj
        now = parent.children
      for i in countdown(kids.len - 1, 0):
        if kids[i] notin now:
          gSignalEmitChild(obj, cs("children-changed::remove"),
            uint32(i), kids[i].obj)
      for i, kid in now:
        if kid notin kids:
          gSignalEmitChild(obj, cs("children-changed::add"),
            uint32(i), kid.obj)
    for i, an in list:
      if not fresh[i]:
        an.notifyChanges(prev[i])
  # Lists choosing their rows tell when the choice moves.
  for an in list:
    if an.typ != selectionType:
      continue
    var chosen: seq[uint64]
    for r in an.chosenRows():
      chosen.add r.n.id
    if chosen != an.chosen:
      an.chosen = chosen
      if notify:
        gSignalEmit(an.obj, cs("selection-changed"))
  t.graft(list)
  for an in old.values:
    an.release()
  let focus = tree.focus
  if focus != t.focus:
    if t.nodes.hasKey(t.focus) and notify:
      atkObjectNotifyStateChange(t.nodes[t.focus].obj,
        uint64(atkStates.focused), false)
    t.focus = focus
    if t.nodes.hasKey(focus) and notify:
      atkObjectNotifyStateChange(t.nodes[focus].obj,
        uint64(atkStates.focused), true)
  if announces and notify:
    for text in tree.announcements:
      gSignalEmitAnnouncement(t.root, cs("announcement"), cs(text))

## notifyChanges tells assistive technology how a node changed since
## the last tree, but for its focus.
proc notifyChanges*(an: accessNode, prev: platform.AccessNode) =
  let n = an.n
  let before = stateList(prev, false)
  let after = stateList(n, false)
  for s in before:
    if s notin after:
      atkObjectNotifyStateChange(an.obj, uint64(s), false)
  for s in after:
    if s notin before:
      atkObjectNotifyStateChange(an.obj, uint64(s), true)
  if an.typ == rangeType:
    if prev.now != n.now or prev.min != n.min or prev.max != n.max:
      gObjectNotify(an.obj, cs("accessible-value"))
  elif an.typ == editableType:
    if prev.value != n.value:
      # What changed, between the text both have at their ends.
      let a = toRunes(prev.value)
      let b = toRunes(n.value)
      var start = 0
      while start < a.len and start < b.len and a[start] == b[start]:
        inc start
      var `end` = 0
      while `end` < a.len - start and `end` < b.len - start and
          a[a.len - 1 - `end`] == b[b.len - 1 - `end`]:
        inc `end`
      let removed = a[start ..< a.len - `end`]
      if removed.len > 0:
        gSignalEmitText(an.obj, cs("text-remove"), int32(start),
          int32(removed.len), cs($removed))
      let inserted = b[start ..< b.len - `end`]
      if inserted.len > 0:
        gSignalEmitText(an.obj, cs("text-insert"), int32(start),
          int32(inserted.len), cs($inserted))
    if prev.selEnd != n.selEnd:
      gSignalEmitInt(an.obj, cs("text-caret-moved"), int32(n.selEnd))
    if prev.selStart != n.selStart or prev.selEnd != n.selEnd:
      if prev.selStart != prev.selEnd or n.selStart != n.selEnd:
        gSignalEmit(an.obj, cs("text-selection-changed"))

## stateList returns the ATK states of a node.
proc stateList*(n: platform.AccessNode, focused: bool): seq[int32] =
  var list = @[atkStates.visible]
  if (n.states and accessOffscreen) == AccessStates(0):
    list.add atkStates.showing
  if (n.states and accessDisabled) == AccessStates(0):
    list.add atkStates.enabled
    list.add atkStates.sensitive
  if (n.states and accessFocusable) != AccessStates(0):
    list.add atkStates.focusable
  if focused:
    list.add atkStates.focused
  case n.role
  of roleCheckBox, roleRadio, roleSwitch, roleMenuItemCheckBox,
      roleMenuItemRadio:
    list.add atkStates.checkable
  of roleTab, roleTreeItem, roleRow, roleListItem:
    # Rows and items of lists only where their list chooses them.
    if not ((n.states and accessSelectable) == AccessStates(0) and
        (n.role == roleRow or n.role == roleListItem)):
      list.add atkStates.selectable
      if (n.states and accessChecked) != AccessStates(0):
        list.add atkStates.selected # not checked
  of rolePopUpButton:
    list.add atkStates.expandable
  of roleSlider:
    # As GtkScale's.
    if (n.states and accessVertical) != AccessStates(0):
      list.add atkStates.vertical
    else:
      list.add atkStates.horizontal
  of roleDisclosure:
    # Checked while open, as GTK's expanders.
    list.add atkStates.expandable
    if (n.states and accessExpanded) != AccessStates(0):
      list.add atkStates.checked
  of roleMenuButton:
    list.add atkStates.hasPopup
  of roleTextField, roleComboBox:
    if n.role == roleComboBox:
      list.add atkStates.expandable
    list.add atkStates.selectableText
    if (n.states and accessReadOnly) == AccessStates(0):
      list.add atkStates.editable
    else:
      list.add atkStates.readOnly
    if (n.states and accessMultiline) != AccessStates(0):
      list.add atkStates.multiLine
    else:
      list.add atkStates.singleLine
  else: discard
  # A toggle button is checked while pressed, as GTK's are.
  if (n.states and accessChecked) != AccessStates(0) and n.role != roleTab and
      n.role != roleTreeItem and n.role != roleRow and
      n.role != roleListItem:
    list.add atkStates.checked
  if (n.states and accessMixed) != AccessStates(0) or n.now < n.min:
    list.add atkStates.indeterminate # a progress of unknown length
  if (n.states and accessExpandable) != AccessStates(0):
    list.add atkStates.expandable
  if (n.states and accessExpanded) != AccessStates(0):
    list.add atkStates.expanded
  if (n.states and accessMultiselectable) != AccessStates(0):
    list.add atkStates.multiselectable
  if (n.states and accessInvalid) != AccessStates(0):
    list.add atkStates.invalidEntry
  list.keepItIf(it != 0)
  list

## act performs an action of assistive technology on the node.
proc act*(an: accessNode, action: platform.AccessActionKind,
    text: string) =
  discard an.tree.s.send(SurfaceEvent(kind: accessAction,
    id: an.n.id, action: action, text: text))

## extents returns the node's bounds in ATK's coordinates.
proc nodeExtents*(an: accessNode, coords: int32):
    tuple[x, y, w, h: int32] =
  var b = an.n.bounds
  if coords == atkXYParent:
    if not an.parent.isNil:
      b.x -= an.parent.n.bounds.x
      b.y -= an.parent.n.bounds.y
  else:
    var rx, ry, rw, rh: int32
    atkComponentGetExtents(an.tree.root, addr rx, addr ry, addr rw,
      addr rh, coords)
    if rx == int32.low:
      return (rx, rx, int32(b.w), int32(b.h)) # not on the screen
    b.x += float64(rx)
    b.y += float64(ry)
  (int32(floor(b.x)), int32(floor(b.y)), int32(round(b.w)),
    int32(round(b.h)))

proc contains*(an: accessNode, x, y, coords: int32): bool =
  let (nx, ny, w, h) = an.nodeExtents(coords)
  x >= nx and y >= ny and x < nx + w and y < ny + h

## at returns a new reference to the topmost of nodes at a point, or
## nil.
proc at*(nodes: seq[accessNode], x, y, coords: int32): pointer =
  for i in countdown(nodes.len - 1, 0):
    if nodes[i].contains(x, y, coords):
      return gObjectRef(nodes[i].obj)
  nil

## text returns the text of a node that ATK reads as text.
proc text*(an: accessNode): seq[Rune] =
  if an.typ == textType:
    return toRunes(an.n.label)
  toRunes(an.n.value)

## span clamps a range of runes of ATK, whose end is -1 for the end.
proc span*(start, `end`: int32, n: int): tuple[a, b: int] =
  var e = `end`
  if e < 0 or int(e) > n:
    e = int32(n)
  let a = max(0, min(int(start), n))
  (a, max(a, int(e)))

## segment returns the range of the character, word, or line, for the
## granularities of ATK 0, 1, and above, at a rune offset.
proc segment*(r: seq[Rune], offset, granularity: int):
    tuple[a, b: int] =
  let offset = max(0, min(offset, r.len))
  case granularity
  of 0:
    return (offset, min(offset + 1, r.len))
  of 1:
    var start = offset
    while start > 0 and isWhiteSpace(r[start - 1]) and
        (start == r.len or isWhiteSpace(r[start])):
      dec start # between words: the one before
    while start > 0 and not isWhiteSpace(r[start - 1]):
      dec start
    var `end` = start
    while `end` < r.len and not isWhiteSpace(r[`end`]):
      inc `end`
    while `end` < r.len and isWhiteSpace(r[`end`]):
      inc `end`
    return (start, `end`)
  else:
    var start = offset
    var `end` = offset
    while start > 0 and r[start - 1] != Rune('\n'):
      dec start
    while `end` < r.len and r[`end`] != Rune('\n'):
      inc `end`
    return (start, min(`end` + 1, r.len))

proc cString*(s: string): pointer = gStrdup(cs(s))

proc setInt*(p: pointer, v: int) =
  if not p.isNil:
    slot(p, 0)[] = cast[pointer](int32(v))

proc setDouble*(gvalue: pointer, v: float64) =
  discard gValueInit(gvalue, gTypeDouble)
  gValueSetDouble(gvalue, v)

## cBytes copies length bytes of a C string, or all of it for -1.
proc cBytes*(p: pointer, length: int32): string =
  if length < 0 or p.isNil:
    return goStr(p)
  let b = cast[ptr UncheckedArray[byte]](slot(p, 0)[])
  var s = newString(int(length))
  copyMem(addr s[0], b, int(length))
  s

var cbActionEmpty, cbActionName, cbAddSelection, cbAttributes, cbCaret, cbCharAt, cbChild, cbChildren, cbContainsCb, cbCount, cbCurrent, cbDefaultAttributes, cbDoAction, cbExtentsCb, cbGetText, cbGrabFocus, cbIncrement, cbIndex, cbInsert, cbIsSelected, cbMaximum, cbMinimum, cbNActions, cbNodeAt, cbOverlayChild, cbOverlayChildren, cbRefSelection, cbRefuse, cbRefuseAt, cbRemove, cbRootAt, cbRootChild, cbRootChildren, cbRootIndex, cbRunAttributes, cbScrollTo, cbSelection, cbSelectionCount, cbSelections, cbSetContents, cbSetValue, cbStates, cbStringAtOffset, cbTextAtOffset, cbValueAndText, cbValueRange: pointer
var cbScrolls: bool

proc nodeAt0(obj: pointer): accessNode =
  accessObjects.getOrDefault(obj)


proc stringAt(obj: pointer, offset: int32, granularity: int,
    start, `end`: pointer): pointer =
  let an = nodeAt0(obj)
  if an.isNil:
    return nil
  let r = an.text()
  let (a, b) = segment(r, int(offset), granularity)
  setInt(start, a)
  setInt(`end`, b)
  cString($r[a ..< b])
proc actionsOf(obj: pointer):
    tuple[an: accessNode, list: seq[AccessActions]] =
  let an = nodeAt0(obj)
  if an.isNil:
    return (nil, @[])
  var list: seq[AccessActions]
  for a in [actionPress, actionExpand]:
    if (an.n.actions and a) != AccessActions(0):
      list.add a
  (an, list)
proc actionOf(obj: pointer, i: int32):
    tuple[an: accessNode, a: AccessActions] =
  let (an, list) = actionsOf(obj)
  if i < 0 or int(i) >= list.len:
    return (nil, AccessActions(0))
  (an, list[i])
proc childAt(obj: pointer, i: int32): accessNode =
  let an = nodeAt0(obj)
  if not an.isNil and i >= 0 and int(i) < an.children.len:
    return an.children[i]
proc editable(obj: pointer): accessNode =
  let an = nodeAt0(obj)
  if not an.isNil and (an.n.actions and actionSetValue) != AccessActions(0):
    return an

proc initAccessCallbacks*() =
  cbAreaClassInit = cast[pointer](
    proc(class, data: pointer) {.cdecl.} =
      gtkWidgetClassSetAccessibleType(class, rootType)
      gtkWidgetClassSetAccessibleRole(class, atkRole.panel))
  cbRootChildren = cast[pointer](
    proc(root: pointer): int32 {.cdecl.} =
      let t = rootTree(root)
      if not t.isNil:
        return int32(t.top.len)
      0)
  cbRootChild = cast[pointer](
    proc(root: pointer, i: int32): pointer {.cdecl.} =
      let t = rootTree(root)
      if not t.isNil and i >= 0 and int(i) < t.top.len:
        return gObjectRef(t.top[i].obj)
      nil)
  # In the overlay holding web views, the surface is its only child.
  cbRootIndex = cast[pointer](
    proc(root: pointer): int32 {.cdecl.} =
      let s = surfaceAreas.getOrDefault(gtkAccessibleGetWidget(root))
      if not s.isNil and not s.layers.isNil and overlayType != 0:
        return 0
      cast[proc(r: pointer): int32 {.cdecl.}](rootParentIndex)(root))
  cbRootClassInit = cast[pointer](
    proc(class, data: pointer) {.cdecl.} =
      slot(class, atkGetNChildren)[] = cbRootChildren
      slot(class, atkRefChild)[] = cbRootChild
      rootParentIndex = slot(class, atkGetIndexInParent)[]
      slot(class, atkGetIndexInParent)[] = cbRootIndex)
  cbOverlayChildren = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      if not layersOf(gtkAccessibleGetWidget(obj)).isNil:
        return 1
      0)
  cbOverlayChild = cast[pointer](
    proc(obj: pointer, i: int32): pointer {.cdecl.} =
      let s = layersOf(gtkAccessibleGetWidget(obj))
      if not s.isNil and i == 0:
        return gObjectRef(gtkWidgetGetAccessible(s.area))
      nil)
  cbOverlayAccessClassInit = cast[pointer](
    proc(class, data: pointer) {.cdecl.} =
      slot(class, atkGetNChildren)[] = cbOverlayChildren
      slot(class, atkRefChild)[] = cbOverlayChild)
  cbOverlayClassInit = cast[pointer](
    proc(class, data: pointer) {.cdecl.} =
      gtkWidgetClassSetAccessibleType(class, overlayAccessType))
  cbRootAt = cast[pointer](
    proc(root: pointer, x, y, coords: int32): pointer {.cdecl.} =
      let t = rootTree(root)
      if not t.isNil:
        return at(t.top, x, y, coords)
      nil)
  cbRootComponent = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # ref_accessible_at_point; the rest is GtkWidgetAccessible's.
      setIface(iface, {2: cbRootAt}.toTable))

  cbChildren = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and not an.page.isNil:
        return 1
      if not an.isNil:
        return int32(an.children.len)
      0)
  cbChild = cast[pointer](
    proc(obj: pointer, i: int32): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and not an.page.isNil and i == 0:
        return gObjectRef(an.page)
      if not an.isNil and i >= 0 and int(i) < an.children.len:
        return gObjectRef(an.children[i].obj)
      nil)
  cbIndex = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil:
        return -1
      let siblings = if not an.parent.isNil: an.parent.children
                     else: an.tree.top
      int32(siblings.find(an)))
  cbStates = cast[pointer](
    proc(obj: pointer): pointer {.cdecl.} =
      let set = atkStateSetNew()
      let an = nodeAt0(obj)
      if an.isNil:
        discard atkStateSetAddState(set, atkStates.defunct)
        return set
      for s in stateList(an.n, an.n.id == an.tree.focus):
        discard atkStateSetAddState(set, s)
      set)
  # Object cbAttributes: the placeholder of a text field, and the place
  # of a row among its list's, which Orca reads as "5 of 10000".
  cbAttributes = cast[pointer](
    proc(obj: pointer): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil:
        return nil
      var list: pointer
      proc add(name, value: string) {.closure.} =
        let attr = gMalloc0(16) # AtkAttribute: name, value
        slot(attr, 0)[] = cString(name)
        slot(attr, 8)[] = cString(value)
        list = gSlistAppend(list, attr)
      if an.n.placeholder != "":
        add("placeholder-text", an.n.placeholder)
      if an.n.posInSet > 0:
        add("posinset", $an.n.posInSet)
      if an.n.setSize > 0:
        add("setsize", $an.n.setSize)
      if an.n.level > 0:
        add("level", $an.n.level)
      # The order of the column a table is sorted by, as Chromium says.
      if (an.n.states and accessSortAscending) != AccessStates(0):
        add("sort", "ascending")
      elif (an.n.states and accessSortDescending) != AccessStates(0):
        add("sort", "descending")
      list)
  cbNodeClassInit = cast[pointer](
    proc(class, data: pointer) {.cdecl.} =
      slot(class, atkGetNChildren)[] = cbChildren
      slot(class, atkRefChild)[] = cbChild
      slot(class, atkGetIndexInParent)[] = cbIndex
      slot(class, atkRefStateSet)[] = cbStates
      slot(class, atkGetAttributes)[] = cbAttributes)

  cbContainsCb = cast[pointer](
    proc(obj: pointer, x, y, coords: int32): bool {.cdecl.} =
      let an = nodeAt0(obj)
      not an.isNil and an.contains(x, y, coords))
  cbNodeAt = cast[pointer](
    proc(obj: pointer, x, y, coords: int32): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and not an.page.isNil:
        return gObjectRef(an.page)
      if not an.isNil:
        return at(an.children, x, y, coords)
      nil)
  cbExtentsCb = cast[pointer](
    proc(obj, px, py, pw, ph: pointer, coords: int32) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        let (x, y, w, h) = an.nodeExtents(coords)
        setInt(px, int(x))
        setInt(py, int(y))
        setInt(pw, int(w))
        setInt(ph, int(h)))
  cbGrabFocus = cast[pointer](
    proc(obj: pointer): bool {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil or (an.n.actions and actionFocus) == AccessActions(0):
        return false
      gtkWidgetGrabFocus(an.tree.s.area)
      an.act(accessFocus, "")
      true)
  # What assistive technology moves to out of view scrolls into view.
  cbScrollTo = cast[pointer](
    proc(obj: pointer, how: int32): bool {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil or
          (an.n.actions and actionScrollIntoView) == AccessActions(0):
        return false
      an.act(accessScrollIntoView, "")
      true)
  # scroll_to arrived in ATK 2.30, past the end of the interface before.
  cbScrolls = atkGetMajorVersion() > 2 or atkGetMinorVersion() >= 30
  cbComponentInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      var fns = {1: cbContainsCb, 2: cbNodeAt, 3: cbExtentsCb,
        6: cbGrabFocus}.toTable
      if cbScrolls:
        fns[15] = cbScrollTo
      setIface(iface, fns))

  # The actions of a node: click, then expand or contract, for an item
  # of a tree with cbChildren, as GTK's tree views have.
  cbDoAction = cast[pointer](
    proc(obj: pointer, i: int32): bool {.cdecl.} =
      let (an, a) = actionOf(obj, i)
      if not an.isNil:
        if a == actionPress:
          an.act(accessPress, "")
        elif a == actionExpand and
            (an.n.states and accessExpanded) != AccessStates(0):
          an.act(accessCollapse, "")
        elif a == actionExpand:
          an.act(accessExpand, "")
      not an.isNil)
  cbNActions = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let (_, list) = actionsOf(obj)
      int32(list.len))
  cbActionName = cast[pointer](
    proc(obj: pointer, i: int32): pointer {.cdecl.} =
      let (_, a) = actionOf(obj, i)
      if a == actionPress:
        return cast[pointer](clickName)
      if a == actionExpand:
        return cast[pointer](expandName)
      nil)
  cbActionEmpty = cast[pointer](
    proc(obj: pointer, i: int32): pointer {.cdecl.} =
      let (an, _) = actionOf(obj, i)
      if not an.isNil:
        return cast[pointer](emptyName)
      nil)
  cbActionInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # do_action, get_n_actions, get_description, get_name,
      # get_keybinding and get_localized_name.
      setIface(iface, {0: cbDoAction, 1: cbNActions, 2: cbActionEmpty,
        3: cbActionName, 4: cbActionEmpty, 6: cbActionName}.toTable))

  cbCurrent = cast[pointer](
    proc(obj, gvalue: pointer) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        setDouble(gvalue, max(an.n.now, an.n.min)))
  cbMaximum = cast[pointer](
    proc(obj, gvalue: pointer) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        setDouble(gvalue, an.n.max))
  cbMinimum = cast[pointer](
    proc(obj, gvalue: pointer) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        setDouble(gvalue, an.n.min))
  # The step, through the GValue of get_minimum_increment: callbacks
  # return no floats for get_increment, which AT-SPI's bridge then
  # leaves for this.
  cbIncrement = cast[pointer](
    proc(obj, gvalue: pointer) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        setDouble(gvalue, an.n.step))
  cbValueAndText = cast[pointer](
    proc(obj, value, text: pointer) {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and not value.isNil:
        slot(value, 0)[] = cast[pointer](
          cast[float64](max(an.n.now, an.n.min)))
      if not text.isNil:
        slot(text, 0)[] = nil)
  cbValueRange = cast[pointer](
    proc(obj: pointer): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        return atkRangeNew(an.n.min, an.n.max, nil)
      nil)
  # Values change as the arrow keys change them.
  cbSetValue = cast[pointer](
    proc(obj: pointer, v: float64) {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil or (an.n.actions and actionIncrement) == AccessActions(0):
        return
      if v > an.n.now:
        an.act(accessIncrement, "")
      elif v < an.n.now:
        an.act(accessDecrement, ""))
  cbValueInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # get_current_value, get_maximum_value, get_minimum_value,
      # get_minimum_increment, get_value_and_text, get_range and
      # set_value.
      setIface(iface, {0: cbCurrent, 1: cbMaximum, 2: cbMinimum,
        4: cbIncrement, 5: cbValueAndText, 6: cbValueRange,
        9: cbSetValue}.toTable))

  cbGetText = cast[pointer](
    proc(obj: pointer, start, `end`: int32): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil:
        return nil
      let r = an.text()
      let (a, b) = span(start, `end`, r.len)
      cString($r[a ..< b]))
  cbCharAt = cast[pointer](
    proc(obj: pointer, offset: int32): uint32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        let r = an.text()
        if offset >= 0 and int(offset) < r.len:
          return uint32(r[offset])
      0)
  cbCaret = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and an.typ == editableType:
        return int32(an.n.selEnd)
      -1)
  cbCount = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        return int32(an.text().len)
      0)
  cbSelections = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil and an.n.selStart != an.n.selEnd:
        return 1
      0)
  cbSelection = cast[pointer](
    proc(obj: pointer, i: int32, start, `end`: pointer):
        pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil or i != 0 or an.n.selStart == an.n.selEnd:
        setInt(start, 0)
        setInt(`end`, 0)
        return nil
      let r = an.text()
      let (a, b) = span(int32(an.n.selStart), int32(an.n.selEnd),
        r.len)
      setInt(start, a)
      setInt(`end`, b)
      cString($r[a ..< b]))
  cbStringAtOffset = cast[pointer](
    proc(obj: pointer, offset, granularity: int32, start,
        `end`: pointer): pointer {.cdecl.} =
      stringAt(obj, offset, int(granularity), start, `end`))
  # Boundaries of the older text_at_offset: characters, the starts and
  # ends of words, sentences and lines.
  cbTextAtOffset = cast[pointer](
    proc(obj: pointer, offset, boundary: int32, start,
        `end`: pointer): pointer {.cdecl.} =
      let g = [0, 1, 1, 3, 3, 3, 3][max(0, min(int(boundary), 6))]
      stringAt(obj, offset, g, start, `end`))
  # The formats of a rich text's runs, in ATK's text cbAttributes, which
  # Orca reads as bold, italic, underlined.
  cbRunAttributes = cast[pointer](
    proc(obj: pointer, offset: int32, start, `end`: pointer):
        pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if an.isNil:
        setInt(start, 0)
        setInt(`end`, 0)
        return nil
      let (run, a, z) = textRunAt(an.n.textRuns, int(offset),
        an.text().len)
      setInt(start, a)
      setInt(`end`, z)
      textAttributeSet(run))
  cbDefaultAttributes = cast[pointer](
    proc(obj: pointer): pointer {.cdecl.} =
      textAttributeSet(platform.AccessTextRun()))
  cbTextInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # get_text, get_text_at_offset, get_character_at_offset,
      # get_caret_offset, get_run_attributes, get_default_attributes,
      # get_character_count, get_n_selections, get_selection and
      # get_string_at_offset.
      setIface(iface, {0: cbGetText, 2: cbTextAtOffset, 3: cbCharAt,
        5: cbCaret, 6: cbRunAttributes, 7: cbDefaultAttributes,
        9: cbCount, 11: cbSelections, 12: cbSelection,
        23: cbStringAtOffset}.toTable))

  # The rows a list chooses, which choosing a row as a click does
  # changes: it chooses that row alone.
  cbAddSelection = cast[pointer](
    proc(obj: pointer, i: int32): bool {.cdecl.} =
      let c = childAt(obj, i)
      if c.isNil or not chooses(c.n) or
          (c.n.actions and actionPress) == AccessActions(0):
        return false
      c.act(accessPress, "")
      true)
  cbRefuse = cast[pointer](
    proc(obj: pointer): bool {.cdecl.} = false)
  cbRefuseAt = cast[pointer](
    proc(obj: pointer, i: int32): bool {.cdecl.} = false)
  cbRefSelection = cast[pointer](
    proc(obj: pointer, i: int32): pointer {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        let rows = an.chosenRows()
        if i >= 0 and int(i) < rows.len:
          return gObjectRef(rows[i].obj)
      nil)
  cbSelectionCount = cast[pointer](
    proc(obj: pointer): int32 {.cdecl.} =
      let an = nodeAt0(obj)
      if not an.isNil:
        return int32(an.chosenRows().len)
      0)
  cbIsSelected = cast[pointer](
    proc(obj: pointer, i: int32): bool {.cdecl.} =
      let c = childAt(obj, i)
      not c.isNil and chooses(c.n) and
        (c.n.states and accessChecked) != AccessStates(0))
  cbSelectionInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # add_selection, clear_selection, ref_selection,
      # get_selection_count, is_child_selected, remove_selection and
      # select_all_selection.
      setIface(iface, {0: cbAddSelection, 1: cbRefuse, 2: cbRefSelection,
        3: cbSelectionCount, 4: cbIsSelected, 5: cbRefuseAt,
        6: cbRefuse}.toTable))

  cbSetContents = cast[pointer](
    proc(obj, text: pointer) {.cdecl.} =
      let an = editable(obj)
      if not an.isNil:
        an.act(accessSetValue, goStr(text)))
  cbInsert = cast[pointer](
    proc(obj, text: pointer, length: int32,
        position: pointer) {.cdecl.} =
      let an = editable(obj)
      if an.isNil or position.isNil:
        return
      let str = cBytes(text, length)
      let r = an.text()
      let at = max(0, min(int(cast[ptr int32](slot(position, 0)[])[]),
        r.len))
      an.act(accessSetValue, $r[0 ..< at] & str & $r[at ..< r.len])
      setInt(position, at + runeLen(str)))
  cbRemove = cast[pointer](
    proc(obj: pointer, start, `end`: int32) {.cdecl.} =
      let an = editable(obj)
      if not an.isNil:
        let r = an.text()
        let (a, b) = span(start, `end`, r.len)
        an.act(accessSetValue, $r[0 ..< a] & $r[b ..< r.len]))
  cbEditableInit = cast[pointer](
    proc(iface, data: pointer) {.cdecl.} =
      # set_text_contents, insert_text and delete_text.
      setIface(iface, {1: cbSetContents, 2: cbInsert, 5: cbRemove}.toTable))

## graft puts the pages of the surface's web views in the nodes of
## list standing for them, and takes those of the others out.
proc graft*(t: accessTree, list: seq[accessNode]) =
  var grafted = initTable[gtkWindow, bool]()
  for an in list:
    an.page = nil
    if not (an.n.webView of gtkWebView):
      continue
    let v = gtkWebView(an.n.webView).w
    if v.isNil or grafted.getOrDefault(v) or v.closed or
        v.host.isNil or v.host.surface != t.s:
      continue
    let acc = v.pageAccessible()
    if not acc.isNil:
      grafted[v] = true
      an.page = acc
      if v.accessParent != an.obj:
        v.accessParent = an.obj
        atkObjectSetParent(acc, an.obj)
  for v in t.s.w.webViews:
    if not grafted.getOrDefault(v) and not v.accessParent.isNil:
      v.accessParent = nil
      let acc = v.pageAccessible()
      if not acc.isNil:
        atkObjectSetParent(acc, nil)

## textRunAt returns the run of runs holding rune i of a text of n
## runes, and where it starts and ends: between runs, a run without
## formats over the runes between them.
proc textRunAt*(runs: seq[platform.AccessTextRun], i, n: int):
    tuple[run: platform.AccessTextRun, a, b: int] =
  var start = 0
  for r in runs:
    if i < r.start:
      return (platform.AccessTextRun(), start, r.start)
    if i < r.`end`:
      return (r, r.start, r.`end`)
    start = r.`end`
  (platform.AccessTextRun(), min(start, n), n)

## textAttributeSet returns the formats of a run as an AtkAttributeSet,
## which ATK frees.
proc textAttributeSet*(r: platform.AccessTextRun): pointer =
  var list: pointer
  proc add(name, value: string) {.closure.} =
    let attr = gMalloc0(16) # AtkAttribute: name, value
    slot(attr, 0)[] = cString(name)
    slot(attr, 8)[] = cString(value)
    list = gSlistAppend(list, attr)
  if r.family != "":
    add("family-name", r.family)
  if r.size > 0:
    add("size", formatFloat(float64(r.size) * 0.75, ffDecimal, 4))
      # points
  var weight = r.weight
  if weight <= 0:
    weight = 400
  add("weight", $weight)
  if r.italic:
    add("style", "italic")
  else:
    add("style", "normal")
  if r.underline:
    add("underline", "single")
  else:
    add("underline", "none")
  add("strikethrough", $r.strikethrough)
  proc color(c: array[4, uint8]): string =
    $ (int(c[0]) * 257) & "," & $(int(c[1]) * 257) & "," &
      $(int(c[2]) * 257)
  if r.color[3] > 0:
    add("fg-color", color(r.color))
  if r.background[3] > 0:
    add("bg-color", color(r.background))
  list
