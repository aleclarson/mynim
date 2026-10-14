## dialog.go: NSOpenPanel/NSSavePanel/NSAlert and the JavaScript panels
## requested by WKUIDelegate.

const nsModalResponseOK = 1
const nsAlertFirstButtonReturn = 1000


## runPanel shows a panel or alert as a sheet of parent when possible,
## else application modal, and calls done with the modal response.
proc runPanel(obj: id, parent: macWindow, sheetSel: string,
              done: proc(resp: int)) =
  if parent != nil and not parent.closed and parent.isVisible():
    discard retain(obj)
    let blk = mkBlockInt(proc(resp: clonglong) =
      withPool(proc() = done(resp.int))
      release(obj))
    discard send(obj, sheetSel, argu(parent.win), argu(blk))
    blockRelease(blk)
    return
  discard send(theBackend.app, "activateIgnoringOtherApps:", argu(1))
  done(sendInt(obj, "runModal"))
  let b = theBackend
  if b.quitAfterModal:
    b.quitAfterModal = false
    b.quit()

proc asWindow(pw: platform.Window): macWindow =
  if pw of macWindow: macWindow(pw) else: nil

## setupSavePanel applies the options shared by open and save panels.
proc setupSavePanel(panel: id; title, message, button,
    defaultPath: string; filters: seq[FileFilter]; hidden, mkdir,
    packages: bool) =
  if title != "":
    discard send(panel, "setTitle:", argu(nsString(title)))
  if message != "":
    discard send(panel, "setMessage:", argu(nsString(message)))
  if button != "":
    discard send(panel, "setPrompt:", argu(nsString(button)))
  discard send(panel, "setShowsHiddenFiles:", argu(hidden))
  discard send(panel, "setCanCreateDirectories:", argu(mkdir))
  discard send(panel, "setTreatsFilePackagesAsDirectories:",
               argu(packages))
  if defaultPath != "":
    if dirExists(defaultPath):
      discard send(panel, "setDirectoryURL:",
                   argu(fileURL(defaultPath)))
    else:
      discard send(panel, "setDirectoryURL:",
                   argu(fileURL(parentDir(defaultPath))))
      discard send(panel, "setNameFieldStringValue:",
                   argu(nsString(extractFilename(defaultPath))))
  var exts: seq[string]
  block done:
    for f in filters:
      for e in f.extensions:
        if e == "*":
          break done
        exts.add e.strip(chars = {'.'})
    if exts.len == 0:
      break done
    if hasClass("UTType"):
      var types: seq[id]
      for e in exts:
        let t = send(`class`("UTType"), "typeWithFilenameExtension:",
                     argu(nsString(e)))
        if not t.isNil:
          types.add t
      discard send(panel, "setAllowedContentTypes:", argu(nsArray(types)))
      break done
    var names: seq[id]
    for e in exts:
      names.add nsString(e)
    discard send(panel, "setAllowedFileTypes:", argu(nsArray(names)))

method showOpenDialog*(d: dialogsImpl, parent: platform.Window,
    o: OpenDialogOptions,
    cb: proc(paths: seq[string], err: ref CatchableError)) =
  withPool(proc() =
    let panel = send(`class`("NSOpenPanel"), "openPanel")
    discard send(panel, "setCanChooseFiles:", argu(o.openFiles))
    discard send(panel, "setCanChooseDirectories:",
                 argu(o.openDirectories))
    discard send(panel, "setAllowsMultipleSelection:",
                 argu(o.multiple))
    setupSavePanel(panel, o.title, o.message, o.buttonLabel,
      o.defaultPath, o.filters, o.showHiddenFiles,
      o.createDirectories, o.treatPackagesAsDirectories)
    runPanel(panel, asWindow(parent),
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        if resp != nsModalResponseOK:
          cb(@[], nil)
          return
        var paths: seq[string]
        for u in arrayItems(send(panel, "URLs")):
          paths.add goString(send(u, "path"))
        cb(paths, nil)))

method showSaveDialog*(d: dialogsImpl, parent: platform.Window,
    o: SaveDialogOptions,
    cb: proc(path: string, err: ref CatchableError)) =
  withPool(proc() =
    let panel = send(`class`("NSSavePanel"), "savePanel")
    if o.nameFieldLabel != "":
      discard send(panel, "setNameFieldLabel:",
                   argu(nsString(o.nameFieldLabel)))
    setupSavePanel(panel, o.title, o.message, o.buttonLabel,
      o.defaultPath, o.filters, o.showHiddenFiles,
      o.createDirectories, o.treatPackagesAsDirectories)
    runPanel(panel, asWindow(parent),
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        if resp != nsModalResponseOK:
          cb("", nil)
          return
        cb(goString(send(send(panel, "URL"), "path")), nil)))

proc newAlert(kind, message, detail: string; buttons: seq[string];
              defaultID, cancelID: int): id =
  let alert = autorelease(alloc("NSAlert"))
  var style = 1u ## NSAlertStyleInformational
  case kind
  of "warning": style = 0
  of "error": style = 2
  else: discard
  discard send(alert, "setAlertStyle:", argu(style))
  discard send(alert, "setMessageText:", argu(nsString(message)))
  if detail != "":
    discard send(alert, "setInformativeText:", argu(nsString(detail)))
  for b in buttons:
    discard send(alert, "addButtonWithTitle:", argu(nsString(b)))
  for i, btn in arrayItems(send(alert, "buttons")):
    var key = ""
    if i == defaultID:
      key = "\r"
    elif i == cancelID:
      key = "\x1b"
    discard send(btn, "setKeyEquivalent:", argu(nsString(key)))
  alert

method showMessageBox*(d: dialogsImpl, parent: platform.Window,
    o: MessageBoxOptions,
    cb: proc(res: MessageBoxResult, err: ref CatchableError)) =
  withPool(proc() =
    var message = o.message
    var detail = o.detail
    if message == "":
      message = o.title
    let alert = newAlert(o.`type`, message, detail, o.buttons,
                         o.defaultId, o.cancelId)
    if o.checkboxLabel != "":
      discard send(alert, "setShowsSuppressionButton:", argu(1))
      let btn = send(alert, "suppressionButton")
      discard send(btn, "setTitle:", argu(nsString(o.checkboxLabel)))
      discard send(btn, "setState:", argu(o.checkboxChecked))
    runPanel(alert, asWindow(parent),
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        var res = MessageBoxResult(response: resp - nsAlertFirstButtonReturn)
        if o.checkboxLabel != "":
          res.checkboxChecked = sendInt(send(alert, "suppressionButton"),
                                        "state") == 1
        cb(res, nil)))

## JavaScript panels requested by WKUIDelegate. The completion handler
## block must be called exactly once.

proc jsAlert*(w: macWindow, message: string, handler: pointer) =
  let handler = blockCopy(handler)
  withPool(proc() =
    let alert = newAlert("info", message, "", @[currentTexts().ok],
                         0, 0)
    runPanel(alert, w,
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        callBlock(handler, @[])
        blockRelease(handler)))

proc jsConfirm*(w: macWindow, message: string, handler: pointer) =
  let handler = blockCopy(handler)
  withPool(proc() =
    let tx = currentTexts()
    let alert = newAlert("info", message, "", @[tx.ok, tx.cancel], 0, 1)
    runPanel(alert, w,
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        callBlock(handler,
                  @[argu(resp == nsAlertFirstButtonReturn)])
        blockRelease(handler)))

proc jsPrompt*(w: macWindow, prompt, defaultText: string,
               handler: pointer) =
  let handler = blockCopy(handler)
  withPool(proc() =
    let tx = currentTexts()
    let alert = newAlert("info", prompt, "", @[tx.ok, tx.cancel], 0, 1)
    let field = autorelease(msgInitRect(
      send(`class`("NSTextField"), "alloc"), sel("initWithFrame:"),
      NSRect(size: NSSize(width: 280, height: 24))))
    discard send(field, "setStringValue:", argu(nsString(defaultText)))
    discard send(alert, "setAccessoryView:", argu(field))
    discard send(send(alert, "window"), "setInitialFirstResponder:",
                 argu(field))
    runPanel(alert, w,
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        var res: id
        if resp == nsAlertFirstButtonReturn:
          res = send(field, "stringValue")
        callBlock(handler, @[argu(res)])
        blockRelease(handler)))

proc jsFileInput*(w: macWindow, params: id, handler: pointer) =
  let handler = blockCopy(handler)
  withPool(proc() =
    let panel = send(`class`("NSOpenPanel"), "openPanel")
    discard send(panel, "setCanChooseFiles:", argu(1))
    discard send(panel, "setAllowsMultipleSelection:",
                 argu(sendBool(params, "allowsMultipleSelection")))
    if respondsTo(params, "allowsDirectories"):
      discard send(panel, "setCanChooseDirectories:",
                   argu(sendBool(params, "allowsDirectories")))
    runPanel(panel, w,
      "beginSheetModalForWindow:completionHandler:", proc(resp: int) =
        var urls: id
        if resp == nsModalResponseOK:
          urls = send(panel, "URLs")
        callBlock(handler, @[argu(urls)])
        blockRelease(handler)))
