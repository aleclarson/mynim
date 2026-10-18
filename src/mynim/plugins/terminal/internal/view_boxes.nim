## Box drawing, block, and Powerline characters drawn to fill terminal cells.

import std/math
import mynim/ui as ui

type PixelRect = object
  x0, y0, x1, y1: float32

const
  armNone = 0
  armLight = 1
  armHeavy = 2
  armDouble = 3
  boxArms = [
    "0101", "0202", "1010", "2020", "", "", "", "", "", "", "", "",
    "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",
    "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",
    "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
    "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",
    "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",
    "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
    "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",
    "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222",
    "", "", "", "", "0303", "3030", "0310", "0130", "0330", "0013",
    "0031", "0033", "1300", "3100", "3300", "1003", "3001", "3003",
    "1310", "3130", "3330", "1013", "3031", "3033", "0313", "0131",
    "0333", "1303", "3101", "3303", "1313", "3131", "3333", "", "", "",
    "", "", "", "", "0001", "1000", "0100", "0010", "0002", "2000",
    "0200", "0020", "0201", "1020", "0102", "2010"]

static:
  doAssert boxArms.len == 128

proc drawn*(codepoint: uint32): bool =
  if codepoint in 0x2500'u32 .. 0x257f'u32:
    return boxArms[int(codepoint - 0x2500)] != "" or
      codepoint in 0x256d'u32 .. 0x2573'u32
  codepoint in 0x2580'u32 .. 0x259f'u32 or
    codepoint in 0xe0b0'u32 .. 0xe0b3'u32

proc addFill(fills: var seq[PixelRect]; x0, y0, x1, y1: float32) =
  if x1 > x0 and y1 > y0:
    fills.add(PixelRect(x0: x0, y0: y0, x1: x1, y1: y1))

proc drawArms(fills: var seq[PixelRect]; arms: array[4, int];
    x0, y0, x1, y1, mx, my, light: float32) =
  let
    up = arms[0]
    right = arms[1]
    down = arms[2]
    left = arms[3]
    off = light
    vDouble = up == armDouble or down == armDouble
    hDouble = left == armDouble or right == armDouble
  let thick = proc(weight: int): float32 =
    case weight
    of armHeavy: 2 * light
    of armDouble: 2 * off + light
    else: light
  let
    hw = max(thick(left), thick(right))
    vw = max(thick(up), thick(down))
    single = proc(weight: int): bool = weight in {armLight, armHeavy}
  if single(up):
    let t = thick(up)
    var finish = my + hw / 2
    if hDouble and down == armNone:
      finish = my - off + light / 2
    fills.addFill(mx - t / 2, y0, mx + t / 2, finish)
  if single(down):
    let t = thick(down)
    var start = my - hw / 2
    if hDouble and up == armNone:
      start = my + off - light / 2
    fills.addFill(mx - t / 2, start, mx + t / 2, y1)
  if single(left):
    let t = thick(left)
    var finish = mx + vw / 2
    if vDouble and right == armNone:
      finish = mx - off + light / 2
    fills.addFill(x0, my - t / 2, finish, my + t / 2)
  if single(right):
    let t = thick(right)
    var start = mx - vw / 2
    if vDouble and left == armNone:
      start = mx + off - light / 2
    fills.addFill(start, my - t / 2, x1, my + t / 2)

  for side in [-1'f32, 1'f32]:
    if vDouble:
      let lx = mx + side * off - light / 2
      let across = if side > 0: right else: left
      if up == armDouble and down == armDouble and across != armDouble:
        fills.addFill(lx, y0, lx + light, y1)
      else:
        var inside = my - off + light / 2
        var outside = my + off + light / 2
        if across == armDouble:
          outside = inside
        elif not hDouble:
          outside = my + light / 2
        if up == armDouble:
          fills.addFill(lx, y0, lx + light, outside)
        inside = my + off - light / 2
        outside = my - off - light / 2
        if across == armDouble:
          outside = inside
        elif not hDouble:
          outside = my - light / 2
        if down == armDouble:
          fills.addFill(lx, outside, lx + light, y1)
    if hDouble:
      let ly = my + side * off - light / 2
      let across = if side > 0: down else: up
      if left == armDouble and right == armDouble and across != armDouble:
        fills.addFill(x0, ly, x1, ly + light)
      else:
        var inside = mx - off + light / 2
        var outside = mx + off + light / 2
        if across == armDouble:
          outside = inside
        elif not vDouble:
          outside = mx + light / 2
        if left == armDouble:
          fills.addFill(x0, ly, outside, ly + light)
        inside = mx + off - light / 2
        outside = mx - off - light / 2
        if across == armDouble:
          outside = inside
        elif not vDouble:
          outside = mx - light / 2
        if right == armDouble:
          fills.addFill(outside, ly, x1, ly + light)

proc drawBlock(painter: var ui.Painter; codepoint: uint32;
    x0, y0, width, height, scale: float32; color: ui.Color;
    fills: var seq[PixelRect]) =
  let
    x1 = x0 + width
    y1 = y0 + height
    rx = proc(fraction: float32): float32 =
      x0 + float32(round(float64(width * fraction)))
    ry = proc(fraction: float32): float32 =
      y0 + float32(round(float64(height * fraction)))
  case codepoint
  of 0x2580:
    fills.addFill(x0, y0, x1, ry(0.5'f32))
  of 0x2581'u32 .. 0x2588'u32:
    fills.addFill(x0, ry(1 - float32(codepoint - 0x2580'u32) / 8), x1, y1)
  of 0x2589'u32 .. 0x258f'u32:
    fills.addFill(x0, y0, rx(float32(0x2590'u32 - codepoint) / 8), y1)
  of 0x2590:
    fills.addFill(rx(0.5'f32), y0, x1, y1)
  of 0x2591'u32 .. 0x2593'u32:
    let alpha = float32(codepoint - 0x2590'u32) / 4
    painter.fill(ui.Rect(x: x0 / scale, y: y0 / scale,
      w: width / scale, h: height / scale), color.alpha(alpha), 0)
  of 0x2594:
    fills.addFill(x0, y0, x1, ry(1 / 8))
  of 0x2595:
    fills.addFill(rx(7 / 8), y0, x1, y1)
  else:
    let mx = rx(0.5'f32)
    let my = ry(0.5'f32)
    case codepoint
    of 0x2596: fills.addFill(x0, my, mx, y1)
    of 0x2597: fills.addFill(mx, my, x1, y1)
    of 0x2598: fills.addFill(x0, y0, mx, my)
    of 0x2599:
      fills.addFill(x0, y0, mx, y1)
      fills.addFill(mx, my, x1, y1)
    of 0x259a:
      fills.addFill(x0, y0, mx, my)
      fills.addFill(mx, my, x1, y1)
    of 0x259b:
      fills.addFill(x0, y0, x1, my)
      fills.addFill(x0, my, mx, y1)
    of 0x259c:
      fills.addFill(x0, y0, x1, my)
      fills.addFill(mx, my, x1, y1)
    of 0x259d: fills.addFill(mx, y0, x1, my)
    of 0x259e:
      fills.addFill(mx, y0, x1, my)
      fills.addFill(x0, my, mx, y1)
    of 0x259f:
      fills.addFill(mx, y0, x1, y1)
      fills.addFill(x0, my, mx, y1)
    else: discard

proc draw*(painter: var ui.Painter; codepoint: uint32; rect: ui.Rect;
           color: ui.Color) =
  ## Draws a supported box, block, or Powerline rune in its terminal cell.
  if not codepoint.drawn:
    return
  let scale = painter.scale()
  let
    x0 = float32(round(float64(rect.x * scale)))
    y0 = float32(round(float64(rect.y * scale)))
    x1 = float32(round(float64((rect.x + rect.w) * scale)))
    y1 = float32(round(float64((rect.y + rect.h) * scale)))
    width = x1 - x0
    height = y1 - y0
    light = max(1'f32, float32(round(float64(scale))))
    cx = x0 + float32(floor(float64(width - light) / 2))
    cy = y0 + float32(floor(float64(height - light) / 2))
  var fills: seq[PixelRect]

  if codepoint in 0x2580'u32 .. 0x259f'u32:
    painter.drawBlock(codepoint, x0, y0, width, height, scale, color, fills)
  elif codepoint in 0xe0b0'u32 .. 0xe0b3'u32:
    let path = ui.newPath()
    if codepoint == 0xe0b0'u32 or codepoint == 0xe0b1'u32:
      discard path.moveTo(x0 / scale, y0 / scale)
        .lineTo(x1 / scale, (y0 + height / 2) / scale)
        .lineTo(x0 / scale, y1 / scale)
    else:
      discard path.moveTo(x1 / scale, y0 / scale)
        .lineTo(x0 / scale, (y0 + height / 2) / scale)
        .lineTo(x1 / scale, y1 / scale)
    if codepoint == 0xe0b0'u32 or codepoint == 0xe0b2'u32:
      discard path.close()
      painter.fillPath(path, color)
    else:
      painter.strokePath(path, light / scale, color)
    return
  elif codepoint in 0x256d'u32 .. 0x2573'u32:
    let path = ui.newPath()
    let mx = (cx + light / 2) / scale
    let my = (cy + light / 2) / scale
    let radius = min(width, height) / 2 / scale
    case codepoint
    of 0x256d:
      discard path.moveTo(mx, y1 / scale).lineTo(mx, my + radius)
        .quadTo(mx, my, mx + radius, my).lineTo(x1 / scale, my)
    of 0x256e:
      discard path.moveTo(mx, y1 / scale).lineTo(mx, my + radius)
        .quadTo(mx, my, mx - radius, my).lineTo(x0 / scale, my)
    of 0x256f:
      discard path.moveTo(mx, y0 / scale).lineTo(mx, my - radius)
        .quadTo(mx, my, mx - radius, my).lineTo(x0 / scale, my)
    of 0x2570:
      discard path.moveTo(mx, y0 / scale).lineTo(mx, my - radius)
        .quadTo(mx, my, mx + radius, my).lineTo(x1 / scale, my)
    of 0x2571:
      discard path.moveTo(x1 / scale, y0 / scale).lineTo(x0 / scale, y1 / scale)
    of 0x2572:
      discard path.moveTo(x0 / scale, y0 / scale).lineTo(x1 / scale, y1 / scale)
    of 0x2573:
      discard path.moveTo(x1 / scale, y0 / scale).lineTo(x0 / scale, y1 / scale)
      painter.strokePath(path, light / scale, color)
      let second = ui.newPath()
      discard second.moveTo(x0 / scale, y0 / scale)
        .lineTo(x1 / scale, y1 / scale)
      painter.strokePath(second, light / scale, color)
      return
    else: discard
    painter.strokePath(path, light / scale, color)
    return
  else:
    let arms = boxArms[int(codepoint - 0x2500'u32)]
    if arms.len != 4:
      return
    var weights: array[4, int]
    for i, arm in arms:
      weights[i] = ord(arm) - ord('0')
    fills.drawArms(weights, x0, y0, x1, y1,
      cx + light / 2, cy + light / 2, light)

  for fill in fills:
    painter.fill(ui.Rect(x: fill.x0 / scale, y: fill.y0 / scale,
      w: (fill.x1 - fill.x0) / scale, h: (fill.y1 - fill.y0) / scale),
      color, 0)
