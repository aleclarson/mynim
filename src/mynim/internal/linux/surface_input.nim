## surface_input.nim: input methods ask for the text around the caret,
## and delete some of it before they commit what replaces it, as Hangul
## and other input methods that edit what was typed do.

var
  systemOnce: bool
  gtkIMContextSetSurrounding: proc(im: pointer, text: cstring,
    length, cursor: int32) {.cdecl.}
  gtkIMContextGetSurrounding: proc(im: pointer, text: ptr pointer,
    cursor: ptr int32): bool {.cdecl.}
  gtkIMContextDeleteSurrounding: proc(im: pointer, offset,
    n: int32): bool {.cdecl.}
  cbIMRetrieveSurrounding*, cbIMDeleteSurrounding*,
    cbSurfaceAreaDestroy*: pointer
  ## surfaceAreas finds surfaces by their widget.
  surfaceAreas*: Table[pointer, gtkSurface]

proc initSystemSurface()
proc acceptFileDrops*(s: gtkSurface, data: pointer) ## surface_drop.nim

## connectSystem connects the surface to the system's input methods,
## drag and drop, and assistive technology.
proc connectSystem*(s: gtkSurface, data: pointer) =
  if not systemOnce:
    systemOnce = true
    initSystemSurface()
  surfaceAreas[s.area] = s
  discard connect(s.area, "destroy", cbSurfaceAreaDestroy, data)
  discard connect(s.im, "retrieve-surrounding",
    cbIMRetrieveSurrounding, data)
  discard connect(s.im, "delete-surrounding", cbIMDeleteSurrounding, data)
  s.acceptFileDrops(data)

proc surrounding*(s: gtkSurface): tuple[text: string, cursor: int]

proc destroyAccess*(s: gtkSurface) ## surface_access.nim

proc initSystemSurface() =
  mustBind(libGTK,
    cast[ptr pointer](addr gtkIMContextSetSurrounding),
    "gtk_im_context_set_surrounding")
  mustBind(libGTK,
    cast[ptr pointer](addr gtkIMContextGetSurrounding),
    "gtk_im_context_get_surrounding")
  mustBind(libGTK,
    cast[ptr pointer](addr gtkIMContextDeleteSurrounding),
    "gtk_im_context_delete_surrounding")
  loadDrops()
  cbIMRetrieveSurrounding = cast[pointer](
    proc(im, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil or not s.input.active:
        return false
      let (text, cursor) = s.surrounding()
      gtkIMContextSetSurrounding(im, cs(text), int32(text.len),
        int32(cursor))
      true)
  cbIMDeleteSurrounding = cast[pointer](
    proc(im: pointer, offset, n: int32, data: pointer): bool {.cdecl.} =
      let s = theBackend.surfaceOf(data)
      if s.isNil or not s.input.active or n < 0:
        return false
      if s.input.client != nil:
        var r = new(TextRange)
        r[] = platform.clientDeleteRange(s.input.client,
          int(offset), int(n))
        s.input.client.replaceText(r, "")
        return true
      let `from` = s.input.`end` + int(offset)
      discard s.send(SurfaceEvent(kind: textInput, replace: true,
        `from`: `from`, to: `from` + int(n)))
      true)
  cbSurfaceAreaDestroy = cast[pointer](
    proc(widget, data: pointer) {.cdecl.} =
      if surfaceAreas.hasKey(widget):
        let s = surfaceAreas[widget]
        surfaceAreas.del(widget)
        s.destroyAccess())

## surrounding returns the text around the caret that input methods
## see, and the caret's byte offset in it: the end of the selection.
proc surrounding*(s: gtkSurface): tuple[text: string, cursor: int] =
  if s.input.client != nil:
    let context = platform.clientTextContext(s.input.client)
    return (context.text,
      platform.utf16ByteOffset(context.text, context.caret))
  let text = s.input.text
  var cursor = 0
  var i = 0
  while i < text.len:
    if cursor == s.input.`end`:
      return (text, i)
    i += text.runeLenAt(i)
    inc cursor
  (text, text.len)
