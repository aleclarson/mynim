## platform/access.go — the content of a surface for assistive technology.

type
  AccessRole* = enum
    roleGroup
    roleText
    roleButton
    roleLink
    roleCheckBox
    roleRadio
    roleSwitch
    roleSlider
    roleProgress
    roleTextField
    roleImage
    roleList
    roleScroll
    roleDialog
    rolePopup
    roleTooltip
    rolePopUpButton
    roleTabList
    roleTab
    roleSplitter
    roleStatus
    roleTable
    roleRow
    roleCell
    roleColumnHeader
    roleTree
    roleTreeItem
    roleListItem
    roleMenuButton
    roleToolbar
    roleRadioGroup
    ## roleToggleButton is pressed while accessChecked.
    roleToggleButton
    ## roleComboBox is a text field with a popup of options.
    roleComboBox
    ## roleDisclosure is a button showing or hiding content below it.
    roleDisclosure
    roleMeter
    roleStepper
    roleColorWell
    roleAlertDialog
    roleMenu
    roleMenuBar
    roleMenuItem
    roleMenuItemCheckBox
    roleMenuItemRadio
    roleHeading

  AccessStates* = distinct uint32
    ## The states of an element of an AccessTree.

  AccessActions* = distinct uint8
    ## The actions an element of an AccessTree takes.

  AccessActionKind* = enum
    ## The action of an accessAction event.
    accessPress
    accessFocus
    accessIncrement
    accessDecrement
    accessSetValue
    accessScrollIntoView
    accessExpand
    accessCollapse
    ## accessSelectText selects runes from..to of a text field's value.
    accessSelectText

  AccessTextRun* = object
    ## A run of the value of a text field with formats of its own.
    start*, `end`*: int
    family*: string
    size*: float32
    weight*: int
    italic*, underline*, strikethrough*: bool
    color*, background*: array[4, uint8]
    link*: string
    heading*: int

  AccessNode* = object
    ## An element of an AccessTree.
    id*: uint64 ## identifies the element from frame to frame
    ## parent is the index of the parent node in AccessTree.nodes, -1 for
    ## the elements at the top.
    parent*: int
    role*: AccessRole
    ## label names the element; value is its value.
    label*, value*: string
    ## bounds is the element's visible box, in DIPs relative to the surface.
    bounds*: RectF
    states*: AccessStates
    ## min, max and now are the range and the value of a slider or a
    ## progress bar; now is below min for progress of unknown length.
    min*, max*, now*, step*: float64
    ## selStart and selEnd are the selection of a text field, in runes.
    selStart*, selEnd*: int
    placeholder*: string
    description*: string
    level*: int
    posInSet*, setSize*: int
    actions*: AccessActions
    ## webView is the web view whose page the node stands for, if any.
    webView*: WebView
    ## textRuns are the formats of the runes of a text field's value.
    textRuns*: seq[AccessTextRun]

  AccessTree* = object
    ## The elements a user can perceive and act on.
    ## nodes are the elements in tree order: a parent before its children.
    nodes*: seq[AccessNode]
    ## focus is the ID of the element with the keyboard focus, 0 for none.
    focus*: uint64
    ## announcements are texts for assistive technology to read out once.
    announcements*: seq[string]

proc ranged*(r: AccessRole): bool =
  ## Whether nodes of a role have a value in a range.
  r in {roleSlider, roleProgress, roleMeter, roleStepper}

const
  accessFocusable* = AccessStates(1)
  accessDisabled* = AccessStates(2)
  accessChecked* = AccessStates(4)
  accessMixed* = AccessStates(8)
  accessSelected* = AccessStates(16)
  accessExpanded* = AccessStates(32)
  accessMultiline* = AccessStates(64)
  accessPassword* = AccessStates(128)
  accessReadOnly* = AccessStates(256)
  accessSelectable* = AccessStates(512)
  accessOffscreen* = AccessStates(1024)
  accessMultiselectable* = AccessStates(2048)
  accessSegment* = AccessStates(4096)
  accessSearch* = AccessStates(8192)
  accessInvalid* = AccessStates(16384)
  accessSortAscending* = AccessStates(32768)
  accessSortDescending* = AccessStates(65536)
  accessExpandable* = AccessStates(131072)
  accessVertical* = AccessStates(262144)

proc `or`*(a, b: AccessStates): AccessStates {.borrow.}
proc `and`*(a, b: AccessStates): AccessStates {.borrow.}
proc `==`*(a, b: AccessStates): bool {.borrow.}
proc `+`*(a, b: AccessStates): AccessStates {.borrow.}

const
  actionPress* = AccessActions(1)
  actionFocus* = AccessActions(2)
  actionIncrement* = AccessActions(4)
  actionDecrement* = AccessActions(8)
  actionSetValue* = AccessActions(16)
  actionScrollIntoView* = AccessActions(32)
  actionExpand* = AccessActions(64)

proc `or`*(a, b: AccessActions): AccessActions {.borrow.}
proc `and`*(a, b: AccessActions): AccessActions {.borrow.}
proc `==`*(a, b: AccessActions): bool {.borrow.}
proc `+`*(a, b: AccessActions): AccessActions {.borrow.}
