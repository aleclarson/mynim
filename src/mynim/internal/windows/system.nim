## system.nim (system.go): shell, screens and the theme.

## Shell.

method shell*(b: WinBackend): Shell = w32Shell()

method openExternal*(s: w32Shell, url: string): ref CatchableError =
  shellExecute("open", url, "")
method openPath*(s: w32Shell, path: string) =
  let e = shellExecute("open", path, "")
  if not e.isNil:
    raise e

method showItemInFolder*(s: w32Shell, path: string) =
  discard shellExecute("open", "explorer.exe",
    "/select,\"" & path & "\"")

method trashItem*(s: w32Shell, path: string) =
  type shFileOp = object
    hwnd: uint
    fun: uint32
    `from`, to: ptr uint16
    flags: uint16
    anyOperationsAborted: int32
    nameMappings: uint
    progressTitle: ptr uint16
  const
    foDelete = 3'u32
    fofSilent = 0x0004'u16
    fofNoConfirmation = 0x0010'u16
    fofAllowUndo = 0x0040'u16
    fofNoErrorUI = 0x0400'u16
  let `from` = utf16Units(path) & @[0'u16, 0'u16] ## double NUL
  var op = shFileOp(fun: foDelete,
    `from`: cast[ptr uint16](u16Seq(`from`)),
    flags: fofAllowUndo or fofNoConfirmation or fofSilent or
      fofNoErrorUI)
  let r = procSHFileOperationW(cast[uint](addr op))
  if r != 0 or op.anyOperationsAborted != 0:
    raise newException(CatchableError,
      "mynim: cannot move " & path & " to the recycle bin (error " &
        $r & ")")

method beep*(s: w32Shell) = discard procMessageBeep(0)

## Screen.

method screen*(b: WinBackend): Screen = w32Screen()

var monitorSink: proc(m: uint)

proc monitorEnumCb(mon, hdc, r, l: uint): uint {.stdcall.} =
  if not monitorSink.isNil:
    monitorSink(mon)
  1

## enumMonitors calls fn with every monitor. Main thread only.
proc enumMonitors*(fn: proc(m: uint)) =
  monitorSink = fn
  discard procEnumDisplayMonitors(0, 0, cast[uint](monitorEnumCb), 0)
  monitorSink = nil

proc monitorInfo*(m: uint): monitorInfoEx =
  result.size = uint32(sizeof(result))
  discard procGetMonitorInfoW(m, cast[uint](addr result))

proc monitorDPI*(m: uint): int =
  var x, y: uint32
  if not procGetDpiForMonitor.isNil and
      procGetDpiForMonitor(m, 0, cast[uint](addr x),
        cast[uint](addr y)) == sOK:
    return int(x)
  dpiOf(0)

## monitorAt is the monitor a point of the screen is on.
proc monitorWorkArea*(mon: uint): w32Rect = monitorInfo(mon).work

proc monitorAt*(x, y: int): uint =
  var p = w32Point(x: int32(x), y: int32(y))
  procMonitorFromPoint(cast[uint](addr p), monitorDefaultToNearest)

method displays*(s: w32Screen): seq[Display] =
  var mons: seq[uint]
  enumMonitors(proc(m: uint) = mons.add m)
  for m in mons:
    let info = monitorInfo(m)
    let dpi = monitorDPI(m)
    template conv(r: w32Rect): platform.Rect =
      platform.Rect(x: int(toDIP(r.left, dpi)),
        y: int(toDIP(r.top, dpi)),
        width: int(toDIP(r.right - r.left, dpi)),
        height: int(toDIP(r.bottom - r.top, dpi)))
    result.add Display(
      id: int64(m),
      label: u16str(info.device.toOpenArray(0, 31).filterIt(
        it != 0)),
      bounds: conv(info.monitor),
      workArea: conv(info.work),
      scaleFactor: dpi.float64 / 96,
      primary: (info.flags and monitorInfoPrimary) != 0)

method cursorPoint*(s: w32Screen): platform.Point =
  var pt: w32Point
  discard procGetCursorPos(cast[uint](addr pt))
  let dpi = monitorDPI(monitorAt(int(pt.x), int(pt.y)))
  platform.Point(x: int(toDIP(pt.x, dpi)),
    y: int(toDIP(pt.y, dpi)))

## Theme.

method theme*(b: WinBackend): Theme = w32Theme(b: b)

proc isDark*(b: WinBackend): bool
proc applyTheme*(b: WinBackend)
proc applyWindowTheme*(b: WinBackend, w: w32Window)
proc applyWebViewTheme*(b: WinBackend, w: w32Window)

method isDark*(t: w32Theme): bool = t.b.isDark()

## uiFont is DirectWrite's to find: Segoe UI.
method uiFont*(t: w32Theme): string = ""

method fontRendering*(t: w32Theme): FontRendering = FontRendering()

method setSource*(t: w32Theme, source: string) =
  t.b.themeSource = source
  t.b.applyTheme()

const
  spiGetHighContrast* = 0x0042'u
  spiSetHighContrast* = 0x0043'u
  spiGetClientAreaAnimation* = 0x1042'u
  spiSetClientAreaAnimation* = 0x1043'u
  hcfHighContrastOn* = 0x1'u32
  accessibilityKey* = "Software\\Microsoft\\Accessibility"
  dwmKey* = "Software\\Microsoft\\Windows\\DWM"
  textScaleFactor* = "TextScaleFactor"
  settingImmersiveColorSet* = "ImmersiveColorSet"
  settingWindowMetrics* = "WindowMetrics"
  ## settingIntl is the lParam of WM_SETTINGCHANGE when the display
  ## languages or the regional formats changed.
  settingIntl* = "intl"

## regDWORD reads a DWORD value, reporting whether it exists.
proc regDWORD*(root: uint, path, name: string): tuple[v: uint32,
    ok: bool] =
  let (data, ok) = regGetBytes(root, path, name)
  if not ok or data.len < 4:
    return (0, false)
  (uint32(data[0]) or uint32(data[1]) shl 8 or
    uint32(data[2]) shl 16 or uint32(data[3]) shl 24, true)

## highContrast is HIGHCONTRASTW.
type highContrast = object
  size*, flags*: uint32
  defaultScheme*: uint

## highContrastOn reports whether a contrast theme is on.
proc highContrastOn*(): bool =
  var hc = highContrast(size: uint32(sizeof(highContrast)))
  let r = procSystemParametersInfoW(spiGetHighContrast,
    uint(hc.size), cast[uint](addr hc), 0)
  r != 0 and (hc.flags and hcfHighContrastOn) != 0

## Preferences reads the accent of the title bars and the Start menu,
## the settings of animation effects and contrast themes, and the
## size of text of Accessibility.
method preferences*(t: w32Theme): platform.Preferences =
  var p: platform.Preferences
  let (v, ok) = regDWORD(hkeyCurrentUser, dwmKey, "AccentColor")
  if ok: ## 0xAABBGGRR
    p.accent = platform.Color(r: uint8(v), g: uint8(v shr 8),
      b: uint8(v shr 16), a: 255)
  var animate: int32
  if procSystemParametersInfoW(spiGetClientAreaAnimation, 0,
      cast[uint](addr animate), 0) != 0:
    p.reduceMotion = animate == 0
  p.highContrast = highContrastOn()
  let (v2, ok2) = regDWORD(hkeyCurrentUser, accessibilityKey,
    textScaleFactor)
  if ok2 and v2 >= 100 and v2 <= 500:
    p.textScale = v2.float64 / 100
  p

## preferencesChanged reports whether a WM_SETTINGCHANGE is about the
## preferences: the colors, animation effects, contrast themes or the
## size of text.
proc preferencesChanged*(wp, lp: uint): bool =
  if wp == spiSetClientAreaAnimation or wp == spiSetHighContrast:
    return true
  if lp == 0:
    return false
  wstr(cast[pointer](lp)) in [settingImmersiveColorSet,
    settingWindowMetrics, textScaleFactor]

proc isDark*(b: WinBackend): bool =
  case b.themeSource
  of "dark":
    return true
  of "light":
    return false
  else: discard
  let (light, ok) = regDWORD(hkeyCurrentUser,
    "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    "AppsUseLightTheme")
  ok and light == 0

const
  rdwInvalidate* = 0x0001'u32
  rdwFrame* = 0x0400'u32
  rdwUpdateNow* = 0x0100'u32

proc applyTheme*(b: WinBackend) =
  b.applyMenuTheme()
  for _, w in b.windows:
    b.applyWindowTheme(w)
    w.withWebView(proc() = b.applyWebViewTheme(w))

## applyWindowTheme matches the title bar, or the controls drawn in
## its place, and the menus to the appearance.
proc applyWindowTheme*(b: WinBackend, w: w32Window) =
  var dark = int32(0)
  if b.isDark():
    dark = 1
  discard procDwmSetWindowAttribute(w.hwnd,
    dwmwaUseImmersiveDarkMode, cast[uint](addr dark), 4)
  if not w.caption.isNil:
    w.caption.paint()
  ## The bar is drawn again in the appearance, with the line below it.
  if w.menuShown():
    discard procRedrawWindow(w.hwnd, 0, 0,
      rdwInvalidate or rdwFrame or rdwUpdateNow)

## applyWebViewTheme makes prefers-color-scheme follow an overridden
## appearance; "system" leaves it to WebView2.
proc applyWebViewTheme*(b: WinBackend, w: w32Window) =
  var value = ""
  if b.themeSource == "dark" or b.themeSource == "light":
    value = b.themeSource
  w.devtools("Emulation.setEmulatedMedia",
    "{\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":\"" &
      value & "\"}]}", nil)
