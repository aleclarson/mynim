## Fixed-step game views and 2D cameras for MyGo's native UI.

import std/[math, monotimes, sets, times]
import mynim/ui as ui

const
  Rate* = 60 ## Default number of game updates per second.
  maxCatchUpNanoseconds = 250_000_000'i64

type
  Game* = ref object of RootObj ## A world advanced by a fixed-step game view.
  Input* = ref object ## Keyboard and pointer state sampled by a game step.
    heldKeys: HashSet[ui.Key]
    pressedKeys, releasedKeys: HashSet[ui.Key]
    x, y: float32
    pointerOver: bool
    buttons, pressedButtons, releasedButtons: array[3, bool]
    wheelX, wheelY, width, height: float32
    hasFocus: bool

  GameLoop = ref object
    game: Game
    input: Input
    last: MonoTime
    lagNanoseconds: int64
    wantsFocus, requestedInitialFocus: bool
    focus: ui.Handle

  Camera* = object ## A 2D view of the game world.
    x*, y*: float32 ## World point shown at the center of the view.
    zoom*: float32 ## Magnification; zero means 1.
    rotation*: float32 ## Clockwise camera rotation in degrees.

method update*(game: Game; input: Input) {.base.} =
  ## Advances the game world by one fixed step.
  discard

method draw*(game: Game; painter: var ui.Painter; rect: ui.Rect;
             alpha: float64) {.base.} =
  ## Draws the interpolated world into `rect`.
  discard

method rate*(game: Game): int {.base.} =
  ## Returns the update rate, or `Rate` when the returned value is not positive.
  Rate

proc newInput(): Input =
  Input(heldKeys: initHashSet[ui.Key](),
    pressedKeys: initHashSet[ui.Key](),
    releasedKeys: initHashSet[ui.Key]())

proc down*(input: Input; key: ui.Key): bool =
  ## Reports whether `key` is held.
  input != nil and key in input.heldKeys

proc pressed*(input: Input; key: ui.Key): bool =
  ## Reports whether `key` was pressed since the previous game step.
  input != nil and key in input.pressedKeys

proc released*(input: Input; key: ui.Key): bool =
  ## Reports whether `key` was released since the previous game step.
  input != nil and key in input.releasedKeys

proc pointer*(input: Input): tuple[x, y: float32, over: bool] =
  ## Returns the pointer in view coordinates and whether it is over the view.
  if input != nil:
    result = (input.x, input.y, input.pointerOver)

proc pointerDown*(input: Input; button: int): bool =
  ## Reports whether pointer button 0, 1, or 2 is held.
  input != nil and button >= 0 and button < input.buttons.len and
    input.buttons[button]

proc pointerPressed*(input: Input; button: int): bool =
  ## Reports whether pointer button `button` was pressed since the last step.
  input != nil and button >= 0 and button < input.pressedButtons.len and
    input.pressedButtons[button]

proc pointerReleased*(input: Input; button: int): bool =
  ## Reports whether pointer button `button` was released since the last step.
  input != nil and button >= 0 and button < input.releasedButtons.len and
    input.releasedButtons[button]

proc wheel*(input: Input): tuple[dx, dy: float32] =
  ## Returns accumulated scroll distance since the previous step.
  if input != nil:
    result = (input.wheelX, input.wheelY)

proc size*(input: Input): tuple[width, height: float32] =
  ## Returns the view's size in device-independent pixels.
  if input != nil:
    result = (input.width, input.height)

proc focused*(input: Input): bool =
  ## Reports whether the view has keyboard focus.
  input != nil and input.hasFocus

proc step(input: Input) =
  input.pressedKeys.clear()
  input.releasedKeys.clear()
  input.pressedButtons = [false, false, false]
  input.releasedButtons = [false, false, false]
  input.wheelX = 0
  input.wheelY = 0

proc releaseAll(input: Input) =
  for key in input.heldKeys:
    input.releasedKeys.incl(key)
  input.heldKeys.clear()
  for button, held in input.buttons:
    if held:
      input.releasedButtons[button] = true
  input.buttons = [false, false, false]

proc updatePointer(input: Input; x, y: float32) =
  input.x = x
  input.y = y
  input.pointerOver = x >= 0 and y >= 0 and
    x < input.width and y < input.height

proc handleInput(loop: GameLoop; event: ui.InputEvent): bool =
  let input = loop.input
  case event.kind
  of ui.InputKind.InputKeyDown, ui.InputKind.InputKeyUp:
    if event.kind == ui.InputKind.InputKeyDown and
        (event.mods and (ui.modSuper or ui.modCtrl or ui.modAlt)) != 0:
      return false
    let key = if event.physicalKey != ui.keyUnknown:
        event.physicalKey
      else:
        event.key
    if event.kind == ui.InputKind.InputKeyDown:
      if not event.repeat and key notin input.heldKeys:
        input.pressedKeys.incl(key)
      input.heldKeys.incl(key)
    elif key in input.heldKeys:
      input.releasedKeys.incl(key)
      input.heldKeys.excl(key)
    true
  of ui.InputKind.InputPointerDown, ui.InputKind.InputPointerUp:
    input.updatePointer(event.x, event.y)
    if event.button >= 0 and event.button < input.buttons.len:
      let down = event.kind == ui.InputKind.InputPointerDown
      if down and not input.buttons[event.button]:
        input.pressedButtons[event.button] = true
      elif not down and input.buttons[event.button]:
        input.releasedButtons[event.button] = true
      input.buttons[event.button] = down
    if event.kind == ui.InputKind.InputPointerDown:
      loop.wantsFocus = true
    true
  of ui.InputKind.InputPointerMove:
    input.updatePointer(event.x, event.y)
    true
  of ui.InputKind.InputScroll:
    input.updatePointer(event.x, event.y)
    input.wheelX += event.dx
    input.wheelY += event.dy
    true
  else:
    false

proc draw(loop: GameLoop; painter: var ui.Painter; rect: ui.Rect) =
  loop.input.width = rect.w
  loop.input.height = rect.h
  let now = getMonoTime()
  let configuredRate = loop.game.rate()
  let rate = if configuredRate > 0: configuredRate else: Rate
  let stepNanoseconds = max(1_000_000_000'i64 div int64(rate), 1'i64)
  if loop.last != MonoTime():
    let elapsed = max((now - loop.last).inNanoseconds, 0'i64)
    loop.lagNanoseconds += min(elapsed, maxCatchUpNanoseconds)
  loop.last = now
  while loop.lagNanoseconds >= stepNanoseconds:
    loop.game.update(loop.input)
    loop.input.step()
    loop.lagNanoseconds -= stepNanoseconds
  loop.game.draw(painter, rect,
    float64(loop.lagNanoseconds) / float64(stepNanoseconds))

proc view*(context: ui.Context; game: Game): ui.Element =
  ## Creates an element that updates `game` in fixed steps and draws each frame.
  if context == nil or game == nil:
    raise newException(ValueError, "game: view needs a context and game")
  result = context.box().focusable()
  let state = result.local("mynim.game.loop", proc(): GameLoop =
    GameLoop(input: newInput(), focus: ui.newHandle()))
  if state == nil:
    return
  let loop = state.value
  loop.game = game
  discard result.bindHandle(loop.focus)
  if not loop.requestedInitialFocus:
    loop.requestedInitialFocus = true
    loop.focus.focus(context)
  if loop.wantsFocus:
    loop.wantsFocus = false
    loop.focus.focus(context)
  loop.input.hasFocus = loop.focus.focused(context)
  if not loop.input.hasFocus:
    loop.input.releaseAll()
  context.animationFrame()
  discard result.handleInput(proc(event: ui.InputEvent): bool =
    loop.handleInput(event)
  )
  discard result.draw(proc(painter: var ui.Painter; rect: ui.Rect) =
    loop.draw(painter, rect)
  )

proc zoom(camera: Camera): float32 =
  if camera.zoom == 0: 1'f32 else: camera.zoom

proc transform*(camera: Camera; rect: ui.Rect): ui.Transform =
  ## Returns the world-to-view transform for `rect`, with origin at (0, 0).
  result = ui.translation(-camera.x, -camera.y)
  if camera.rotation != 0:
    result = result.then(ui.rotation(-camera.rotation))
  result = result.then(ui.scaling(camera.zoom(), camera.zoom()))
    .then(ui.translation(rect.x + rect.w / 2, rect.y + rect.h / 2))

proc draw*(camera: Camera; painter: var ui.Painter; rect: ui.Rect;
           callback: proc(painter: var ui.Painter) {.closure.}) =
  ## Draws world coordinates through the camera, clipped to `rect`.
  if callback == nil:
    raise newException(ValueError, "game: camera draw callback is nil")
  var transform = camera.transform(rect)
  if camera.rotation == 0:
    let zoom = camera.zoom()
    let scale = painter.scale()
    if scale > 0:
      proc snap(value: float32): float32 =
        round(value * scale) / scale
      transform = ui.scaling(zoom, zoom).then(ui.translation(
        snap(rect.x + rect.w / 2 - camera.x * zoom),
        snap(rect.y + rect.h / 2 - camera.y * zoom)))
  painter.clip(rect, 0, proc(clipped: var ui.Painter) =
    clipped.transform(transform, 0, 0, proc(transformed: var ui.Painter) =
      callback(transformed)
    )
  )

proc toWorld*(camera: Camera; rect: ui.Rect; x, y: float32):
    tuple[x, y: float32] =
  ## Converts a point within `rect` from view coordinates to world coordinates.
  let zoom = camera.zoom()
  var dx = (x - rect.w / 2) / zoom
  var dy = (y - rect.h / 2) / zoom
  if camera.rotation != 0:
    let angle = float64(camera.rotation) * PI / 180
    let sinAngle = float32(sin(angle))
    let cosAngle = float32(cos(angle))
    (camera.x + dx * cosAngle - dy * sinAngle,
     camera.y + dx * sinAngle + dy * cosAngle)
  else:
    (camera.x + dx, camera.y + dy)

proc visible*(camera: Camera; rect: ui.Rect): ui.Rect =
  ## Returns the world-space bounds visible through the camera.
  let corners = [(0'f32, 0'f32), (rect.w, 0'f32), (0'f32, rect.h),
    (rect.w, rect.h)]
  var minX = Inf.float32
  var maxX = NegInf.float32
  var minY = Inf.float32
  var maxY = NegInf.float32
  for (x, y) in corners:
    let (worldX, worldY) = camera.toWorld(rect, x, y)
    minX = min(minX, worldX)
    maxX = max(maxX, worldX)
    minY = min(minY, worldY)
    maxY = max(maxY, worldY)
  ui.Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)

proc integerFit*(painter: ui.Painter; width, height: int; rect: ui.Rect):
    tuple[rect: ui.Rect, scale: int] =
  ## Fits a canvas at the largest whole pixel multiple, centered in `rect`.
  if width <= 0 or height <= 0:
    return (ui.Rect(), 0)
  let surfaceScale = painter.scale()
  if surfaceScale <= 0:
    return (ui.Rect(), 0)
  let multiple = max(int(min(rect.w * surfaceScale / float32(width),
    rect.h * surfaceScale / float32(height))), 1)
  let drawWidth = float32(width * multiple) / surfaceScale
  let drawHeight = float32(height * multiple) / surfaceScale
  let x = float32(int((rect.x + (rect.w - drawWidth) / 2) * surfaceScale +
    0.5'f32)) / surfaceScale
  let y = float32(int((rect.y + (rect.h - drawHeight) / 2) * surfaceScale +
    0.5'f32)) / surfaceScale
  (ui.Rect(x: x, y: y, w: drawWidth, h: drawHeight), multiple)
