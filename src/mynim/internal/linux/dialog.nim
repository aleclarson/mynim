## dialog.nim: file choosers and message boxes. GtkFileChooserNative runs
## the desktop's portal dialog where the desktop has one.

const gtkResponseAccept = -3

proc parentWindow*(pw: Window): pointer =
  let w = gtkWindow(pw)
  if w != nil and not w.closed:
    return w.win
  nil

## slistStrings reads and frees a GSList of GLib allocated strings.
proc slistStrings(list: pointer): seq[string] =
  var node = list
  while not node.isNil:
    result.add takeStr(field[pointer](node, 0))
    node = field[pointer](node, 8)
  if not list.isNil:
    gSlistFree(list)

proc setupChooser(fc: pointer, defaultPath: string,
    filters: seq[platform.FileFilter], hidden, save: bool) =
  gtkFileChooserSetShowHidden(fc, hidden)
  if defaultPath != "":
    var st: Stat
    if stat(defaultPath.cstring, st) == 0 and S_ISDIR(st.st_mode):
      discard gtkFileChooserSetCurrentFolder(fc, cs(defaultPath))
    else:
      discard gtkFileChooserSetCurrentFolder(fc, cs(parentDir(defaultPath)))
      if save:
        gtkFileChooserSetCurrentName(fc, cs(extractFilename(defaultPath)))
  for f in filters:
    let filter = gtkFileFilterNew()
    var name = f.name
    if name == "":
      name = f.extensions.join(", ")
    gtkFileFilterSetName(filter, cs(name))
    for e0 in f.extensions:
      let e = e0.dup(removePrefix("."))
      if e == "*":
        gtkFileFilterAddPattern(filter, cs("*"))
        continue
      gtkFileFilterAddPattern(filter, cs("*." & e))
      let up = e.toUpperAscii()
      if up != e:
        gtkFileFilterAddPattern(filter, cs("*." & up))
    gtkFileChooserAddFilter(fc, filter)

proc runDialog*(b: Backend, dlg: pointer, native: bool): int32

method showOpenDialog*(d: dialogsImpl, parent: Window,
    o: OpenDialogOptions, cb: proc(paths: seq[string],
    err: ref CatchableError)) =
  let tx = currentTexts()
  var action = 0'i32 # GTK_FILE_CHOOSER_ACTION_OPEN
  var title = tx.open
  if o.openDirectories:
    action = 2
    title = tx.selectFolder # SELECT_FOLDER
  if o.title != "":
    title = o.title
  var accept = "_" & tx.open
  if o.buttonLabel != "":
    accept = o.buttonLabel
  let fc = gtkFileChooserNativeNew(cs(title), parentWindow(parent),
    action, cs(accept), cs("_" & tx.cancel))
  gtkFileChooserSetSelectMultiple(fc, o.multiple)
  setupChooser(fc, o.defaultPath, o.filters, o.showHiddenFiles, false)
  var paths: seq[string]
  if d.b.runDialog(fc, true) == gtkResponseAccept:
    paths = slistStrings(gtkFileChooserGetFilenames(fc))
  gObjectUnref(fc)
  cb(paths, nil)

method showSaveDialog*(d: dialogsImpl, parent: Window,
    o: SaveDialogOptions, cb: proc(path: string,
    err: ref CatchableError)) =
  let tx = currentTexts()
  var title = o.title
  if title == "": title = tx.save
  var accept = "_" & tx.save
  if o.buttonLabel != "": accept = o.buttonLabel
  let fc = gtkFileChooserNativeNew(cs(title), parentWindow(parent), 1,
    cs(accept), cs("_" & tx.cancel)) # SAVE
  gtkFileChooserSetDoOverwriteConfirm(fc, true)
  setupChooser(fc, o.defaultPath, o.filters, o.showHiddenFiles, true)
  var path = ""
  if d.b.runDialog(fc, true) == gtkResponseAccept:
    path = takeStr(gtkFileChooserGetFilename(fc))
  gObjectUnref(fc)
  cb(path, nil)

method showMessageBox*(d: dialogsImpl, parent: Window,
    o: MessageBoxOptions, cb: proc(res: MessageBoxResult,
    err: ref CatchableError)) =
  var kind = 4'i32 # GTK_MESSAGE_OTHER
  case o.`type`
  of "info": kind = 0
  of "warning": kind = 1
  of "question": kind = 2
  of "error": kind = 3
  else: discard
  var message = o.message
  if message == "": message = o.title
  let dlg = gtkMessageDialogNew(parentWindow(parent), 1 or 2, kind, 0,
    cs("%s"), cs(message)) # MODAL | DESTROY_WITH_PARENT, BUTTONS_NONE
  if o.detail != "":
    gtkMessageDialogFormatSecondaryText(dlg, cs("%s"), cs(o.detail))
  if o.title != "":
    gtkWindowSetTitle(dlg, cs(o.title))
  for i, label in o.buttons:
    discard gtkDialogAddButton(dlg, cs(label), int32(i))
  gtkDialogSetDefaultResponse(dlg, int32(o.defaultId))
  var check: pointer
  if o.checkboxLabel != "":
    check = gtkCheckButtonNewWithLabel(cs(o.checkboxLabel))
    gtkToggleButtonSetActive(check, o.checkboxChecked)
    gtkContainerAdd(gtkMessageDialogGetMessageArea(dlg), check)
    gtkWidgetShow(check)
  let resp = d.b.runDialog(dlg, false)
  var res = MessageBoxResult(response: int(resp))
  if resp < 0:
    # Escape or the window's close button.
    res.response = o.cancelId
  if not check.isNil:
    res.checkboxChecked = gtkToggleButtonGetActive(check)
  gtkWidgetDestroy(dlg)
  cb(res, nil)
