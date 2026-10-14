## surface_access.nim (surface_access.go): UI Automation. Assistive
## technology, such as Narrator, reads native UI through it. The
## surface's window answers WM_GETOBJECT with a fragment root whose
## fragments are the nodes of the content's tree: COM objects with
## the control patterns of their roles. Invoke presses buttons and
## links, Toggle check boxes and switches, SelectionItem radio
## buttons and the rows lists choose, in the Selection of their
## list; RangeValue gives sliders and progress bars, Value text
## fields and pop-up buttons, which ExpandCollapse opens;
## ScrollItem scrolls what is in scroll containers into view. Rows
## say which of all of their list's they are (PositionInSet,
## SizeOfSet), as a list builds only those in view.
##
## Go needed assembly thunks for the methods that take doubles;
## Nim's stdcall procs take them directly.

var
  uiaInited = false
  ## The vtables of the interfaces, by uiaIface index.
  uiaVtbls*: array[13, seq[uint]]
  ## uiaElements keeps the elements COM holds alive.
  uiaElements* = initHashSet[uiaElement]()

## The interfaces of elements.
const
  ifaceSimple* = 0
  ifaceFragment* = 1
  ifaceRoot* = 2
  ifaceInvoke* = 3
  ifaceToggle* = 4
  ifaceSelectionItem* = 5
  ifaceRangeValue* = 6
  ifaceValue* = 7
  ifaceExpandCollapse* = 8
  ifaceSelection* = 9
  ifaceScrollItem* = 10
  ifaceHwndOverride* = 11
  ifaceText* = 12
  uiaIfaces* = 13

var uiaIIDs*: array[uiaIfaces, GUID] = [
  guid("d6dd68d1-86fd-4332-8666-9abedea2d24c"), ## IRawElementProviderSimple
  guid("f7063da8-8359-439c-9297-bbc5299a7d87"), ## IRawElementProviderFragment
  guid("620ce2a5-ab8f-40a9-86cb-de3c75599b58"), ## IRawElementProviderFragmentRoot
  guid("54fcb24b-e18e-47a2-b4d3-eccbe77599a2"), ## IInvokeProvider
  guid("56d00bd0-c4f4-433c-a836-1a52a57e0892"), ## IToggleProvider
  guid("2acad808-b2d4-452d-a407-91ff1ad167b2"), ## ISelectionItemProvider
  guid("36dc7aef-33e6-4691-afe1-2be7274b3d33"), ## IRangeValueProvider
  guid("c7935180-6fb3-4201-b174-7df73adbf64a"), ## IValueProvider
  guid("d847d3a5-cab0-4a98-8c32-ecb45c59ad24"), ## IExpandCollapseProvider
  guid("fb8b03af-3bdf-48d4-bd36-1a65793be168"), ## ISelectionProvider
  guid("2360c714-4bf1-4b26-ba65-9b21316127eb"), ## IScrollItemProvider
  guid("1d5df27c-8947-4425-b8d9-79787bb460b8"), ## IRawElementProviderHwndOverride
  guid("3589c92c-63f3-4367-99bb-ada653b77cf2"), ## ITextProvider
]

## Pattern identifiers of UI Automation, by interface.
const uiaPatterns* = {10000'u32: ifaceInvoke,
  10001: ifaceSelection, 10002: ifaceValue, 10003: ifaceRangeValue,
  10005: ifaceExpandCollapse, 10010: ifaceSelectionItem,
  10014: ifaceText, 10015: ifaceToggle,
  10017: ifaceScrollItem}.toTable

const
  uiaRootObjectID* = -25'i32
  objidClient* = -4'i32
  eventObjectFocus* = 0x8005'u32

  uiaRuntimeIDProperty* = 30000
  uiaControlTypeProperty* = 30003
  uiaLocalizedControlProperty* = 30004
  uiaNameProperty* = 30005
  uiaHasKeyboardFocusProperty* = 30008
  uiaIsFocusableProperty* = 30009
  uiaIsEnabledProperty* = 30010
  uiaHelpTextProperty* = 30013
  uiaIsDataValidProperty* = 30103
  uiaItemStatusProperty* = 30026
  uiaLevelProperty* = 30154
  uiaFullDescriptionProperty* = 30159
  uiaIsPasswordProperty* = 30019
  uiaFrameworkIDProperty* = 30024
  uiaValueProperty* = 30045
  uiaRangeValueProperty* = 30047
  uiaExpandStateProperty* = 30070
  uiaIsSelectedProperty* = 30079
  uiaToggleStateProperty* = 30086
  uiaIsDialogProperty* = 30174
  uiaHeadingLevelProperty* = 30173
  uiaOrientationProperty* = 30023
  uiaIsOffscreenProperty* = 30022
  uiaPositionInSetProperty* = 30152
  uiaSizeOfSetProperty* = 30153
  uiaLiveSettingProperty* = 30135

  uiaFocusChangedEvent* = 20005
  uiaElementAddedToSelectionEvent* = 20010
  uiaElementRemovedFromSelectionEvent* = 20011
  uiaElementSelectedEvent* = 20012
  uiaLiveRegionChangedEvent* = 20024
  uiaTextSelectionChangedEvent* = 20014
  uiaTextChangedEvent* = 20015

  ## announcerID identifies the live region holding announcements.
  announcerID* = high(uint64)

  vtEmpty* = 0'u16
  vtI4* = 3'u16
  vtR8* = 5'u16
  vtBSTR* = 8'u16
  vtBool* = 11'u16
  vtUnknown* = 13'u16

  uiaElementNotEnabled* = 0x80040200'u
  uiaElementNotAvailable* = 0x80040201'u
  uiaInvalidOperation* = 0x80131509'u

## Control types of roles.
const uiaControlTypes* = {roleGroup: 50026'i32, roleText: 50020,
  roleButton: 50000, roleLink: 50005, roleCheckBox: 50002,
  roleRadio: 50013, roleSwitch: 50000, roleSlider: 50015,
  roleProgress: 50012, roleTextField: 50004, roleImage: 50006,
  roleList: 50008, roleScroll: 50033, roleDialog: 50033,
  rolePopup: 50033, roleTooltip: 50022, rolePopUpButton: 50003,
  roleTabList: 50018, roleTab: 50019, roleSplitter: 50038,
  roleStatus: 50017, roleTable: 50036, roleRow: 50029,
  roleCell: 50025, roleColumnHeader: 50035, roleTree: 50023,
  roleTreeItem: 50024, roleListItem: 50007, roleMenuButton: 50000,
  roleToolbar: 50021, roleRadioGroup: 50026, roleToggleButton: 50000,
  roleComboBox: 50003, roleDisclosure: 50000, roleMeter: 50012,
  roleStepper: 50016, roleColorWell: 50000, roleAlertDialog: 50033,
  roleMenu: 50009, roleMenuBar: 50010, roleMenuItem: 50011,
  roleMenuItemCheckBox: 50011, roleMenuItemRadio: 50011,
  roleHeading: 50020}.toTable

## variant is VARIANT, with the value of the types used here.
type variant* = object
  vt*: uint16
  pad0*: array[3, uint16]
  val*: uint64
  pad1*: uint

## uiaRect is UiaRect.
type uiaRect* = object
  left*, top*, width*, height*: float64

proc ptr*(e: uiaElement, i: int): uint =
  cast[uint](cast[pointer](addr e.ifaces[i]))

proc uiaOf*(this: uint): uiaElement =
  cast[ptr uiaIface](cast[pointer](this)).e

proc newUIAElement*(t: uiaTree): uiaElement =
  let e = uiaElement(refs: 1, tree: t)
  for i in 0 ..< uiaIfaces:
    e.ifaces[i] = uiaIface(vtbl: addr uiaVtbls[i][0], e: e)
  uiaElements.incl(e)
  e

proc addRef*(e: uiaElement): int32 =
  inc e.refs
  e.refs

proc release*(e: uiaElement): int32 =
  dec e.refs
  if e.refs == 0:
    uiaElements.excl(e)
  e.refs

## supports reports whether the element implements an interface.
proc supports*(e: uiaElement, i: int): bool =
  let n = e.n
  case i
  of ifaceSimple, ifaceFragment:
    return true
  of ifaceRoot, ifaceHwndOverride:
    return e.root
  else:
    discard
  if e.root:
    return false
  case i
  of ifaceInvoke:
    if n.role in [roleCheckBox, roleSwitch, roleRadio,
        rolePopUpButton, roleTab, roleMenuButton, roleToggleButton,
        roleDisclosure]:
      return false
    return (n.actions and actionPress) != AccessActions(0)
  of ifaceToggle:
    ## Items of menus showing a choice toggle it, as WPF's
    ## checkable items, and are invoked as well.
    return n.role in [roleCheckBox, roleSwitch, roleToggleButton,
      roleMenuItemCheckBox, roleMenuItemRadio]
  of ifaceSelectionItem:
    if n.role in [roleRadio, roleTab, roleTreeItem]:
      return true
    if n.role in [roleListItem, roleRow]:
      return (n.states and accessSelectable) != AccessStates(0)
    return false
  of ifaceSelection:
    ## A list or table choosing its rows.
    return n.role in [roleList, roleTable, roleTree] and
      (n.states and accessSelectable) != AccessStates(0)
  of ifaceScrollItem:
    return (n.actions and actionScrollIntoView) != AccessActions(0)
  of ifaceRangeValue:
    return n.role.ranged()
  of ifaceValue:
    return n.role in [roleTextField, rolePopUpButton, roleComboBox,
      roleColorWell]
  of ifaceText:
    ## Text fields' text, by characters, formats, words and lines,
    ## with the formats of a rich text's runs; a password's is not.
    return n.role == roleTextField and
      (n.states and accessPassword) == AccessStates(0)
  of ifaceExpandCollapse:
    ## A menu button expands into its menu, as WinUI's
    ## DropDownButton.
    return n.role in [rolePopUpButton, roleTreeItem, roleMenuButton,
      roleComboBox, roleDisclosure]
  else:
    return false

## out stores an interface of an element, with a reference, at a
## pointer.
proc out0*(p: uint, e: uiaElement, i: int): uint =
  if e.isNil:
    cast[ptr uint](cast[pointer](p))[] = 0
    return sOK
  discard e.addRef()
  cast[ptr uint](cast[pointer](p))[] = e.ptr(i)
  sOK

proc setBool*(p: uint, v: bool) =
  cast[ptr int32](cast[pointer](p))[] = 0
  if v:
    cast[ptr int32](cast[pointer](p))[] = 1

proc setFloat*(p: uint, v: float64) =
  cast[ptr float64](cast[pointer](p))[] = v

proc bstr*(s: string): uint =
  procSysAllocString(cast[uint](u16(s)))

proc boolVariant*(v: bool): variant =
  if v:
    ## VARIANT_TRUE
    return variant(vt: vtBool, val: 0xFFFF)
  variant(vt: vtBool)

## accessRoot returns the root of the tree UI Automation sees,
## asking the content for the tree while it has none, as before its
## first frame.
proc accessRoot*(s: w32Surface): uiaElement =
  if not uiaInited:
    uiaInited = true
    initUIA()
  var t = s.access
  if t.isNil:
    t = uiaTree(s: s, nodes: initTable[uint64, uiaElement]())
    t.root = newUIAElement(t)
    t.root.root = true
    s.access = t
  if t.order.len == 0:
    t.quiet = true
    discard s.send(SurfaceEvent(kind: accessibilityOn))
    t.quiet = false
  t.root

## getObject answers WM_GETOBJECT for UI Automation.
proc getObject*(s: w32Surface, wp,
    lp: uint): tuple[r: uint, ok: bool] =
  ## UI Automation asks for the root (UiaRootObjectId), and, with
  ## object IDs from 0 up, for the elements whose events its clients
  ## receive: UiaReturnRawElementProvider answers both, and
  ## OBJID_CLIENT with the MSAA view of the tree. Other MSAA objects
  ## (the title bar, the scroll bars, …) are the window's.
  let id = int32(uint32(lp))
  if (id < 0 and id != uiaRootObjectID and id != objidClient) or
      s.w.closed:
    return (0'u, false)
  let root = s.accessRoot()
  let r = procUiaReturnRawElementProvider(s.hwnd, wp, lp,
    root.ptr(ifaceSimple))
  (r, true)

## updateAccessibility shows UI Automation the content's last frame,
## and tells its clients what changed.
method updateAccessibility*(s: w32Surface, tree: AccessTree) =
  let t = s.access
  if not t.isNil:
    t.update(tree)

## destroyAccess disconnects the tree when the surface's window
## goes.
proc destroyAccess*(s: w32Surface) =
  let t = s.access
  if t.isNil:
    return
  s.access = nil
  discard procUiaReturnRawElementProvider(s.hwnd, 0, 0, 0)
  for e in t.order:
    e.disconnect()
  t.root.disconnect()
  t.nodes.clear()
  t.order.setLen(0)

## disconnect lets go of an element that left the tree.
proc disconnect*(e: uiaElement) =
  e.dead = true
  discard procUiaDisconnectProvider(e.ptr(ifaceSimple))
  discard e.release()

proc listening*(): bool =
  procUiaClientsAreListening() != 0

## Forward declarations for procs defined below.
proc runtimeID*(e: uiaElement): seq[int32]
proc notifyChanges*(e: uiaElement, prev: AccessNode)
proc disconnect*(e: uiaElement)
proc initUIA*()
proc page*(e: uiaElement): w32Window
proc pageCall*(e: uiaElement, `method`: int,
  args: varargs[uint]): tuple[r: uint, ok: bool]
proc update*(t: uiaTree, tree: AccessTree)
proc focusWebView*(w: w32Window)
proc container*(e: uiaElement): uiaElement
proc chosen*(e: uiaElement): seq[uiaElement]
proc textProviderMethods*(): seq[uint]
proc initTextRanges*()

proc update*(t: uiaTree, tree: AccessTree) =
  ## Announcements go into a polite live region at the end of the
  ## tree, whose LiveRegionChanged screen readers read, as
  ## Flutter's alerts: notification events
  ## (UiaRaiseNotificationEvent), which a provider of another
  ## process raises, reached no client in tests, unlike its other
  ## events.
  var tree = tree
  if tree.announcements.len > 0:
    t.announced = tree.announcements.join(" ")
  if t.announced != "":
    let announcer = AccessNode(id: announcerID, parent: -1,
      role: roleText, label: t.announced,
      bounds: RectF(w: 1, h: 1))
    tree = AccessTree(nodes: tree.nodes & @[announcer],
      focus: tree.focus, announcements: tree.announcements)
  let notify = not t.quiet and listening()
  var old = t.nodes
  t.nodes = initTable[uint64, uiaElement]()
  var order = newSeq[uiaElement](tree.nodes.len)
  var prev = newSeq[AccessNode](tree.nodes.len)
  var fresh = newSeq[bool](tree.nodes.len)
  var oldKids = initTable[uiaElement, seq[uiaElement]]()
  oldKids[t.root] = t.root.children
  for i, n in tree.nodes:
    var e = old.getOrDefault(n.id)
    if not e.isNil:
      old.del(n.id)
      oldKids[e] = e.children
      prev[i] = e.n
    else:
      e = newUIAElement(t)
      fresh[i] = true
    e.n = n
    e.children.setLen(0)
    t.nodes[n.id] = e
    order[i] = e
  t.root.children.setLen(0)
  for e in order:
    e.parent = t.root
    if e.n.parent >= 0:
      e.parent = order[e.n.parent]
    e.parent.children.add(e)
  t.order = order
  if notify:
    for parent, kids in oldKids:
      var added, removed: seq[uiaElement]
      for k in kids:
        if k notin parent.children:
          removed.add(k)
      for k in parent.children:
        if k notin kids:
          added.add(k)
      if added.len + removed.len > 1:
        var id = parent.runtimeID()
        ## StructureChangeType_ChildrenInvalidated
        discard procUiaRaiseStructureChangedEvent(
          parent.ptr(ifaceSimple), 2,
          cast[uint](if id.len > 0: addr id[0] else: nil),
          uint(id.len))
      elif added.len == 1:
        var id = added[0].runtimeID()
        ## StructureChangeType_ChildAdded
        discard procUiaRaiseStructureChangedEvent(
          added[0].ptr(ifaceSimple), 0,
          cast[uint](addr id[0]), uint(id.len))
      elif removed.len == 1:
        var id = removed[0].runtimeID()
        ## StructureChangeType_ChildRemoved
        discard procUiaRaiseStructureChangedEvent(
          parent.ptr(ifaceSimple), 1,
          cast[uint](addr id[0]), uint(id.len))
    for i, e in order:
      if not fresh[i]:
        e.notifyChanges(prev[i])
  for e in old.values:
    e.disconnect()
  if tree.focus != t.focus:
    t.focus = tree.focus
    let e = t.nodes.getOrDefault(t.focus)
    if not e.isNil and notify:
      discard procUiaRaiseAutomationEvent(e.ptr(ifaceSimple),
        uiaFocusChangedEvent)
      ## Clients that follow the focus through WinEvents, as those
      ## of System.Windows.Automation, then ask the window for it.
      discard procNotifyWinEvent(eventObjectFocus, t.s.hwnd,
        uint(uint32(objidClient)), 0)
  let e = t.nodes.getOrDefault(announcerID)
  if not e.isNil and notify and tree.announcements.len > 0:
    discard procUiaRaiseAutomationEvent(e.ptr(ifaceSimple),
      uiaLiveRegionChangedEvent)

proc smallChange*(n: AccessNode): float64 =
  if n.step > 0:
    return n.step
  (n.max - n.min) / 100

proc toggleState*(n: AccessNode): int32 =
  if (n.states and accessMixed) != AccessStates(0):
    ## ToggleState_Indeterminate
    return 2
  if (n.states and accessChecked) != AccessStates(0):
    return 1
  0

proc expandState*(n: AccessNode): int32 =
  if (n.states and accessExpanded) != AccessStates(0):
    ## ExpandCollapseState_Expanded
    return 1
  if n.role == roleTreeItem and
      (n.states and accessExpandable) == AccessStates(0):
    ## ExpandCollapseState_LeafNode
    return 3
  0

## rangeValue is the value of a slider or progress bar, the minimum
## for a progress of unknown length.
proc rangeValue*(n: AccessNode): float64 = max(n.now, n.min)

## notifyChanges tells UI Automation's clients how an element
## changed since the last tree.
proc notifyChanges*(e: uiaElement, prev: AccessNode) =
  let n = e.n
  proc changed(property: int, before, after: variant) =
    var b = before
    var a = after
    discard procUiaRaiseAutomationPropertyChangedEvent(
      e.ptr(ifaceSimple), uint(property), cast[uint](addr b),
      cast[uint](addr a))
  proc str(property: int, before, after: string) =
    var b = variant(vt: vtBSTR, val: uint64(bstr(before)))
    var a = variant(vt: vtBSTR, val: uint64(bstr(after)))
    discard procUiaRaiseAutomationPropertyChangedEvent(
      e.ptr(ifaceSimple), uint(property), cast[uint](addr b),
      cast[uint](addr a))
    discard procVariantClear(cast[uint](addr b))
    discard procVariantClear(cast[uint](addr a))
  if prev.label != n.label:
    str(uiaNameProperty, prev.label, n.label)
  if (prev.states and accessDisabled) !=
      (n.states and accessDisabled):
    changed(uiaIsEnabledProperty,
      boolVariant((prev.states and accessDisabled) ==
        AccessStates(0)),
      boolVariant((n.states and accessDisabled) == AccessStates(0)))
  if e.supports(ifaceToggle):
    let before = toggleState(prev)
    let after = toggleState(n)
    if before != after:
      changed(uiaToggleStateProperty,
        variant(vt: vtI4, val: uint64(uint32(before))),
        variant(vt: vtI4, val: uint64(uint32(after))))
  elif e.supports(ifaceSelectionItem):
    let before = (prev.states and accessChecked) != AccessStates(0)
    let after = (n.states and accessChecked) != AccessStates(0)
    if before != after:
      changed(uiaIsSelectedProperty, boolVariant(before),
        boolVariant(after))
      ## A row of a list choosing several joins the choice or
      ## leaves it, unless it is now the only one.
      var event = uint(uiaElementSelectedEvent)
      let c = e.container()
      if not c.isNil and (c.n.states and accessMultiselectable) !=
          AccessStates(0):
        if not after:
          event = uiaElementRemovedFromSelectionEvent
        elif c.chosen().len > 1:
          event = uiaElementAddedToSelectionEvent
      if after or event != uiaElementSelectedEvent:
        discard procUiaRaiseAutomationEvent(e.ptr(ifaceSimple),
          event)
  elif e.supports(ifaceRangeValue):
    if prev.now != n.now:
      changed(uiaRangeValueProperty,
        variant(vt: vtR8,
          val: cast[uint64](rangeValue(prev))),
        variant(vt: vtR8, val: cast[uint64](rangeValue(n))))
  if e.supports(ifaceValue) and prev.value != n.value:
    str(uiaValueProperty, prev.value, n.value)
  if e.supports(ifaceText):
    if prev.value != n.value or prev.textRuns != n.textRuns:
      discard procUiaRaiseAutomationEvent(e.ptr(ifaceSimple),
        uiaTextChangedEvent)
    if prev.selStart != n.selStart or prev.selEnd != n.selEnd:
      discard procUiaRaiseAutomationEvent(e.ptr(ifaceSimple),
        uiaTextSelectionChangedEvent)
  if e.supports(ifaceExpandCollapse) and
      (prev.states and accessExpanded) !=
      (n.states and accessExpanded):
    changed(uiaExpandStateProperty,
      variant(vt: vtI4, val: uint64(uint32(expandState(prev)))),
      variant(vt: vtI4, val: uint64(uint32(expandState(n)))))

## runtimeID returns the element's runtime identifier:
## UiaAppendRuntimeId and its node's identifier, or nothing for the
## root, which its window identifies.
proc runtimeID*(e: uiaElement): seq[int32] =
  if e.root:
    return @[]
  @[3'i32, int32(uint32(e.n.id)),
    int32(uint32(e.n.id shr 32))]

## act performs an action of assistive technology on the element.
proc act*(e: uiaElement, action: AccessActionKind,
    text: string): uint =
  if e.dead:
    return uiaElementNotAvailable
  if (e.n.states and accessDisabled) != AccessStates(0):
    return uiaElementNotEnabled
  discard e.tree.s.send(SurfaceEvent(kind: accessAction,
    id: e.n.id, action: action, text: text))
  sOK

## screenRect returns the element's bounds in pixels of the screen.
proc screenRect*(e: uiaElement): uiaRect =
  let s = e.tree.s
  var origin: w32Point
  discard procClientToScreen(s.hwnd, cast[uint](addr origin))
  let scale = float64(s.dpi()) / 96
  let b = e.n.bounds
  uiaRect(left: float64(origin.x) + b.x * scale,
    top: float64(origin.y) + b.y * scale,
    width: b.w * scale, height: b.h * scale)

## at returns the deepest element at a point of the screen, in
## pixels, the topmost of those that overlap.
proc at*(t: uiaTree, x, y: float64): uiaElement =
  for i in countdown(t.order.len - 1, 0):
    let r = t.order[i].screenRect()
    if x >= r.left and y >= r.top and x < r.left + r.width and
        y < r.top + r.height:
      return t.order[i]
  nil

## The COM callbacks. Each takes the interface pointer as its first
## argument, from which uiaOf recovers the element.

proc liveElement*(this: uint): tuple[e: uiaElement, hr: uint] =
  let e = uiaOf(this)
  if e.isNil or e.dead:
    return (nil, uiaElementNotAvailable)
  (e, sOK)

proc uiaQueryInterface(this, riid, p: uint): uint {.stdcall.} =
  let e = uiaOf(this)
  let iid = cast[ptr GUID](cast[pointer](riid))[]
  if iid == iidIUnknown:
    return out0(p, e, ifaceSimple)
  for i, id in uiaIIDs:
    if id == iid and e.supports(i):
      return out0(p, e, i)
  cast[ptr uint](cast[pointer](p))[] = 0
  eNoInterface

proc uiaAddRef(this: uint): uint {.stdcall.} =
  uint(uiaOf(this).addRef())

proc uiaRelease(this: uint): uint {.stdcall.} =
  uint(uiaOf(this).release())

proc uiaGetProviderOptionsCb(this, p: uint): uint {.stdcall.} =
  let e = uiaOf(this)
  let (hr, ok) = e.pageCall(uiaGetProviderOptions, p)
  if ok:
    return hr
  ## ServerSideProvider, UseComThreading
  cast[ptr int32](cast[pointer](p))[] = 0x1 or 0x20
  sOK

proc uiaGetPatternProviderCb(this, pattern, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  let (phr, ok) = e.pageCall(uiaGetPatternProvider, pattern, p)
  if ok and phr != eNotImpl:
    return phr
  let i = uiaPatterns.getOrDefault(uint32(pattern), -1)
  if i >= 0 and e.supports(i):
    return out0(p, e, i)
  out0(p, nil, 0)

proc uiaGetPropertyValueCb(this, property, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  let v = cast[ptr variant](cast[pointer](p))
  v[] = variant()
  if e.isNil:
    return hr
  let (phr, ok) = e.pageCall(uiaGetPropertyValue, property, p)
  if ok and phr != eNotImpl:
    return phr
  e.property(int(property), v)
  sOK

proc uiaGetHostRawElementProviderCb(this, p: uint): uint {.stdcall.} =
  let e = uiaOf(this)
  if e.root and not e.dead:
    return procUiaHostProviderFromHwnd(e.tree.s.hwnd, p)
  let (hr, ok) = e.pageCall(uiaGetHostRawElementProvider, p)
  if ok:
    return hr
  out0(p, nil, 0)

proc uiaNavigateCb(this, direction, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  var to: uiaElement
  proc siblings(d: int): uiaElement =
    if e.root:
      return nil
    let kids = e.parent.children
    var i = -1
    for j, k in kids:
      if k == e:
        i = j
        break
    i += d
    if i >= 0 and i < kids.len:
      return kids[i]
    nil
  case direction
  of 0: ## NavigateDirection_Parent
    if not e.root:
      to = e.parent
  of 1: ## NextSibling
    to = siblings(1)
  of 2: ## PreviousSibling
    to = siblings(-1)
  of 3: ## FirstChild
    if e.children.len > 0:
      to = e.children[0]
  of 4: ## LastChild
    if e.children.len > 0:
      to = e.children[^1]
  else:
    discard
  out0(p, to, ifaceFragment)

proc uiaGetRuntimeIdCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  cast[ptr uint](cast[pointer](p))[] = 0
  if e.isNil:
    return hr
  let id = e.runtimeID()
  if id.len == 0 or not e.page().isNil:
    ## a page's is its window's
    return sOK
  let sa = procSafeArrayCreateVector(uint(vtI4), 0, uint(id.len))
  for i in 0 ..< id.len:
    var index = int32(i)
    var v = id[i]
    discard procSafeArrayPutElement(sa, cast[uint](addr index),
      cast[uint](addr v))
  cast[ptr uint](cast[pointer](p))[] = sa
  sOK

proc uiaGetBoundingRectangleCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  cast[ptr uiaRect](cast[pointer](p))[] = uiaRect()
  if e.isNil:
    return hr
  if not e.root: ## the root's window gives the root's
    cast[ptr uiaRect](cast[pointer](p))[] = e.screenRect()
  sOK

proc uiaGetEmbeddedFragmentRootsCb(this, p: uint): uint {.stdcall.} =
  cast[ptr uint](cast[pointer](p))[] = 0
  sOK

proc uiaSetFocusCb(this: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  let v = e.page()
  if not v.isNil:
    v.focusWebView()
    return sOK
  discard procSetFocus(e.tree.s.hwnd)
  if e.root or
      (e.n.actions and actionFocus) == AccessActions(0):
    return sOK
  e.act(accessFocus, "")

proc uiaGetFragmentRootCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  out0(p, e.tree.root, ifaceRoot)

proc uiaElementProviderFromPointCb(this: uint, x, y: float64,
    p: uint): uint {.stdcall.} =
  ## ElementProviderFromPoint: the doubles come in floating point
  ## registers, which Nim reads.
  discard out0(p, nil, 0)
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  out0(p, e.tree.at(x, y), ifaceFragment)

proc uiaSetValueThunkCb(this: uint, v: float64): uint {.stdcall.} =
  ## IRangeValueProvider::SetValue.
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  e.setRangeValue(v)

proc uiaGetOverrideProviderForHwndCb(this, hwnd,
    p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  cast[ptr uint](cast[pointer](p))[] = 0
  if e.isNil:
    return hr
  out0(p, e.tree.pageOfWindow(hwnd), ifaceSimple)

proc uiaGetFocusCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  out0(p, e.tree.nodes.getOrDefault(e.tree.focus), ifaceFragment)

proc uiaInvokeCb(this: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  e.act(accessPress, "")

proc uiaToggleInvokeCb(this: uint): uint {.stdcall.} =
  uiaInvokeCb(this)

proc uiaGetToggleStateCb(this, p: uint): uint {.stdcall.} =
  cast[ptr int32](cast[pointer](p))[] = toggleState(uiaOf(this).n)
  sOK

proc uiaSelectItemCb(this: uint): uint {.stdcall.} =
  ## Select, AddToSelection.
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  if (e.n.states and accessChecked) != AccessStates(0):
    return sOK
  e.act(accessPress, "")

proc uiaRemoveFromSelectionCb(this: uint): uint {.stdcall.} =
  uiaInvalidOperation

proc uiaGetIsSelectedCb(this, p: uint): uint {.stdcall.} =
  setBool(p, (uiaOf(this).n.states and accessChecked) !=
    AccessStates(0))
  sOK

proc uiaGetSelectionContainerCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  out0(p, e.container(), ifaceSimple)

proc uiaGetSelectionCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  cast[ptr uint](cast[pointer](p))[] = 0
  if e.isNil:
    return hr
  let chosen = e.chosen()
  let sa = procSafeArrayCreateVector(uint(vtUnknown), 0,
    uint(chosen.len))
  for i, d in chosen:
    var index = int32(i)
    var v = d.ptr(ifaceSimple)
    discard procSafeArrayPutElement(sa, cast[uint](addr index),
      cast[uint](addr v))
  cast[ptr uint](cast[pointer](p))[] = sa
  sOK

proc uiaGetCanSelectMultipleCb(this, p: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    setBool(p, false)
    return hr
  setBool(p, (e.n.states and accessMultiselectable) !=
    AccessStates(0))
  sOK

proc uiaGetIsSelectionRequiredCb(this, p: uint): uint {.stdcall.} =
  setBool(p, false)
  sOK

proc uiaScrollIntoViewCb(this: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  e.act(accessScrollIntoView, "")

proc uiaGetRangeValueCb(this, p: uint): uint {.stdcall.} =
  setFloat(p, rangeValue(uiaOf(this).n))
  sOK

proc uiaGetIsReadOnlyRangeCb(this, p: uint): uint {.stdcall.} =
  setBool(p, (uiaOf(this).n.actions and actionIncrement) ==
    AccessActions(0))
  sOK

proc uiaGetMaximumCb(this, p: uint): uint {.stdcall.} =
  setFloat(p, uiaOf(this).n.max)
  sOK

proc uiaGetMinimumCb(this, p: uint): uint {.stdcall.} =
  setFloat(p, uiaOf(this).n.min)
  sOK

proc uiaGetLargeChangeCb(this, p: uint): uint {.stdcall.} =
  let n = uiaOf(this).n
  ## as Page Up and Down
  setFloat(p, max(smallChange(n), (n.max - n.min) / 10))
  sOK

proc uiaGetSmallChangeCb(this, p: uint): uint {.stdcall.} =
  ## as the arrow keys
  setFloat(p, smallChange(uiaOf(this).n))
  sOK

proc uiaValueSetValueCb(this, s: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  if (e.n.actions and actionSetValue) == AccessActions(0):
    return uiaInvalidOperation
  e.act(accessSetValue, wstr(cast[pointer](s)))

proc uiaGetValueCb(this, p: uint): uint {.stdcall.} =
  cast[ptr uint](cast[pointer](p))[] = bstr(uiaOf(this).n.value)
  sOK

proc uiaGetIsReadOnlyValueCb(this, p: uint): uint {.stdcall.} =
  setBool(p, (uiaOf(this).n.actions and actionSetValue) ==
    AccessActions(0))
  sOK

proc uiaExpandCb(this: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  if (e.n.states and accessExpanded) != AccessStates(0):
    return sOK
  if (e.n.actions and actionExpand) != AccessActions(0):
    ## An item of a tree, which pressing chooses.
    return e.act(accessExpand, "")
  e.act(accessPress, "")

proc uiaCollapseCb(this: uint): uint {.stdcall.} =
  let (e, hr) = liveElement(this)
  if e.isNil:
    return hr
  if (e.n.states and accessExpanded) == AccessStates(0):
    return sOK
  if (e.n.actions and actionExpand) != AccessActions(0):
    return e.act(accessCollapse, "")
  e.act(accessPress, "")

proc uiaGetExpandCollapseStateCb(this, p: uint): uint {.stdcall.} =
  cast[ptr int32](cast[pointer](p))[] = expandState(uiaOf(this).n)
  sOK

## initUIA builds the vtables of the interfaces, once.
proc initUIA*() =
  let unknown = @[cast[uint](uiaQueryInterface),
    cast[uint](uiaAddRef), cast[uint](uiaRelease)]
  proc vtbl(methods: openArray[uint]): seq[uint] =
    unknown & @methods

  uiaVtbls[ifaceSimple] = vtbl([
    cast[uint](uiaGetProviderOptionsCb),
    cast[uint](uiaGetPatternProviderCb),
    cast[uint](uiaGetPropertyValueCb),
    cast[uint](uiaGetHostRawElementProviderCb)])
  uiaVtbls[ifaceFragment] = vtbl([
    cast[uint](uiaNavigateCb),
    cast[uint](uiaGetRuntimeIdCb),
    cast[uint](uiaGetBoundingRectangleCb),
    cast[uint](uiaGetEmbeddedFragmentRootsCb),
    cast[uint](uiaSetFocusCb),
    cast[uint](uiaGetFragmentRootCb)])
  uiaVtbls[ifaceHwndOverride] = vtbl([
    cast[uint](uiaGetOverrideProviderForHwndCb)])
  uiaVtbls[ifaceText] = vtbl(textProviderMethods())
  initTextRanges()
  uiaVtbls[ifaceRoot] = vtbl([
    cast[uint](uiaElementProviderFromPointCb),
    cast[uint](uiaGetFocusCb)])
  uiaVtbls[ifaceInvoke] = vtbl([cast[uint](uiaInvokeCb)])
  uiaVtbls[ifaceToggle] = vtbl([
    cast[uint](uiaToggleInvokeCb),
    cast[uint](uiaGetToggleStateCb)])
  uiaVtbls[ifaceSelectionItem] = vtbl([
    cast[uint](uiaSelectItemCb),
    cast[uint](uiaSelectItemCb),
    cast[uint](uiaRemoveFromSelectionCb),
    cast[uint](uiaGetIsSelectedCb),
    cast[uint](uiaGetSelectionContainerCb)])
  uiaVtbls[ifaceSelection] = vtbl([
    cast[uint](uiaGetSelectionCb),
    cast[uint](uiaGetCanSelectMultipleCb),
    cast[uint](uiaGetIsSelectionRequiredCb)])
  uiaVtbls[ifaceScrollItem] = vtbl([
    cast[uint](uiaScrollIntoViewCb)])
  uiaVtbls[ifaceRangeValue] = vtbl([
    cast[uint](uiaSetValueThunkCb),
    cast[uint](uiaGetRangeValueCb),
    cast[uint](uiaGetIsReadOnlyRangeCb),
    cast[uint](uiaGetMaximumCb),
    cast[uint](uiaGetMinimumCb),
    cast[uint](uiaGetLargeChangeCb),
    cast[uint](uiaGetSmallChangeCb)])
  uiaVtbls[ifaceValue] = vtbl([
    cast[uint](uiaValueSetValueCb),
    cast[uint](uiaGetValueCb),
    cast[uint](uiaGetIsReadOnlyValueCb)])
  uiaVtbls[ifaceExpandCollapse] = vtbl([
    cast[uint](uiaExpandCb),
    cast[uint](uiaCollapseCb),
    cast[uint](uiaGetExpandCollapseStateCb)])

## setRangeValue moves a slider toward a value, as the arrow keys
## do.
proc setRangeValue*(e: uiaElement, v: float64): uint =
  if (e.n.actions and actionIncrement) == AccessActions(0):
    return uiaInvalidOperation
  if v > e.n.now:
    return e.act(accessIncrement, "")
  if v < e.n.now:
    return e.act(accessDecrement, "")
  sOK

## property fills in a property of the element, leaving the ones it
## has not empty for UI Automation's defaults.
proc property*(e: uiaElement, id: int, v: ptr variant) =
  if e.root:
    ## the window's
    return
  let n = e.n
  proc str(s: string) =
    if s != "":
      v[] = variant(vt: vtBSTR, val: uint64(bstr(s)))
  case id
  of uiaControlTypeProperty:
    v[] = variant(vt: vtI4,
      val: uint64(uint32(uiaControlTypes.getOrDefault(n.role))))
  of uiaLocalizedControlProperty:
    case n.role
    of roleSwitch:
      str("toggle switch")
    of roleMenuButton:
      str("menu button")
    of roleRadioGroup:
      str("radio group")
    of roleDialog:
      str("dialog")
    of roleAlertDialog:
      str("alert dialog")
    of rolePopup:
      str("popup")
    of roleHeading:
      str("heading")
    else:
      discard
  of uiaNameProperty:
    str(n.label)
  of uiaHasKeyboardFocusProperty:
    v[] = boolVariant(n.id == e.tree.focus)
  of uiaIsFocusableProperty:
    v[] = boolVariant((n.states and accessFocusable) !=
      AccessStates(0))
  of uiaIsEnabledProperty:
    v[] = boolVariant((n.states and accessDisabled) ==
      AccessStates(0))
  of uiaHelpTextProperty:
    ## The placeholder of a text field, else the description, as
    ## Chromium's.
    if n.placeholder != "":
      str(n.placeholder)
    else:
      str(n.description)
  of uiaFullDescriptionProperty:
    str(n.description)
  of uiaItemStatusProperty:
    ## The order of the column a table is sorted by, as Chromium
    ## says.
    if (n.states and accessSortAscending) != AccessStates(0):
      str("ascending")
    elif (n.states and accessSortDescending) != AccessStates(0):
      str("descending")
  of uiaIsDataValidProperty:
    v[] = boolVariant((n.states and accessInvalid) ==
      AccessStates(0))
  of uiaIsPasswordProperty:
    v[] = boolVariant((n.states and accessPassword) !=
      AccessStates(0))
  of uiaFrameworkIDProperty:
    str("mynim")
  of uiaIsDialogProperty:
    v[] = boolVariant(n.role == roleDialog or
      n.role == roleAlertDialog)
  of uiaIsOffscreenProperty:
    v[] = boolVariant((n.states and accessOffscreen) !=
      AccessStates(0))
  of uiaOrientationProperty:
    ## OrientationType_Horizontal or Vertical, of a slider.
    if n.role == roleSlider:
      var o = 1'u64
      if (n.states and accessVertical) != AccessStates(0):
        o = 2
      v[] = variant(vt: vtI4, val: o)
  of uiaHeadingLevelProperty:
    ## HeadingLevel1 to HeadingLevel9, as Chromium's headings.
    if n.role == roleHeading and n.level > 0:
      v[] = variant(vt: vtI4,
        val: uint64(80050 + min(n.level, 9)))
  of uiaLevelProperty:
    if n.level > 0 and n.role != roleHeading:
      v[] = variant(vt: vtI4, val: uint64(n.level))
  of uiaPositionInSetProperty:
    if n.posInSet > 0:
      v[] = variant(vt: vtI4, val: uint64(n.posInSet))
  of uiaSizeOfSetProperty:
    if n.setSize > 0:
      v[] = variant(vt: vtI4, val: uint64(n.setSize))
  of uiaLiveSettingProperty:
    ## Statuses, as toasts, and announcements are polite live
    ## regions.
    if n.role == roleStatus or n.id == announcerID:
      ## Polite
      v[] = variant(vt: vtI4, val: 1)
  else:
    discard

## chosen returns the elements chosen in the element's Selection.
proc chosen*(e: uiaElement): seq[uiaElement] =
  for d in e.tree.order:
    if (d.n.states and accessChecked) != AccessStates(0) and
        d.supports(ifaceSelectionItem) and d.container() == e:
      result.add(d)

## container returns the element whose Selection holds the
## element's, the list or table around it choosing it.
proc container*(e: uiaElement): uiaElement =
  var p = e.parent
  while not p.isNil and not p.root:
    if p.supports(ifaceSelection):
      return p
    p = p.parent
  nil

## The methods of IRawElementProviderSimple.
const
  uiaGetProviderOptions* = 3
  uiaGetPatternProvider* = 4
  uiaGetPropertyValue* = 5
  uiaGetHostRawElementProvider* = 6

## page returns the web view whose page the element stands for, if
## any.
proc page*(e: uiaElement): w32Window =
  let v = e.n.webView
  if v.isNil or not (cast[ref RootObj](v) of w32Window):
    return nil
  let w = cast[w32Window](v)
  if w.closed or w.comp == 0 or w.host.isNil or
      w.host.surface != e.tree.s:
    return nil
  w

## pageCall calls a method of WebView2's provider of the page the
## element stands for, and reports whether it is one's.
proc pageCall*(e: uiaElement, `method`: int,
    args: varargs[uint]): tuple[r: uint, ok: bool] =
  let v = e.page()
  if v.isNil or e.dead:
    return (0'u, false)
  let p = v.automationProvider()
  if p == 0:
    return (0'u, false)
  let simple = queryInterface(p, addr uiaIIDs[ifaceSimple])
  if simple == 0:
    return (0'u, false)
  defer: release(simple)
  var r = 0'u
  case args.len
  of 0: r = comCall(simple, `method`)
  of 1: r = comCall(simple, `method`, args[0])
  of 2: r = comCall(simple, `method`, args[0], args[1])
  else: discard
  (r, true)

## pageOfWindow returns the node of the page that WebView2 shows
## with the window hwnd, a child of the surface's, if one does.
proc pageOfWindow*(t: uiaTree, hwnd: uint): uiaElement =
  let env4 = queryInterface(t.s.w.b.env,
    addr iidICoreWebView2Environment4)
  if env4 == 0:
    return nil
  defer: release(env4)
  var p: uint
  if failed(comCall(env4, env4GetAutomationProviderForWindow, hwnd,
      cast[uint](addr p))) or p == 0:
    return nil
  defer: release(p)
  let want = queryInterface(p, addr iidIUnknown)
  defer: release(want)
  for e in t.order:
    let v = e.page()
    if not v.isNil:
      let q = v.automationProvider()
      if q != 0:
        let got = queryInterface(q, addr iidIUnknown)
        release(got)
        if got == want:
          return e
  nil
