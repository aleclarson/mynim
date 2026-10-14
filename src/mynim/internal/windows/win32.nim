import std/widestrs
import std/unicode


## win32.nim (win32.go): the backend for Windows: Win32 windows
## hosting WebView2, called through the system DLLs (no COM boilerplate
## here; com.nim has that).
##
## System DLLs are loaded from the system directory, never from the
## application directory or the search path.

proc loadLibraryW(name: pointer): uint
  {.importc: "LoadLibraryW", dynlib: "kernel32.dll", stdcall.}
proc getModuleHandleW(name: pointer): uint
  {.importc: "GetModuleHandleW", dynlib: "kernel32.dll", stdcall.}
proc getProcAddress(hmod, name: pointer): pointer
  {.importc: "GetProcAddress", dynlib: "kernel32.dll", stdcall.}
proc getSystemDirectoryW(buf: pointer, n: uint32): uint32
  {.importc: "GetSystemDirectoryW", dynlib: "kernel32.dll", stdcall.}
proc getCurrentThreadId(): uint32
  {.importc: "GetCurrentThreadId", dynlib: "kernel32.dll", stdcall.}

## UTF-16 helpers.

## utf16z is s as a NUL-terminated UTF-16 sequence; NULs inside s are
## dropped. The result must stay reachable during the call it is passed
## to: pass it as cast[pointer](addr utf16z(s)[0]) for the call.
proc utf16z*(s: string): seq[uint16] =
  for r in s.runes:
    let u = uint32(r)
    if u == 0:
      continue
    if u >= 0x10000:
      let u = u - 0x10000
      result.add uint16(0xD800 + (u shr 10))
      result.add uint16(0xDC00 + (u and 0x3FF))
    else:
      result.add uint16(u)
  result.add 0

## u16 converts s to a NUL-terminated UTF-16 string. The buffer is
## alive until the end of the enclosing statement: pass it as u16(s)
## directly in a call's arguments.
template u16*(s: string): pointer =
  cast[pointer](unsafeAddr newWideCString(s)[0])

## u16Seq is u16 on a seq the caller owns: it must outlive the call.
proc u16Seq*(u: openArray[uint16]): pointer =
  if u.len == 0: nil else: cast[pointer](unsafeAddr u[0])

## utf16Units is s in UTF-16, without a terminating NUL.
proc utf16Units*(s: string): seq[uint16] =
  let b = utf16z(s)
  b[0 ..< b.len - 1]

## u16Opt is u16, or nil for an empty string.
proc u16Opt*(s: string): pointer =
  if s == "": nil else: u16(s)

## u16str decodes a UTF-16 sequence to UTF-8.
proc u16str*(u: openArray[uint16]): string =
  var i = 0
  while i < u.len:
    var c = uint32(u[i])
    inc i
    if c >= 0xD800 and c <= 0xDBFF and i < u.len:
      c = 0x10000 + ((c - 0xD800) shl 10) + (uint32(u[i]) - 0xDC00)
      inc i
    result &= $Rune(c)

## wstr reads a NUL-terminated UTF-16 string at a native address.
proc wstr*(p: pointer): string =
  if p.isNil:
    return ""
  let u = cast[ptr UncheckedArray[uint16]](p)
  var n = 0
  while u[n] != 0:
    inc n
  u16str(u.toOpenArray(0, n - 1))

## systemDirectory returns the Windows system directory.
proc systemDirectory*(): string =
  var buf: array[260, uint16]
  let n = getSystemDirectoryW(addr buf[0], 260)
  if n == 0 or int(n) > buf.len:
    return "C:\\Windows\\System32"
  u16str(buf.toOpenArray(0, int(n) - 1))

var sysDir* = systemDirectory()

## systemDLL loads a DLL from the system directory alone.
proc systemDLL*(name: string): uint =
  loadLibraryW(u16(sysDir & "\\" & name))

var
  iphlpapi*, imm32*, oleaut32*, uiaCore*, wtsapi32*: uint
  kernel32* = loadLibraryW(u16("kernel32.dll")) ## a KnownDLL
  user32* = systemDLL("user32.dll")
  gdi32* = systemDLL("gdi32.dll")
  ole32* = systemDLL("ole32.dll")
  shell32* = systemDLL("shell32.dll")
  shlwapi* = systemDLL("shlwapi.dll")
  dwmapi* = systemDLL("dwmapi.dll")
  shcore* = systemDLL("shcore.dll")
  advapi32* = systemDLL("advapi32.dll")
  versionD* = systemDLL("version.dll")
  ntdll* = systemDLL("ntdll.dll")

## bindW resolves name of a DLL to a typed proc var, or leaves nil.
proc bindW*(lib: uint, fn: ptr pointer, name: string) =
  let a = alloc0(name.len + 1)
  copyMem(a, name.cstring, name.len)
  fn[] = getProcAddress(cast[pointer](lib), a)
  dealloc(a)

var procActivateActCtx*: proc(a0, a1: uint): uint {.stdcall.}
var procAdjustWindowRectExForDpi*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procAppendMenuW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procBeginPaint*: proc(a0, a1: uint): uint {.stdcall.}
var procClientToScreen*: proc(a0, a1: uint): uint {.stdcall.}
var procCloseClipboard*: proc(): uint {.stdcall.}
var procCloseHandle*: proc(a0: uint): uint {.stdcall.}
var procCoCreateInstance*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procCoInitializeEx*: proc(a0, a1: uint): uint {.stdcall.}
var procCoTaskMemAlloc*: proc(a0: uint): uint {.stdcall.}
var procCoTaskMemFree*: proc(a0: uint): uint {.stdcall.}
var procCoUninitialize*: proc(): uint {.stdcall.}
var procCreateActCtxW*: proc(a0: uint): uint {.stdcall.}
var procCreateCompatibleBitmap*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procCreateCompatibleDC*: proc(a0: uint): uint {.stdcall.}
var procCreateDIBSection*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procCreateEventW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procCreateFontW*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13: uint): uint {.stdcall.}
var procCreateIconFromResourceEx*: proc(a0, a1, a2, a3, a4, a5, a6: uint): uint {.stdcall.}
var procCreateMenu*: proc(): uint {.stdcall.}
var procCreatePopupMenu*: proc(): uint {.stdcall.}
var procCreateSolidBrush*: proc(a0: uint): uint {.stdcall.}
var procCreateStreamOnHGlobal*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procCreateWindowExW*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11: uint): uint {.stdcall.}
var procCredDeleteW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procCredFree*: proc(a0: uint): uint {.stdcall.}
var procCredReadW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procCredWriteW*: proc(a0, a1: uint): uint {.stdcall.}
var procDefWindowProcW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procDeleteDC*: proc(a0: uint): uint {.stdcall.}
var procDeleteObject*: proc(a0: uint): uint {.stdcall.}
var procDestroyIcon*: proc(a0: uint): uint {.stdcall.}
var procDestroyMenu*: proc(a0: uint): uint {.stdcall.}
var procDestroyWindow*: proc(a0: uint): uint {.stdcall.}
var procDispatchMessageW*: proc(a0: uint): uint {.stdcall.}
var procDoDragDrop*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procDragQueryFileW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procDrawMenuBar*: proc(a0: uint): uint {.stdcall.}
var procDrawTextW*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procDwmExtendFrameIntoClientArea*: proc(a0, a1: uint): uint {.stdcall.}
var procDwmSetWindowAttribute*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procEmptyClipboard*: proc(): uint {.stdcall.}
var procEnableMenuItem*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procEnableWindow*: proc(a0, a1: uint): uint {.stdcall.}
var procEndMenu*: proc(): uint {.stdcall.}
var procEndPaint*: proc(a0, a1: uint): uint {.stdcall.}
var procEnumClipboardFormats*: proc(a0: uint): uint {.stdcall.}
var procEnumDisplayMonitors*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procEnumDisplaySettingsW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procFillRect*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procFlashWindowEx*: proc(a0: uint): uint {.stdcall.}
var procGdiFlush*: proc(): uint {.stdcall.}
var procGetClientRect*: proc(a0, a1: uint): uint {.stdcall.}
var procGetClipboardData*: proc(a0: uint): uint {.stdcall.}
var procGetClipboardFormatNameW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGetCurrentThreadId*: proc(): uint {.stdcall.}
var procGetCursorPos*: proc(a0: uint): uint {.stdcall.}
var procGetDC*: proc(a0: uint): uint {.stdcall.}
var procGetDpiForMonitor*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetDpiForSystem*: proc(): uint {.stdcall.}
var procGetDpiForWindow*: proc(a0: uint): uint {.stdcall.}
var procGetFileVersionInfoSizeW*: proc(a0, a1: uint): uint {.stdcall.}
var procGetFileVersionInfoW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetForegroundWindow*: proc(): uint {.stdcall.}
var procGetHGlobalFromStream*: proc(a0, a1: uint): uint {.stdcall.}
var procGetKeyState*: proc(a0: uint): uint {.stdcall.}
var procGetLastInputInfo*: proc(a0: uint): uint {.stdcall.}
var procGetLocaleInfoEx*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetMenuBarInfo*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetMenuItemCount*: proc(a0: uint): uint {.stdcall.}
var procGetMenuItemID*: proc(a0, a1: uint): uint {.stdcall.}
var procGetMenuState*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGetMenuStringW*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procGetMessageW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetModuleHandleW*: proc(a0: uint): uint {.stdcall.}
var procGetMonitorInfoW*: proc(a0, a1: uint): uint {.stdcall.}
var procGetNetworkConnectivityHint*: proc(a0: uint): uint {.stdcall.}
var procGetNextWindow*: proc(a0, a1: uint): uint {.stdcall.}
var procGetObjectW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGetPixel*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGetProcAddress*: proc(a0, a1: uint): uint {.stdcall.}
var procGetSubMenu*: proc(a0, a1: uint): uint {.stdcall.}
var procGetSystemMenu*: proc(a0, a1: uint): uint {.stdcall.}
var procGetSystemMetricsForDpi*: proc(a0, a1: uint): uint {.stdcall.}
var procGetSystemPowerStatus*: proc(a0: uint): uint {.stdcall.}
var procGetTextFaceW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGetTickCount*: proc(): uint {.stdcall.}
var procGetUserDefaultUILanguage*: proc(): uint {.stdcall.}
var procGetUserPreferredUILanguages*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procGetWindowDC*: proc(a0: uint): uint {.stdcall.}
var procGetWindowLongPtrW*: proc(a0, a1: uint): uint {.stdcall.}
var procGetWindowPlacement*: proc(a0, a1: uint): uint {.stdcall.}
var procGetWindowRect*: proc(a0, a1: uint): uint {.stdcall.}
var procGetWindowTextLengthW*: proc(a0: uint): uint {.stdcall.}
var procGetWindowTextW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procGlobalAlloc*: proc(a0, a1: uint): uint {.stdcall.}
var procGlobalFree*: proc(a0: uint): uint {.stdcall.}
var procGlobalLock*: proc(a0: uint): uint {.stdcall.}
var procGlobalSize*: proc(a0: uint): uint {.stdcall.}
var procGlobalUnlock*: proc(a0: uint): uint {.stdcall.}
var procImmAssociateContextEx*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procImmGetCompositionStrW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procImmGetContext*: proc(a0: uint): uint {.stdcall.}
var procImmNotifyIME*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procImmReleaseContext*: proc(a0, a1: uint): uint {.stdcall.}
var procImmSetCandidateWindow*: proc(a0, a1: uint): uint {.stdcall.}
var procImmSetCompositionWnd*: proc(a0, a1: uint): uint {.stdcall.}
var procInvalidateRectW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procIsClipboardFormatAvailable*: proc(a0: uint): uint {.stdcall.}
var procIsIconic*: proc(a0: uint): uint {.stdcall.}
var procIsWindowVisible*: proc(a0: uint): uint {.stdcall.}
var procIsZoomed*: proc(a0: uint): uint {.stdcall.}
var procKillTimer*: proc(a0, a1: uint): uint {.stdcall.}
var procLCIDToLocaleName*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procLoadCursorW*: proc(a0, a1: uint): uint {.stdcall.}
var procLoadIconW*: proc(a0, a1: uint): uint {.stdcall.}
var procLoadLibraryExW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procMessageBeep*: proc(a0: uint): uint {.stdcall.}
var procMessageBoxW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procMonitorFromPoint*: proc(a0, a1: uint): uint {.stdcall.}
var procMonitorFromRect*: proc(a0, a1: uint): uint {.stdcall.}
var procMonitorFromWindow*: proc(a0, a1: uint): uint {.stdcall.}
var procMsgWaitForMultipleObjectsEx*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procNotifyNetworkConnectivityHintChange*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procNotifyWinEvent*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procOleDuplicateData*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procOleFlushClipboard*: proc(): uint {.stdcall.}
var procOleInitialize*: proc(a0: uint): uint {.stdcall.}
var procOleIsCurrentClipboard*: proc(a0: uint): uint {.stdcall.}
var procOleSetClipboard*: proc(a0: uint): uint {.stdcall.}
var procOpenClipboard*: proc(a0: uint): uint {.stdcall.}
var procPeekMessageW*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procPostMessageW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procPostQuitMessage*: proc(a0: uint): uint {.stdcall.}
var procPowerClearRequest*: proc(a0, a1: uint): uint {.stdcall.}
var procPowerCreateRequest*: proc(a0: uint): uint {.stdcall.}
var procPowerSetRequest*: proc(a0, a1: uint): uint {.stdcall.}
var procPrintWindow*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procRedrawWindow*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procRegCloseKey*: proc(a0: uint): uint {.stdcall.}
var procRegCreateKeyExW*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8: uint): uint {.stdcall.}
var procRegDeleteTreeW*: proc(a0, a1: uint): uint {.stdcall.}
var procRegDeleteValueW*: proc(a0, a1: uint): uint {.stdcall.}
var procRegOpenKeyExW*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procRegQueryValueExW*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procRegSetValueExW*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procRegisterClassExW*: proc(a0: uint): uint {.stdcall.}
var procRegisterClipboardFormatW*: proc(a0: uint): uint {.stdcall.}
var procRegisterDragDrop*: proc(a0, a1: uint): uint {.stdcall.}
var procRegisterHotKey*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procRegisterWindowMessageW*: proc(a0: uint): uint {.stdcall.}
var procReleaseCapture*: proc(): uint {.stdcall.}
var procReleaseDC*: proc(a0, a1: uint): uint {.stdcall.}
var procReleaseStgMedium*: proc(a0: uint): uint {.stdcall.}
var procRemoveMenu*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procReplaceFileW*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procRevokeDragDrop*: proc(a0: uint): uint {.stdcall.}
var procRtlGetVersion*: proc(a0: uint): uint {.stdcall.}
var procSHAddToRecentDocs*: proc(a0, a1: uint): uint {.stdcall.}
var procSHCreateItemFromParsingName*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procSHCreateMemStream*: proc(a0, a1: uint): uint {.stdcall.}
var procSHFileOperationW*: proc(a0: uint): uint {.stdcall.}
var procSHGetKnownFolderItem*: proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
var procSafeArrayCreateVector*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procSafeArrayPutElement*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procScreenToClient*: proc(a0, a1: uint): uint {.stdcall.}
var procSelectObject*: proc(a0, a1: uint): uint {.stdcall.}
var procSendMessageW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procSetBkMode*: proc(a0, a1: uint): uint {.stdcall.}
var procSetCapture*: proc(a0: uint): uint {.stdcall.}
var procSetClipboardData*: proc(a0, a1: uint): uint {.stdcall.}
var procSetCursor*: proc(a0: uint): uint {.stdcall.}
var procSetDIBitsToDevice*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11: uint): uint {.stdcall.}
var procSetEvent*: proc(a0: uint): uint {.stdcall.}
var procSetFocus*: proc(a0: uint): uint {.stdcall.}
var procSetForegroundWindow*: proc(a0: uint): uint {.stdcall.}
var procSetLayeredWindowAttributes*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procSetMenu*: proc(a0, a1: uint): uint {.stdcall.}
var procSetMenuItemInfoW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procSetProcessDpiAwarenessContext*: proc(a0: uint): uint {.stdcall.}
var procSetProcessPreferredUILanguages*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procSetTextColor*: proc(a0, a1: uint): uint {.stdcall.}
var procSetTimer*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procSetWindowDisplayAffinity*: proc(a0, a1: uint): uint {.stdcall.}
var procSetWindowLongPtrW*: proc(a0, a1, a2: uint): uint {.stdcall.}
var procSetWindowPlacement*: proc(a0, a1: uint): uint {.stdcall.}
var procSetWindowPos*: proc(a0, a1, a2, a3, a4, a5, a6: uint): uint {.stdcall.}
var procSetWindowTextW*: proc(a0, a1: uint): uint {.stdcall.}
var procShellExecuteW*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procShellNotifyIconGetRect*: proc(a0, a1: uint): uint {.stdcall.}
var procShellNotifyIconW*: proc(a0, a1: uint): uint {.stdcall.}
var procShowWindow*: proc(a0, a1: uint): uint {.stdcall.}
var procSysAllocString*: proc(a0: uint): uint {.stdcall.}
var procSysFreeString*: proc(a0: uint): uint {.stdcall.}
var procSystemParametersInfoW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procTrackMouseEvent*: proc(a0: uint): uint {.stdcall.}
var procTrackPopupMenuEx*: proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
var procTranslateMessage*: proc(a0: uint): uint {.stdcall.}
var procUiaClientsAreListening*: proc(): uint {.stdcall.}
var procUiaDisconnectProvider*: proc(a0: uint): uint {.stdcall.}
var procUiaGetReservedMixedAttributeValue*: proc(a0: uint): uint {.stdcall.}
var procUiaGetReservedNotSupportedValue*: proc(a0: uint): uint {.stdcall.}
var procUiaHostProviderFromHwnd*: proc(a0, a1: uint): uint {.stdcall.}
var procUiaRaiseAutomationEvent*: proc(a0, a1: uint): uint {.stdcall.}
var procUiaRaiseAutomationPropertyChangedEvent*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procUiaRaiseStructureChangedEvent*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procUiaReturnRawElementProvider*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procUnregisterHotKey*: proc(a0, a1: uint): uint {.stdcall.}
var procUpdateLayeredWindow*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8: uint): uint {.stdcall.}
var procVariantClear*: proc(a0: uint): uint {.stdcall.}
var procVerQueryValueW*: proc(a0, a1, a2, a3: uint): uint {.stdcall.}
var procWTSRegisterSessionNotification*: proc(a0, a1: uint): uint {.stdcall.}
var procWaitForSingleObject*: proc(a0, a1: uint): uint {.stdcall.}

proc loadWin32*() =
  iphlpapi = systemDLL("iphlpapi.dll")
  imm32 = systemDLL("imm32.dll")
  oleaut32 = systemDLL("oleaut32.dll")
  uiaCore = systemDLL("uiautomationcore.dll")
  wtsapi32 = systemDLL("wtsapi32.dll")
  bindW(kernel32, cast[ptr pointer](addr procActivateActCtx), "ActivateActCtx")
  bindW(user32, cast[ptr pointer](addr procAdjustWindowRectExForDpi), "AdjustWindowRectExForDpi")
  bindW(user32, cast[ptr pointer](addr procAppendMenuW), "AppendMenuW")
  bindW(user32, cast[ptr pointer](addr procBeginPaint), "BeginPaint")
  bindW(user32, cast[ptr pointer](addr procClientToScreen), "ClientToScreen")
  bindW(user32, cast[ptr pointer](addr procCloseClipboard), "CloseClipboard")
  bindW(kernel32, cast[ptr pointer](addr procCloseHandle), "CloseHandle")
  bindW(ole32, cast[ptr pointer](addr procCoCreateInstance), "CoCreateInstance")
  bindW(ole32, cast[ptr pointer](addr procCoInitializeEx), "CoInitializeEx")
  bindW(ole32, cast[ptr pointer](addr procCoTaskMemAlloc), "CoTaskMemAlloc")
  bindW(ole32, cast[ptr pointer](addr procCoTaskMemFree), "CoTaskMemFree")
  bindW(ole32, cast[ptr pointer](addr procCoUninitialize), "CoUninitialize")
  bindW(kernel32, cast[ptr pointer](addr procCreateActCtxW), "CreateActCtxW")
  bindW(gdi32, cast[ptr pointer](addr procCreateCompatibleBitmap), "CreateCompatibleBitmap")
  bindW(gdi32, cast[ptr pointer](addr procCreateCompatibleDC), "CreateCompatibleDC")
  bindW(gdi32, cast[ptr pointer](addr procCreateDIBSection), "CreateDIBSection")
  bindW(kernel32, cast[ptr pointer](addr procCreateEventW), "CreateEventW")
  bindW(gdi32, cast[ptr pointer](addr procCreateFontW), "CreateFontW")
  bindW(user32, cast[ptr pointer](addr procCreateIconFromResourceEx), "CreateIconFromResourceEx")
  bindW(user32, cast[ptr pointer](addr procCreateMenu), "CreateMenu")
  bindW(user32, cast[ptr pointer](addr procCreatePopupMenu), "CreatePopupMenu")
  bindW(gdi32, cast[ptr pointer](addr procCreateSolidBrush), "CreateSolidBrush")
  bindW(ole32, cast[ptr pointer](addr procCreateStreamOnHGlobal), "CreateStreamOnHGlobal")
  bindW(user32, cast[ptr pointer](addr procCreateWindowExW), "CreateWindowExW")
  bindW(advapi32, cast[ptr pointer](addr procCredDeleteW), "CredDeleteW")
  bindW(advapi32, cast[ptr pointer](addr procCredFree), "CredFree")
  bindW(advapi32, cast[ptr pointer](addr procCredReadW), "CredReadW")
  bindW(advapi32, cast[ptr pointer](addr procCredWriteW), "CredWriteW")
  bindW(user32, cast[ptr pointer](addr procDefWindowProcW), "DefWindowProcW")
  bindW(gdi32, cast[ptr pointer](addr procDeleteDC), "DeleteDC")
  bindW(gdi32, cast[ptr pointer](addr procDeleteObject), "DeleteObject")
  bindW(user32, cast[ptr pointer](addr procDestroyIcon), "DestroyIcon")
  bindW(user32, cast[ptr pointer](addr procDestroyMenu), "DestroyMenu")
  bindW(user32, cast[ptr pointer](addr procDestroyWindow), "DestroyWindow")
  bindW(user32, cast[ptr pointer](addr procDispatchMessageW), "DispatchMessageW")
  bindW(ole32, cast[ptr pointer](addr procDoDragDrop), "DoDragDrop")
  bindW(shell32, cast[ptr pointer](addr procDragQueryFileW), "DragQueryFileW")
  bindW(user32, cast[ptr pointer](addr procDrawMenuBar), "DrawMenuBar")
  bindW(user32, cast[ptr pointer](addr procDrawTextW), "DrawTextW")
  bindW(dwmapi, cast[ptr pointer](addr procDwmExtendFrameIntoClientArea), "DwmExtendFrameIntoClientArea")
  bindW(dwmapi, cast[ptr pointer](addr procDwmSetWindowAttribute), "DwmSetWindowAttribute")
  bindW(user32, cast[ptr pointer](addr procEmptyClipboard), "EmptyClipboard")
  bindW(user32, cast[ptr pointer](addr procEnableMenuItem), "EnableMenuItem")
  bindW(user32, cast[ptr pointer](addr procEnableWindow), "EnableWindow")
  bindW(user32, cast[ptr pointer](addr procEndMenu), "EndMenu")
  bindW(user32, cast[ptr pointer](addr procEndPaint), "EndPaint")
  bindW(user32, cast[ptr pointer](addr procEnumClipboardFormats), "EnumClipboardFormats")
  bindW(user32, cast[ptr pointer](addr procEnumDisplayMonitors), "EnumDisplayMonitors")
  bindW(user32, cast[ptr pointer](addr procEnumDisplaySettingsW), "EnumDisplaySettingsW")
  bindW(user32, cast[ptr pointer](addr procFillRect), "FillRect")
  bindW(user32, cast[ptr pointer](addr procFlashWindowEx), "FlashWindowEx")
  bindW(gdi32, cast[ptr pointer](addr procGdiFlush), "GdiFlush")
  bindW(user32, cast[ptr pointer](addr procGetClientRect), "GetClientRect")
  bindW(user32, cast[ptr pointer](addr procGetClipboardData), "GetClipboardData")
  bindW(user32, cast[ptr pointer](addr procGetClipboardFormatNameW), "GetClipboardFormatNameW")
  bindW(kernel32, cast[ptr pointer](addr procGetCurrentThreadId), "GetCurrentThreadId")
  bindW(user32, cast[ptr pointer](addr procGetCursorPos), "GetCursorPos")
  bindW(user32, cast[ptr pointer](addr procGetDC), "GetDC")
  bindW(shcore, cast[ptr pointer](addr procGetDpiForMonitor), "GetDpiForMonitor")
  bindW(user32, cast[ptr pointer](addr procGetDpiForSystem), "GetDpiForSystem")
  bindW(user32, cast[ptr pointer](addr procGetDpiForWindow), "GetDpiForWindow")
  bindW(versionD, cast[ptr pointer](addr procGetFileVersionInfoSizeW), "GetFileVersionInfoSizeW")
  bindW(versionD, cast[ptr pointer](addr procGetFileVersionInfoW), "GetFileVersionInfoW")
  bindW(user32, cast[ptr pointer](addr procGetForegroundWindow), "GetForegroundWindow")
  bindW(ole32, cast[ptr pointer](addr procGetHGlobalFromStream), "GetHGlobalFromStream")
  bindW(user32, cast[ptr pointer](addr procGetKeyState), "GetKeyState")
  bindW(user32, cast[ptr pointer](addr procGetLastInputInfo), "GetLastInputInfo")
  bindW(kernel32, cast[ptr pointer](addr procGetLocaleInfoEx), "GetLocaleInfoEx")
  bindW(user32, cast[ptr pointer](addr procGetMenuBarInfo), "GetMenuBarInfo")
  bindW(user32, cast[ptr pointer](addr procGetMenuItemCount), "GetMenuItemCount")
  bindW(user32, cast[ptr pointer](addr procGetMenuItemID), "GetMenuItemID")
  bindW(user32, cast[ptr pointer](addr procGetMenuState), "GetMenuState")
  bindW(user32, cast[ptr pointer](addr procGetMenuStringW), "GetMenuStringW")
  bindW(user32, cast[ptr pointer](addr procGetMessageW), "GetMessageW")
  bindW(kernel32, cast[ptr pointer](addr procGetModuleHandleW), "GetModuleHandleW")
  bindW(user32, cast[ptr pointer](addr procGetMonitorInfoW), "GetMonitorInfoW")
  bindW(iphlpapi, cast[ptr pointer](addr procGetNetworkConnectivityHint), "GetNetworkConnectivityHint")
  bindW(user32, cast[ptr pointer](addr procGetNextWindow), "GetWindow")
  bindW(gdi32, cast[ptr pointer](addr procGetObjectW), "GetObjectW")
  bindW(gdi32, cast[ptr pointer](addr procGetPixel), "GetPixel")
  bindW(kernel32, cast[ptr pointer](addr procGetProcAddress), "GetProcAddress")
  bindW(user32, cast[ptr pointer](addr procGetSubMenu), "GetSubMenu")
  bindW(user32, cast[ptr pointer](addr procGetSystemMenu), "GetSystemMenu")
  bindW(user32, cast[ptr pointer](addr procGetSystemMetricsForDpi), "GetSystemMetricsForDpi")
  bindW(kernel32, cast[ptr pointer](addr procGetSystemPowerStatus), "GetSystemPowerStatus")
  bindW(gdi32, cast[ptr pointer](addr procGetTextFaceW), "GetTextFaceW")
  bindW(kernel32, cast[ptr pointer](addr procGetTickCount), "GetTickCount")
  bindW(kernel32, cast[ptr pointer](addr procGetUserDefaultUILanguage), "GetUserDefaultUILanguage")
  bindW(kernel32, cast[ptr pointer](addr procGetUserPreferredUILanguages), "GetUserPreferredUILanguages")
  bindW(user32, cast[ptr pointer](addr procGetWindowDC), "GetWindowDC")
  bindW(user32, cast[ptr pointer](addr procGetWindowLongPtrW), "GetWindowLongPtrW")
  bindW(user32, cast[ptr pointer](addr procGetWindowPlacement), "GetWindowPlacement")
  bindW(user32, cast[ptr pointer](addr procGetWindowRect), "GetWindowRect")
  bindW(user32, cast[ptr pointer](addr procGetWindowTextLengthW), "GetWindowTextLengthW")
  bindW(user32, cast[ptr pointer](addr procGetWindowTextW), "GetWindowTextW")
  bindW(kernel32, cast[ptr pointer](addr procGlobalAlloc), "GlobalAlloc")
  bindW(kernel32, cast[ptr pointer](addr procGlobalFree), "GlobalFree")
  bindW(kernel32, cast[ptr pointer](addr procGlobalLock), "GlobalLock")
  bindW(kernel32, cast[ptr pointer](addr procGlobalSize), "GlobalSize")
  bindW(kernel32, cast[ptr pointer](addr procGlobalUnlock), "GlobalUnlock")
  bindW(imm32, cast[ptr pointer](addr procImmAssociateContextEx), "ImmAssociateContextEx")
  bindW(imm32, cast[ptr pointer](addr procImmGetCompositionStrW), "ImmGetCompositionStringW")
  bindW(imm32, cast[ptr pointer](addr procImmGetContext), "ImmGetContext")
  bindW(imm32, cast[ptr pointer](addr procImmNotifyIME), "ImmNotifyIME")
  bindW(imm32, cast[ptr pointer](addr procImmReleaseContext), "ImmReleaseContext")
  bindW(imm32, cast[ptr pointer](addr procImmSetCandidateWindow), "ImmSetCandidateWindow")
  bindW(imm32, cast[ptr pointer](addr procImmSetCompositionWnd), "ImmSetCompositionWindow")
  bindW(user32, cast[ptr pointer](addr procInvalidateRectW), "InvalidateRect")
  bindW(user32, cast[ptr pointer](addr procIsClipboardFormatAvailable), "IsClipboardFormatAvailable")
  bindW(user32, cast[ptr pointer](addr procIsIconic), "IsIconic")
  bindW(user32, cast[ptr pointer](addr procIsWindowVisible), "IsWindowVisible")
  bindW(user32, cast[ptr pointer](addr procIsZoomed), "IsZoomed")
  bindW(user32, cast[ptr pointer](addr procKillTimer), "KillTimer")
  bindW(kernel32, cast[ptr pointer](addr procLCIDToLocaleName), "LCIDToLocaleName")
  bindW(user32, cast[ptr pointer](addr procLoadCursorW), "LoadCursorW")
  bindW(user32, cast[ptr pointer](addr procLoadIconW), "LoadIconW")
  bindW(kernel32, cast[ptr pointer](addr procLoadLibraryExW), "LoadLibraryExW")
  bindW(user32, cast[ptr pointer](addr procMessageBeep), "MessageBeep")
  bindW(user32, cast[ptr pointer](addr procMessageBoxW), "MessageBoxW")
  bindW(user32, cast[ptr pointer](addr procMonitorFromPoint), "MonitorFromPoint")
  bindW(user32, cast[ptr pointer](addr procMonitorFromRect), "MonitorFromRect")
  bindW(user32, cast[ptr pointer](addr procMonitorFromWindow), "MonitorFromWindow")
  bindW(user32, cast[ptr pointer](addr procMsgWaitForMultipleObjectsEx), "MsgWaitForMultipleObjectsEx")
  bindW(iphlpapi, cast[ptr pointer](addr procNotifyNetworkConnectivityHintChange), "NotifyNetworkConnectivityHintChange")
  bindW(user32, cast[ptr pointer](addr procNotifyWinEvent), "NotifyWinEvent")
  bindW(ole32, cast[ptr pointer](addr procOleDuplicateData), "OleDuplicateData")
  bindW(ole32, cast[ptr pointer](addr procOleFlushClipboard), "OleFlushClipboard")
  bindW(ole32, cast[ptr pointer](addr procOleInitialize), "OleInitialize")
  bindW(ole32, cast[ptr pointer](addr procOleIsCurrentClipboard), "OleIsCurrentClipboard")
  bindW(ole32, cast[ptr pointer](addr procOleSetClipboard), "OleSetClipboard")
  bindW(user32, cast[ptr pointer](addr procOpenClipboard), "OpenClipboard")
  bindW(user32, cast[ptr pointer](addr procPeekMessageW), "PeekMessageW")
  bindW(user32, cast[ptr pointer](addr procPostMessageW), "PostMessageW")
  bindW(user32, cast[ptr pointer](addr procPostQuitMessage), "PostQuitMessage")
  bindW(kernel32, cast[ptr pointer](addr procPowerClearRequest), "PowerClearRequest")
  bindW(kernel32, cast[ptr pointer](addr procPowerCreateRequest), "PowerCreateRequest")
  bindW(kernel32, cast[ptr pointer](addr procPowerSetRequest), "PowerSetRequest")
  bindW(user32, cast[ptr pointer](addr procPrintWindow), "PrintWindow")
  bindW(user32, cast[ptr pointer](addr procRedrawWindow), "RedrawWindow")
  bindW(advapi32, cast[ptr pointer](addr procRegCloseKey), "RegCloseKey")
  bindW(advapi32, cast[ptr pointer](addr procRegCreateKeyExW), "RegCreateKeyExW")
  bindW(advapi32, cast[ptr pointer](addr procRegDeleteTreeW), "RegDeleteTreeW")
  bindW(advapi32, cast[ptr pointer](addr procRegDeleteValueW), "RegDeleteValueW")
  bindW(advapi32, cast[ptr pointer](addr procRegOpenKeyExW), "RegOpenKeyExW")
  bindW(advapi32, cast[ptr pointer](addr procRegQueryValueExW), "RegQueryValueExW")
  bindW(advapi32, cast[ptr pointer](addr procRegSetValueExW), "RegSetValueExW")
  bindW(user32, cast[ptr pointer](addr procRegisterClassExW), "RegisterClassExW")
  bindW(user32, cast[ptr pointer](addr procRegisterClipboardFormatW), "RegisterClipboardFormatW")
  bindW(ole32, cast[ptr pointer](addr procRegisterDragDrop), "RegisterDragDrop")
  bindW(user32, cast[ptr pointer](addr procRegisterHotKey), "RegisterHotKey")
  bindW(user32, cast[ptr pointer](addr procRegisterWindowMessageW), "RegisterWindowMessageW")
  bindW(user32, cast[ptr pointer](addr procReleaseCapture), "ReleaseCapture")
  bindW(user32, cast[ptr pointer](addr procReleaseDC), "ReleaseDC")
  bindW(ole32, cast[ptr pointer](addr procReleaseStgMedium), "ReleaseStgMedium")
  bindW(user32, cast[ptr pointer](addr procRemoveMenu), "RemoveMenu")
  bindW(kernel32, cast[ptr pointer](addr procReplaceFileW), "ReplaceFileW")
  bindW(ole32, cast[ptr pointer](addr procRevokeDragDrop), "RevokeDragDrop")
  bindW(ntdll, cast[ptr pointer](addr procRtlGetVersion), "RtlGetVersion")
  bindW(shell32, cast[ptr pointer](addr procSHAddToRecentDocs), "SHAddToRecentDocs")
  bindW(shell32, cast[ptr pointer](addr procSHCreateItemFromParsingName), "SHCreateItemFromParsingName")
  bindW(shlwapi, cast[ptr pointer](addr procSHCreateMemStream), "SHCreateMemStream")
  bindW(shell32, cast[ptr pointer](addr procSHFileOperationW), "SHFileOperationW")
  bindW(shell32, cast[ptr pointer](addr procSHGetKnownFolderItem), "SHGetKnownFolderItem")
  bindW(oleaut32, cast[ptr pointer](addr procSafeArrayCreateVector), "SafeArrayCreateVector")
  bindW(oleaut32, cast[ptr pointer](addr procSafeArrayPutElement), "SafeArrayPutElement")
  bindW(user32, cast[ptr pointer](addr procScreenToClient), "ScreenToClient")
  bindW(gdi32, cast[ptr pointer](addr procSelectObject), "SelectObject")
  bindW(user32, cast[ptr pointer](addr procSendMessageW), "SendMessageW")
  bindW(gdi32, cast[ptr pointer](addr procSetBkMode), "SetBkMode")
  bindW(user32, cast[ptr pointer](addr procSetCapture), "SetCapture")
  bindW(user32, cast[ptr pointer](addr procSetClipboardData), "SetClipboardData")
  bindW(user32, cast[ptr pointer](addr procSetCursor), "SetCursor")
  bindW(gdi32, cast[ptr pointer](addr procSetDIBitsToDevice), "SetDIBitsToDevice")
  bindW(kernel32, cast[ptr pointer](addr procSetEvent), "SetEvent")
  bindW(user32, cast[ptr pointer](addr procSetFocus), "SetFocus")
  bindW(user32, cast[ptr pointer](addr procSetForegroundWindow), "SetForegroundWindow")
  bindW(user32, cast[ptr pointer](addr procSetLayeredWindowAttributes), "SetLayeredWindowAttributes")
  bindW(user32, cast[ptr pointer](addr procSetMenu), "SetMenu")
  bindW(user32, cast[ptr pointer](addr procSetMenuItemInfoW), "SetMenuItemInfoW")
  bindW(user32, cast[ptr pointer](addr procSetProcessDpiAwarenessContext), "SetProcessDpiAwarenessContext")
  bindW(kernel32, cast[ptr pointer](addr procSetProcessPreferredUILanguages), "SetProcessPreferredUILanguages")
  bindW(gdi32, cast[ptr pointer](addr procSetTextColor), "SetTextColor")
  bindW(user32, cast[ptr pointer](addr procSetTimer), "SetTimer")
  bindW(user32, cast[ptr pointer](addr procSetWindowDisplayAffinity), "SetWindowDisplayAffinity")
  bindW(user32, cast[ptr pointer](addr procSetWindowLongPtrW), "SetWindowLongPtrW")
  bindW(user32, cast[ptr pointer](addr procSetWindowPlacement), "SetWindowPlacement")
  bindW(user32, cast[ptr pointer](addr procSetWindowPos), "SetWindowPos")
  bindW(user32, cast[ptr pointer](addr procSetWindowTextW), "SetWindowTextW")
  bindW(shell32, cast[ptr pointer](addr procShellExecuteW), "ShellExecuteW")
  bindW(shell32, cast[ptr pointer](addr procShellNotifyIconGetRect), "Shell_NotifyIconGetRect")
  bindW(shell32, cast[ptr pointer](addr procShellNotifyIconW), "Shell_NotifyIconW")
  bindW(user32, cast[ptr pointer](addr procShowWindow), "ShowWindow")
  bindW(oleaut32, cast[ptr pointer](addr procSysAllocString), "SysAllocString")
  bindW(oleaut32, cast[ptr pointer](addr procSysFreeString), "SysFreeString")
  bindW(user32, cast[ptr pointer](addr procSystemParametersInfoW), "SystemParametersInfoW")
  bindW(user32, cast[ptr pointer](addr procTrackMouseEvent), "TrackMouseEvent")
  bindW(user32, cast[ptr pointer](addr procTrackPopupMenuEx), "TrackPopupMenuEx")
  bindW(user32, cast[ptr pointer](addr procTranslateMessage), "TranslateMessage")
  bindW(uiaCore, cast[ptr pointer](addr procUiaClientsAreListening), "UiaClientsAreListening")
  bindW(uiaCore, cast[ptr pointer](addr procUiaDisconnectProvider), "UiaDisconnectProvider")
  bindW(uiaCore, cast[ptr pointer](addr procUiaGetReservedMixedAttributeValue), "UiaGetReservedMixedAttributeValue")
  bindW(uiaCore, cast[ptr pointer](addr procUiaGetReservedNotSupportedValue), "UiaGetReservedNotSupportedValue")
  bindW(uiaCore, cast[ptr pointer](addr procUiaHostProviderFromHwnd), "UiaHostProviderFromHwnd")
  bindW(uiaCore, cast[ptr pointer](addr procUiaRaiseAutomationEvent), "UiaRaiseAutomationEvent")
  bindW(uiaCore, cast[ptr pointer](addr procUiaRaiseAutomationPropertyChangedEvent), "UiaRaiseAutomationPropertyChangedEvent")
  bindW(uiaCore, cast[ptr pointer](addr procUiaRaiseStructureChangedEvent), "UiaRaiseStructureChangedEvent")
  bindW(uiaCore, cast[ptr pointer](addr procUiaReturnRawElementProvider), "UiaReturnRawElementProvider")
  bindW(user32, cast[ptr pointer](addr procUnregisterHotKey), "UnregisterHotKey")
  bindW(user32, cast[ptr pointer](addr procUpdateLayeredWindow), "UpdateLayeredWindow")
  bindW(oleaut32, cast[ptr pointer](addr procVariantClear), "VariantClear")
  bindW(versionD, cast[ptr pointer](addr procVerQueryValueW), "VerQueryValueW")
  bindW(wtsapi32, cast[ptr pointer](addr procWTSRegisterSessionNotification), "WTSRegisterSessionNotification")
  bindW(kernel32, cast[ptr pointer](addr procWaitForSingleObject), "WaitForSingleObject")

## takeWstr reads a string allocated with CoTaskMemAlloc and frees it.
proc takeWstr*(p: pointer): string =
  let s = wstr(p)
  if not p.isNil:
    discard procCoTaskMemFree(cast[uint](p))
  s

proc loword*(v: uint): uint16 = uint16(v)
proc hiword*(v: uint): uint16 = uint16(v shr 16)

## getXParam and getYParam decode the signed coordinates of an lParam.
proc getXParam*(v: uint): int32 = int32(int16(loword(v)))
proc getYParam*(v: uint): int32 = int32(int16(hiword(v)))

proc currentThreadID*(): uint32 = getCurrentThreadId()

proc instance*(): uint = getModuleHandleW(nil)

proc windowLong*(hwnd: uint, index: int32): uint =
  procGetWindowLongPtrW(hwnd, uint(uint64(uint32(index))))
proc setWindowLong*(hwnd: uint, index: int32, v: uint) =
  discard procSetWindowLongPtrW(hwnd, uint(uint64(uint32(index))), v)

proc postMessage*(hwnd: uint, m: uint32, w, l: uint) =
  discard procPostMessageW(hwnd, m, w, l)

## has reports whether an optional API exists on this version of
## Windows.
proc has*(p: pointer): bool = not p.isNil

## dpiOf returns the DPI of the window, or the system's.
proc dpiOf*(hwnd: uint): int =
  if hwnd != 0 and not procGetDpiForWindow.isNil:
    let d = procGetDpiForWindow(hwnd)
    if d != 0:
      return int(d)
  if not procGetDpiForSystem.isNil:
    let d = procGetDpiForSystem()
    if d != 0:
      return int(d)
  96

## Conversions between DIPs (the unit of the public API) and pixels.
proc toPx*(v, dpi: int): int32 = int32((v * dpi + 48) div 96)
proc toDIP*(v: int32, dpi: int): int = (int(v) * 96 + dpi div 2) div dpi

## commonControl resolves a function of the common controls library. It
## is loaded by name, so that the activation context (see
## activateCommonControls) selects version 6, and only from the system
## directory.
proc commonControl*(name: string): pointer =
  const loadLibrarySearchSystem32 = 0x800
  let h = procLoadLibraryExW(cast[uint](u16("comctl32.dll")), 0,
    loadLibrarySearchSystem32)
  if h == 0:
    return nil
  let aname = name & "\0"
  cast[pointer](procGetProcAddress(h, cast[uint](
    cast[pointer](addr aname[0]))))

## Window messages and constants.
const
  wmDestroy* = 0x0002'u32
  wmMove* = 0x0003'u32
  wmSize* = 0x0005'u32
  wmActivate* = 0x0006'u32
  wmSetFocus* = 0x0007'u32
  wmClose* = 0x0010'u32
  wmQueryEndSession* = 0x0011'u32
  wmQuit* = 0x0012'u32
  wmEraseBkgnd* = 0x0014'u32
  wmEndSession* = 0x0016'u32
  wmSettingChange* = 0x001A'u32
  wmGetMinMaxInfo* = 0x0024'u32
  wmWindowPosChanging* = 0x0046'u32
  wmSetIcon* = 0x0080'u32
  wmNCCalcSize* = 0x0083'u32
  wmNCHitTest* = 0x0084'u32
  wmNCMouseMove* = 0x00A0'u32
  wmNCLButtonDown* = 0x00A1'u32
  wmNCLButtonUp* = 0x00A2'u32
  wmNCLButtonDblClk* = 0x00A3'u32
  wmNCRButtonDown* = 0x00A4'u32
  wmNCRButtonUp* = 0x00A5'u32
  wmNCRButtonDblClk* = 0x00A6'u32
  wmNCMouseLeave* = 0x02A2'u32
  wmMouseLeave* = 0x02A3'u32
  wmCommand* = 0x0111'u32
  wmSysCommand* = 0x0112'u32
  wmMenuChar* = 0x0120'u32
  wmEnterMenuLoop* = 0x0211'u32
  wmExitMenuLoop* = 0x0212'u32
  wmLButtonUp* = 0x0202'u32
  wmRButtonUp* = 0x0205'u32
  wmContextMenu* = 0x007B'u32
  wmHotkey* = 0x0312'u32
  wmDisplayChange* = 0x007E'u32
  wmDpiChanged* = 0x02E0'u32
  wmUser* = 0x0400'u32
  wmApp* = 0x8000'u32

  wmAppDispatch* = wmApp + 1
  wmAppWake* = wmApp + 2
  wmAppTray* = wmApp + 3
  wmAppReady* = wmApp + 4
  ## wmAppDeviceRemoved tells the application window that the GPU device
  ## of DirectComposition was removed (compositor.nim).
  wmAppDeviceRemoved* = wmApp + 5
  ## wmAppNetwork tells the application window that the connectivity
  ## hint changed (network.nim). wmApp + 6 is a flyout's wmAppDismiss.
  wmAppNetwork* = wmApp + 7

  wsOverlapped* = 0x00000000'u32
  wsPopup* = 0x80000000'u32
  wsChild* = 0x40000000'u32
  wsVisible* = 0x10000000'u32
  wsClipSiblings* = 0x04000000'u32
  wsClipChildren* = 0x02000000'u32
  wsCaption* = 0x00C00000'u32
  wsSysMenu* = 0x00080000'u32
  wsThickFrame* = 0x00040000'u32
  wsMinimizeBox* = 0x00020000'u32
  wsMaximizeBox* = 0x00010000'u32
  wsOverlappedWindow* = wsOverlapped or wsCaption or wsSysMenu or
    wsThickFrame or wsMinimizeBox or wsMaximizeBox

  wsExTopmost* = 0x00000008'u32
  wsExTransparent* = 0x00000020'u32
  wsExToolWindow* = 0x00000080'u32
  wsExAppWindow* = 0x00040000'u32
  wsExLayered* = 0x00080000'u32
  wsExNoRedirect* = 0x00200000'u32 ## WS_EX_NOREDIRECTIONBITMAP
  wsExNoActivate* = 0x08000000'u32

  gwlStyle* = -16'i32
  gwlExStyle* = -20'i32

  swHide* = 0
  swShowNormal* = 1
  swShowMinimized* = 2
  swShowMaximized* = 3
  swShowNoActivate* = 4
  swShow* = 5
  swMinimize* = 6
  swRestore* = 9

  swpNoSize* = 0x0001'u32
  swpNoMove* = 0x0002'u32
  swpNoZOrder* = 0x0004'u32
  swpNoActivate* = 0x0010'u32
  swpFrameChanged* = 0x0020'u32
  swpShowWindow* = 0x0040'u32
  swpHideWindow* = 0x0080'u32

  hwndTopmost* = uint.high ## -1
  hwndNoTopmost* = uint.high - 1 ## -2
  hwndMessage* = uint.high - 2 ## -3

  sizeRestored* = 0
  sizeMinimized* = 1
  sizeMaximized* = 2

  waInactive* = 0

  htClient* = 1
  htCaption* = 2
  htMinButton* = 8
  htMaxButton* = 9
  htLeft* = 10
  htRight* = 11
  htTop* = 12
  htTopLeft* = 13
  htTopRight* = 14
  htBottom* = 15
  htBottomLeft* = 16
  htBottomRight* = 17
  htClose* = 20

  scMinimize* = 0xF020
  scMaximize* = 0xF030
  scClose* = 0xF060
  scKeyMenu* = 0xF100
  scRestore* = 0xF120

  mfString* = 0x0000'u32
  mfGrayed* = 0x0001'u32
  mfChecked* = 0x0008'u32
  mfPopup* = 0x0010'u32
  mfSeparator* = 0x0800'u32
  mfByCommand* = 0x0000'u32
  mfByPosition* = 0x0400'u32

  miimState* = 0x0001'u32
  miimFType* = 0x0100'u32
  miimString* = 0x0040'u32
  mftRadioCheck* = 0x0200'u32
  mfsChecked* = 0x0008'u32
  mfsDisabled* = 0x0003'u32

  tpmRightButton* = 0x0002'u32
  tpmRightAlign* = 0x0008'u32
  tpmReturnCmd* = 0x0100'u32
  tpmLayoutRTL* = 0x8000'u32
  mncClose* = 1'u32

  monitorDefaultToNull* = 0
  monitorDefaultToNearest* = 2
  monitorDefaultToPrimary* = 1
  monitorInfoPrimary* = 1

  smCxFrame* = 32
  smCyFrame* = 33
  smCxPaddedBorder* = 92

  vkShift* = 0x10
  vkControl* = 0x11
  vkMenu* = 0x12
  vkLWin* = 0x5B
  vkRWin* = 0x5C

  vkProcessKey* = 0xE5
  vkPacket* = 0xE7

  cfUnicodeText* = 13
  cfDIB* = 8
  cfDIBV5* = 17
  gmemMoveable* = 0x0002'u32

  idcArrow* = 32512

  dwmwaUseImmersiveDarkMode* = 20
  dwmwaWindowCornerPreference* = 33
  dwmwaSystemBackdropType* = 38

  dwmwcpRound* = 2 ## DWM_WINDOW_CORNER_PREFERENCE

  lwaAlpha* = 0x2
  ulwAlpha* = 0x2

  tmeLeave* = 0x02'u32
  tmeNonClient* = 0x10'u32

  dtCenter* = 0x001'u32
  dtVCenter* = 0x004'u32
  dtSingleLine* = 0x020'u32
  dtNoPrefix* = 0x800'u32

  wdaNone* = 0
  wdaExcludeFromCapture* = 0x11

  coinitApartmentThreaded* = 0x2
  clsctxInprocServer* = 0x1

  dpiAwarenessContextPerMonitorAwareV2* = uint.high - 3 ## -4

  qsAllInput* = 0x04FF'u32
  mwmoInputAvailable* = 0x0004'u32
  pmRemove* = 0x0001'u32

  sOK* = 0
  eNoInterface* = 0x80004002'u32
  eFail* = 0x80004005'u32

type
  w32Rect* = object
    left*, top*, right*, bottom*: int32

  w32Point* = object
    x*, y*: int32

  w32Msg* = object
    hwnd*: uint
    message*: uint32
    wParam*, lParam*: uint
    time*: uint32
    pt*: w32Point
    private*: uint32

  wndClassEx* = object
    size*, style*: uint32
    wndProc*: pointer
    clsExtra*, wndExtra*: int32
    instance*, icon*, cursor*, background*: uint
    menuName*, className*: pointer
    iconSm*: uint

  minMaxInfo* = object
    reserved*, maxSize*, maxPosition*, minTrackSize*,
      maxTrackSize*: w32Point

  windowPlacement* = object
    length*, flags*, showCmd*: uint32
    minPosition*, maxPosition*: w32Point
    normalPosition*: w32Rect

  monitorInfoEx* = object
    size*: uint32
    monitor*, work*: w32Rect
    flags*: uint32
    device*: array[32, uint16]

  ## devMode is DEVMODEW, of a display: position holds the union of
  ## the printer's fields and the display's.
  devMode* = object
    deviceName*: array[32, uint16]
    specVersion*, driverVersion*, size*, driverExtra*: uint16
    fields*: uint32
    position*: array[16, byte]
    color*, duplex*, yResolution*, tTOption*, collate*: int16
    formName*: array[32, uint16]
    logPixels*: uint16
    bitsPerPel*, pelsWidth*, pelsHeight*: uint32
    displayFlags*, displayFrequency*: uint32
    icmMethod*, icmIntent*, mediaType*, ditherType*: uint32
    reserved1*, reserved2*: uint32
    panningWidth*, panningHeight*: uint32

  windowPos* = object
    hwnd*, insertAfter*: uint
    x*, y*, cx*, cy*: int32
    flags*: uint32

  ncCalcSizeParams* = object
    rgrc*: array[3, w32Rect]
    pos*: ptr windowPos

  margins* = object
    left*, right*, top*, bottom*: int32

  ## osVersionInfo is RTL_OSVERSIONINFOW.
  osVersionInfo* = object
    size*, major*, minor*, build*, platformID*: uint32
    csdVersion*: array[128, uint16]

  flashWInfo* = object
    size*: uint32
    hwnd*: uint
    flags*, count*, timeout*: uint32

  ## GUID is a COM interface or class identifier.
  GUID* = object
    data1*: uint32
    data2*, data3*: uint16
    data4*: array[8, byte]

static: assert sizeof(devMode) == 220

## enumCurrentSettings asks EnumDisplaySettingsW for the mode in use.
const enumCurrentSettings* = 0xFFFFFFFF'u32

## guid parses "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
proc guid*(s: string): GUID =
  proc hex(t: string): uint64 =
    for c in t:
      result = result shl 4
      if c >= '0' and c <= '9':
        result = result or uint64(c.ord - '0'.ord)
      elif c >= 'a' and c <= 'f':
        result = result or uint64(c.ord - 'a'.ord + 10)
      elif c >= 'A' and c <= 'F':
        result = result or uint64(c.ord - 'A'.ord + 10)
  result = GUID(data1: uint32(hex(s[0 ..< 8])),
    data2: uint16(hex(s[9 ..< 13])),
    data3: uint16(hex(s[14 ..< 18])))
  result.data4[0] = byte(hex(s[19 ..< 21]))
  result.data4[1] = byte(hex(s[21 ..< 23]))
  for i in 0 ..< 6:
    result.data4[2 + i] = byte(hex(s[24 + 2 * i ..< 26 + 2 * i]))

## windowsBuild is the build of Windows 10 or 11, the maximum on a
## later major version. RtlGetVersion tells the version whatever the
## executable's manifest declares.
var winBuild: uint32
var winBuildDone: bool

proc windowsBuild*(): uint32 =
  if winBuildDone:
    return winBuild
  winBuildDone = true
  var v: osVersionInfo
  v.size = uint32(sizeof(v))
  if not procRtlGetVersion.isNil:
    discard procRtlGetVersion(cast[uint](cast[pointer](addr v)))
  if v.major > 10:
    return uint32.high
  if v.major < 10:
    return 0
  winBuild = v.build
  winBuild

## windows11 reports Windows 11 (build 22000) or later.
proc windows11*(): bool = windowsBuild() >= 22000

## systemBackdrops reports Windows 11 22H2 (build 22621) or later,
## where DWM draws the materials of DWMWA_SYSTEMBACKDROP_TYPE.
proc systemBackdrops*(): bool = windowsBuild() >= 22621

## Load every bound proc. mainThreadID, in types.nim, is set at module
## init, on the main thread.
loadWin32()
