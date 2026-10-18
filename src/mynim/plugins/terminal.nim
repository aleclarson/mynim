## Native GPU-rendered terminal views backed by Ghostty's VT library.

import std/[math, monotimes, options, os, strutils, tables, times, unicode]
import mynim/ui as ui
import mynim/plugins/terminal/internal/[pty, session, view_paint]
import mynim/plugins/terminal/internal/vt/[input as vtInput, library,
    terminal as vtTerminal]
import mynim/plugins/terminal/native_library

export view_paint.TerminalGrid, view_paint.TerminalPaintOptions,
  view_paint.defaultTerminalPaintOptions

type
  ## Selects what happens to terminal text when a selection ends.
  TerminalCopyOnSelect* = enum
    ## Leave the selection in the terminal without copying it.
    copyOnSelectNone,
    ## Copy the selected text to the system clipboard.
    copyOnSelectClipboard

  TerminalTheme* = ref object
    foreground*, background*: ui.Color
    cursor*, cursorText*: ui.Color
    selection*, selectionText*: ui.Color
    palette*: array[16, ui.Color]

  PendingTerminalKey = object
    sourceKey: ui.Key
    key: vtInput.Key
    mods: ui.Modifiers
    unshifted: uint32
    repeat: bool

  TerminalOptions* = object
    ## Process and native view options for `newTerminal`.
    command*: seq[string]
    dir*: string
    env*: seq[string]
    font*: TerminalPaintOptions
    scrollbackMaxBytes*: int
    copyOnSelect*: TerminalCopyOnSelect
    noBlink*, optionAsAlt*: bool
    theme*, darkTheme*: TerminalTheme
    onTitle*: proc(title: string) {.closure.}
    onExit*: proc(exitCode: int) {.closure.}
    onBell*: proc() {.closure.}
    onKey*: proc(mods: ui.Modifiers; key: ui.Key): bool {.closure.}

  TerminalViewState = ref object
    hasGrid, hasFocus, focused, cursorBlinking, pointerPressed: bool
    selecting, ticking, scrollbarDragging: bool
    hasPendingKey: bool
    grid: TerminalGrid
    bounds: ui.Rect
    scale, scrollRemainder: float32
    pointerX, pointerY, scrollbarWidth, scrollbarGrabOffset: float32
    blinkStart: MonoTime
    preedit: string
    preeditCaret: int
    pendingTyped: bool
    pendingKey: PendingTerminalKey
    takenKeys: seq[ui.Key]
    appliedTheme: TerminalTheme

  Terminal* = ref object
    options: TerminalOptions
    library: GhosttyVT
    session: TerminalSession
    state: TerminalViewState
    closed: bool

proc lightTheme*(): TerminalTheme =
  let base = ui.lightTheme()
  TerminalTheme(
    foreground: base.text, background: base.background,
    palette: [ui.parseColor("#000000"), ui.parseColor("#cd3131"),
      ui.parseColor("#00bc00"), ui.parseColor("#949800"),
      ui.parseColor("#0451a5"), ui.parseColor("#bc05bc"),
      ui.parseColor("#0598bc"), ui.parseColor("#555555"),
      ui.parseColor("#666666"), ui.parseColor("#cd3131"),
      ui.parseColor("#14ce14"), ui.parseColor("#b5ba00"),
      ui.parseColor("#0451a5"), ui.parseColor("#bc05bc"),
      ui.parseColor("#0598bc"), ui.parseColor("#a5a5a5")])

proc darkTheme*(): TerminalTheme =
  let base = ui.darkTheme()
  TerminalTheme(
    foreground: base.text, background: base.background,
    palette: [ui.parseColor("#000000"), ui.parseColor("#cd3131"),
      ui.parseColor("#0dbc79"), ui.parseColor("#e5e510"),
      ui.parseColor("#2472c8"), ui.parseColor("#bc3fbc"),
      ui.parseColor("#11a8cd"), ui.parseColor("#e5e5e5"),
      ui.parseColor("#666666"), ui.parseColor("#f14c4c"),
      ui.parseColor("#23d18b"), ui.parseColor("#f5f543"),
      ui.parseColor("#3b8eea"), ui.parseColor("#d670d6"),
      ui.parseColor("#29b8db"), ui.parseColor("#ffffff")])

let
  defaultLightTerminalTheme = lightTheme()
  defaultDarkTerminalTheme = darkTheme()

proc defaultTerminalOptions*(): TerminalOptions =
  TerminalOptions(font: defaultTerminalPaintOptions(),
    scrollbackMaxBytes: 10 * 1024 * 1024)

proc normalized(options: TerminalOptions): TerminalOptions =
  result = options
  if result.font.fontFamily.len == 0 and result.font.fontFeatures.len == 0 and
      result.font.fontSize <= 0 and result.font.fontWeight <= 0 and
      result.font.lineHeight <= 0 and result.font.paddingX == 0 and
      result.font.paddingY == 0:
    result.font = defaultTerminalPaintOptions()
  if result.scrollbackMaxBytes == 0:
    result.scrollbackMaxBytes = 10 * 1024 * 1024
  else:
    result.scrollbackMaxBytes = max(result.scrollbackMaxBytes, 0)

proc rgb(color: ui.Color): vtTerminal.TerminalColor =
  vtTerminal.TerminalColor(r: color.r, g: color.g, b: color.b)

proc palette256(theme: TerminalTheme): vtTerminal.TerminalPalette =
  for index, color in theme.palette:
    result[index] = color.rgb()
  const levels: array[6, uint8] = [0, 95, 135, 175, 215, 255]
  for index in 0 ..< 216:
    result[16 + index] = vtTerminal.TerminalColor(
      r: levels[index div 36], g: levels[index div 6 mod 6],
      b: levels[index mod 6])
  for index in 0 ..< 24:
    let value = uint8(8 + 10 * index)
    result[232 + index] = vtTerminal.TerminalColor(
      r: value, g: value, b: value)

proc apply(theme: TerminalTheme; session: TerminalSession) =
  if theme == nil:
    return
  let cursor = if theme.cursor.a > 0:
      some(theme.cursor.rgb()) else: none(vtTerminal.TerminalColor)
  session.setColors(theme.foreground.rgb(), theme.background.rgb(), cursor,
    some(theme.palette256()))

proc defaultEnvironment(overrides: openArray[string]): seq[string] =
  var values = initOrderedTable[string, string]()
  for key, value in envPairs():
    values[key] = value
  for value in overrides:
    let separator = value.find('=')
    if separator <= 0:
      raise newException(ValueError,
        "terminal environment entries must be KEY=value")
    values[value[0 ..< separator]] = value[separator + 1 .. ^1]
  values["TERM"] = "xterm-256color"
  values["COLORTERM"] = "truecolor"
  when not defined(windows):
    if values.getOrDefault("LANG").len == 0 and
        values.getOrDefault("LC_ALL").len == 0 and
        values.getOrDefault("LC_CTYPE").len == 0:
      values["LANG"] = "en_US.UTF-8"
  for key, value in values:
    result.add(key & "=" & value)

proc processOptions(options: TerminalOptions): PtyOptions =
  var command = options.command
  var loginShell = false
  if command.len == 0:
    when defined(windows):
      let shell = getEnv("COMSPEC", "powershell.exe")
      command = @[shell]
    else:
      var shell = getEnv("SHELL")
      if shell.len == 0:
        when defined(macosx): shell = "/bin/zsh"
        else: shell = "/bin/sh"
      command = @[shell]
      loginShell = true
  if command[0].len == 0:
    raise newException(ValueError, "terminal command path is empty")
  var args = command
  if loginShell:
    args.add("-l")
  PtyOptions(path: command[0], args: args,
    dir: if options.dir.len > 0: options.dir else: getHomeDir(),
    env: defaultEnvironment(options.env))

proc newTerminal*(options = defaultTerminalOptions()): Terminal =
  ## Loads Ghostty, starts the configured shell/program, and creates a view owner.
  let options = options.normalized()
  new(result)
  result.options = options
  result.state = TerminalViewState(blinkStart: getMonoTime())
  result.library = loadGhosttyVT()
  try:
    result.session = newTerminalSession(result.library,
      processOptions(options), cursorBlink = not options.noBlink,
      scrollbackMaxBytes = max(options.scrollbackMaxBytes, 0))
  except CatchableError:
    result.library.close()
    result.library = nil
    raise

proc send*(terminal: Terminal; data: string) =
  ## Queues UTF-8 or VT-encoded input for the terminal's process.
  if terminal == nil or terminal.closed:
    raise newException(IOError, "terminal is closed")
  terminal.session.send(data)

proc paste*(terminal: Terminal; text: string) =
  ## Sanitizes clipboard text and sends it with the active bracketed-paste mode.
  if terminal == nil or terminal.closed:
    raise newException(IOError, "terminal is closed")
  terminal.session.paste(text)

proc size*(terminal: Terminal): tuple[cols, rows: int] =
  ## Returns the current terminal grid dimensions.
  if terminal == nil or terminal.closed:
    raise newException(IOError, "terminal is closed")
  terminal.session.size()

proc processExitCode*(terminal: Terminal): Option[int] =
  ## Returns the process exit code once its PTY output has reached EOF.
  if terminal == nil or terminal.closed:
    return none(int)
  terminal.session.processExitCode()

proc waitForExit*(terminal: Terminal): int =
  ## Waits until the child process exits and its PTY output has been drained.
  if terminal == nil or terminal.closed:
    raise newException(IOError, "terminal is closed")
  terminal.session.waitForExit()

proc failure*(terminal: Terminal): string =
  ## Returns the first PTY input or output failure, if any.
  if terminal == nil or terminal.closed:
    return "terminal is closed"
  terminal.session.failure()

proc close*(terminal: Terminal) =
  ## Stops the process and releases Ghostty handles and its dynamic library.
  if terminal == nil or terminal.closed:
    return
  terminal.closed = true
  terminal.session.setWake(nil)
  terminal.session.close()
  terminal.library.close()
  terminal.session = nil
  terminal.library = nil

proc keyCode(key: ui.Key): vtInput.Key =
  if key >= ui.keyA and key <= ui.keyZ:
    return vtInput.Key(int32(vtInput.keyA) + int32(key - ui.keyA))
  if key >= ui.key0 and key <= ui.key9:
    return vtInput.Key(int32(vtInput.keyDigit0) + int32(key - ui.key0))
  if key >= ui.keyF1 and key <= ui.keyF12:
    return vtInput.Key(int32(vtInput.keyF1) + int32(key - ui.keyF1))
  case key
  of ui.keyEnter: vtInput.keyEnter
  of ui.keyEscape: vtInput.keyEscape
  of ui.keyBackspace: vtInput.keyBackspace
  of ui.keyTab: vtInput.keyTab
  of ui.keySpace: vtInput.keySpace
  of ui.keyDelete: vtInput.keyDelete
  of ui.keyInsert: vtInput.keyInsert
  of ui.keyHome: vtInput.keyHome
  of ui.keyEnd: vtInput.keyEnd
  of ui.keyPageUp: vtInput.keyPageUp
  of ui.keyPageDown: vtInput.keyPageDown
  of ui.keyLeft: vtInput.keyArrowLeft
  of ui.keyRight: vtInput.keyArrowRight
  of ui.keyUp: vtInput.keyArrowUp
  of ui.keyDown: vtInput.keyArrowDown
  of ui.keyMinus: vtInput.keyMinus
  of ui.keyEqual: vtInput.keyEqual
  of ui.keyComma: vtInput.keyComma
  of ui.keyPeriod: vtInput.keyPeriod
  of ui.keySlash: vtInput.keySlash
  of ui.keySemicolon: vtInput.keySemicolon
  of ui.keyQuote: vtInput.keyQuote
  of ui.keyBracketLeft: vtInput.keyBracketLeft
  of ui.keyBracketRight: vtInput.keyBracketRight
  of ui.keyBackslash: vtInput.keyBackslash
  of ui.keyBackquote: vtInput.keyBackquote
  of ui.keyContextMenu: vtInput.keyContextMenu
  else: vtInput.keyUnidentified

proc unshiftedCodepoint(key: ui.Key): uint32 =
  if key >= ui.keyA and key <= ui.keyZ:
    return uint32(ord('a') + int(key - ui.keyA))
  if key >= ui.key0 and key <= ui.key9:
    return uint32(ord('0') + int(key - ui.key0))
  case key
  of ui.keySpace: uint32(ord(' '))
  of ui.keyMinus: uint32(ord('-'))
  of ui.keyEqual: uint32(ord('='))
  of ui.keyComma: uint32(ord(','))
  of ui.keyPeriod: uint32(ord('.'))
  of ui.keySlash: uint32(ord('/'))
  of ui.keySemicolon: uint32(ord(';'))
  of ui.keyQuote: uint32(ord('\''))
  of ui.keyBracketLeft: uint32(ord('['))
  of ui.keyBracketRight: uint32(ord(']'))
  of ui.keyBackslash: uint32(ord('\\'))
  of ui.keyBackquote: uint32(ord('`'))
  else: 0

proc shiftedCodepoint(codepoint: uint32): uint32 =
  case codepoint
  of uint32(ord('a')) .. uint32(ord('z')):
    codepoint - uint32(ord('a')) + uint32(ord('A'))
  of uint32(ord('1')): uint32(ord('!'))
  of uint32(ord('2')): uint32(ord('@'))
  of uint32(ord('3')): uint32(ord('#'))
  of uint32(ord('4')): uint32(ord('$'))
  of uint32(ord('5')): uint32(ord('%'))
  of uint32(ord('6')): uint32(ord('^'))
  of uint32(ord('7')): uint32(ord('&'))
  of uint32(ord('8')): uint32(ord('*'))
  of uint32(ord('9')): uint32(ord('('))
  of uint32(ord('0')): uint32(ord(')'))
  of uint32(ord('-')): uint32(ord('_'))
  of uint32(ord('=')): uint32(ord('+'))
  of uint32(ord('[')): uint32(ord('{'))
  of uint32(ord(']')): uint32(ord('}'))
  of uint32(ord('\\')): uint32(ord('|'))
  of uint32(ord(';')): uint32(ord(':'))
  of uint32(ord('\'')): uint32(ord('"'))
  of uint32(ord(',')): uint32(ord('<'))
  of uint32(ord('.')): uint32(ord('>'))
  of uint32(ord('/')): uint32(ord('?'))
  of uint32(ord('`')): uint32(ord('~'))
  else: codepoint

proc keyMods(modifiers: ui.Modifiers): vtInput.Mods =
  if (modifiers and ui.modShift) != 0: result = result or vtInput.modShift
  if (modifiers and ui.modCtrl) != 0: result = result or vtInput.modCtrl
  if (modifiers and ui.modAlt) != 0: result = result or vtInput.modAlt
  if (modifiers and ui.modSuper) != 0: result = result or vtInput.modSuper

proc pointerButton(button: int): vtInput.MouseButton =
  case button
  of 0: vtInput.buttonLeft
  of 1: vtInput.buttonRight
  of 2: vtInput.buttonMiddle
  else: vtInput.buttonNone

proc selectionCell(terminal: Terminal; x, y: float32):
    tuple[column, row, paddingLeft, paddingTop: int] =
  let grid = terminal.state.grid
  let scale = max(terminal.state.scale, 0.01'f32)
  result.paddingLeft = int(round(terminal.options.font.paddingX * scale))
  result.paddingTop = int(round(terminal.options.font.paddingY * scale))
  result.column = int(floor(float64((x * scale -
    float32(result.paddingLeft)) / float32(max(grid.cellWidthPixels, 1)))))
  result.row = int(floor(float64((y * scale -
    float32(result.paddingTop)) / float32(max(grid.cellHeightPixels, 1)))))
  result.column = max(0, min(result.column, max(grid.cols - 1, 0)))
  result.row = max(0, min(result.row, max(grid.rows - 1, 0)))

proc selectionGeometry(terminal: Terminal; paddingLeft, paddingTop: int):
    tuple[columns, cellWidth, paddingLeft, screenHeight: int] =
  let grid = terminal.state.grid
  (columns: grid.cols, cellWidth: max(grid.cellWidthPixels, 1),
    paddingLeft: paddingLeft,
    screenHeight: paddingTop + grid.rows * max(grid.cellHeightPixels, 1))

proc copySelection(terminal: Terminal; services: ui.Services;
                   clear: bool): bool =
  let selected = terminal.session.selectedText()
  if selected.isNone or selected.get().len == 0:
    return false
  services.writeClipboard(selected.get())
  if clear:
    terminal.session.clearSelection()
    services.invalidate()
  true

proc selectAll(terminal: Terminal; services: ui.Services) =
  if terminal.session.selectAll() and
      terminal.options.copyOnSelect == copyOnSelectClipboard:
    discard terminal.copySelection(services, clear = false)
  services.invalidate()

proc pasteClipboard(terminal: Terminal; services: ui.Services) =
  terminal.state.preedit.setLen(0)
  terminal.state.hasPendingKey = false
  terminal.session.scrollToBottom()
  terminal.session.clearSelection()
  terminal.session.paste(services.readClipboard())

proc tickSelection(terminal: Terminal) =
  if not terminal.state.selecting or not terminal.state.ticking or
      not terminal.state.hasGrid:
    return
  let direction = terminal.session.selectionAutoscroll()
  if direction == 0:
    terminal.state.ticking = false
    return
  terminal.session.scrollForSelection(direction)
  let pointer = terminal.selectionCell(terminal.state.pointerX,
    terminal.state.pointerY)
  let geometry = terminal.selectionGeometry(pointer.paddingLeft,
    pointer.paddingTop)
  let scale = max(terminal.state.scale, 0.01'f32)
  discard terminal.session.selectionTick(pointer.column, pointer.row,
    float64(terminal.state.pointerX * scale),
    float64(terminal.state.pointerY * scale), geometry.columns,
    geometry.cellWidth, geometry.paddingLeft, geometry.screenHeight)
  terminal.state.ticking = terminal.session.selectionAutoscroll() != 0

proc applyTheme(terminal: Terminal; dark: bool): TerminalTheme =
  if dark and terminal.options.darkTheme != nil:
    return terminal.options.darkTheme
  if terminal.options.theme != nil:
    return terminal.options.theme
  if dark: defaultDarkTerminalTheme else: defaultLightTerminalTheme

proc dispatchEvents(terminal: Terminal) =
  for event in terminal.session.takeEvents():
    case event.kind
    of terminalTitleChanged:
      if terminal.options.onTitle != nil:
        terminal.options.onTitle(event.title)
    of terminalBell:
      if terminal.options.onBell != nil:
        terminal.options.onBell()
    of terminalProcessExited:
      if terminal.options.onExit != nil:
        terminal.options.onExit(event.exitCode)
    of terminalPwdChanged, terminalRenderHoldChanged, terminalReset:
      discard

proc reportKey(terminal: Terminal; event: ui.InputEvent): bool =
  let key = keyCode(if event.physicalKey != ui.keyUnknown:
      event.physicalKey else: event.key)
  if key == vtInput.keyUnidentified:
    return false
  let action = case event.kind
    of ui.InputKind.InputKeyUp: vtInput.keyRelease
    of ui.InputKind.InputKeyDown:
      if event.repeat: vtInput.keyRepeat else: vtInput.keyPress
    else: return false
  if action != vtInput.keyRelease:
    terminal.session.scrollToBottom()
    terminal.session.clearSelection()
  terminal.session.sendKey(vtInput.KeyEvent(action: action, key: key,
    mods: keyMods(event.mods), unshifted: unshiftedCodepoint(
      if event.physicalKey != ui.keyUnknown: event.physicalKey else: event.key)),
    terminal.options.optionAsAlt)
  true

proc flushPendingKey(terminal: Terminal) =
  if not terminal.state.hasPendingKey:
    return
  let pending = terminal.state.pendingKey
  terminal.state.hasPendingKey = false
  var text = ""
  if (pending.mods and ui.modCtrl) == 0 and pending.unshifted > 0:
    let codepoint = if (pending.mods and ui.modShift) != 0:
        shiftedCodepoint(pending.unshifted) else: pending.unshifted
    text = toUTF8(Rune(codepoint))
  terminal.session.scrollToBottom()
  terminal.session.clearSelection()
  terminal.session.sendKey(vtInput.KeyEvent(
    action: if pending.repeat: vtInput.keyRepeat else: vtInput.keyPress,
    key: pending.key, mods: keyMods(pending.mods), text: text,
    unshifted: pending.unshifted), terminal.options.optionAsAlt)

proc sendPendingText(terminal: Terminal; text: string) =
  if not terminal.state.hasPendingKey:
    terminal.session.scrollToBottom()
    terminal.session.clearSelection()
    terminal.session.send(text)
    return
  let pending = terminal.state.pendingKey
  terminal.state.hasPendingKey = false
  terminal.session.scrollToBottom()
  terminal.session.clearSelection()
  let runes = text.toRunes()
  if pending.key == vtInput.keyUnidentified or runes.len != 1:
    terminal.session.send(text)
    return
  let consumed = if uint32(runes[0]) != pending.unshifted:
      keyMods(pending.mods and (ui.modShift or ui.modAlt))
    else: vtInput.Mods(0)
  terminal.session.sendKey(vtInput.KeyEvent(
    action: if pending.repeat: vtInput.keyRepeat else: vtInput.keyPress,
    key: pending.key, mods: keyMods(pending.mods), consumed: consumed,
    text: text, unshifted: pending.unshifted), terminal.options.optionAsAlt)

proc handleInput(terminal: Terminal; services: ui.Services;
                 event: ui.InputEvent): bool =
  if terminal == nil or terminal.closed:
    return false
  case event.kind
  of ui.InputKind.InputKeyDown:
    terminal.state.pendingTyped = false
    terminal.flushPendingKey()
    if terminal.options.onKey != nil and
        terminal.options.onKey(event.mods, event.key):
      if event.key notin terminal.state.takenKeys:
        terminal.state.takenKeys.add(event.key)
      terminal.state.pendingTyped = true
      return true
    var clipboardShortcutMods = false
    when defined(macosx):
      clipboardShortcutMods = (event.mods and ui.modSuper) != 0
    else:
      clipboardShortcutMods =
        (event.mods and (ui.modCtrl or ui.modShift)) ==
        (ui.modCtrl or ui.modShift)
    if clipboardShortcutMods and event.key == ui.keyC:
      discard terminal.copySelection(services, clear = true)
      if event.key notin terminal.state.takenKeys:
        terminal.state.takenKeys.add(event.key)
      terminal.state.pendingTyped = true
      return true
    if clipboardShortcutMods and event.key == ui.keyV:
      terminal.state.preedit.setLen(0)
      terminal.state.hasPendingKey = false
      terminal.session.scrollToBottom()
      terminal.session.clearSelection()
      terminal.session.paste(services.readClipboard())
      if event.key notin terminal.state.takenKeys:
        terminal.state.takenKeys.add(event.key)
      terminal.state.pendingTyped = true
      return true
    if (event.mods and ui.modSuper) != 0:
      return false
    let sourceKey = if event.physicalKey != ui.keyUnknown:
        event.physicalKey else: event.key
    let unshifted = unshiftedCodepoint(sourceKey)
    let key = keyCode(sourceKey)
    if key != vtInput.keyUnidentified and unshifted > 0:
      terminal.state.pendingKey = PendingTerminalKey(sourceKey: event.key,
        key: key, mods: event.mods, unshifted: unshifted,
        repeat: event.repeat)
      terminal.state.hasPendingKey = true
      return true
    return terminal.reportKey(event)
  of ui.InputKind.InputKeyUp:
    for index in countdown(terminal.state.takenKeys.high, 0):
      if terminal.state.takenKeys[index] == event.key:
        terminal.state.takenKeys.delete(index)
        terminal.state.pendingTyped = false
        return true
    if terminal.state.hasPendingKey and
        terminal.state.pendingKey.sourceKey == event.key:
      terminal.flushPendingKey()
    return terminal.reportKey(event)
  of ui.InputKind.InputText:
    if terminal.state.pendingTyped:
      terminal.state.pendingTyped = false
      return true
    terminal.state.preedit.setLen(0)
    terminal.state.preeditCaret = 0
    if event.text.len > 0:
      terminal.sendPendingText(event.text)
    else:
      terminal.state.hasPendingKey = false
    return true
  of ui.InputKind.InputCompose:
    terminal.state.hasPendingKey = false
    terminal.state.preedit = event.text
    terminal.state.preeditCaret = event.caret
    return true
  of ui.InputKind.InputCommand:
    if event.text == "copy":
      discard terminal.copySelection(services, clear = false)
      return true
    if event.text == "selectAll":
      terminal.selectAll(services)
      return true
    if event.text == "paste" or event.text == "pasteAndMatchStyle":
      terminal.pasteClipboard(services)
      return true
    return false
  of ui.InputKind.InputPointerDown, ui.InputKind.InputPointerUp,
      ui.InputKind.InputPointerMove:
    let tracking = terminal.session.mouseTracking() and
      (event.mods and ui.modShift) == 0
    if not terminal.state.hasGrid:
      return false
    if terminal.state.scrollbarDragging:
      if event.kind == ui.InputKind.InputPointerUp:
        terminal.state.scrollbarDragging = false
        return true
      let viewport = terminal.session.scrollbar()
      let geometry = view_paint.scrollbarGeometry(terminal.state.bounds,
        viewport, terminal.state.scrollbarWidth,
        terminal.options.font.paddingX, terminal.options.font.paddingY)
      terminal.session.scrollToOffset(geometry.scrollbarOffsetAt(event.y,
        terminal.state.scrollbarGrabOffset))
      services.invalidate()
      return true
    if (tracking and not terminal.state.selecting) or
        terminal.state.pointerPressed:
      let button = event.button.pointerButton()
      if event.kind == ui.InputKind.InputPointerDown and
          button == vtInput.buttonNone:
        return false
      let action = case event.kind
        of ui.InputKind.InputPointerDown:
          terminal.state.pointerPressed = true
          vtInput.mousePress
        of ui.InputKind.InputPointerUp:
          terminal.state.pointerPressed = false
          vtInput.mouseRelease
        else: vtInput.mouseMotion
      let grid = terminal.state.grid
      let scale = max(terminal.state.scale, 0.01'f32)
      let paddingX = int(round(terminal.options.font.paddingX * scale))
      let paddingY = int(round(terminal.options.font.paddingY * scale))
      let screenWidth = paddingX * 2 + grid.cols * grid.cellWidthPixels
      let screenHeight = paddingY * 2 + grid.rows * grid.cellHeightPixels
      let sent = terminal.session.sendMouse(action, button,
        keyMods(event.mods), event.x * scale, event.y * scale,
        screenWidth, screenHeight, grid.cellWidthPixels,
        grid.cellHeightPixels, paddingX, paddingY,
        terminal.state.pointerPressed)
      if event.kind == ui.InputKind.InputPointerMove:
        return sent
      return true

    if event.kind == ui.InputKind.InputPointerDown and event.button == 0:
      let viewport = terminal.session.scrollbar()
      let geometry = view_paint.scrollbarGeometry(terminal.state.bounds,
        viewport, terminal.state.scrollbarWidth,
        terminal.options.font.paddingX, terminal.options.font.paddingY)
      let hitSlop = 3'f32
      let inTrack = geometry.track.w > 0 and
        event.x >= geometry.track.x - hitSlop and
        event.x <= geometry.track.x + geometry.track.w + hitSlop and
        event.y >= geometry.track.y and
        event.y <= geometry.track.y + geometry.track.h
      if inTrack:
        let inThumb = event.y >= geometry.thumb.y and
          event.y <= geometry.thumb.y + geometry.thumb.h
        terminal.state.scrollbarGrabOffset = if inThumb:
            event.y - geometry.thumb.y else: geometry.thumb.h / 2
        terminal.state.scrollbarDragging = true
        terminal.session.scrollToOffset(geometry.scrollbarOffsetAt(event.y,
          terminal.state.scrollbarGrabOffset))
        services.invalidate()
        return true

    if event.kind == ui.InputKind.InputPointerDown and event.button != 0:
      return false
    if event.kind == ui.InputKind.InputPointerMove and
        not terminal.state.selecting:
      return false
    if event.kind == ui.InputKind.InputPointerUp and
        not terminal.state.selecting:
      return false
    terminal.state.pointerX = event.x
    terminal.state.pointerY = event.y
    let pointer = terminal.selectionCell(event.x, event.y)
    let geometry = terminal.selectionGeometry(pointer.paddingLeft,
      pointer.paddingTop)
    let scale = max(terminal.state.scale, 0.01'f32)
    let pixelX = float64(event.x * scale)
    let pixelY = float64(event.y * scale)
    case event.kind
    of ui.InputKind.InputPointerDown:
      terminal.state.selecting = terminal.session.selectionPress(
        pointer.column, pointer.row, pixelX, pixelY,
        uint64(getMonoTime().ticks), 5.0 * float64(scale))
      terminal.state.ticking = false
      services.invalidate()
      return terminal.state.selecting
    of ui.InputKind.InputPointerMove:
      discard terminal.session.selectionDrag(pointer.column, pointer.row,
        pixelX, pixelY, geometry.columns, geometry.cellWidth,
        geometry.paddingLeft, geometry.screenHeight,
        rectangle = (event.mods and ui.modAlt) != 0)
      terminal.state.ticking = terminal.session.selectionAutoscroll() != 0
      services.invalidate()
      return true
    of ui.InputKind.InputPointerUp:
      terminal.state.selecting = false
      terminal.state.ticking = false
      terminal.session.selectionRelease(pointer.column, pointer.row,
        inside = true)
      if terminal.options.copyOnSelect == copyOnSelectClipboard:
        discard terminal.copySelection(services, clear = false)
      services.invalidate()
      return true
    else:
      return false
  of ui.InputKind.InputScroll:
    if not terminal.state.hasGrid or event.dy == 0:
      return false
    let grid = terminal.state.grid
    let cellHeight = max(grid.cellHeight, 1'f32)
    var delta = event.dy
    if not event.precise:
      delta = delta / 40 * 3 * cellHeight
    terminal.state.scrollRemainder += delta
    let rows = int(terminal.state.scrollRemainder / cellHeight)
    if rows == 0:
      return true
    terminal.state.scrollRemainder -= float32(rows) * cellHeight
    let scale = max(terminal.state.scale, 0.01'f32)
    if terminal.session.mouseTracking() and
        (event.mods and ui.modShift) == 0:
      let paddingX = int(round(terminal.options.font.paddingX * scale))
      let paddingY = int(round(terminal.options.font.paddingY * scale))
      let screenWidth = paddingX * 2 + grid.cols * grid.cellWidthPixels
      let screenHeight = paddingY * 2 + grid.rows * grid.cellHeightPixels
      let wheel = if rows < 0: vtInput.wheelUp else: vtInput.wheelDown
      for _ in 0 ..< abs(rows):
        discard terminal.session.sendMouse(vtInput.mousePress, wheel,
          keyMods(event.mods), event.x * scale, event.y * scale,
          screenWidth, screenHeight, grid.cellWidthPixels,
          grid.cellHeightPixels, paddingX, paddingY, false)
      return true
    if terminal.session.activeScreen() and
        terminal.session.mode(vtTerminal.modeAltScroll):
      let key = if rows < 0: vtInput.keyArrowUp else: vtInput.keyArrowDown
      for _ in 0 ..< abs(rows):
        terminal.session.sendKey(vtInput.KeyEvent(action: vtInput.keyPress,
          key: key, mods: keyMods(event.mods)), terminal.options.optionAsAlt)
      return true
    terminal.session.scrollBy(rows)
    return true
  of ui.InputKind.InputSelect:
    return false

proc view*(context: ui.Context; terminal: Terminal): ui.Element =
  ## Builds a focusable native GPU terminal view.
  if terminal == nil or terminal.closed:
    raise newException(ValueError, "cannot build a view for a closed terminal")
  let services = context.services()
  let uiTheme = context.theme()
  let darkAppearance = uiTheme.dark
  terminal.state.scrollbarWidth = uiTheme.scrollbarWidth
  terminal.session.setWake(proc() = services.invalidate())
  terminal.dispatchEvents()
  result = ui.box(context).direction(ui.Direction.LeftToRight).focusable()
    .focusRing(false).clip().label("Terminal")
  let focused = result.focused()
  if not terminal.state.hasFocus or focused != terminal.state.focused:
    terminal.state.focused = focused
    terminal.state.hasFocus = true
    terminal.state.blinkStart = getMonoTime()
    if not focused:
      terminal.state.preedit.setLen(0)
      terminal.state.pendingTyped = false
      terminal.state.hasPendingKey = false
    terminal.session.sendFocus(focused)
  let elapsed = (getMonoTime() - terminal.state.blinkStart).inMilliseconds
  let blinkPhase = elapsed mod 1200
  let cursorBlinkOn = terminal.options.noBlink or not focused or
    blinkPhase < 600
  if terminal.state.ticking:
    terminal.tickSelection()
    if terminal.state.ticking:
      context.after(initDuration(milliseconds = 40))
  var frame = terminal.session.snapshot()
  terminal.state.cursorBlinking = frame.cursor.visible and frame.cursor.blinking
  if focused and terminal.state.cursorBlinking:
    let untilChange = if blinkPhase < 600: 600 - blinkPhase else: 1200 - blinkPhase
    if not terminal.options.noBlink:
      context.after(initDuration(milliseconds = untilChange))

  discard result.handleInput(proc(event: ui.InputEvent): bool =
    terminal.handleInput(services, event))
  discard result.contextMenu(proc(menu: ui.Menu) =
    let selected = terminal.session.selectedText()
    let text = if selected.isSome: selected.get() else: ""
    if menu.item("Copy")
        .disabled(selected.isNone or text.len == 0).chosen:
      services.writeClipboard(text)
    if menu.item("Paste").chosen:
      terminal.pasteClipboard(services)
    if menu.item("Select All").chosen:
      terminal.selectAll(services)
    menu.separator()
    if menu.item("Clear Scrollback").chosen:
      terminal.session.clearScrollback()
      services.invalidate()
  )
  discard result.cursor(ui.cursorText)
  let draw = proc(painter: var ui.Painter; bounds: ui.Rect) =
    terminal.state.bounds = bounds
    let theme = terminal.applyTheme(darkAppearance)
    var themeChanged = false
    if theme != terminal.state.appliedTheme:
      theme.apply(terminal.session)
      terminal.state.appliedTheme = theme
      themeChanged = true
    var paintOptions = terminal.options.font
    paintOptions.focused = focused
    paintOptions.cursorBlinkOn = cursorBlinkOn
    paintOptions.preedit = terminal.state.preedit
    paintOptions.preeditCaret = terminal.state.preeditCaret
    paintOptions.selection = theme.selection
    paintOptions.selectionText = theme.selectionText
    paintOptions.cursor = theme.cursor
    paintOptions.cursorText = theme.cursorText
    let grid = painter.grid(bounds, paintOptions)
    let changed = not terminal.state.hasGrid or
      grid.cols != terminal.state.grid.cols or
      grid.rows != terminal.state.grid.rows or
      grid.cellWidthPixels != terminal.state.grid.cellWidthPixels or
      grid.cellHeightPixels != terminal.state.grid.cellHeightPixels
    if changed:
      terminal.session.resize(grid.cols, grid.rows,
        grid.cellWidthPixels, grid.cellHeightPixels)
      terminal.state.grid = grid
      terminal.state.hasGrid = true
    terminal.state.scale = max(painter.scale(), 0.01'f32)
    if changed or themeChanged:
      frame = terminal.session.snapshot()
    terminal.state.cursorBlinking = frame.cursor.visible and
        frame.cursor.blinking
    paintOptions.cursorBlinkOn = cursorBlinkOn
    painter.paintFrame(bounds, frame, paintOptions)
    painter.paintScrollbar(bounds, terminal.session.scrollbar(),
      uiTheme.scrollbar, uiTheme.scrollbarWidth,
      terminal.options.font.paddingX, terminal.options.font.paddingY)
  discard ui.draw(result, draw)
