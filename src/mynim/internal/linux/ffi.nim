## ffi.go — GTK 3 + WebKitGTK bound at run time with dlopen, no cgo.

import std/[dynlib, strutils]

type
  gdkRectangle* = object
    x*, y*, width*, height*: int32
  gdkRGBA* = object
    r*, g*, b*, a*: float64
  gdkGeometry* = object
    minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    baseWidth*, baseHeight*, widthInc*, heightInc*: int32
    minAspect*, maxAspect*: float64
    winGravity*: int32
    pad: int32

## Library handles.
var
  libGLib*, libGObject*, libGIO*, libGDK*, libGTK*, libWebKit*, libJSC*,
    libSoup*, libCairo*, libPixbuf*, libIndicator*: LibHandle

var webkitVersion*: string
var soup3*: bool
var
  gFree*: proc(p: pointer) {.cdecl.}
  gErrorFree*: proc(e: pointer) {.cdecl.}
  gStrfreev*: proc(v: pointer) {.cdecl.}
  gFilenameFromURI*: proc(uri: cstring, hostname: pointer, gerr: pointer): pointer {.cdecl.}
  gErrorNewLiteral*: proc(domain: uint32, code: int32, msg: cstring): pointer {.cdecl.}
  gQuarkFromString*: proc(s: cstring): uint32 {.cdecl.}
  gIdleAddFull*: proc(priority: int32, fn: pointer, data: pointer, notify: pointer): uint32 {.cdecl.}
  gTimeoutAdd*: proc(ms: uint32, fn: pointer, data: pointer): uint32 {.cdecl.}
  gMainContextIteration*: proc(ctx: pointer, mayBlock: bool): bool {.cdecl.}
  gMainContextWakeup*: proc(ctx: pointer) {.cdecl.}
  gMainLoopNew*: proc(ctx: pointer, running: bool): pointer {.cdecl.}
  gMainLoopRun*: proc(loop: pointer) {.cdecl.}
  gMainLoopQuit*: proc(loop: pointer) {.cdecl.}
  gMainLoopUnref*: proc(loop: pointer) {.cdecl.}
  gSignalConnectData*: proc(instance: pointer, signal: cstring, handler: pointer, data: pointer, destroy: pointer, flags: int32): uint64 {.cdecl.}
  gSignalHandlerDisconnect*: proc(instance: pointer, id: uint64) {.cdecl.}
  gObjectRef*: proc(obj: pointer): pointer {.cdecl.}
  gObjectRefSink*: proc(obj: pointer): pointer {.cdecl.}
  gObjectUnref*: proc(obj: pointer) {.cdecl.}
  gObjectSetBool*: proc(obj: pointer, name: cstring, v: bool, `end`: pointer) {.cdecl.}
  gObjectGetPtr*: proc(obj: pointer, name: cstring, `out`: pointer, `end`: pointer) {.cdecl.}
  gSlistFree*: proc(list: pointer) {.cdecl.}
  gListFree*: proc(list: pointer) {.cdecl.}
  gUnixInputStreamNew*: proc(fd: int32, closeFD: bool): pointer {.cdecl.}
  gInputStreamReadAll*: proc(stream: pointer, buf: pointer, count: uint, read: ptr uint, cancellable: pointer, err: ptr pointer): bool {.cdecl.}
  gAppInfoLaunchDefaultForURI*: proc(uri: cstring, ctx: pointer, err: ptr pointer): bool {.cdecl.}
  gAppInfoGetDefaultForURIScheme*: proc(scheme: cstring): pointer {.cdecl.}
  gAppInfoGetID*: proc(info: pointer): pointer {.cdecl.}
  gFileNewForPath*: proc(path: cstring): pointer {.cdecl.}
  gFileGetURI*: proc(file: pointer): pointer {.cdecl.}
  gFileTrash*: proc(file: pointer, cancellable: pointer, err: ptr pointer): bool {.cdecl.}
  gBusGetSync*: proc(busType: int32, cancellable: pointer, err: ptr pointer): pointer {.cdecl.}
  gDBusConnectionCallSync*: proc(conn: pointer, name: cstring, path: cstring, iface: cstring, `method`: cstring, params: pointer, replyType: pointer, flags: int32, timeout: int32, cancellable: pointer, err: ptr pointer): pointer {.cdecl.}
  gDBusConnectionSignalSubscribe*: proc(conn: pointer, sender: cstring, iface: cstring, member: cstring, path: cstring, arg0: cstring, flags: int32, cb: pointer, data: pointer, free: pointer): uint32 {.cdecl.}
  gVariantNewString*: proc(s: cstring): pointer {.cdecl.}
  gVariantNewUint32*: proc(v: uint32): pointer {.cdecl.}
  gVariantNewInt32*: proc(v: int32): pointer {.cdecl.}
  gVariantNewTuple*: proc(children: pointer, n: uint): pointer {.cdecl.}
  gVariantNewArray*: proc(typ: pointer, children: pointer, n: uint): pointer {.cdecl.}
  gVariantTypeNew*: proc(s: cstring): pointer {.cdecl.}
  gVariantGetChildValue*: proc(v: pointer, i: uint): pointer {.cdecl.}
  gVariantGetUint32*: proc(v: pointer): uint32 {.cdecl.}
  gVariantGetUint64*: proc(v: pointer): uint64 {.cdecl.}
  gVariantGetBoolean*: proc(v: pointer): bool {.cdecl.}
  gVariantGetDouble*: proc(v: pointer): float64 {.cdecl.}
  gVariantGetString*: proc(v: pointer, length: ptr uint): pointer {.cdecl.}
  gVariantUnref*: proc(v: pointer) {.cdecl.}
  gVariantGetVariant*: proc(v: pointer): pointer {.cdecl.}
  gVariantGetTypeString*: proc(v: pointer): pointer {.cdecl.}
  gVariantNewBoolean*: proc(v: bool): pointer {.cdecl.}
  gVariantNewDictEntry*: proc(key: pointer, value: pointer): pointer {.cdecl.}
  gVariantNewVariant*: proc(v: pointer): pointer {.cdecl.}
  gVariantNewDouble*: proc(v: float64): pointer {.cdecl.}
  gVariantNewInt64*: proc(v: int64): pointer {.cdecl.}
  gVariantNewObjectPath*: proc(s: cstring): pointer {.cdecl.}
  gVariantLookupValue*: proc(dict: pointer, key: cstring, typ: pointer): pointer {.cdecl.}
  gVariantNChildren*: proc(v: pointer): uint {.cdecl.}
  gDBusConnectionEmitSignal*: proc(conn: pointer, dest: cstring, path: cstring, iface: cstring, signal: cstring, params: pointer, err: ptr pointer): bool {.cdecl.}
  gDBusConnectionGetUniqueName*: proc(conn: pointer): pointer {.cdecl.}
  gNetworkMonitorGetDefault*: proc(): pointer {.cdecl.}
  gNetworkMonitorGetNetworkAvailable*: proc(monitor: pointer): bool {.cdecl.}
  gNetworkMonitorGetNetworkMetered*: proc(monitor: pointer): bool {.cdecl.}
  gdkScreenGetRGBAVisual*: proc(screen: pointer): pointer {.cdecl.}
  gdkDisplayGetDefault*: proc(): pointer {.cdecl.}
  gdkDisplayGetNMonitors*: proc(d: pointer): int32 {.cdecl.}
  gdkDisplayGetMonitor*: proc(d: pointer, i: int32): pointer {.cdecl.}
  gdkDisplayGetPrimaryMonitor*: proc(d: pointer): pointer {.cdecl.}
  gdkMonitorGetGeometry*: proc(m: pointer, r: ptr gdkRectangle) {.cdecl.}
  gdkMonitorGetWorkarea*: proc(m: pointer, r: ptr gdkRectangle) {.cdecl.}
  gdkMonitorGetScaleFactor*: proc(m: pointer): int32 {.cdecl.}
  gdkMonitorGetRefreshRate*: proc(m: pointer): int32 {.cdecl.}
  gdkDisplayGetMonitorAtWin*: proc(d: pointer, w: pointer): pointer {.cdecl.}
  gdkMonitorGetModel*: proc(m: pointer): pointer {.cdecl.}
  gdkDisplayGetDefaultSeat*: proc(d: pointer): pointer {.cdecl.}
  gdkSeatGetPointer*: proc(s: pointer): pointer {.cdecl.}
  gdkDeviceGetPosition*: proc(dev: pointer, screen: ptr pointer, x: ptr int32, y: ptr int32) {.cdecl.}
  gdkWindowGetDevicePosition*: proc(w: pointer, dev: pointer, x: ptr int32, y: ptr int32, mask: ptr uint32): pointer {.cdecl.}
  gdkWindowGetDisplay*: proc(w: pointer): pointer {.cdecl.}
  gdkWindowGetFrameExtents*: proc(w: pointer, r: ptr gdkRectangle) {.cdecl.}
  gdkWindowGetOrigin*: proc(w: pointer, x: ptr int32, y: ptr int32): int32 {.cdecl.}
  gdkWindowGetGeometry*: proc(w: pointer, x: ptr int32, y: ptr int32, width: ptr int32, height: ptr int32) {.cdecl.}
  gdkWindowGetCursor*: proc(w: pointer): pointer {.cdecl.}
  gdkWindowSetCursor*: proc(w: pointer, cursor: pointer) {.cdecl.}
  gdkCursorNewFromName*: proc(d: pointer, name: cstring): pointer {.cdecl.}
  gdkDisplayBeep*: proc(d: pointer) {.cdecl.}
  gdkEventCopy*: proc(e: pointer): pointer {.cdecl.}
  gdkEventFree*: proc(e: pointer) {.cdecl.}
  gdkAtomIntern*: proc(name: cstring, onlyIfExists: bool): pointer {.cdecl.}
  gdkAtomName*: proc(atom: pointer): pointer {.cdecl.}
  gdkKeyvalFromName*: proc(name: cstring): uint32 {.cdecl.}
  gdkUnicodeToKeyval*: proc(r: uint32): uint32 {.cdecl.}
  gdkPixbufLoaderNew*: proc(): pointer {.cdecl.}
  gdkPixbufLoaderWrite*: proc(l: pointer, buf: pointer, n: uint, err: ptr pointer): bool {.cdecl.}
  gdkPixbufLoaderClose*: proc(l: pointer, err: ptr pointer): bool {.cdecl.}
  gdkPixbufLoaderGetPixbuf*: proc(l: pointer): pointer {.cdecl.}
  gdkPixbufSaveToBufferv*: proc(p: pointer, buf: ptr pointer, size: ptr uint, typ: cstring, keys: pointer, values: pointer, err: ptr pointer): bool {.cdecl.}
  gtkInitCheck*: proc(argc: pointer, argv: pointer): bool {.cdecl.}
  gtkMain*: proc() {.cdecl.}
  gtkMainQuit*: proc() {.cdecl.}
  gtkGetCurrentEventTime*: proc(): uint32 {.cdecl.}
  gtkWindowNew*: proc(typ: int32): pointer {.cdecl.}
  gtkWindowSetTitle*: proc(w: pointer, title: cstring) {.cdecl.}
  gtkWindowGetTitle*: proc(w: pointer): pointer {.cdecl.}
  gtkWindowSetDefaultSize*: proc(w: pointer, width: int32, height: int32) {.cdecl.}
  gtkWindowResize*: proc(w: pointer, width: int32, height: int32) {.cdecl.}
  gtkWindowGetSize*: proc(w: pointer, width: ptr int32, height: ptr int32) {.cdecl.}
  gtkWindowMove*: proc(w: pointer, x: int32, y: int32) {.cdecl.}
  gtkWindowGetPosition*: proc(w: pointer, x: ptr int32, y: ptr int32) {.cdecl.}
  gtkWindowSetPosition*: proc(w: pointer, pos: int32) {.cdecl.}
  gtkWindowSetResizable*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowGetResizable*: proc(w: pointer): bool {.cdecl.}
  gtkWindowSetDecorated*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowSetDeletable*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowGetDeletable*: proc(w: pointer): bool {.cdecl.}
  gtkWindowSetKeepAbove*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowSetSkipTaskbarHint*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowSetTransientFor*: proc(w: pointer, parent: pointer) {.cdecl.}
  gtkWindowSetModal*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowSetGeometryHints*: proc(w: pointer, widget: pointer, geom: ptr gdkGeometry, mask: int32) {.cdecl.}
  gtkWindowPresent*: proc(w: pointer) {.cdecl.}
  gtkWindowIconify*: proc(w: pointer) {.cdecl.}
  gtkWindowDeiconify*: proc(w: pointer) {.cdecl.}
  gtkWindowMaximize*: proc(w: pointer) {.cdecl.}
  gtkWindowUnmaximize*: proc(w: pointer) {.cdecl.}
  gtkWindowFullscreen*: proc(w: pointer) {.cdecl.}
  gtkWindowUnfullscreen*: proc(w: pointer) {.cdecl.}
  gtkWindowIsActive*: proc(w: pointer): bool {.cdecl.}
  gtkWindowIsMaximized*: proc(w: pointer): bool {.cdecl.}
  gtkWindowBeginMoveDrag*: proc(w: pointer, button: int32, rootX: int32, rootY: int32, timestamp: uint32) {.cdecl.}
  gtkWindowBeginResizeDrag*: proc(w: pointer, edge: int32, button: int32, rootX: int32, rootY: int32, timestamp: uint32) {.cdecl.}
  gtkWindowAddAccelGroup*: proc(w: pointer, group: pointer) {.cdecl.}
  gtkWindowRemoveAccelGroup*: proc(w: pointer, group: pointer) {.cdecl.}
  gtkWindowSetUrgencyHint*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWindowStick*: proc(w: pointer) {.cdecl.}
  gtkWindowUnstick*: proc(w: pointer) {.cdecl.}
  gtkWindowSetIcon*: proc(w: pointer, pixbuf: pointer) {.cdecl.}
  gtkWindowSetDefaultIcon*: proc(pixbuf: pointer) {.cdecl.}
  gtkWidgetShowAll*: proc(w: pointer) {.cdecl.}
  gtkWidgetSetDirection*: proc(w: pointer, dir: int32) {.cdecl.}
  gtkWidgetSetDefaultDirection*: proc(dir: int32) {.cdecl.}
  gtkWidgetShow*: proc(w: pointer) {.cdecl.}
  gtkWidgetHide*: proc(w: pointer) {.cdecl.}
  gtkWidgetDestroy*: proc(w: pointer) {.cdecl.}
  gtkWidgetGetVisible*: proc(w: pointer): bool {.cdecl.}
  gtkWidgetGetMapped*: proc(w: pointer): bool {.cdecl.}
  gtkWidgetSetOpacity*: proc(w: pointer, v: float64) {.cdecl.}
  gtkWidgetGetOpacity*: proc(w: pointer): float64 {.cdecl.}
  gtkWidgetGrabFocus*: proc(w: pointer) {.cdecl.}
  gtkWidgetHasFocus*: proc(w: pointer): bool {.cdecl.}
  gtkGLAreaNew*: proc(): pointer {.cdecl.}
  gtkGLAreaSetHasAlpha*: proc(area: pointer, alpha: bool) {.cdecl.}
  gtkDrawingAreaNew*: proc(): pointer {.cdecl.}
  gtkIMMulticontextNew*: proc(): pointer {.cdecl.}
  gtkWidgetSetVisual*: proc(w: pointer, visual: pointer) {.cdecl.}
  gtkWidgetSetAppPaintable*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWidgetGetScreen*: proc(w: pointer): pointer {.cdecl.}
  gtkWidgetSetSensitive*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWidgetIsSensitive*: proc(w: pointer): bool {.cdecl.}
  gtkWidgetSetTooltipText*: proc(w: pointer, s: cstring) {.cdecl.}
  gtkWidgetAddAccelerator*: proc(w: pointer, signal: cstring, group: pointer, key: uint32, mods: uint32, flags: int32) {.cdecl.}
  gtkWidgetSetNoShowAll*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWidgetSetVisible*: proc(w: pointer, v: bool) {.cdecl.}
  gtkWidgetMnemonicActivate*: proc(w: pointer, groupCycling: bool): bool {.cdecl.}
  gtkBoxNew*: proc(orientation: int32, spacing: int32): pointer {.cdecl.}
  gtkBoxPackStart*: proc(box: pointer, child: pointer, expand: bool, fill: bool, padding: uint32) {.cdecl.}
  gtkBoxReorderChild*: proc(box: pointer, child: pointer, pos: int32) {.cdecl.}
  gtkContainerAdd*: proc(c: pointer, w: pointer) {.cdecl.}
  gtkContainerRemove*: proc(c: pointer, w: pointer) {.cdecl.}
  gtkContainerCheckResize*: proc(c: pointer) {.cdecl.}
  gtkMenuBarNew*: proc(): pointer {.cdecl.}
  gtkMenuNew*: proc(): pointer {.cdecl.}
  gtkMenuItemNewWithLabel*: proc(label: cstring): pointer {.cdecl.}
  gtkMenuItemSetLabel*: proc(item: pointer, label: cstring) {.cdecl.}
  gtkMenuItemSetSubmenu*: proc(item: pointer, menu: pointer) {.cdecl.}
  gtkMenuItemGetSubmenu*: proc(item: pointer): pointer {.cdecl.}
  gtkMenuItemGetLabel*: proc(item: pointer): pointer {.cdecl.}
  gtkMenuItemActivate*: proc(item: pointer) {.cdecl.}
  gtkContainerGetChildren*: proc(c: pointer): pointer {.cdecl.}
  gtkCheckMenuItemNewWithLabel*: proc(label: cstring): pointer {.cdecl.}
  gtkCheckMenuItemSetActive*: proc(item: pointer, v: bool) {.cdecl.}
  gtkCheckMenuItemSetDrawAsRadio*: proc(item: pointer, v: bool) {.cdecl.}
  gtkSeparatorMenuItemNew*: proc(): pointer {.cdecl.}
  gtkMenuShellAppend*: proc(shell: pointer, child: pointer) {.cdecl.}
  gtkMenuPopupAtPointer*: proc(menu: pointer, event: pointer) {.cdecl.}
  gtkMenuPopupAtRect*: proc(menu: pointer, window: pointer, rect: ptr gdkRectangle, rectAnchor: int32, menuAnchor: int32, event: pointer) {.cdecl.}
  gtkMenuShellDeactivate*: proc(menu: pointer) {.cdecl.}
  gtkWidgetGetWindow*: proc(w: pointer): pointer {.cdecl.}
  gtkWidgetRealize*: proc(w: pointer) {.cdecl.}
  gtkWidgetGetAllocation*: proc(w: pointer, a: ptr gdkRectangle) {.cdecl.}
  gtkAccelGroupNew*: proc(): pointer {.cdecl.}
  gtkFileChooserNativeNew*: proc(title: cstring, parent: pointer, action: int32, accept: cstring, cancel: cstring): pointer {.cdecl.}
  gtkNativeDialogRun*: proc(d: pointer): int32 {.cdecl.}
  gtkNativeDialogHide*: proc(d: pointer) {.cdecl.}
  gtkFileChooserSetSelectMultiple*: proc(fc: pointer, v: bool) {.cdecl.}
  gtkFileChooserSetShowHidden*: proc(fc: pointer, v: bool) {.cdecl.}
  gtkFileChooserSetDoOverwriteConfirm*: proc(fc: pointer, v: bool) {.cdecl.}
  gtkFileChooserSetCurrentFolder*: proc(fc: pointer, path: cstring): bool {.cdecl.}
  gtkFileChooserSetCurrentName*: proc(fc: pointer, name: cstring) {.cdecl.}
  gtkFileChooserGetFilenames*: proc(fc: pointer): pointer {.cdecl.}
  gtkFileChooserGetFilename*: proc(fc: pointer): pointer {.cdecl.}
  gtkFileChooserAddFilter*: proc(fc: pointer, filter: pointer) {.cdecl.}
  gtkFileFilterNew*: proc(): pointer {.cdecl.}
  gtkFileFilterSetName*: proc(f: pointer, name: cstring) {.cdecl.}
  gtkFileFilterAddPattern*: proc(f: pointer, pattern: cstring) {.cdecl.}
  gtkMessageDialogNew*: proc(parent: pointer, flags: int32, typ: int32, buttons: int32, format: cstring, arg: cstring): pointer {.cdecl.}
  gtkMessageDialogFormatSecondaryText*: proc(d: pointer, format: cstring, arg: cstring) {.cdecl.}
  gtkMessageDialogGetMessageArea*: proc(d: pointer): pointer {.cdecl.}
  gtkDialogAddButton*: proc(d: pointer, text: cstring, response: int32): pointer {.cdecl.}
  gtkDialogSetDefaultResponse*: proc(d: pointer, response: int32) {.cdecl.}
  gtkDialogRun*: proc(d: pointer): int32 {.cdecl.}
  gtkCheckButtonNewWithLabel*: proc(label: cstring): pointer {.cdecl.}
  gtkToggleButtonGetActive*: proc(b: pointer): bool {.cdecl.}
  gtkToggleButtonSetActive*: proc(b: pointer, v: bool) {.cdecl.}
  gtkClipboardGet*: proc(atom: pointer): pointer {.cdecl.}
  gtkClipboardSetText*: proc(cb: pointer, text: cstring, n: int32) {.cdecl.}
  gtkClipboardWaitForText*: proc(cb: pointer): pointer {.cdecl.}
  gtkClipboardWaitForImage*: proc(cb: pointer): pointer {.cdecl.}
  gtkClipboardSetImage*: proc(cb: pointer, pixbuf: pointer) {.cdecl.}
  gtkClipboardWaitForContents*: proc(cb: pointer, target: pointer): pointer {.cdecl.}
  gtkClipboardWaitForTargets*: proc(cb: pointer, targets: ptr pointer, n: ptr int32): bool {.cdecl.}
  gtkClipboardClear*: proc(cb: pointer) {.cdecl.}
  gtkSelectionDataGetData*: proc(sd: pointer): pointer {.cdecl.}
  gtkSelectionDataGetLength*: proc(sd: pointer): int32 {.cdecl.}
  gtkSelectionDataFree*: proc(sd: pointer) {.cdecl.}
  gtkSelectionDataGetUris*: proc(sd: pointer): pointer {.cdecl.}
  gtkSettingsGetDefault*: proc(): pointer {.cdecl.}
  gtkOverlayNew*: proc(): pointer {.cdecl.}
  gtkOverlayAddOverlay*: proc(o: pointer, w: pointer) {.cdecl.}
  gtkHeaderBarNew*: proc(): pointer {.cdecl.}
  gtkHeaderBarSetShowCloseButton*: proc(b: pointer, v: bool) {.cdecl.}
  gtkHeaderBarSetHasSubtitle*: proc(b: pointer, v: bool) {.cdecl.}
  gtkHeaderBarSetDecorationLayout*: proc(b: pointer, layout: cstring) {.cdecl.}
  gtkWidgetSetHalign*: proc(w: pointer, align: int32) {.cdecl.}
  gtkWidgetSetValign*: proc(w: pointer, align: int32) {.cdecl.}
  gtkWidgetSetSizeRequest*: proc(w: pointer, width: int32, height: int32) {.cdecl.}
  gtkWidgetGetPreferredWidth*: proc(w: pointer, min: ptr int32, natural: ptr int32) {.cdecl.}
  gtkWidgetGetPreferredHeight*: proc(w: pointer, min: ptr int32, natural: ptr int32) {.cdecl.}
  gtkWidgetGetStyleContext*: proc(w: pointer): pointer {.cdecl.}
  gtkStyleContextAddClass*: proc(c: pointer, name: cstring) {.cdecl.}
  gtkStyleContextAddProviderForScreen*: proc(screen: pointer, provider: pointer, priority: uint32) {.cdecl.}
  gtkCssProviderNew*: proc(): pointer {.cdecl.}
  gtkCssProviderLoadFromData*: proc(p: pointer, data: cstring, length: int, err: ptr pointer): bool {.cdecl.}
  gtkAboutDialogNew*: proc(): pointer {.cdecl.}
  gtkAboutDialogSetProgramName*: proc(d: pointer, s: cstring) {.cdecl.}
  gtkAboutDialogSetVersion*: proc(d: pointer, s: cstring) {.cdecl.}
  gtkAboutDialogSetCopyright*: proc(d: pointer, s: cstring) {.cdecl.}
  gtkAboutDialogSetComments*: proc(d: pointer, s: cstring) {.cdecl.}
  webkitWebContextGetDefault*: proc(): pointer {.cdecl.}
  webkitWebContextRegisterURIScheme*: proc(ctx: pointer, scheme: cstring, cb: pointer, data: pointer, destroy: pointer) {.cdecl.}
  webkitWebContextGetSecurityManager*: proc(ctx: pointer): pointer {.cdecl.}
  webkitWebContextGetWebsiteDataManager*: proc(ctx: pointer): pointer {.cdecl.}
  webkitWebContextSetPreferredLanguages*: proc(ctx: pointer, languages: ptr cstring) {.cdecl.}
  webkitWebsiteDataManagerClear*: proc(m: pointer, types: uint32, timespan: int64, cancellable: pointer, cb: pointer, data: pointer) {.cdecl.}
  webkitWebsiteDataManagerClearFinish*: proc(m: pointer, res: pointer, err: ptr pointer): bool {.cdecl.}
  webkitDownloadGetWebView*: proc(d: pointer): pointer {.cdecl.}
  webkitDownloadGetRequest*: proc(d: pointer): pointer {.cdecl.}
  webkitDownloadSetDestination*: proc(d: pointer, uri: cstring) {.cdecl.}
  webkitDownloadSetAllowOverwrite*: proc(d: pointer, v: bool) {.cdecl.}
  webkitDownloadCancel*: proc(d: pointer) {.cdecl.}
  webkitResponsePolicyDecisionGetResponse*: proc(d: pointer): pointer {.cdecl.}
  webkitResponsePolicyDecisionIsMIMETypeSupported*: proc(d: pointer): bool {.cdecl.}
  webkitPolicyDecisionDownload*: proc(d: pointer) {.cdecl.}
  webkitURIResponseGetURI*: proc(r: pointer): pointer {.cdecl.}
  webkitURIResponseGetHTTPHeaders*: proc(r: pointer): pointer {.cdecl.}
  webkitSecurityManagerRegisterSecure*: proc(m: pointer, scheme: cstring) {.cdecl.}
  webkitSecurityManagerRegisterCORS*: proc(m: pointer, scheme: cstring) {.cdecl.}
  webkitUserContentManagerNew*: proc(): pointer {.cdecl.}
  webkitUserContentManagerRegisterHandler*: proc(ucm: pointer, name: cstring): bool {.cdecl.}
  webkitUserContentManagerUnregisterHandler*: proc(ucm: pointer, name: cstring) {.cdecl.}
  webkitUserContentManagerAddScript*: proc(ucm: pointer, script: pointer) {.cdecl.}
  webkitUserContentManagerRemoveAllScripts*: proc(ucm: pointer) {.cdecl.}
  webkitUserScriptNew*: proc(src: cstring, frames: int32, time: int32, allow: pointer, `block`: pointer): pointer {.cdecl.}
  webkitUserScriptUnref*: proc(s: pointer) {.cdecl.}
  webkitWebViewNewWithUserContentManager*: proc(ucm: pointer): pointer {.cdecl.}
  webkitWebViewGetSettings*: proc(wv: pointer): pointer {.cdecl.}
  webkitSettingsSetEnableDeveloperExtras*: proc(s: pointer, v: bool) {.cdecl.}
  webkitSettingsSetUserAgent*: proc(s: pointer, ua: cstring) {.cdecl.}
  webkitSettingsGetUserAgent*: proc(s: pointer): pointer {.cdecl.}
  webkitSettingsSetAllowFileAccessFromFileURLs*: proc(s: pointer, v: bool) {.cdecl.}
  webkitSettingsSetJavascriptCanAccessClipboard*: proc(s: pointer, v: bool) {.cdecl.}
  webkitWebViewLoadURI*: proc(wv: pointer, uri: cstring) {.cdecl.}
  webkitWebViewLoadHTML*: proc(wv: pointer, html: cstring, base: cstring) {.cdecl.}
  webkitWebViewReload*: proc(wv: pointer) {.cdecl.}
  webkitWebViewReloadBypassCache*: proc(wv: pointer) {.cdecl.}
  webkitWebViewStopLoading*: proc(wv: pointer) {.cdecl.}
  webkitWebViewGoBack*: proc(wv: pointer) {.cdecl.}
  webkitWebViewGoForward*: proc(wv: pointer) {.cdecl.}
  webkitWebViewCanGoBack*: proc(wv: pointer): bool {.cdecl.}
  webkitWebViewCanGoForward*: proc(wv: pointer): bool {.cdecl.}
  webkitWebViewIsLoading*: proc(wv: pointer): bool {.cdecl.}
  webkitWebViewGetURI*: proc(wv: pointer): pointer {.cdecl.}
  webkitWebViewGetTitle*: proc(wv: pointer): pointer {.cdecl.}
  webkitWebViewSetZoomLevel*: proc(wv: pointer, z: float64) {.cdecl.}
  webkitWebViewGetZoomLevel*: proc(wv: pointer): float64 {.cdecl.}
  webkitWebViewSetBackgroundColor*: proc(wv: pointer, rgba: ptr gdkRGBA) {.cdecl.}
  webkitWebViewEvaluateJavascript*: proc(wv: pointer, script: cstring, length: int, world: cstring, sourceURI: cstring, cancellable: pointer, cb: pointer, data: pointer) {.cdecl.}
  webkitWebViewRunJavascript*: proc(wv: pointer, script: cstring, cancellable: pointer, cb: pointer, data: pointer) {.cdecl.}
  webkitWebViewCallAsyncJavascriptFunction*: proc(wv: pointer, body: cstring, length: int, args: pointer, world: cstring, sourceURI: cstring, cancellable: pointer, cb: pointer, data: pointer) {.cdecl.}
  webkitWebViewCallAsyncJavascriptFunctionFinish*: proc(wv: pointer, res: pointer, err: ptr pointer): pointer {.cdecl.}
  webkitWebViewGetInspector*: proc(wv: pointer): pointer {.cdecl.}
  webkitWebInspectorShow*: proc(i: pointer) {.cdecl.}
  webkitWebInspectorClose*: proc(i: pointer) {.cdecl.}
  webkitWebInspectorGetWebView*: proc(i: pointer): pointer {.cdecl.}
  webkitWebViewGetSnapshot*: proc(wv: pointer, region: int32, options: int32, cancellable: pointer, cb: pointer, data: pointer) {.cdecl.}
  webkitWebViewGetSnapshotFinish*: proc(wv: pointer, res: pointer, err: ptr pointer): pointer {.cdecl.}
  webkitWebViewExecuteEditingCommand*: proc(wv: pointer, cmd: cstring) {.cdecl.}
  webkitPrintOperationNew*: proc(wv: pointer): pointer {.cdecl.}
  webkitPrintOperationRunDialog*: proc(op: pointer, parent: pointer): int32 {.cdecl.}
  webkitPrintOperationSetPrintSettings*: proc(op: pointer, settings: pointer) {.cdecl.}
  webkitPrintOperationSetPageSetup*: proc(op: pointer, setup: pointer) {.cdecl.}
  webkitPrintOperationPrint*: proc(op: pointer) {.cdecl.}
  webkitSettingsGetPrintBackgrounds*: proc(s: pointer): bool {.cdecl.}
  webkitSettingsSetPrintBackgrounds*: proc(s: pointer, v: bool) {.cdecl.}
  webkitUserMediaPermissionRequestGetType*: proc(): uint {.cdecl.}
  webkitGeolocationPermissionRequestGetType*: proc(): uint {.cdecl.}
  webkitNotificationPermissionRequestGetType*: proc(): uint {.cdecl.}
  webkitUserMediaPermissionIsForAudioDevice*: proc(req: pointer): bool {.cdecl.}
  webkitUserMediaPermissionIsForVideoDevice*: proc(req: pointer): bool {.cdecl.}
  webkitPermissionRequestAllow*: proc(req: pointer) {.cdecl.}
  webkitPermissionRequestDeny*: proc(req: pointer) {.cdecl.}
  gTypeCheckInstanceIsA*: proc(instance: pointer, typ: uint): bool {.cdecl.}
  gtkPrintSettingsNew*: proc(): pointer {.cdecl.}
  gtkPrintSettingsSet*: proc(s: pointer, key: cstring, value: cstring) {.cdecl.}
  gtkPageSetupNew*: proc(): pointer {.cdecl.}
  gtkPageSetupSetPaperSize*: proc(setup: pointer, size: pointer) {.cdecl.}
  gtkPageSetupSetOrientation*: proc(setup: pointer, orientation: int32) {.cdecl.}
  gtkPageSetupSetTopMargin*: proc(setup: pointer, margin: float64, unit: int32) {.cdecl.}
  gtkPageSetupSetBottomMargin*: proc(setup: pointer, margin: float64, unit: int32) {.cdecl.}
  gtkPageSetupSetLeftMargin*: proc(setup: pointer, margin: float64, unit: int32) {.cdecl.}
  gtkPageSetupSetRightMargin*: proc(setup: pointer, margin: float64, unit: int32) {.cdecl.}
  gtkPaperSizeNewCustom*: proc(name: cstring, displayName: cstring, width: float64, height: float64, unit: int32): pointer {.cdecl.}
  gtkPaperSizeFree*: proc(size: pointer) {.cdecl.}
  gtkRecentManagerGetDefault*: proc(): pointer {.cdecl.}
  gtkRecentManagerAddItem*: proc(manager: pointer, uri: cstring): bool {.cdecl.}
  gtkRecentManagerGetItems*: proc(manager: pointer): pointer {.cdecl.}
  gtkRecentInfoGetURI*: proc(info: pointer): pointer {.cdecl.}
  gtkRecentInfoHasApplication*: proc(info: pointer, app: pointer): bool {.cdecl.}
  gtkRecentInfoUnref*: proc(info: pointer) {.cdecl.}
  gGetApplicationName*: proc(): pointer {.cdecl.}
  gtkRecentManagerRemoveItem*: proc(manager: pointer, uri: cstring, gerr: pointer): bool {.cdecl.}
  gtkRecentManagerHasItem*: proc(manager: pointer, uri: cstring): bool {.cdecl.}
  webkitJavascriptResultGetJSValue*: proc(r: pointer): pointer {.cdecl.}
  webkitNavigationPolicyDecisionGetNavigationAction*: proc(d: pointer): pointer {.cdecl.}
  webkitNavigationPolicyDecisionGetFrameName*: proc(d: pointer): pointer {.cdecl.}
  webkitNavigationActionGetRequest*: proc(a: pointer): pointer {.cdecl.}
  webkitNavigationActionGetNavigationType*: proc(a: pointer): int32 {.cdecl.}
  webkitNavigationActionIsUserGesture*: proc(a: pointer): bool {.cdecl.}
  webkitURIRequestGetURI*: proc(r: pointer): pointer {.cdecl.}
  webkitPolicyDecisionUse*: proc(d: pointer) {.cdecl.}
  webkitPolicyDecisionIgnore*: proc(d: pointer) {.cdecl.}
  webkitURISchemeRequestGetURI*: proc(r: pointer): pointer {.cdecl.}
  webkitURISchemeRequestGetHTTPMethod*: proc(r: pointer): pointer {.cdecl.}
  webkitURISchemeRequestGetHTTPHeaders*: proc(r: pointer): pointer {.cdecl.}
  webkitURISchemeRequestGetHTTPBody*: proc(r: pointer): pointer {.cdecl.}
  webkitURISchemeRequestGetWebView*: proc(r: pointer): pointer {.cdecl.}
  webkitURISchemeRequestFinishWithResponse*: proc(r: pointer, resp: pointer) {.cdecl.}
  webkitURISchemeRequestFinishError*: proc(r: pointer, gerr: pointer) {.cdecl.}
  webkitURISchemeRequestFinish*: proc(r: pointer, stream: pointer, length: int64, contentType: cstring) {.cdecl.}
  webkitURISchemeResponseNew*: proc(stream: pointer, length: int64): pointer {.cdecl.}
  webkitURISchemeResponseSetStatus*: proc(resp: pointer, status: uint32, reason: cstring) {.cdecl.}
  webkitURISchemeResponseSetContentType*: proc(resp: pointer, ct: cstring) {.cdecl.}
  webkitURISchemeResponseSetHTTPHeaders*: proc(resp: pointer, headers: pointer) {.cdecl.}
  jscValueToString*: proc(v: pointer): pointer {.cdecl.}
  soupMessageHeadersNew*: proc(typ: int32): pointer {.cdecl.}
  soupMessageHeadersAppend*: proc(h: pointer, name: cstring, value: cstring) {.cdecl.}
  soupMessageHeadersForeach*: proc(h: pointer, fn: pointer, data: pointer) {.cdecl.}
  soupMessageHeadersGetOne*: proc(h: pointer, name: cstring): pointer {.cdecl.}
  cairoSurfaceWriteToPNGStream*: proc(surface: pointer, write: pointer, closure: pointer): int32 {.cdecl.}
  cairoSurfaceDestroy*: proc(s: pointer) {.cdecl.}
  appIndicatorNew*: proc(id: cstring, icon: cstring, category: int32): pointer {.cdecl.}
  appIndicatorSetStatus*: proc(ind: pointer, status: int32) {.cdecl.}
  appIndicatorSetMenu*: proc(ind: pointer, menu: pointer) {.cdecl.}
  appIndicatorSetIconFull*: proc(ind: pointer, icon: cstring, desc: cstring) {.cdecl.}
  appIndicatorSetIconThemePath*: proc(ind: pointer, path: cstring) {.cdecl.}
  appIndicatorSetTitle*: proc(ind: pointer, title: cstring) {.cdecl.}
  appIndicatorSetLabel*: proc(ind: pointer, label: cstring, guide: cstring) {.cdecl.}

proc cs*(s: string): cstring = cstring(s)
  ## cs passes s to a C function, NUL terminated.

proc optCS*(s: string): cstring =
  ## optCS is cs that maps "" to NULL.
  if s == "": nil else: cstring(s)

proc goStr*(p: pointer): string =
  ## goStr copies a C string.
  if p.isNil: "" else: $(cast[cstring](p))

proc takeStr*(p: pointer): string =
  ## takeStr copies and frees a C string allocated by GLib.
  result = goStr(p)
  if not p.isNil:
    gFree(p)

proc gErr*(e: pointer): ref CatchableError =
  ## gErr converts and frees a GError.
  if e.isNil: return nil
  # struct GError { GQuark domain; gint code; gchar *message; }
  let msg = goStr(cast[ptr pointer](cast[uint](e) + 8)[])
  gErrorFree(e)
  newException(CatchableError, msg)

proc openLib*(names: varargs[string]): tuple[lib: LibHandle, err: ref CatchableError] =
  var errs: seq[string]
  for n in names:
    let h = loadLib(n, globalSymbols = true)
    if not h.isNil:
      return (h, nil)
    errs.add n
  (nil, newException(CatchableError,
    "cannot load " & names[0] & ": " & errs.join("; ")))

proc bindFunc*(lib: LibHandle, fn: ptr pointer, name: cstring): bool =
  ## bindFunc registers fn from lib; missing symbols leave fn nil.
  let sym = lib.symAddr(name)
  if sym.isNil:
    return false
  fn[] = sym
  true

proc mustBind*(lib: LibHandle, fn: ptr pointer, name: cstring) =
  ## mustBind is bind for required symbols.
  if not bindFunc(lib, fn, name):
    raise newException(LibraryError, "mynim: missing symbol " & $name)
proc load*(): ref CatchableError =
  ## The libraries' load; windows that only draw Content need GTK alone.
  var e: ref CatchableError
  (libGLib, e) = openLib("libglib-2.0.so.0")
  if not e.isNil: return e
  (libGObject, e) = openLib("libgobject-2.0.so.0")
  if not e.isNil: return e
  (libGIO, e) = openLib("libgio-2.0.so.0")
  if not e.isNil: return e
  (libGDK, e) = openLib("libgdk-3.so.0")
  if not e.isNil: return e
  (libGTK, e) = openLib("libgtk-3.so.0")
  if not e.isNil: return e
  (libCairo, e) = openLib("libcairo.so.2")
  if not e.isNil: return e
  (libPixbuf, e) = openLib("libgdk_pixbuf-2.0.so.0")
  if not e.isNil: return e
  (libIndicator, _) = openLib("libayatana-appindicator3.so.1",
                           "libappindicator3.so.1")

  mustBind(libGLib, cast[ptr pointer](addr gFree), "g_free")
  mustBind(libGLib, cast[ptr pointer](addr gErrorFree), "g_error_free")
  mustBind(libGLib, cast[ptr pointer](addr gStrfreev), "g_strfreev")
  mustBind(libGLib, cast[ptr pointer](addr gFilenameFromURI), "g_filename_from_uri")
  mustBind(libGLib, cast[ptr pointer](addr gErrorNewLiteral), "g_error_new_literal")
  mustBind(libGLib, cast[ptr pointer](addr gQuarkFromString), "g_quark_from_string")
  mustBind(libGLib, cast[ptr pointer](addr gIdleAddFull), "g_idle_add_full")
  mustBind(libGLib, cast[ptr pointer](addr gTimeoutAdd), "g_timeout_add")
  mustBind(libGLib, cast[ptr pointer](addr gMainContextIteration), "g_main_context_iteration")
  mustBind(libGLib, cast[ptr pointer](addr gMainContextWakeup), "g_main_context_wakeup")
  mustBind(libGLib, cast[ptr pointer](addr gMainLoopNew), "g_main_loop_new")
  mustBind(libGLib, cast[ptr pointer](addr gMainLoopRun), "g_main_loop_run")
  mustBind(libGLib, cast[ptr pointer](addr gMainLoopQuit), "g_main_loop_quit")
  mustBind(libGLib, cast[ptr pointer](addr gMainLoopUnref), "g_main_loop_unref")
  mustBind(libGLib, cast[ptr pointer](addr gSlistFree), "g_slist_free")
  mustBind(libGLib, cast[ptr pointer](addr gListFree), "g_list_free")
  mustBind(libGLib, cast[ptr pointer](addr gGetApplicationName), "g_get_application_name")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewString), "g_variant_new_string")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewUint32), "g_variant_new_uint32")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewInt32), "g_variant_new_int32")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewTuple), "g_variant_new_tuple")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewArray), "g_variant_new_array")
  mustBind(libGLib, cast[ptr pointer](addr gVariantTypeNew), "g_variant_type_new")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetChildValue), "g_variant_get_child_value")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetUint32), "g_variant_get_uint32")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetUint64), "g_variant_get_uint64")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetBoolean), "g_variant_get_boolean")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetDouble), "g_variant_get_double")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetString), "g_variant_get_string")
  mustBind(libGLib, cast[ptr pointer](addr gVariantUnref), "g_variant_unref")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetVariant), "g_variant_get_variant")
  mustBind(libGLib, cast[ptr pointer](addr gVariantGetTypeString), "g_variant_get_type_string")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewBoolean), "g_variant_new_boolean")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewDictEntry), "g_variant_new_dict_entry")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewVariant), "g_variant_new_variant")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewDouble), "g_variant_new_double")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewInt64), "g_variant_new_int64")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNewObjectPath), "g_variant_new_object_path")
  mustBind(libGLib, cast[ptr pointer](addr gVariantLookupValue), "g_variant_lookup_value")
  mustBind(libGLib, cast[ptr pointer](addr gVariantNChildren), "g_variant_n_children")
  mustBind(libGObject, cast[ptr pointer](addr gSignalConnectData), "g_signal_connect_data")
  mustBind(libGObject, cast[ptr pointer](addr gSignalHandlerDisconnect), "g_signal_handler_disconnect")
  mustBind(libGObject, cast[ptr pointer](addr gObjectRef), "g_object_ref")
  mustBind(libGObject, cast[ptr pointer](addr gObjectRefSink), "g_object_ref_sink")
  mustBind(libGObject, cast[ptr pointer](addr gObjectUnref), "g_object_unref")
  mustBind(libGObject, cast[ptr pointer](addr gObjectSetBool), "g_object_set")
  mustBind(libGObject, cast[ptr pointer](addr gObjectGetPtr), "g_object_get")
  mustBind(libGIO, cast[ptr pointer](addr gUnixInputStreamNew), "g_unix_input_stream_new")
  mustBind(libGIO, cast[ptr pointer](addr gInputStreamReadAll), "g_input_stream_read_all")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoLaunchDefaultForURI), "g_app_info_launch_default_for_uri")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoGetDefaultForURIScheme), "g_app_info_get_default_for_uri_scheme")
  mustBind(libGIO, cast[ptr pointer](addr gAppInfoGetID), "g_app_info_get_id")
  mustBind(libGIO, cast[ptr pointer](addr gFileNewForPath), "g_file_new_for_path")
  mustBind(libGIO, cast[ptr pointer](addr gFileGetURI), "g_file_get_uri")
  mustBind(libGIO, cast[ptr pointer](addr gFileTrash), "g_file_trash")
  mustBind(libGIO, cast[ptr pointer](addr gBusGetSync), "g_bus_get_sync")
  mustBind(libGIO, cast[ptr pointer](addr gDBusConnectionEmitSignal), "g_dbus_connection_emit_signal")
  mustBind(libGIO, cast[ptr pointer](addr gDBusConnectionCallSync), "g_dbus_connection_call_sync")
  mustBind(libGIO, cast[ptr pointer](addr gDBusConnectionSignalSubscribe), "g_dbus_connection_signal_subscribe")
  mustBind(libGIO, cast[ptr pointer](addr gDBusConnectionGetUniqueName), "g_dbus_connection_get_unique_name")
  mustBind(libGIO, cast[ptr pointer](addr gNetworkMonitorGetDefault), "g_network_monitor_get_default")
  mustBind(libGIO, cast[ptr pointer](addr gNetworkMonitorGetNetworkAvailable), "g_network_monitor_get_network_available")
  mustBind(libGIO, cast[ptr pointer](addr gNetworkMonitorGetNetworkMetered), "g_network_monitor_get_network_metered")
  mustBind(libGDK, cast[ptr pointer](addr gdkScreenGetRGBAVisual), "gdk_screen_get_rgba_visual")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetDefault), "gdk_display_get_default")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetNMonitors), "gdk_display_get_n_monitors")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetMonitor), "gdk_display_get_monitor")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetPrimaryMonitor), "gdk_display_get_primary_monitor")
  mustBind(libGDK, cast[ptr pointer](addr gdkMonitorGetGeometry), "gdk_monitor_get_geometry")
  mustBind(libGDK, cast[ptr pointer](addr gdkMonitorGetWorkarea), "gdk_monitor_get_workarea")
  mustBind(libGDK, cast[ptr pointer](addr gdkMonitorGetScaleFactor), "gdk_monitor_get_scale_factor")
  mustBind(libGDK, cast[ptr pointer](addr gdkMonitorGetRefreshRate), "gdk_monitor_get_refresh_rate")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetMonitorAtWin), "gdk_display_get_monitor_at_window")
  mustBind(libGDK, cast[ptr pointer](addr gdkMonitorGetModel), "gdk_monitor_get_model")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayGetDefaultSeat), "gdk_display_get_default_seat")
  mustBind(libGDK, cast[ptr pointer](addr gdkSeatGetPointer), "gdk_seat_get_pointer")
  mustBind(libGDK, cast[ptr pointer](addr gdkDeviceGetPosition), "gdk_device_get_position")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetDevicePosition), "gdk_window_get_device_position")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetDisplay), "gdk_window_get_display")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetFrameExtents), "gdk_window_get_frame_extents")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetOrigin), "gdk_window_get_origin")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetGeometry), "gdk_window_get_geometry")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowGetCursor), "gdk_window_get_cursor")
  mustBind(libGDK, cast[ptr pointer](addr gdkWindowSetCursor), "gdk_window_set_cursor")
  mustBind(libGDK, cast[ptr pointer](addr gdkCursorNewFromName), "gdk_cursor_new_from_name")
  mustBind(libGDK, cast[ptr pointer](addr gdkDisplayBeep), "gdk_display_beep")
  mustBind(libGDK, cast[ptr pointer](addr gdkEventCopy), "gdk_event_copy")
  mustBind(libGDK, cast[ptr pointer](addr gdkEventFree), "gdk_event_free")
  mustBind(libGDK, cast[ptr pointer](addr gdkAtomIntern), "gdk_atom_intern")
  mustBind(libGDK, cast[ptr pointer](addr gdkAtomName), "gdk_atom_name")
  mustBind(libGDK, cast[ptr pointer](addr gdkKeyvalFromName), "gdk_keyval_from_name")
  mustBind(libGDK, cast[ptr pointer](addr gdkUnicodeToKeyval), "gdk_unicode_to_keyval")
  mustBind(libPixbuf, cast[ptr pointer](addr gdkPixbufLoaderNew), "gdk_pixbuf_loader_new")
  mustBind(libPixbuf, cast[ptr pointer](addr gdkPixbufLoaderWrite), "gdk_pixbuf_loader_write")
  mustBind(libPixbuf, cast[ptr pointer](addr gdkPixbufLoaderClose), "gdk_pixbuf_loader_close")
  mustBind(libPixbuf, cast[ptr pointer](addr gdkPixbufLoaderGetPixbuf), "gdk_pixbuf_loader_get_pixbuf")
  mustBind(libPixbuf, cast[ptr pointer](addr gdkPixbufSaveToBufferv), "gdk_pixbuf_save_to_bufferv")
  mustBind(libGTK, cast[ptr pointer](addr gtkInitCheck), "gtk_init_check")
  mustBind(libGTK, cast[ptr pointer](addr gtkMain), "gtk_main")
  mustBind(libGTK, cast[ptr pointer](addr gtkMainQuit), "gtk_main_quit")
  mustBind(libGTK, cast[ptr pointer](addr gtkGetCurrentEventTime), "gtk_get_current_event_time")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowNew), "gtk_window_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetTitle), "gtk_window_set_title")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowGetTitle), "gtk_window_get_title")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetDefaultSize), "gtk_window_set_default_size")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowResize), "gtk_window_resize")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowGetSize), "gtk_window_get_size")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowMove), "gtk_window_move")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowGetPosition), "gtk_window_get_position")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetPosition), "gtk_window_set_position")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetResizable), "gtk_window_set_resizable")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowGetResizable), "gtk_window_get_resizable")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetDecorated), "gtk_window_set_decorated")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetDeletable), "gtk_window_set_deletable")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowGetDeletable), "gtk_window_get_deletable")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetKeepAbove), "gtk_window_set_keep_above")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetSkipTaskbarHint), "gtk_window_set_skip_taskbar_hint")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetTransientFor), "gtk_window_set_transient_for")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetModal), "gtk_window_set_modal")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetGeometryHints), "gtk_window_set_geometry_hints")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowPresent), "gtk_window_present")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowIconify), "gtk_window_iconify")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowDeiconify), "gtk_window_deiconify")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowMaximize), "gtk_window_maximize")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowUnmaximize), "gtk_window_unmaximize")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowFullscreen), "gtk_window_fullscreen")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowUnfullscreen), "gtk_window_unfullscreen")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowIsActive), "gtk_window_is_active")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowIsMaximized), "gtk_window_is_maximized")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowBeginMoveDrag), "gtk_window_begin_move_drag")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowBeginResizeDrag), "gtk_window_begin_resize_drag")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowAddAccelGroup), "gtk_window_add_accel_group")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowRemoveAccelGroup), "gtk_window_remove_accel_group")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetUrgencyHint), "gtk_window_set_urgency_hint")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowStick), "gtk_window_stick")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowUnstick), "gtk_window_unstick")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetIcon), "gtk_window_set_icon")
  mustBind(libGTK, cast[ptr pointer](addr gtkWindowSetDefaultIcon), "gtk_window_set_default_icon")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetShowAll), "gtk_widget_show_all")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetDirection), "gtk_widget_set_direction")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetDefaultDirection), "gtk_widget_set_default_direction")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetShow), "gtk_widget_show")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetHide), "gtk_widget_hide")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetDestroy), "gtk_widget_destroy")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetVisible), "gtk_widget_get_visible")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetMapped), "gtk_widget_get_mapped")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetOpacity), "gtk_widget_set_opacity")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetOpacity), "gtk_widget_get_opacity")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGrabFocus), "gtk_widget_grab_focus")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetHasFocus), "gtk_widget_has_focus")
  mustBind(libGTK, cast[ptr pointer](addr gtkGLAreaNew), "gtk_gl_area_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkGLAreaSetHasAlpha), "gtk_gl_area_set_has_alpha")
  mustBind(libGTK, cast[ptr pointer](addr gtkDrawingAreaNew), "gtk_drawing_area_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkIMMulticontextNew), "gtk_im_multicontext_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetVisual), "gtk_widget_set_visual")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetAppPaintable), "gtk_widget_set_app_paintable")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetScreen), "gtk_widget_get_screen")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetSensitive), "gtk_widget_set_sensitive")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetIsSensitive), "gtk_widget_is_sensitive")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetTooltipText), "gtk_widget_set_tooltip_text")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetAddAccelerator), "gtk_widget_add_accelerator")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetNoShowAll), "gtk_widget_set_no_show_all")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetVisible), "gtk_widget_set_visible")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetMnemonicActivate), "gtk_widget_mnemonic_activate")
  mustBind(libGTK, cast[ptr pointer](addr gtkBoxNew), "gtk_box_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkBoxPackStart), "gtk_box_pack_start")
  mustBind(libGTK, cast[ptr pointer](addr gtkBoxReorderChild), "gtk_box_reorder_child")
  mustBind(libGTK, cast[ptr pointer](addr gtkContainerAdd), "gtk_container_add")
  mustBind(libGTK, cast[ptr pointer](addr gtkContainerRemove), "gtk_container_remove")
  mustBind(libGTK, cast[ptr pointer](addr gtkContainerCheckResize), "gtk_container_check_resize")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuBarNew), "gtk_menu_bar_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuNew), "gtk_menu_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemNewWithLabel), "gtk_menu_item_new_with_label")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemSetLabel), "gtk_menu_item_set_label")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemSetSubmenu), "gtk_menu_item_set_submenu")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemGetSubmenu), "gtk_menu_item_get_submenu")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemGetLabel), "gtk_menu_item_get_label")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuItemActivate), "gtk_menu_item_activate")
  mustBind(libGTK, cast[ptr pointer](addr gtkContainerGetChildren), "gtk_container_get_children")
  mustBind(libGTK, cast[ptr pointer](addr gtkCheckMenuItemNewWithLabel), "gtk_check_menu_item_new_with_label")
  mustBind(libGTK, cast[ptr pointer](addr gtkCheckMenuItemSetActive), "gtk_check_menu_item_set_active")
  mustBind(libGTK, cast[ptr pointer](addr gtkCheckMenuItemSetDrawAsRadio), "gtk_check_menu_item_set_draw_as_radio")
  mustBind(libGTK, cast[ptr pointer](addr gtkSeparatorMenuItemNew), "gtk_separator_menu_item_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuShellAppend), "gtk_menu_shell_append")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuPopupAtPointer), "gtk_menu_popup_at_pointer")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuPopupAtRect), "gtk_menu_popup_at_rect")
  mustBind(libGTK, cast[ptr pointer](addr gtkMenuShellDeactivate), "gtk_menu_shell_deactivate")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetWindow), "gtk_widget_get_window")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetRealize), "gtk_widget_realize")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetAllocation), "gtk_widget_get_allocation")
  mustBind(libGTK, cast[ptr pointer](addr gtkAccelGroupNew), "gtk_accel_group_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserNativeNew), "gtk_file_chooser_native_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkNativeDialogRun), "gtk_native_dialog_run")
  mustBind(libGTK, cast[ptr pointer](addr gtkNativeDialogHide), "gtk_native_dialog_hide")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserSetSelectMultiple), "gtk_file_chooser_set_select_multiple")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserSetShowHidden), "gtk_file_chooser_set_show_hidden")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserSetDoOverwriteConfirm), "gtk_file_chooser_set_do_overwrite_confirmation")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserSetCurrentFolder), "gtk_file_chooser_set_current_folder")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserSetCurrentName), "gtk_file_chooser_set_current_name")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserGetFilenames), "gtk_file_chooser_get_filenames")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserGetFilename), "gtk_file_chooser_get_filename")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileChooserAddFilter), "gtk_file_chooser_add_filter")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileFilterNew), "gtk_file_filter_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileFilterSetName), "gtk_file_filter_set_name")
  mustBind(libGTK, cast[ptr pointer](addr gtkFileFilterAddPattern), "gtk_file_filter_add_pattern")
  mustBind(libGTK, cast[ptr pointer](addr gtkMessageDialogNew), "gtk_message_dialog_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkMessageDialogFormatSecondaryText), "gtk_message_dialog_format_secondary_text")
  mustBind(libGTK, cast[ptr pointer](addr gtkMessageDialogGetMessageArea), "gtk_message_dialog_get_message_area")
  mustBind(libGTK, cast[ptr pointer](addr gtkDialogAddButton), "gtk_dialog_add_button")
  mustBind(libGTK, cast[ptr pointer](addr gtkDialogSetDefaultResponse), "gtk_dialog_set_default_response")
  mustBind(libGTK, cast[ptr pointer](addr gtkDialogRun), "gtk_dialog_run")
  mustBind(libGTK, cast[ptr pointer](addr gtkCheckButtonNewWithLabel), "gtk_check_button_new_with_label")
  mustBind(libGTK, cast[ptr pointer](addr gtkToggleButtonGetActive), "gtk_toggle_button_get_active")
  mustBind(libGTK, cast[ptr pointer](addr gtkToggleButtonSetActive), "gtk_toggle_button_set_active")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardGet), "gtk_clipboard_get")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardSetText), "gtk_clipboard_set_text")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardWaitForText), "gtk_clipboard_wait_for_text")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardWaitForImage), "gtk_clipboard_wait_for_image")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardSetImage), "gtk_clipboard_set_image")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardWaitForContents), "gtk_clipboard_wait_for_contents")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardWaitForTargets), "gtk_clipboard_wait_for_targets")
  mustBind(libGTK, cast[ptr pointer](addr gtkClipboardClear), "gtk_clipboard_clear")
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataGetData), "gtk_selection_data_get_data")
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataGetUris), "gtk_selection_data_get_uris")
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataGetLength), "gtk_selection_data_get_length")
  mustBind(libGTK, cast[ptr pointer](addr gtkSelectionDataFree), "gtk_selection_data_free")
  mustBind(libGTK, cast[ptr pointer](addr gtkSettingsGetDefault), "gtk_settings_get_default")
  mustBind(libGTK, cast[ptr pointer](addr gtkOverlayNew), "gtk_overlay_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkOverlayAddOverlay), "gtk_overlay_add_overlay")
  mustBind(libGTK, cast[ptr pointer](addr gtkHeaderBarNew), "gtk_header_bar_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkHeaderBarSetShowCloseButton), "gtk_header_bar_set_show_close_button")
  mustBind(libGTK, cast[ptr pointer](addr gtkHeaderBarSetHasSubtitle), "gtk_header_bar_set_has_subtitle")
  mustBind(libGTK, cast[ptr pointer](addr gtkHeaderBarSetDecorationLayout), "gtk_header_bar_set_decoration_layout")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetHalign), "gtk_widget_set_halign")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetValign), "gtk_widget_set_valign")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetSetSizeRequest), "gtk_widget_set_size_request")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetPreferredWidth), "gtk_widget_get_preferred_width")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetPreferredHeight), "gtk_widget_get_preferred_height")
  mustBind(libGTK, cast[ptr pointer](addr gtkWidgetGetStyleContext), "gtk_widget_get_style_context")
  mustBind(libGTK, cast[ptr pointer](addr gtkStyleContextAddClass), "gtk_style_context_add_class")
  mustBind(libGTK, cast[ptr pointer](addr gtkStyleContextAddProviderForScreen), "gtk_style_context_add_provider_for_screen")
  mustBind(libGTK, cast[ptr pointer](addr gtkCssProviderNew), "gtk_css_provider_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkCssProviderLoadFromData), "gtk_css_provider_load_from_data")
  mustBind(libGTK, cast[ptr pointer](addr gtkAboutDialogNew), "gtk_about_dialog_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkAboutDialogSetProgramName), "gtk_about_dialog_set_program_name")
  mustBind(libGTK, cast[ptr pointer](addr gtkAboutDialogSetVersion), "gtk_about_dialog_set_version")
  mustBind(libGTK, cast[ptr pointer](addr gtkAboutDialogSetCopyright), "gtk_about_dialog_set_copyright")
  mustBind(libGTK, cast[ptr pointer](addr gtkAboutDialogSetComments), "gtk_about_dialog_set_comments")
  mustBind(libGObject, cast[ptr pointer](addr gTypeCheckInstanceIsA), "g_type_check_instance_is_a")
  mustBind(libGTK, cast[ptr pointer](addr gtkPrintSettingsNew), "gtk_print_settings_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkPrintSettingsSet), "gtk_print_settings_set")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupNew), "gtk_page_setup_new")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetPaperSize), "gtk_page_setup_set_paper_size")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetOrientation), "gtk_page_setup_set_orientation")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetTopMargin), "gtk_page_setup_set_top_margin")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetBottomMargin), "gtk_page_setup_set_bottom_margin")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetLeftMargin), "gtk_page_setup_set_left_margin")
  mustBind(libGTK, cast[ptr pointer](addr gtkPageSetupSetRightMargin), "gtk_page_setup_set_right_margin")
  mustBind(libGTK, cast[ptr pointer](addr gtkPaperSizeNewCustom), "gtk_paper_size_new_custom")
  mustBind(libGTK, cast[ptr pointer](addr gtkPaperSizeFree), "gtk_paper_size_free")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentManagerGetDefault), "gtk_recent_manager_get_default")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentManagerAddItem), "gtk_recent_manager_add_item")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentManagerGetItems), "gtk_recent_manager_get_items")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentInfoGetURI), "gtk_recent_info_get_uri")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentInfoHasApplication), "gtk_recent_info_has_application")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentInfoUnref), "gtk_recent_info_unref")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentManagerRemoveItem), "gtk_recent_manager_remove_item")
  mustBind(libGTK, cast[ptr pointer](addr gtkRecentManagerHasItem), "gtk_recent_manager_has_item")
  mustBind(libCairo, cast[ptr pointer](addr cairoSurfaceWriteToPNGStream), "cairo_surface_write_to_png_stream")
  mustBind(libCairo, cast[ptr pointer](addr cairoSurfaceDestroy), "cairo_surface_destroy")
  if not libIndicator.isNil:
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorNew), "app_indicator_new")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetStatus), "app_indicator_set_status")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetMenu), "app_indicator_set_menu")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetIconFull), "app_indicator_set_icon_full")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetIconThemePath), "app_indicator_set_icon_theme_path")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetTitle), "app_indicator_set_title")
    discard bindFunc(libIndicator, cast[ptr pointer](addr appIndicatorSetLabel), "app_indicator_set_label")
  nil
var webKitLoaded: bool
var webKitErr: ref CatchableError

proc bindCookies*()

proc webKit*(): ref CatchableError =
  ## webKit loads WebKitGTK, JavaScriptCore and libsoup the first time a
  ## window shows a web page or browsing data is cleared, and returns why
  ## they did not load. Windows that show Content need GTK alone: an app
  ## whose windows all do never loads them, which saves it some 75
  ## libraries, 7 MB and 20 ms of startup.
  if webKitLoaded:
    return webKitErr
  webKitLoaded = true
  var e: ref CatchableError
  (libWebKit, e) = openLib("libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37")
  if not e.isNil:
    webKitErr = newException(CatchableError, e.msg &
      " (install WebKitGTK: libwebkit2gtk-4.1-0 on Debian/Ubuntu, webkit2gtk4.1 on Fedora)")
    return webKitErr
  # 4.1 links libsoup 3 and 4.0 libsoup 2.4. Opening the loaded library
  # again returns the same handle, which tells the two apart.
  let (h41, _) = openLib("libwebkit2gtk-4.1.so.0")
  soup3 = not h41.isNil and h41 == libWebKit
  var jsc, soup: string
  if soup3:
    jsc = "libjavascriptcoregtk-4.1.so.0"
    soup = "libsoup-3.0.so.0"
  else:
    jsc = "libjavascriptcoregtk-4.0.so.18"
    soup = "libsoup-2.4.so.1"
  # SoupCookie pointers must never cross Soup ABI generations.
  (libJSC, e) = openLib(jsc)
  if not e.isNil:
    webKitErr = e
    return e
  (libSoup, e) = openLib(soup)
  if not e.isNil:
    webKitErr = e
    return e
  bindCookies()
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebContextGetDefault), "webkit_web_context_get_default")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebContextRegisterURIScheme), "webkit_web_context_register_uri_scheme")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebContextGetSecurityManager), "webkit_web_context_get_security_manager")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebContextGetWebsiteDataManager), "webkit_web_context_get_website_data_manager")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitWebContextSetPreferredLanguages), "webkit_web_context_set_preferred_languages")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebsiteDataManagerClear), "webkit_website_data_manager_clear")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebsiteDataManagerClearFinish), "webkit_website_data_manager_clear_finish")
  mustBind(libWebKit, cast[ptr pointer](addr webkitDownloadGetWebView), "webkit_download_get_web_view")
  mustBind(libWebKit, cast[ptr pointer](addr webkitDownloadGetRequest), "webkit_download_get_request")
  mustBind(libWebKit, cast[ptr pointer](addr webkitDownloadSetDestination), "webkit_download_set_destination")
  mustBind(libWebKit, cast[ptr pointer](addr webkitDownloadSetAllowOverwrite), "webkit_download_set_allow_overwrite")
  mustBind(libWebKit, cast[ptr pointer](addr webkitDownloadCancel), "webkit_download_cancel")
  mustBind(libWebKit, cast[ptr pointer](addr webkitResponsePolicyDecisionGetResponse), "webkit_response_policy_decision_get_response")
  mustBind(libWebKit, cast[ptr pointer](addr webkitResponsePolicyDecisionIsMIMETypeSupported), "webkit_response_policy_decision_is_mime_type_supported")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPolicyDecisionDownload), "webkit_policy_decision_download")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURIResponseGetURI), "webkit_uri_response_get_uri")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURIResponseGetHTTPHeaders), "webkit_uri_response_get_http_headers")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSecurityManagerRegisterSecure), "webkit_security_manager_register_uri_scheme_as_secure")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSecurityManagerRegisterCORS), "webkit_security_manager_register_uri_scheme_as_cors_enabled")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserContentManagerNew), "webkit_user_content_manager_new")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserContentManagerRegisterHandler), "webkit_user_content_manager_register_script_message_handler")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserContentManagerUnregisterHandler), "webkit_user_content_manager_unregister_script_message_handler")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserContentManagerAddScript), "webkit_user_content_manager_add_script")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserContentManagerRemoveAllScripts), "webkit_user_content_manager_remove_all_scripts")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserScriptNew), "webkit_user_script_new")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserScriptUnref), "webkit_user_script_unref")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewNewWithUserContentManager), "webkit_web_view_new_with_user_content_manager")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetSettings), "webkit_web_view_get_settings")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsSetEnableDeveloperExtras), "webkit_settings_set_enable_developer_extras")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsSetUserAgent), "webkit_settings_set_user_agent")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsGetUserAgent), "webkit_settings_get_user_agent")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsSetAllowFileAccessFromFileURLs), "webkit_settings_set_allow_file_access_from_file_urls")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsSetJavascriptCanAccessClipboard), "webkit_settings_set_javascript_can_access_clipboard")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewLoadURI), "webkit_web_view_load_uri")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewLoadHTML), "webkit_web_view_load_html")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewReload), "webkit_web_view_reload")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewReloadBypassCache), "webkit_web_view_reload_bypass_cache")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewStopLoading), "webkit_web_view_stop_loading")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGoBack), "webkit_web_view_go_back")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGoForward), "webkit_web_view_go_forward")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewCanGoBack), "webkit_web_view_can_go_back")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewCanGoForward), "webkit_web_view_can_go_forward")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewIsLoading), "webkit_web_view_is_loading")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetURI), "webkit_web_view_get_uri")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetTitle), "webkit_web_view_get_title")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewSetZoomLevel), "webkit_web_view_set_zoom_level")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetZoomLevel), "webkit_web_view_get_zoom_level")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewSetBackgroundColor), "webkit_web_view_set_background_color")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitWebViewEvaluateJavascript), "webkit_web_view_evaluate_javascript")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitWebViewRunJavascript), "webkit_web_view_run_javascript")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitWebViewCallAsyncJavascriptFunction), "webkit_web_view_call_async_javascript_function")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitWebViewCallAsyncJavascriptFunctionFinish), "webkit_web_view_call_async_javascript_function_finish")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetInspector), "webkit_web_view_get_inspector")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebInspectorShow), "webkit_web_inspector_show")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebInspectorClose), "webkit_web_inspector_close")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebInspectorGetWebView), "webkit_web_inspector_get_web_view")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetSnapshot), "webkit_web_view_get_snapshot")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewGetSnapshotFinish), "webkit_web_view_get_snapshot_finish")
  mustBind(libWebKit, cast[ptr pointer](addr webkitWebViewExecuteEditingCommand), "webkit_web_view_execute_editing_command")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPrintOperationNew), "webkit_print_operation_new")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPrintOperationRunDialog), "webkit_print_operation_run_dialog")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPrintOperationSetPrintSettings), "webkit_print_operation_set_print_settings")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPrintOperationSetPageSetup), "webkit_print_operation_set_page_setup")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPrintOperationPrint), "webkit_print_operation_print")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsGetPrintBackgrounds), "webkit_settings_get_print_backgrounds")
  mustBind(libWebKit, cast[ptr pointer](addr webkitSettingsSetPrintBackgrounds), "webkit_settings_set_print_backgrounds")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserMediaPermissionRequestGetType), "webkit_user_media_permission_request_get_type")
  mustBind(libWebKit, cast[ptr pointer](addr webkitGeolocationPermissionRequestGetType), "webkit_geolocation_permission_request_get_type")
  mustBind(libWebKit, cast[ptr pointer](addr webkitNotificationPermissionRequestGetType), "webkit_notification_permission_request_get_type")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserMediaPermissionIsForAudioDevice), "webkit_user_media_permission_is_for_audio_device")
  mustBind(libWebKit, cast[ptr pointer](addr webkitUserMediaPermissionIsForVideoDevice), "webkit_user_media_permission_is_for_video_device")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPermissionRequestAllow), "webkit_permission_request_allow")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPermissionRequestDeny), "webkit_permission_request_deny")
  mustBind(libWebKit, cast[ptr pointer](addr webkitJavascriptResultGetJSValue), "webkit_javascript_result_get_js_value")
  mustBind(libWebKit, cast[ptr pointer](addr webkitNavigationPolicyDecisionGetNavigationAction), "webkit_navigation_policy_decision_get_navigation_action")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitNavigationPolicyDecisionGetFrameName), "webkit_navigation_policy_decision_get_frame_name")
  mustBind(libWebKit, cast[ptr pointer](addr webkitNavigationActionGetRequest), "webkit_navigation_action_get_request")
  mustBind(libWebKit, cast[ptr pointer](addr webkitNavigationActionGetNavigationType), "webkit_navigation_action_get_navigation_type")
  mustBind(libWebKit, cast[ptr pointer](addr webkitNavigationActionIsUserGesture), "webkit_navigation_action_is_user_gesture")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURIRequestGetURI), "webkit_uri_request_get_uri")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPolicyDecisionUse), "webkit_policy_decision_use")
  mustBind(libWebKit, cast[ptr pointer](addr webkitPolicyDecisionIgnore), "webkit_policy_decision_ignore")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestGetURI), "webkit_uri_scheme_request_get_uri")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestGetWebView), "webkit_uri_scheme_request_get_web_view")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestFinishError), "webkit_uri_scheme_request_finish_error")
  mustBind(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestFinish), "webkit_uri_scheme_request_finish")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestGetHTTPMethod), "webkit_uri_scheme_request_get_http_method")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestGetHTTPHeaders), "webkit_uri_scheme_request_get_http_headers")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestGetHTTPBody), "webkit_uri_scheme_request_get_http_body")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeRequestFinishWithResponse), "webkit_uri_scheme_request_finish_with_response")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeResponseNew), "webkit_uri_scheme_response_new")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeResponseSetStatus), "webkit_uri_scheme_response_set_status")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeResponseSetContentType), "webkit_uri_scheme_response_set_content_type")
  discard bindFunc(libWebKit, cast[ptr pointer](addr webkitURISchemeResponseSetHTTPHeaders), "webkit_uri_scheme_response_set_http_headers")
  mustBind(libJSC, cast[ptr pointer](addr jscValueToString), "jsc_value_to_string")
  mustBind(libSoup, cast[ptr pointer](addr soupMessageHeadersNew), "soup_message_headers_new")
  mustBind(libSoup, cast[ptr pointer](addr soupMessageHeadersGetOne), "soup_message_headers_get_one")
  mustBind(libSoup, cast[ptr pointer](addr soupMessageHeadersAppend), "soup_message_headers_append")
  mustBind(libSoup, cast[ptr pointer](addr soupMessageHeadersForeach), "soup_message_headers_foreach")
  nil

proc connect*(instance: pointer, signal: string, handler, data: pointer): uint64 =
  ## connect connects a signal handler with the given user data.
  gSignalConnectData(instance, cs(signal), handler, data, nil, 0)
