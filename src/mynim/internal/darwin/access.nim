## access.go: VoiceOver and other assistive technology see the content
## of a surface as NSAccessibilityElements, one per node of the
## content's accessibility tree, which the surface view contains.
## Elements are kept from update to update by node ID, so that
## VoiceOver's cursor stays on them, and only what changed is set
## again. Lists are tables of rows, as AppKit's own lists.

var
  accessLoaded = false
  ## NSAccessibilityPostNotification and
  ## NSAccessibilityPostNotificationWithUserInfo.
  postAccessNote: proc(obj, name: id) {.cdecl.}
  postAccessInfo: proc(app, name, info: id) {.cdecl.}
  ## NSAccessibilityActionDescription.
  actionDescription: proc(action: id): id {.cdecl.}

proc loadAccess() =
  if accessLoaded:
    return
  accessLoaded = true
  postAccessNote = cast[typeof postAccessNote](
    mustDlsym(libAppKitH, "NSAccessibilityPostNotification"))
  postAccessInfo = cast[typeof postAccessInfo](
    mustDlsym(libAppKitH,
              "NSAccessibilityPostNotificationWithUserInfo"))
  actionDescription = cast[typeof actionDescription](
    mustDlsym(libAppKitH, "NSAccessibilityActionDescription"))

## postNote posts an accessibility notification about obj.
proc postNote(obj: id, name: string) =
  if not obj.isNil:
    postAccessNote(obj, nsString(name))

## announce asks VoiceOver to read text out, after what it is reading
## (NSAccessibilityAnnouncementRequestedNotification).
proc announce(app: id, text: string) =
  let info = send(`class`("NSMutableDictionary"), "dictionary")
  discard send(info, "setObject:forKey:", argu(nsString(text)),
               argu(nsString("AXAnnouncementKey")))
  discard send(info, "setObject:forKey:", argu(nsNumberInt(50)),
               argu(nsString("AXPriorityKey")))
  ## NSAccessibilityPriorityMedium
  postAccessInfo(app, nsString("AXAnnouncementRequested"), info)

## accessRoles are the roles and subroles of node roles.
const accessRoles: array[AccessRole, tuple[role, subrole: string]] = [
  ("AXGroup", ""),           ## roleGroup
  ("AXStaticText", ""),      ## roleText
  ("AXButton", ""),          ## roleButton
  ("AXLink", ""),            ## roleLink
  ("AXCheckBox", ""),        ## roleCheckBox
  ("AXRadioButton", ""),     ## roleRadio
  ("AXCheckBox", "AXSwitch"),## roleSwitch
  ("AXSlider", ""),          ## roleSlider
  ("AXProgressIndicator", ""),## roleProgress
  ("AXTextField", ""),       ## roleTextField
  ("AXImage", ""),           ## roleImage
  ("AXTable", ""),           ## roleList
  ("AXScrollArea", ""),      ## roleScroll
  ("AXGroup", "AXDialog"),   ## roleDialog
  ("AXPopover", ""),         ## rolePopup
  ("AXHelpTag", ""),         ## roleTooltip
  ("AXPopUpButton", ""),     ## rolePopUpButton
  ("AXTabGroup", ""),        ## roleTabList
  ("AXRadioButton", "AXTabButton"), ## roleTab
  ("AXSplitter", ""),        ## roleSplitter
  ("AXGroup", "AXApplicationStatus"), ## roleStatus
  ("AXTable", ""),           ## roleTable
  ("AXRow", "AXTableRow"),   ## roleRow
  ("AXCell", ""),            ## roleCell
  ("AXCell", ""),            ## roleColumnHeader
  ("AXOutline", ""),         ## roleTree
  ("AXRow", "AXOutlineRow"), ## roleTreeItem
  ("AXRow", "AXTableRow"),   ## roleListItem
  ("AXMenuButton", ""),      ## roleMenuButton
  ("AXToolbar", ""),         ## roleToolbar
  ("AXRadioGroup", ""),      ## roleRadioGroup
  ("AXCheckBox", "AXToggle"),## roleToggleButton
  ("AXComboBox", ""),        ## roleComboBox
  ("AXDisclosureTriangle", ""),## roleDisclosure
  ("AXLevelIndicator", ""),  ## roleMeter
  ("AXIncrementor", ""),     ## roleStepper
  ("AXColorWell", ""),       ## roleColorWell
  ("AXGroup", "AXApplicationAlertDialog"), ## roleAlertDialog
  ("AXMenu", ""),            ## roleMenu
  ("AXMenuBar", ""),         ## roleMenuBar
  ## AppKit's items show a choice with a mark (AXMenuItemMarkChar).
  ("AXMenuItem", ""),        ## roleMenuItem
  ("AXMenuItem", ""),        ## roleMenuItemCheckBox
  ("AXMenuItem", ""),        ## roleMenuItemRadio
  ## WebKit's headings, whose value is their level.
  ("AXHeading", ""),         ## roleHeading
]

## menuItem reports whether nodes of a role are items of a menu.
proc menuItem(r: AccessRole): bool =
  r in {roleMenuItem, roleMenuItemCheckBox, roleMenuItemRadio}

## markChar returns the mark an item of a menu shows for its choice, as
## AppKit's: a check mark when on, a dash when mixed, none otherwise.
proc markChar(n: AccessNode): string =
  if not menuItem(n.role):
    return ""
  if (n.states and accessMixed) != 0.AccessStates:
    return "-"
  if (n.states and accessChecked) != 0.AccessStates:
    return "✓"
  ""

## chooses reports whether a node is the row of a list, a table or an
## outline that its list chooses.
proc chooses(n: AccessNode): bool =
  (n.role in {roleListItem, roleRow, roleTreeItem}) and
    (n.states and accessSelectable) != 0.AccessStates

proc roleOf(n: AccessNode): tuple[role, subrole: string] =
  let r = accessRoles[n.role]
  result = r
  if (n.states and accessSegment) != 0.AccessStates:
    result.subrole = "AXSegment" ## as NSSegmentedControl's
  if n.role == roleTextField:
    if (n.states and accessSearch) != 0.AccessStates:
      result.subrole = "AXSearchField"
    elif (n.states and accessPassword) != 0.AccessStates:
      result.subrole = "AXSecureTextField"
    elif (n.states and accessMultiline) != 0.AccessStates:
      result.role = "AXTextArea"

## titled reports whether elements of a role show their name as a
## title.
proc titled(r: AccessRole): bool =
  r in {roleButton, roleLink, roleCheckBox, roleRadio, roleSwitch,
        rolePopUpButton, roleTab, roleMenuButton, roleToggleButton,
        roleMenuItem, roleMenuItemCheckBox, roleMenuItemRadio}

## textual reports whether elements of a role edit text: text fields
## and combo boxes.
proc textual(r: AccessRole): bool =
  r in {roleTextField, roleComboBox}

## toggle reports whether elements of a role have their state as their
## value.
proc toggle(r: AccessRole): bool =
  r in {roleCheckBox, roleRadio, roleSwitch, roleTab, roleToggleButton}

## units is the UTF-16 length of a rune sequence's string.
proc units(s: string): int =
  for c in s.runes:
    result += (if ord(c) >= 0x10000: 2 else: 1)

## runeSub is s from rune a to rune b, for UTF-16 counts.
proc runeSub(s: string, a, b: int): string =
  var i = 0
  for c in s.runes:
    if i >= b:
      break
    if i >= a:
      result.add $c
    inc i

## runeAt16 is the rune index of UTF-16 unit i of s.
proc runeAt16(s: string, i: int): int =
  var u = 0
  for c in s.runes:
    if u >= i:
      break
    u += (if ord(c) >= 0x10000: 2 else: 1)
    inc result

## valueOf returns the value of a node as AppKit wants it: a number for
## toggles, disclosures and ranges, a string for texts.
proc valueOf(n: AccessNode): id =
  if n.role == roleDisclosure:
    ## 1 while open, as AppKit's disclosure triangles.
    return nsNumberInt(
      int(n.states and accessExpanded) div int(accessExpanded))
  if toggle(n.role):
    var v = 0
    if (n.states and accessMixed) != 0.AccessStates:
      v = 2
    elif (n.states and accessChecked) != 0.AccessStates:
      v = 1
    return nsNumberInt(v)
  if n.role.ranged:
    if n.now < n.min:
      return nil ## a progress of unknown length
    return msgFloatID(`class`("NSNumber"), sel("numberWithDouble:"),
                      n.now)
  if n.role == roleText:
    return nsString(n.label)
  if n.role == roleHeading and n.level > 0:
    return nsNumberInt(n.level)
  if n.value != "" or textual(n.role):
    return nsString(n.value)
  nil

## apply sets the properties of a node that changed, all of them for a
## new element, and reports whether its value changed.
proc apply(el: accessElement, n: AccessNode, fresh: bool): bool =
  let o = el.node
  el.node = n
  let obj = el.obj
  let (r, sr) = roleOf(n)
  let (ro, sro) = roleOf(o)
  if fresh or r != ro or sr != sro:
    discard send(obj, "setAccessibilityRole:", argu(nsString(r)))
    var sub: id
    if sr != "":
      sub = nsString(sr)
    discard send(obj, "setAccessibilitySubrole:", argu(sub))
  if fresh or n.label != o.label or n.role != o.role:
    ## Controls show their name, which AppKit's own give as their
    ## title; other elements are described by it.
    if titled(n.role):
      discard send(obj, "setAccessibilityTitle:", argu(nsString(n.label)))
      discard send(obj, "setAccessibilityLabel:", argu(0))
    else:
      discard send(obj, "setAccessibilityTitle:", argu(0))
      discard send(obj, "setAccessibilityLabel:",
                   argu(nsString(n.label)))
  if fresh or (n.states and accessDisabled) != (o.states and accessDisabled):
    discard send(obj, "setAccessibilityEnabled:",
                 argu((n.states and accessDisabled) == 0.AccessStates))
  if fresh or (n.states and accessExpanded) != (o.states and accessExpanded):
    discard send(obj, "setAccessibilityExpanded:",
                 argu((n.states and accessExpanded) != 0.AccessStates))
  if n.role == roleSlider and
      (fresh or (n.states and accessVertical) != (o.states and accessVertical)):
    ## NSAccessibilityOrientationVertical or Horizontal.
    let orient = (if (n.states and accessVertical) != 0.AccessStates: 1
                  else: 2)
    discard send(obj, "setAccessibilityOrientation:", argu(orient))
  if n.role.ranged:
    if fresh or n.min != o.min or n.max != o.max:
      discard send(obj, "setAccessibilityMinValue:",
        argu(msgFloatID(`class`("NSNumber"), sel("numberWithDouble:"),
                        n.min)))
      discard send(obj, "setAccessibilityMaxValue:",
        argu(msgFloatID(`class`("NSNumber"), sel("numberWithDouble:"),
                        n.max)))
  ## The state of a toggle is its value; a row's choice is not, which
  ## its table tells (AXSelectedRowsChanged).
  let checkMask = accessChecked or accessMixed
  let toggled = (toggle(n.role) and
      (n.states and checkMask) != (o.states and checkMask)) or
    (n.role == roleDisclosure and
      (n.states and accessExpanded) != (o.states and accessExpanded))
  if fresh or n.value != o.value or n.now != o.now or toggled or
      (n.role == roleText and n.label != o.label) or
      (n.role == roleHeading and n.level != o.level):
    discard send(obj, "setAccessibilityValue:", argu(valueOf(n)))
    result = not fresh
  if n.level > 0 and n.role != roleHeading and
      (fresh or n.level != o.level):
    ## How deep the row of an outline is, from 0.
    discard send(obj, "setAccessibilityDisclosureLevel:",
                 argu(n.level - 1))
  if n.role == roleTreeItem and
      (fresh or (n.states and accessExpanded) != (o.states and accessExpanded)):
    discard send(obj, "setAccessibilityDisclosed:",
                 argu((n.states and accessExpanded) != 0.AccessStates))
  if n.posInSet > 0 and (fresh or n.posInSet != o.posInSet):
    discard send(obj, "setAccessibilityIndex:", argu(n.posInSet - 1))
  if chooses(n) and (fresh or not chooses(o) or
      (n.states and accessChecked) != (o.states and accessChecked)):
    discard send(obj, "setAccessibilitySelected:",
                 argu((n.states and accessChecked) != 0.AccessStates))
  if fresh or n.placeholder != o.placeholder:
    var p: id
    if n.placeholder != "":
      p = nsString(n.placeholder)
    discard send(obj, "setAccessibilityPlaceholderValue:", argu(p))
  if n.role == roleColumnHeader and
      (fresh or (n.states and (accessSortAscending or accessSortDescending)) !=
        (o.states and (accessSortAscending or accessSortDescending))):
    ## NSAccessibilitySortDirection.
    var dir = 0
    if (n.states and accessSortAscending) != 0.AccessStates:
      dir = 1
    elif (n.states and accessSortDescending) != 0.AccessStates:
      dir = 2
    discard send(obj, "setAccessibilitySortDirection:", argu(dir))
  if fresh or n.description != o.description:
    ## AppKit's help, which it gives tooltips as.
    var d: id
    if n.description != "":
      d = nsString(n.description)
    discard send(obj, "setAccessibilityHelp:", argu(d))
  if textual(n.role) and (fresh or n.value != o.value or
      n.selStart != o.selStart or n.selEnd != o.selEnd):
    let text = n.value
    let a = max(0, min(n.selStart, text.runeLen))
    let b = max(0, min(n.selEnd, text.runeLen))
    discard send(obj, "setAccessibilityNumberOfCharacters:",
                 argu(units(text)))
    discard send(obj, "setAccessibilitySelectedTextRange:",
                 argu(units(text.runeSub(0, a))),
                 argu(units(text.runeSub(a, max(a, b)))))

## send sends a surface event to the window's handler.
proc send*(s: macSurface, ev: SurfaceEvent): bool =
  if s.w.closed:
    return false
  s.w.h.surfaceEvent(ev)

## surfaceOf returns the live surface of a view.
proc surfaceOf*(b: Backend, view: id): macSurface =
  let s = b.bySurface.getOrDefault(view)
  if s == nil or s.w.closed:
    return nil
  s

## accessRequested starts the content describing its frames, the first
## time AppKit asks about the surface.
proc accessRequested*(s: macSurface) =
  if not s.accessOn:
    s.accessOn = true
    discard s.send(SurfaceEvent(kind: accessibilityOn))

## updateAccessibility keeps the elements of a surface's accessibility
## tree matching it.
method updateAccessibility*(s: macSurface, tree: AccessTree) =
  if s.w.closed:
    return
  loadAccess()
  withPool(proc() =
    s.updating = true
    defer: s.updating = false
    if s.elements.len == 0:
      s.elements = initTable[uint64, accessElement]()
    var changed = false
    var objs = newSeq[id](tree.nodes.len)
    var valueChanged: seq[id]
    var fresh = initTable[uint64, bool]()
    for i, n in tree.nodes:
      var el = s.elements.getOrDefault(n.id)
      if el == nil:
        fresh[n.id] = true
        el = accessElement(
          obj: send(send(`class`("MyNimAccessibilityElement"), "alloc"),
                    "init"),
          s: s)
        s.elements[n.id] = el
        s.w.b.byAccess[el.obj] = el
        discard el.apply(n, true)
        changed = true
      elif el.apply(n, false):
        valueChanged.add el.obj
      objs[i] = el.obj
    var children = newSeq[seq[uint64]](tree.nodes.len)
    var childObjs = newSeq[seq[id]](tree.nodes.len)
    var top: seq[id]
    for i, n in tree.nodes:
      if n.parent < 0 or n.parent >= tree.nodes.len:
        top.add objs[i]
        continue
      children[n.parent].add n.id
      childObjs[n.parent].add objs[i]
    var grafted = initHashSet[pointer]()
    for i, n in tree.nodes:
      let el = s.elements[n.id]
      var parent = s.view
      if n.parent >= 0 and n.parent < tree.nodes.len:
        parent = objs[n.parent]
      if el.parent != parent:
        el.parent = parent
        discard send(el.obj, "setAccessibilityParent:", argu(parent))
      ## The page of a web view is inside the element showing it.
      var web: macWindow = nil
      if not n.webView.isNil and
          cast[ref RootObj](n.webView) of macWindow:
        let v = cast[macWindow](n.webView)
        if v.host == s.w and not v.closed and
            not grafted.contains(cast[pointer](v)):
          web = v
          grafted.incl(cast[pointer](v))
          v.accessParent = el.obj
      if el.children != children[i] or el.webView != web:
        el.children = children[i]
        el.webView = web
        var kids = childObjs[i]
        if web != nil:
          kids = @[web.web] & kids
        discard send(el.obj, "setAccessibilityChildren:",
                     argu(nsArray(kids)))
        changed = true
    for v in s.w.webViews:
      if not grafted.contains(cast[pointer](v)):
        v.accessParent = nil
    ## Lists and tables: their rows, those that show, those chosen,
    ## and how many they have, built or not.
    var selectionChanged: seq[accessElement]
    for i, n in tree.nodes:
      if n.role notin {roleList, roleTable, roleTree}:
        continue
      let el = s.elements[n.id]
      var rows, shown, chosen: seq[id]
      var chosenIDs: seq[uint64]
      for cid in children[i]:
        let c = s.elements.getOrDefault(cid)
        if c == nil:
          continue
        if c.node.role notin {roleRow, roleListItem, roleTreeItem} or
            (n.setSize > 0 and c.node.posInSet == 0):
          continue ## a table's header
        if c.node.posInSet == 0:
          discard send(c.obj, "setAccessibilityIndex:", argu(rows.len))
        rows.add c.obj
        if (c.node.states and accessOffscreen) == 0.AccessStates:
          shown.add c.obj
        if chooses(c.node) and
            (c.node.states and accessChecked) != 0.AccessStates:
          chosen.add c.obj
          chosenIDs.add cid
      var count = n.setSize
      if count == 0:
        count = rows.len
      if count != el.count:
        el.count = count
        discard send(el.obj, "setAccessibilityRowCount:", argu(count))
      discard send(el.obj, "setAccessibilityRows:", argu(nsArray(rows)))
      discard send(el.obj, "setAccessibilityVisibleRows:",
                   argu(nsArray(shown)))
      discard send(el.obj, "setAccessibilitySelectedRows:",
                   argu(nsArray(chosen)))
      if el.chosen != chosenIDs:
        el.chosen = chosenIDs
        if not fresh.getOrDefault(n.id):
          ## a new list's choice did not change
          selectionChanged.add el
    release(s.topLevel)
    s.topLevel = retain(nsArray(top))
    var live = initTable[uint64, bool]()
    for n in tree.nodes:
      live[n.id] = true
    var dead: seq[uint64]
    for nid, el in s.elements:
      if not live.hasKey(nid):
        postNote(el.obj, "AXUIElementDestroyed")
        s.w.b.byAccess.del(el.obj)
        release(el.obj)
        dead.add nid
        changed = true
    for nid in dead:
      s.elements.del(nid)
    if changed:
      postNote(s.view, "AXLayoutChanged")
    for obj in valueChanged:
      postNote(obj, "AXValueChanged")
    for el in selectionChanged:
      postNote(el.obj, "AXSelectedRowsChanged")
    if tree.focus != s.access.focus:
      let el = s.elements.getOrDefault(tree.focus)
      if el != nil:
        postNote(el.obj, "AXFocusedUIElementChanged")
    for text in tree.announcements:
      announce(s.w.b.app, text)
    s.access = tree
    s.access.announcements = @[])

## destroyAccess releases the elements of a surface.
proc destroyAccess*(s: macSurface) =
  for v in s.w.webViews:
    v.accessParent = nil
  for nid, el in s.elements:
    postNote(el.obj, "AXUIElementDestroyed")
    s.w.b.byAccess.del(el.obj)
    release(el.obj)
  s.elements.clear()
  release(s.topLevel)
  s.topLevel = nil

## accessAt returns the innermost element at a point of the view.
proc accessAt*(s: macSurface, x, y: float64): id =
  for n in s.access.nodes:
    let b = n.bounds
    if x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h:
      let el = s.elements.getOrDefault(n.id)
      if el != nil:
        result = el.obj ## later nodes are deeper or above

## screenRect converts a rectangle of the view to the screen.
proc screenRect*(s: macSurface, b: RectF): NSRect =
  let inWindow = msgConvertRectView(s.view, sel("convertRect:toView:"),
    NSRect(origin: NSPoint(x: b.x, y: b.y),
           size: NSSize(width: b.w, height: b.h)), nil)
  msgRectToRect(s.w.win, sel("convertRectToScreen:"), inWindow)

proc accessElementOf*(b: Backend, obj: id): accessElement =
  let el = b.byAccess.getOrDefault(obj)
  if el == nil or el.s.w.closed:
    return nil
  el

## act sends an action of assistive technology to the content.
proc act(el: accessElement, a: AccessActionKind, text: string): bool =
  if el.s.updating:
    return false
  discard el.s.send(SurfaceEvent(kind: accessAction, id: el.node.id,
                                 action: a, text: text))
  true

## legacyActions are the actions of nodes by their names in AppKit's
## older API: AXScrollToVisible is NSAccessibilityScrollToVisibleAction,
## which AppKit exports only since macOS 26.
const legacyActions: seq[tuple[name: string, action: AccessActions,
                               kind: AccessActionKind]] = @[
  ("AXPress", actionPress, accessPress),
  ("AXIncrement", actionIncrement, accessIncrement),
  ("AXDecrement", actionDecrement, accessDecrement),
  ("AXScrollToVisible", actionScrollIntoView, accessScrollIntoView),
]

proc registerAccessClass*() =
  let allowed = {
    "accessibilityPerformPress": actionPress,
    "accessibilityPerformIncrement": actionIncrement,
    "accessibilityPerformDecrement": actionDecrement,
    "setAccessibilityValue:": actionSetValue,
    "setAccessibilityFocused:": actionFocus,
    "setAccessibilityDisclosed:": actionExpand,
  }.toTable
  discard classDef("MyNimAccessibilityElement", "NSAccessibilityElement",
    @[], @[
    methodDef("accessibilityFrame",
      cast[pointer](proc(self: id, cmd: SEL): NSRect {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil:
          return el.s.screenRect(el.node.bounds)
        default(NSRect)), "{CGRect={CGPoint=dd}{CGSize=dd}}@:"),
    methodDef("isAccessibilityFocused",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        el != nil and el.s.access.focus == el.node.id), "B@:"),
    methodDef("accessibilityAttributeNames",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
        var names = sendSuper(self, "MyNimAccessibilityElement", cmd)
        let el = theBackend.accessElementOf(self)
        if el == nil:
          return names
        if (el.node.states and accessInvalid) != 0.AccessStates:
          names = send(names, "arrayByAddingObject:",
                       argu(nsString("AXInvalid")))
        if menuItem(el.node.role):
          names = send(names, "arrayByAddingObject:",
                       argu(nsString("AXMenuItemMarkChar")))
        names), "@@:"),
    methodDef("accessibilityAttributeValue:",
      cast[pointer](proc(self: id, cmd: SEL, attr: id): id {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil:
          case goString(attr)
          of "AXInvalid":
            if (el.node.states and accessInvalid) != 0.AccessStates:
              return nsString("true")
          of "AXMenuItemMarkChar":
            let m = markChar(el.node)
            if m != "":
              return nsString(m)
            if menuItem(el.node.role):
              return nil
          else:
            discard
        sendSuper(self, "MyNimAccessibilityElement", cmd, argu(attr))), "@@:@"),
  methodDef("accessibilityIsAttributeSettable:",
      cast[pointer](proc(self: id, cmd: SEL, attr: id): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el == nil:
          return false
        case goString(attr)
        of "AXValue":
          return not textual(el.node.role) or
            (el.node.actions and actionSetValue) != 0.AccessActions
        of "AXFocused":
          return true
        of "AXDisclosing":
          return el.node.role == roleTreeItem
        else:
          return false), "B@:@"),
    methodDef("isAccessibilitySelectorAllowed:",
      cast[pointer](proc(self: id, cmd: SEL, selector: SEL): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil:
          for name, action in allowed:
            if sel(name) == selector:
              return (el.node.actions and action) != 0.AccessActions
        sendSuper(self, "MyNimAccessibilityElement", cmd,
                  argu(selector)) != nil), "B@::"),
  methodDef("accessibilityActionNames",
      cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
        var names: seq[id]
        let el = theBackend.accessElementOf(self)
        if el != nil:
          for a in legacyActions:
            if (el.node.actions and a.action) != 0.AccessActions:
              names.add nsString(a.name)
        nsArray(names)), "@@:"),
    methodDef("accessibilityActionDescription:",
      cast[pointer](proc(self: id, cmd: SEL, action: id): id {.cdecl.} =
        actionDescription(action)), "@@:@"),
    methodDef("accessibilityPerformAction:",
      cast[pointer](proc(self: id, cmd: SEL, action: id) {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el == nil:
          return
        let name = goString(action)
        for a in legacyActions:
          if a.name == name and
              (el.node.actions and a.action) != 0.AccessActions:
            discard el.act(a.kind, "")), "v@:@"),
    methodDef("accessibilityPerformPress",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        el != nil and el.act(accessPress, "")), "B@:"),
    methodDef("accessibilityPerformIncrement",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        el != nil and el.act(accessIncrement, "")), "B@:"),
    methodDef("accessibilityPerformDecrement",
      cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        el != nil and el.act(accessDecrement, "")), "B@:"),
  methodDef("setAccessibilityDisclosed:",
      cast[pointer](proc(self: id, cmd: SEL, open: bool) {.cdecl.} =
        discard sendSuper(self, "MyNimAccessibilityElement", cmd,
                          argu(open))
        let el = theBackend.accessElementOf(self)
        if el != nil and
            (el.node.actions and actionExpand) != 0.AccessActions:
          let kind = (if open: accessExpand else: accessCollapse)
          discard el.act(kind, "")), "v@:B"),
    methodDef("setAccessibilityFocused:",
      cast[pointer](proc(self: id, cmd: SEL, focused: bool) {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil and focused:
          discard el.act(accessFocus, "")), "v@:B"),
    methodDef("setAccessibilityValue:",
      cast[pointer](proc(self: id, cmd: SEL, value: id) {.cdecl.} =
        discard sendSuper(self, "MyNimAccessibilityElement", cmd,
                          argu(value))
        let el = theBackend.accessElementOf(self)
        if el != nil and textual(el.node.role):
          discard el.act(accessSetValue, goString(value))), "v@:@"),
  methodDef("setAccessibilitySelectedTextRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange) {.cdecl.} =
        discard sendSuper(self, "MyNimAccessibilityElement", cmd,
                          argu(r.location), argu(r.length))
        let el = theBackend.accessElementOf(self)
        if el == nil or not textual(el.node.role) or el.s.updating:
          return
        let text = el.node.value
        let total = units(text)
        let lo = min(r.location.int, total)
        let hi = min(lo + r.length.int, total)
        let start = runeAt16(text, lo)
        let `end` = runeAt16(text, hi)
        discard el.s.send(SurfaceEvent(kind: accessAction,
          id: el.node.id, action: accessSelectText, `from`: start,
          to: `end`))), "v@:{_NSRange=QQ}"),
  methodDef("accessibilityStringForRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange): id {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el == nil:
          return nil
        let text = el.node.value
        let total = units(text)
        let lo = min(r.location.int, total)
        let hi = min(lo + r.length.int, total)
        nsString(utf16Slice(text, lo, hi))), "@@:{_NSRange=QQ}"),
  methodDef("accessibilityAttributedStringForRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange): id {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el == nil:
          return nil
        attributedAccessString(el.node, r)), "@@:{_NSRange=QQ}"),
    methodDef("accessibilityLineForIndex:",
      cast[pointer](proc(self: id, cmd: SEL, i: int): int {.cdecl.} = 0), "q@:q"),
    methodDef("accessibilityRangeForLine:",
      cast[pointer](proc(self: id, cmd: SEL, line: int): nsRange {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil:
          return nsRange(length: units(el.node.value).uint)
        default(nsRange)), "{_NSRange=QQ}@:q"),
    methodDef("accessibilityFrameForRange:",
      cast[pointer](proc(self: id, cmd: SEL, r: nsRange): NSRect {.cdecl.} =
        let el = theBackend.accessElementOf(self)
        if el != nil:
          return el.s.screenRect(el.node.bounds)
        default(NSRect)), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}"),
  ])

## accessViewMethods are the methods of the surface view that make it
## the container of the elements.
proc accessViewMethods*(): seq[MethodDef] =
  @[
  methodDef("isAccessibilityElement",
    cast[pointer](proc(self: id, cmd: SEL): bool {.cdecl.} = false), "B@:"),
  methodDef("accessibilityChildren",
    cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
      let s = theBackend.surfaceOf(self)
      if s == nil:
        return nil
      s.accessRequested()
      if s.topLevel.isNil:
        return nsArray()
      s.topLevel), "@@:"),
  methodDef("accessibilityHitTest:",
    cast[pointer](proc(self: id, cmd: SEL, p: NSPoint): id {.cdecl.} =
      let s = theBackend.surfaceOf(self)
      if s == nil:
        return self
      loadAccess()
      s.accessRequested()
      let inWindow = msgPointToPoint(s.w.win,
        sel("convertPointFromScreen:"), p)
      let v = msgPointFromView(self, sel("convertPoint:fromView:"),
                               inWindow, nil)
      let obj = s.accessAt(v.x, v.y)
      if not obj.isNil:
        return obj
      self), "@@:{CGPoint=dd}"),
  methodDef("accessibilityFocusedUIElement",
    cast[pointer](proc(self: id, cmd: SEL): id {.cdecl.} =
      let s = theBackend.surfaceOf(self)
      if s == nil:
        return self
      s.accessRequested()
      let el = s.elements.getOrDefault(s.access.focus)
      if el != nil:
        return el.obj
      self), "@@:"),
  ]
