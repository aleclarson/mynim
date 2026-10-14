## types.nim: the backend's types, in one block as they hold each other.

type
  webBackend* = ref object of Backend
    ## The browser backend.
    h*: AppHandler
    quitFlag*: bool
    signaled*: int
    windows*: seq[webWindow]
    ## clip is the text copied, which pastes read: browsers give the
    ## clipboard's text only to paste events (see surface.paste).
    ## clipData is all that was copied or pasted, in its text formats.
    clip*: string
    clipData*: Data
    ## source is the appearance the app asked for: "light", "dark" or
    ## "system".
    source*: string
    mac*: bool
    funcs*: seq[JsValue]

  webWindow* = ref object of Window
    ## A window of the page: an element filling the page's element with
    ## the ID "mygo", or else the page, holding the canvas its surface
    ## draws on.
    b*: webBackend
    h*: WindowHandler
    opts*: WindowOptions
    el*: JsValue
    s*: webSurface
    title*: string
    visible*, focused*, closed*, full*: bool

  webSurface* = ref object of Surface
    ## The canvas of a window, drawn with WebGL 2, or in memory and
    ## shown with a 2D context where the browser has no WebGL 2.
    w*: webWindow
    canvas*, input*: JsValue
    gl*: pointer ## the GL context, or nil where the browser has none
    ctx2d*: JsValue
    image*: JsValue ## ImageData of the frames drawn in memory
    rgba*: seq[byte]
    width*, height*, scale*: float64
    pending*: bool
    request*: JsValue ## the requestAnimationFrame pending
    frame*: JsValue
    funcs*: seq[JsValue]
    globalListeners*: seq[webListener]
    observer*: JsValue
    closed*: bool
    composing*: bool
    text*: TextInputState
    ## copied tells that a key copying went to the content, which the
    ## copy event that follows does not repeat.
    copied*: bool
    ## The last press, which the next counts clicks from.
    downAt*: MonoTime
    downX*, downY*: float64
    downButton*: int
    clicks*: int

  webListener = object
    target*: JsValue
    event*: string
    fn*: JsValue

  webPopup* = ref object
    ## A context menu shown on the page.
    b*: webBackend
    w*: webWindow
    menus*: seq[JsValue] ## the menu and its submenus open
    funcs*: seq[JsValue]
    ## removers remove the listeners of the page's events.
    removers*: seq[proc()]
    done*: bool
    ## rtl lays the menus out right to left (Menu.RightToLeft).
    rtl*: bool

  ## The leaf controllers.
  webApp* = ref object of AppController
  webDialogs* = ref object of Dialogs
  webClipboard* = ref object of Clipboard
    b*: webBackend
  webShell* = ref object of Shell
  webScreen* = ref object of Screen
  webTheme* = ref object of Theme
    b*: webBackend
  webPower* = ref object of Power
  webNetwork* = ref object of Network
    b*: webBackend
  webSecrets* = ref object of Secrets

  ## files.nim: the dropped files' in-memory filesystem.
  droppedFile = ref object
    data*: seq[byte]
    time*: Time

  webOpenFile = ref object
    path*: string
    f*: droppedFile ## nil for a directory
    at*: int

  dropped = object
    files*: Table[string, droppedFile]
    drops*: seq[string] ## the directories of the drops kept
    n*: int
    fds*: Table[int, webOpenFile]
    fd*: int

var drops* = dropped(files: initTable[string, droppedFile](),
                     fds: initTable[int, webOpenFile](), fd: 1 shl 20)
