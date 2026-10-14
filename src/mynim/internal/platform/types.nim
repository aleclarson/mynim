## Value types of the platform contract (platform/platform.go).

import std/[locks, tables, streams, times]
import ../../transfer
import ../../image
import ../ctx

## dragSessionFormat carries an unguessable, process-local registry key.
const dragSessionFormat* = "application/x-mygo-drag-session"

export ctx.CancelCtx, ctx.newCtx, ctx.cancel, ctx.done,
       ctx.err, ctx.waitDone, ctx.afterDone, ctx.withCancel, ctx.withValue,
       ctx.value, ctx.CanceledError, ctx.newCanceled

## Interfaces referenced by value types are declared here; their method
## sets are completed in ifaces.nim (one module scope, like Go's package).

type
  Page* = ref object of RootObj
  Window* = ref object of Page
  WebView* = ref object of Page
  Tray* = ref object of RootObj
  FileWatch* = ref object of RootObj
  HeaderMap* = Table[string, seq[string]]
    ## Go map[string][]string (an http.Header without the net/http dep).

type
  PlatformError* = object of CatchableError

proc errUnsupported*(): ref PlatformError =
  ## Returned by features the current backend cannot provide.
  newException(PlatformError, "not supported on this platform")

proc errNotificationsDenied*(): ref PlatformError =
  ## ShowNotification fails with this when the user does not allow the
  ## app to show notifications.
  newException(PlatformError, "mygo: the user does not allow notifications")

proc errSecretNotFound*(): ref PlatformError =
  ## What Secrets.secret fails with when the store has no secret for the
  ## service and account.
  newException(PlatformError, "mygo: secret not found")

proc errClipboardChanged*(): ref PlatformError =
  ## Prevents a read from mixing representations from different native
  ## clipboard owners while a toolkit pumps its event loop.
  newException(PlatformError,
    "mygo: clipboard contents changed while reading")

proc errClipboardPersistence*(): ref PlatformError =
  ## The desktop has no storage for clipboard data after the owner exits.
  newException(PlatformError, "mygo: desktop cannot persist clipboard contents")

proc errFileWatchOverflow*(): ref PlatformError =
  ## The Err of a notice when the system dropped changes, for example
  ## because its queue overflowed.
  newException(PlatformError, "file watch queue overflow")

proc isErr*(e: ref CatchableError, msg: string): bool =
  e != nil and e.msg == msg

proc isErrUnsupported*(e: ref CatchableError): bool = isErr(e, "not supported on this platform")
proc isErrSecretNotFound*(e: ref CatchableError): bool = isErr(e, "mygo: secret not found")
proc isErrFileWatchOverflow*(e: ref CatchableError): bool = isErr(e, "file watch queue overflow")

type
  Point* = object
    ## A position in screen coordinates (DIPs, origin top-left of the
    ## primary display).
    x*, y*: int

  Size* = object
    ## A width and height in DIPs.
    width*, height*: int

  Rect* = object
    ## A rectangle in screen coordinates (DIPs).
    x*, y*, width*, height*: int

  TitleBar* = object
    ## The room the window controls take at the top of a window with a
    ## hidden title bar, in DIPs.
    height*, left*, right*: int

  Color* = object
    ## An 8-bit RGBA color.
    r*, g*, b*, a*: uint8

  RectF* = object
    ## A rectangle in DIPs with fractional coordinates.
    x*, y*, w*, h*: float64

proc contains*(r: RectF, x, y: float64): bool =
  x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h

proc contains*(r: Rect, x, y: int): bool =
  x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height

proc rectF*(x, y, w, h: float64): RectF = RectF(x: x, y: y, w: w, h: h)

type
  AppOptions* = object
    ## Configures Backend.init.
    name*: string
    ## activationPolicy is "regular" (default), "accessory" or
    ## "prohibited". Only meaningful on macOS.
    activationPolicy*: string

  Region* = object
    ## The user's regional formats, as the system's settings have them.
    locale*: string ## "" when unknown
    firstWeekday*: int ## 0 Sunday..6 Saturday, -1 unknown
    hourCycle*: int ## 12 or 24, 0 unknown

  PackageInfo* = object
    ## Metadata of a packaged application.
    name*, version*, identifier*: string

  AboutPanelOptions* = object
    applicationName*, applicationVersion*: string
    version*, copyright*, credits*: string

  JumpListTask* = object
    ## A task of a jump list: a program to run, its label and its icon.
    title*, path*, args*, iconPath*: string
    iconIndex*: int

  UserScript* = object
    ## JavaScript injected into pages.
    source*: string
    ## atDocumentEnd injects after the DOM is parsed instead of before
    ## any page script runs.
    atDocumentEnd*: bool
    ## allFrames injects into iframes too.
    allFrames*: bool

  Navigation* = object
    ## A pending navigation.
    url*: string
    isMainFrame*: bool
    userInitiated*: bool
    ## unasked is true for the navigations the app is not asked about
    ## (OnWillNavigate): reloads, history navigations and the loads the
    ## app starts.
    unasked*: bool
    ## reload is true for a reload of the main frame's document.
    reload*: bool

  NewWindowRequest* = object
    ## A window.open() or target=_blank request.
    url*, frameName*, disposition*: string
    ## x/y/width/height come from window.open() features; zero when absent.
    x*, y*, width*, height*: int
    ## native must be copied into WindowOptions.native of the window that
    ## is returned.
    native*: uint

  FileFilter* = object
    ## Restricts the files shown in file dialogs.
    name*: string
    extensions*: seq[string]

  OpenDialogOptions* = ref object
    title*, defaultPath*, buttonLabel*, message*: string
    filters*: seq[FileFilter]
    openFiles*, openDirectories*, multiple*: bool
    showHiddenFiles*, createDirectories*: bool
    treatPackagesAsDirectories*: bool

  SaveDialogOptions* = ref object
    title*, defaultPath*, buttonLabel*, message*, nameFieldLabel*: string
    filters*: seq[FileFilter]
    showHiddenFiles*, createDirectories*: bool
    treatPackagesAsDirectories*: bool

  MessageBoxOptions* = ref object
    ## type is "none", "info", "error", "question" or "warning".
    `type`*: string
    title*, message*, detail*: string
    buttons*: seq[string]
    defaultId*, cancelId*: int
    checkboxLabel*: string
    checkboxChecked*: bool

  MessageBoxResult* = object
    response*: int
    checkboxChecked*: bool

  Application* = object
    ## An installed application (Backend.applications): path is where
    ## fileIcon finds its icon and openApplication starts it.
    name*, id*, path*: string

  Display* = object
    ## A monitor.
    id*: int64
    label*: string
    bounds*, workArea*: Rect
    scaleFactor*: float64
    rotation*: int
    `internal`*, primary*: bool

  Preferences* = object
    ## Settings of the desktop that the system's own controls follow,
    ## and native UI with them.
    accent*: Color ## accent.a is 0 where the desktop has none
    reduceMotion*: bool
    highContrast*: bool
    textScale*: float64 ## 0 or 1 for usual

  FontRendering* = object
    ## How the desktop's settings say to rasterize text, as GTK's
    ## gtk-xft settings: each field is "" for the default, or unknown.
    antialias*: string ## "none", "gray" or "subpixel"
    hinting*: string   ## "none", "slight", "medium" or "full"
    subpixels*: string ## "rgb", "bgr", "vrgb" or "vbgr"

  PDFOptions* = object
    ## Configures Window.printToPDF; lengths are in inches.
    landscape*: bool
    pageWidth*, pageHeight*: float64
    marginTop*, marginRight*, marginBottom*, marginLeft*: float64
    background*: bool

  NetworkStatus* = object
    ## The state of the computer's network connection.
    online*: bool
    constrained*: bool ## expensive, metered or in a low data mode

  Notification* = object
    ## A desktop notification.
    id*, title*, subtitle*, body*: string
    silent*: bool
    ## group gathers the notifications that share it (threadIdentifier
    ## on macOS).
    group*: string

  MenuItemType* = enum
    menuItemNormal
    menuItemSeparator
    menuItemSubmenu
    menuItemCheckbox
    menuItemRadio

  Menu* = ref object
    ## A snapshot of a menu tree.
    items*: seq[MenuItem]
    ## rightToLeft lays a context menu out right to left, as that of an
    ## interface laid out so.
    rightToLeft*: bool

  MenuItem* = ref object
    ## A snapshot of a menu item. id identifies the public item the
    ## native item was built from.
    id*: int
    `type`*: MenuItemType
    label*, role*, accelerator*: string
    enabled*, visible*, checked*: bool
    toolTip*: string
    submenu*: Menu

  Cookie* = object
    ## A normalized snapshot of a cookie in the default page store.
    ## sameSite is "lax", "strict", "none", or empty (unknown on output
    ## only). A zero expires denotes a session cookie.
    name*, value*, domain*, path*: string
    expires*: Time
    secure*, httpOnly*: bool
    sameSite*: string

  CookieKey* = object
    ## Identifies a cookie without request URL matching.
    name*, domain*, path*: string

  TextRange* = object
    ## A half-open range in UTF-16 code units of a text client's
    ## document. Native input protocols use these units, independently
    ## of UTF-8 storage or the client's choice of buffer.
    start*, `end`*: int

  TextSelection* = object
    ## The primary selection exposed to input methods. A client may own
    ## additional selections. reversed puts the caret at range.start.
    `range`*: TextRange
    reversed*: bool

## DragRequest and DataDragEvent (platform/drag.go).

const
  ## DragSessionFormat carries an unguessable, process-local registry key.
  ## It never contains a pointer. Only the core resolves it while a drag
  ## lives.
  DragSessionFormat*: Format = "application/x-mygo-drag-session"

type
  DragRequest* = object
    ## Starts a native drag on the main thread during a pointer gesture.
    ## done must be called exactly once on the main thread. Windows may
    ## run a native nested event loop; other backends return immediately.
    data*: Data
    operations*: Operation
    session*: string
    x*, y*: float64
    preview*: seq[byte] ## premultiplied BGRA, one pixel per DIP
    width*, height*, hotX*, hotY*: int
    done*: proc(r: Result)

  DataDragEvent* = ref object
    ## A synchronous destination query. The core resolves session to
    ## local and the original data only for a live local source. Content
    ## sets operation and formats to accept.
    offer*: Offer
    session*: string
    local*: ref RootObj
    data*: Data
    operation*: Operation
    formats*: seq[Format]
    hasFiles*: bool
    resolved*: bool ## the core substituted its process-local data

## Cursors and keys (platform/surface.go tail).

type
  Cursor* = enum
    ## A pointer shape.
    cursorDefault
    cursorPointer
    cursorText
    cursorMove
    cursorResizeEW
    cursorResizeNS
    cursorResizeNWSE
    cursorResizeNESW
    cursorNotAllowed
    cursorCrosshair
    cursorGrab
    cursorGrabbing
    cursorResizeN
    cursorResizeE
    cursorResizeS
    cursorResizeW
    cursorResizeColumn
    cursorResizeRow
    cursorVerticalText
    cursorCopy
    cursorAlias
    cursorContextMenu
    cursorNone

  Modifiers* = uint8
    ## The modifier keys held during an event (bitmask).

const
  modShift* : Modifiers = 1
  modCtrl* : Modifiers = 2
  modAlt* : Modifiers = 4
  ## modSuper is Command on macOS and the Windows key elsewhere.
  modSuper* : Modifiers = 8

type
  Key* = uint16
    ## Identifies a key. Letter and digit keys follow the keyboard
    ## layout: keyA is the key that types an a.

const
  keyUnknown* : Key = 0
  keyEnter* : Key = 1
  keyEscape* : Key = 2
  keyBackspace* : Key = 3
  keyTab* : Key = 4
  keySpace* : Key = 5
  keyDelete* : Key = 6
  keyInsert* : Key = 7
  keyHome* : Key = 8
  keyEnd* : Key = 9
  keyPageUp* : Key = 10
  keyPageDown* : Key = 11
  keyLeft* : Key = 12
  keyRight* : Key = 13
  keyUp* : Key = 14
  keyDown* : Key = 15
  keyF1* : Key = 16
  keyF2* : Key = 17
  keyF3* : Key = 18
  keyF4* : Key = 19
  keyF5* : Key = 20
  keyF6* : Key = 21
  keyF7* : Key = 22
  keyF8* : Key = 23
  keyF9* : Key = 24
  keyF10* : Key = 25
  keyF11* : Key = 26
  keyF12* : Key = 27
  keyMinus* : Key = 28
  keyEqual* : Key = 29
  keyComma* : Key = 30
  keyPeriod* : Key = 31
  keySlash* : Key = 32
  keySemicolon* : Key = 33
  keyQuote* : Key = 34
  keyBracketLeft* : Key = 35
  keyBracketRight* : Key = 36
  keyBackslash* : Key = 37
  keyBackquote* : Key = 38
  keyContextMenu* : Key = 39
  key0* : Key = 40
  key1* : Key = 41
  key2* : Key = 42
  key3* : Key = 43
  key4* : Key = 44
  key5* : Key = 45
  key6* : Key = 46
  key7* : Key = 47
  key8* : Key = 48
  key9* : Key = 49
  keyA* : Key = 50
  keyB* : Key = 51
  keyC* : Key = 52
  keyD* : Key = 53
  keyE* : Key = 54
  keyF* : Key = 55
  keyG* : Key = 56
  keyH* : Key = 57
  keyI* : Key = 58
  keyJ* : Key = 59
  keyK* : Key = 60
  keyL* : Key = 61
  keyM* : Key = 62
  keyN* : Key = 63
  keyO* : Key = 64
  keyP* : Key = 65
  keyQ* : Key = 66
  keyR* : Key = 67
  keyS* : Key = 68
  keyT* : Key = 69
  keyU* : Key = 70
  keyV* : Key = 71
  keyW* : Key = 72
  keyX* : Key = 73
  keyY* : Key = 74
  keyZ* : Key = 75
  ## keyBack and keyForward go back and forward in a history: the side
  ## buttons of a mouse, and the keys of keyboards that have them.
  keyBack* : Key = 76
  keyForward* : Key = 77

proc keyForRune*(r: int32): Key =
  ## The key typing r unshifted, keyUnknown for others.
  if r >= 'a'.int32 and r <= 'z'.int32: return keyA + Key(r - 'a'.int32)
  if r >= 'A'.int32 and r <= 'Z'.int32: return keyA + Key(r - 'A'.int32)
  if r >= '0'.int32 and r <= '9'.int32: return key0 + Key(r - '0'.int32)
  if r > 255: return keyUnknown
  case char(r)
  of '-': keyMinus
  of '=': keyEqual
  of ',': keyComma
  of '.': keyPeriod
  of '/': keySlash
  of ';': keySemicolon
  of '\'': keyQuote
  of '[': keyBracketLeft
  of ']': keyBracketRight
  of '\\': keyBackslash
  of '`': keyBackquote
  of ' ': keySpace
  else: keyUnknown

## scancodeKeys maps the scancodes of the letter, digit and punctuation
## keys of an ANSI US keyboard to the key at that position. The main
## block's codes are the same in Linux's evdev and in XT set 1, which
## Windows reports.
proc keyForScancode*(code: uint16): Key =
  ## The key at a scancode's position on an ANSI US keyboard, whatever
  ## the layout types (SurfaceEvent.physicalKey), or keyUnknown for a key
  ## it does not map. A scancode is Linux's evdev code (the X keycode
  ## less 8) or Windows's XT set 1 code without the extended flag.
  case int(code)
  of 2: key1
  of 3: key2
  of 4: key3
  of 5: key4
  of 6: key5
  of 7: key6
  of 8: key7
  of 9: key8
  of 10: key9
  of 11: key0
  of 12: keyMinus
  of 13: keyEqual
  of 16: keyQ
  of 17: keyW
  of 18: keyE
  of 19: keyR
  of 20: keyT
  of 21: keyY
  of 22: keyU
  of 23: keyI
  of 24: keyO
  of 25: keyP
  of 26: keyBracketLeft
  of 27: keyBracketRight
  of 30: keyA
  of 31: keyS
  of 32: keyD
  of 33: keyF
  of 34: keyG
  of 35: keyH
  of 36: keyJ
  of 37: keyK
  of 38: keyL
  of 39: keySemicolon
  of 40: keyQuote
  of 41: keyBackquote
  of 43: keyBackslash
  of 44: keyZ
  of 45: keyX
  of 46: keyC
  of 47: keyV
  of 48: keyB
  of 49: keyN
  of 50: keyM
  of 51: keyComma
  of 52: keyPeriod
  of 53: keySlash
  else: keyUnknown

proc keyByPosition*(key, physical: Key, mods: Modifiers): bool =
  ## Whether a key press whose layout key is key may stand for its
  ## physical key: only when the layout types no US key, and a shortcut
  ## modifier is held, so that typing stays on the layout.
  key == keyUnknown and physical != keyUnknown and
    (mods and (modCtrl or modAlt or modSuper)) != 0
