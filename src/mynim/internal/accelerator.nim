## Package accelerator parses Electron style keyboard accelerators such as
## "CmdOrCtrl+Shift+Z" into a platform neutral representation.

import std/[strutils, tables, parseutils, unicode]

type
  Modifiers* = distinct uint8
    ## A bit set of modifier keys.

  Accelerator* = object
    ## A parsed accelerator.
    modifiers*: Modifiers
    ## key is either a single lower case character ("a", "1", ",") or one
    ## of the named keys: F1-F24, Enter, Tab, Space, Backspace, Delete,
    ## Insert, Escape, Up, Down, Left, Right, Home, End, PageUp, PageDown,
    ## VolumeUp, VolumeDown, VolumeMute, MediaNextTrack,
    ## MediaPreviousTrack, MediaStop, MediaPlayPause, PrintScreen,
    ## Num0-Num9, NumDec, NumAdd, NumSub, NumMult, NumDiv, CapsLock,
    ## NumLock, ScrollLock.
    key*: string

## Modifier keys. Super is Command on macOS and the Windows/Super key
## elsewhere.
const
  super* = Modifiers(1)
  ctrl* = Modifiers(2)
  alt* = Modifiers(4)
  shift* = Modifiers(8)

proc `or`*(a, b: Modifiers): Modifiers {.borrow.}
proc `and`*(a, b: Modifiers): Modifiers {.borrow.}
proc `==`*(a, b: Modifiers): bool {.borrow.}
proc `|=`*(a: var Modifiers; b: Modifiers) = a = a or b

proc has*(a: Accelerator, m: Modifiers): bool =
  ## Whether all modifiers in m are set.
  (a.modifiers and m) == m

proc `$$`*(a: Accelerator): string =
  ## The accelerator in canonical form.
  var parts: seq[string]
  if a.has(super): parts.add "Super"
  if a.has(ctrl): parts.add "Ctrl"
  if a.has(alt): parts.add "Alt"
  if a.has(shift): parts.add "Shift"
  var key = a.key
  if key.len == 1: key = key.toUpperAscii()
  parts.add key
  parts.join("+")

const namedKeys = {
  "plus": "+", "space": "Space", "tab": "Tab", "capslock": "CapsLock",
  "numlock": "NumLock", "scrolllock": "ScrollLock", "backspace": "Backspace",
  "delete": "Delete", "del": "Delete", "insert": "Insert", "ins": "Insert",
  "return": "Enter", "enter": "Enter", "up": "Up", "down": "Down",
  "left": "Left", "right": "Right", "home": "Home", "end": "End",
  "pageup": "PageUp", "pagedown": "PageDown", "escape": "Escape",
  "esc": "Escape", "volumeup": "VolumeUp", "volumedown": "VolumeDown",
  "volumemute": "VolumeMute", "medianexttrack": "MediaNextTrack",
  "mediaprevioustrack": "MediaPreviousTrack", "mediastop": "MediaStop",
  "mediaplaypause": "MediaPlayPause", "printscreen": "PrintScreen",
  "numdec": "NumDec", "numadd": "NumAdd", "numsub": "NumSub",
  "nummult": "NumMult", "numdiv": "NumDiv",
}.toTable

type AcceleratorError* = object of ValueError

proc acceleratorErr(msg: string): ref AcceleratorError =
  new result; result.msg = msg

proc splitParts(s: string): seq[string] =
  ## Splits on "+" while allowing "+" itself as the key, as in
  ## "CmdOrCtrl++".
  result = s.split("+")
  if s.endsWith("++"):
    result.setLen(result.len - 2)
    result.add "+"
  elif s == "+":
    result = @["+"]

proc modifier(p, goos: string): tuple[m: Modifiers, ok: bool] =
  case p.toLowerAscii()
  of "command", "cmd", "super", "meta", "win":
    (super, true)
  of "control", "ctrl":
    (ctrl, true)
  of "commandorcontrol", "cmdorctrl":
    if goos == "darwin": (super, true) else: (ctrl, true)
  of "alt", "option", "altgr":
    (alt, true)
  of "shift":
    (shift, true)
  else:
    (Modifiers(0), false)

proc parseKey(p: string): string =
  let lower = p.toLowerAscii()
  if runeLen(p) == 1:
    return lower
  if lower in namedKeys:
    return namedKeys[lower]
  if lower.len >= 2 and lower[0] == 'f':
    var n: int
    if parseInt(lower[1..^1], n) == lower.len - 1 and n >= 1 and n <= 24 and
        $n == lower[1..^1]:
      return "F" & $n
  if lower.startsWith("num") and lower.len == 4 and
      lower[3] in {'0'..'9'}:
    return "Num" & lower[3..^1]
  raise acceleratorErr("unknown key " & p.escape())

proc parse*(s, goos: string): Accelerator =
  ## Parses an accelerator for the given GOOS. "CmdOrCtrl" resolves to
  ## Super (Command) on darwin and Ctrl elsewhere.
  if s.strip() == "":
    raise acceleratorErr("accelerator: empty accelerator")
  let parts = splitParts(s)
  for i, raw in parts:
    let p = raw.strip()
    if p == "":
      raise acceleratorErr("accelerator: invalid accelerator " & s.escape())
    let last = i == parts.len - 1
    let (m, isMod) = modifier(p, goos)
    if isMod and not last:
      result.modifiers = result.modifiers or m
      continue
    if not last:
      raise acceleratorErr("accelerator: unknown modifier " & p.escape() &
        " in " & s.escape())
    try:
      result.key = parseKey(p)
    except AcceleratorError as e:
      raise acceleratorErr("accelerator: " & e.msg & " in " & s.escape())

const keysyms = {
  "!": "exclam", "\"": "quotedbl", "#": "numbersign", "$": "dollar",
  "%": "percent", "&": "ampersand", "'": "apostrophe", "(": "parenleft",
  ")": "parenright", "*": "asterisk", "+": "plus", ",": "comma",
  "-": "minus", ".": "period", "/": "slash", ":": "colon",
  ";": "semicolon", "<": "less", "=": "equal", ">": "greater",
  "?": "question", "@": "at", "[": "bracketleft", "\\": "backslash",
  "]": "bracketright", "^": "asciicircum", "_": "underscore",
  "`": "grave", "{": "braceleft", "|": "bar", "}": "braceright",
  "~": "asciitilde",
  "Enter": "Return", "Tab": "Tab", "Space": "space",
  "Backspace": "BackSpace", "Delete": "Delete", "Insert": "Insert",
  "Escape": "Escape", "Up": "Up", "Down": "Down", "Left": "Left",
  "Right": "Right", "Home": "Home", "End": "End", "PageUp": "Page_Up",
  "PageDown": "Page_Down", "VolumeUp": "XF86AudioRaiseVolume",
  "VolumeDown": "XF86AudioLowerVolume", "VolumeMute": "XF86AudioMute",
  "MediaNextTrack": "XF86AudioNext", "MediaPreviousTrack": "XF86AudioPrev",
  "MediaStop": "XF86AudioStop", "MediaPlayPause": "XF86AudioPlay",
  "PrintScreen": "Print", "CapsLock": "Caps_Lock", "NumLock": "Num_Lock",
  "ScrollLock": "Scroll_Lock", "NumDec": "KP_Decimal", "NumAdd": "KP_Add",
  "NumSub": "KP_Subtract", "NumMult": "KP_Multiply", "NumDiv": "KP_Divide",
}.toTable

## Keysym returns the XKB (and X11) name of the key, as in "a", "comma",
## "Return", "F5" or "KP_Add".
proc keysym*(a: Accelerator): string =
  if a.key in keysyms:
    return keysyms[a.key]
  if a.key.startsWith("Num") and a.key.len == 4:
    return "KP_" & a.key[3..^1]
  let r = a.key.toRunes()
  if r.len == 1 and r[0].int32 > ord('~'):
    return "U" & toUpperAscii(toHex(r[0].int32, 4))
  a.key # letters, digits and F1-F24

## XDGTrigger formats the accelerator as a trigger of the XDG shortcuts
## specification, as in "CTRL+SHIFT+k", which desktop portals take.
proc xdgTrigger*(a: Accelerator): string =
  var parts: seq[string]
  for (m, name) in [(ctrl, "CTRL"), (alt, "ALT"), (shift, "SHIFT"),
                    (super, "LOGO")]:
    if a.has(m): parts.add name
  parts.add a.keysym()
  parts.join("+")

