## platform/surface.go — SurfaceEvent, the input model of a Surface.
## (The Surface interface itself is in ifaces.nim.)

type
  SurfaceEventKind* = enum
    ## The kind of a SurfaceEvent.
    ## surfaceFrame asks the content to draw a frame now.
    surfaceFrame
    ## surfaceResize reports a new size; a frame follows.
    surfaceResize
    ## pointerMove reports the pointer at x, y.
    pointerMove
    ## pointerDown and pointerUp report button pressed or released at
    ## x, y; clicks counts quick successive presses.
    pointerDown
    pointerUp
    ## pointerLeave reports the pointer left the surface.
    pointerLeave
    ## pointerScroll scrolls by dx, dy DIPs at x, y.
    pointerScroll
    ## keyPressed and keyReleased report key with mods; repeat marks
    ## auto-repeat.
    keyPressed
    keyReleased
    ## modifiersChanged reports the modifier keys held as one of them
    ## goes down or up on its own.
    modifiersChanged
    ## textInput inserts text, typed or committed by an input method.
    textInput
    ## textComposition shows text as the input method's composition, its
    ## caret at rune `caret`; an empty text ends the composition.
    textComposition
    ## surfaceFocus and surfaceBlur report the surface gaining or losing
    ## the keyboard.
    surfaceFocus
    surfaceBlur
    ## surfaceCommand performs the edit command text: "copy", "cut",
    ## "paste", "pasteAndMatchStyle", "selectAll", "undo", "redo" or
    ## "delete", or a Format menu role's: "bold", "italic", "underline",
    ## "strikethrough", "alignLeft", "alignCenter" or "alignRight".
    surfaceCommand
    ## fileDragOver reports files of another app dragged over x, y, and
    ## fileDragLeave that they left. fileDrop drops files at x, y.
    fileDragOver
    fileDragLeave
    fileDrop
    ## accessibilityOn reports that assistive technology asked about the
    ## surface.
    accessibilityOn
    ## accessAction performs action on the element id of the
    ## accessibility tree, with text the value of accessSetValue.
    accessAction
    ## surfaceShown reports that some of an occludable surface shows
    ## again after none did.
    surfaceShown
    ## dataDragOver queries a destination; dataDrop commits a transfer.
    ## dataDragLeave clears its hover state. drag carries the
    ## query/result.
    dataDragOver
    dataDragLeave
    dataDrop
    ## surfaceRenew reports that the native objects a GPU renderer draws
    ## into changed (Surface.native).
    surfaceRenew
    ## webViewPress reports that button went down at x, y on a web view
    ## the content shows there (Surface.placeWebViews), which takes the
    ## press and what follows.
    webViewPress
    ## webViewTabOut reports that Tab moved the keyboard out of webView
    ## past its page's last element, or Shift+Tab (mods) past its first.
    webViewTabOut

  SurfaceEvent* = object
    ## Input on a Surface, or a change of it.
    kind*: SurfaceEventKind
    ## x and y locate the pointer in DIPs relative to the surface.
    x*, y*: float64
    ## button is 0 for the primary button, 1 the secondary, 2 the middle.
    button*: int
    clicks*: int
    ## dx and dy are scroll distances in DIPs; precise marks touchpads
    ## and other devices that scroll by pixels rather than by lines.
    dx*, dy*: float64
    precise*: bool
    key*: Key
    ## physicalKey is the key by its position on an ANSI US keyboard,
    ## whatever the active layout types; keyUnknown where the backend
    ## does not report it.
    physicalKey*: Key
    mods*: Modifiers
    repeat*: bool
    text*: string
    caret*: int
    ## replace makes textInput replace, and textComposition compose
    ## over, the runes `from` to `to` of the last TextInputState.text,
    ## instead of the selection.
    replace*: bool
    `from`*, to*: int
    ## files are the paths of fileDrop's files, or original native paths
    ## for dataDrop's legacy file-listener fallback.
    files*: seq[string]
    drag*: DataDragEvent
    ## id and action are accessAction's.
    id*: uint64
    action*: AccessActionKind
    ## webView is webViewTabOut's.
    webView*: WebView
