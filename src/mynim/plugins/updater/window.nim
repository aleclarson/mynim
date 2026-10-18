## Native UI window for the updater's current view.

import std/[locks, math, sequtils]

import mynim as app
import mynim/plugins/updater/frontend as frontend
import mynim/plugins/updater/notes as notes
import mynim/image as sourceImage
import mynim/ui as ui

type
  MainWindow = typeof(app.newWindow(app.WindowOptions()))

  Respond* = proc(prompt: int; action: frontend.Action;
                  automaticDownloads: bool) {.closure.}

  UpdaterWindow* = ref object
    guard: Lock
    current: frontend.View
    texts*: frontend.Texts
    user: bool
    checked: bool
    checkedPrompt, answeredPrompt: int
    onRespond: Respond
    onClose: proc() {.closure.}
    icon: ui.Bitmap
    notesState: notes.NotesState
    fittedWidth, fittedHeight: int
    window: MainWindow

proc newUpdaterWindow*(texts: frontend.Texts; initial: frontend.View;
                       onRespond: Respond; user = true;
                       onClose: proc() {.closure.} = nil;
                       iconPng: seq[byte] = @[]): UpdaterWindow =
  ## Creates a native updater window controller before opening its window.
  var icon: ui.Bitmap
  if iconPng.len > 0:
    let decoded = sourceImage.pngDecode(iconPng)
    if decoded.err == nil:
      icon = ui.newBitmap(decoded.img)
  result = UpdaterWindow(texts: texts, current: initial, user: user,
    checked: initial.checked, checkedPrompt: initial.prompt,
    answeredPrompt: -1, onRespond: onRespond, onClose: onClose,
    icon: icon, notesState: notes.newNotesState())
  initLock(result.guard)

proc currentView(state: UpdaterWindow): frontend.View =
  acquire(state.guard)
  result = state.current
  release(state.guard)

proc answered(state: UpdaterWindow; prompt: int): bool =
  acquire(state.guard)
  result = state.answeredPrompt == prompt
  release(state.guard)

proc respond(state: UpdaterWindow; view: frontend.View;
             button: frontend.Button) =
  if button.disabled:
    return
  acquire(state.guard)
  let valid = state.current.prompt == view.prompt and
    state.answeredPrompt != view.prompt and
    state.current.buttons.anyIt(it.action == button.action and not it.disabled)
  if valid:
    state.answeredPrompt = view.prompt
  let checked = state.checked
  release(state.guard)
  if valid and state.onRespond != nil:
    state.onRespond(view.prompt, button.action, checked)

proc setView*(state: UpdaterWindow; view: frontend.View) =
  ## Replaces the view and resizes the window when status/release layout changes.
  if state == nil:
    return
  acquire(state.guard)
  let releaseChanged = state.current.release != view.release
  state.current = view
  if releaseChanged:
    state.fittedWidth = 0
    state.fittedHeight = 0
  release(state.guard)
  if state.window != nil:
    if releaseChanged:
      let (width, height) = frontend.size(view.release)
      state.window.setContentSize(width, height)
      state.window.center()
    state.window.invalidate()

proc updateTheme(c: ui.Context): ui.Theme =
  result = c.theme()
  let black = ui.rgb(0, 0, 0)
  if result.dark:
    result.background = ui.parseColor("#1e1e1e")
    result.surface = ui.parseColor("#5b5b5f")
    result.border = ui.rgba(255, 255, 255, 0.15'f32)
    result.text = ui.parseColor("#f5f5f7")
    result.textMuted = ui.parseColor("#98989d")
    result.accent = ui.parseColor("#0a84ff")
  else:
    result.background = ui.parseColor("#ececec")
    result.surface = ui.parseColor("#ffffff")
    result.border = ui.rgba(0, 0, 0, 0.15'f32)
    result.text = ui.parseColor("#1d1d1f")
    result.textMuted = ui.parseColor("#6e6e73")
    result.accent = ui.parseColor("#007aff")
  result.surfaceHover = result.surface.mix(black, 0.05'f32)
  result.surfacePressed = result.surface.mix(black, 0.1'f32)
  result.accentHover = result.accent.mix(black, 0.08'f32)
  result.accentPressed = result.accent.mix(black, 0.16'f32)
  result.selection = result.accent.alpha(0.25'f32)
  result.focus = result.accent.alpha(0.55'f32)

proc row(c: ui.Context; rtl: bool): ui.Element =
  result = c.row()
  if rtl:
    result = result.reverse()

proc buttonHeight(theme: ui.Theme): float32 =
  round(theme.fontSize * (24'f32 / 13))

proc buttons(state: UpdaterWindow; c: ui.Context; theme: ui.Theme;
             view: frontend.View; aside: bool) =
  for index in 0..<view.buttons.len:
    let source = view.buttons[index]
    let button = frontend.Button(action: source.action, label: source.label,
      default: source.default, cancel: source.cancel, aside: source.aside,
      disabled: source.disabled)
    if button.aside != aside:
      continue
    var element = if button.default:
        c.primaryButton("")
      else:
        c.button("").shadow(0, 1, 1, 0, ui.rgba(0, 0, 0, 0.08'f32))
    element = element.key($button.action)
      .padding(0, 14).height(buttonHeight(theme)).minWidth(84)
      .disabled(button.disabled or state.answered(view.prompt))
    discard element.children(proc() = discard c.text(button.label).noWrap())
    if element.clicked():
      state.respond(view, button)

proc buildBody(state: UpdaterWindow; c: ui.Context; theme: ui.Theme;
               view: frontend.View) =
  let small = theme.fontSize * (11'f32 / 13)
  discard c.text(view.title).textWeight(700).margin(0, 0, 4, 0)
  if view.message.len > 0:
    discard c.text(view.message).margin(0, 0, 6, 0)
  if view.bar:
    discard c.progress(view.progress).margin(6, 0, 4, 0)
  if view.detail.len > 0:
    discard c.text(view.detail).textSize(small).textColor(theme.textMuted)
      .margin(0, 0, 2, 0)
  if view.notes.len > 0:
    discard c.column().grow().margin(6, 0, 0, 0).children(proc() =
      discard c.text(state.texts.releaseNotes).textSize(small)
        .textWeight(700).margin(0, 0, 4, 0)
      discard notes.render(state.notesState, c, theme, view.notes,
        state.texts.releaseNotes)
        .grow().minHeight(160)
        .background(if theme.dark: ui.parseColor("#141414") else: ui.rgb(255, 255, 255))
        .border(1, theme.border).padding(8, 12)
    )
  if view.checkbox:
    let checkRow = row(c, state.texts.rtl).margin(10, 0, 0, 0)
    discard checkRow.children(proc() =
      discard c.checkbox(state.checked, state.texts.automaticDownloads)
    )

proc textHeight(c: ui.Context; value: string; width, size: float32;
                weight = 0): float32 =
  if value.len > 0:
    result = c.measureText(width, ui.Span(text: value, size: size,
      weight: weight)).height

proc measureReleaseSize*(state: UpdaterWindow; c: ui.Context;
                         theme: ui.Theme; view: frontend.View):
                         tuple[width, height: int] =
  if state == nil or c == nil:
    return frontend.size(true)
  let iconWidth = if state.icon == nil: 0'f32 else: 62'f32
  let textWidth = max(float32(frontend.releaseWidth) - 40 - iconWidth, 1'f32)
  let small = theme.fontSize * (11'f32 / 13)
  var columnHeight = c.textHeight(view.title, textWidth, theme.fontSize, 700) + 4
  if view.message.len > 0:
    columnHeight += c.textHeight(view.message, textWidth, theme.fontSize) + 6
  if view.bar:
    columnHeight += 6 + theme.space(1.5) + 4
  if view.detail.len > 0:
    columnHeight += c.textHeight(view.detail, textWidth, small) + 2
  if view.notes.len > 0:
    let labelHeight = c.textHeight(state.texts.releaseNotes, textWidth,
      small, 700)
    let noteTextWidth = max(textWidth - 26, 1'f32)
    let noteHeight = max(160'f32,
      state.notesState.measureHeight(c, noteTextWidth))
    columnHeight += 6 + labelHeight + 4 + noteHeight + 18
  if view.checkbox:
    let checkboxTextWidth = max(textWidth - theme.space(6), 1'f32)
    columnHeight += 10 + max(theme.space(4), c.textHeight(
      state.texts.automaticDownloads, checkboxTextWidth, theme.fontSize))

  let topHeight = max(columnHeight, if state.icon == nil: 0'f32 else: 44'f32)
  let contentHeight = 38 + 12 + buttonHeight(theme) + topHeight
  frontend.fitSize(true, frontend.releaseWidth,
    int(ceil(contentHeight.float64)))

proc fitReleaseContent(state: UpdaterWindow; c: ui.Context;
                       theme: ui.Theme; view: frontend.View) =
  if not view.release:
    return
  let fitted = state.measureReleaseSize(c, theme, view)
  acquire(state.guard)
  let native = state.window
  release(state.guard)
  if native == nil or native.isDestroyed():
    return
  acquire(state.guard)
  if state.window != native or
      (state.fittedWidth == fitted.width and
       state.fittedHeight == fitted.height):
    release(state.guard)
    return
  state.fittedWidth = fitted.width
  state.fittedHeight = fitted.height
  release(state.guard)
  native.setContentSize(fitted.width, fitted.height)
  native.center()

proc build*(state: UpdaterWindow; c: ui.Context): ui.Element =
  ## Builds the current status or release view in a native UI frame.
  let view = state.currentView()
  let theme = updateTheme(c)
  c.setTheme(theme)
  acquire(state.guard)
  if state.checkedPrompt != view.prompt:
    state.checkedPrompt = view.prompt
    state.checked = view.checked
  release(state.guard)

  result = c.column().fill().padding(18, 20, 20, 20).gap(12)
  let root = result
  discard root.children(proc() =
    let top = row(c, state.texts.rtl).grow().gap(18).alignItems(
      if view.release: ui.Align.Stretch else: ui.Align.Start)
    discard top.children(proc() =
      if state.icon != nil:
        discard c.image(state.icon).size(44, 44).fit(ui.Fit.Contain)
      discard c.column().grow().children(proc() =
        state.buildBody(c, theme, view)
      )
    )
    discard row(c, state.texts.rtl).gap(10).shrink(0).children(proc() =
      discard row(c, state.texts.rtl).gap(10).shrink(0).children(proc() =
        state.buttons(c, theme, view, true)
      )
      discard c.spacer()
      discard row(c, state.texts.rtl).gap(10).shrink(0).children(proc() =
        state.buttons(c, theme, view, false)
      )
    )
  )
  c.onShortcut(0, ui.keyEscape, proc() =
    for button in view.buttons:
      if button.cancel:
        state.respond(view, button)
  )
  c.onShortcut(0, ui.keyEnter, proc() =
    for button in view.buttons:
      if button.default:
        state.respond(view, button)
  )
  state.fitReleaseContent(c, theme, view)

proc open*(state: UpdaterWindow; foreground: bool): MainWindow =
  ## Opens and shows the native update window.
  if state == nil:
    raise newException(ValueError, "updater: window state cannot be nil")
  if state.window != nil and not state.window.isDestroyed():
    if foreground:
      state.window.show()
      state.window.focus()
    return state.window

  let view = state.currentView()
  let (width, height) = frontend.size(view.release)
  let (light, dark) = frontend.background()
  let content = ui.newContent(proc(c: ui.Context) = discard state.build(c))
  state.window = app.newWindow(app.WindowOptions(
    title: state.texts.title, width: width, height: height,
    useContentSize: true, hidden: true, disableResize: true,
    disableMaximize: true, disableFullScreen: true,
    backgroundColor: "light-dark(" & light & ", " & dark & ")",
    content: content
  ))
  if state.onClose != nil:
    discard state.window.onClosed(state.onClose)
  if foreground:
    state.window.show()
    state.window.focus()
  else:
    state.window.showInactive()
  result = state.window

proc open*(state: UpdaterWindow): MainWindow =
  ## Opens the window using the foreground setting passed to its constructor.
  state.open(state.user)

proc close*(state: UpdaterWindow) =
  ## Closes the native window if it is open.
  if state != nil and state.window != nil and not state.window.isDestroyed():
    state.window.close()
