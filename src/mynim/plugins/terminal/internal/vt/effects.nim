## Synchronous effect callbacks for terminal events that need the embedder.
##
## Ghostty invokes these callbacks during VT writes. They must not re-enter
## write() on the same terminal or raise across the C boundary. Calls on a
## terminal must be serialized, and userdata must outlive every callback.

import std/strformat
import ./[library, terminal]

type
  GhosttyResult = int32
  TerminalSetProc = proc(terminal: pointer; option: int32; value: pointer):
    GhosttyResult {.cdecl.}
  TerminalWritePtyFn* = proc(terminal, userdata: pointer;
    data: ptr UncheckedArray[byte]; length: csize_t) {.cdecl.}
  TerminalBellFn* = proc(terminal, userdata: pointer) {.cdecl.}
  TerminalTitleChangedFn* = proc(terminal, userdata: pointer) {.cdecl.}
  TerminalPwdChangedFn* = proc(terminal, userdata: pointer) {.cdecl.}
  TerminalRenderHoldFn* = proc(terminal, userdata: pointer;
    held: bool) {.cdecl.}
  TerminalResetFn* = proc(terminal, userdata: pointer) {.cdecl.}
  TerminalClipboardWriteFn* = proc(terminal, userdata: pointer;
    request: ptr GhosttyClipboardWrite) {.cdecl.}
  TerminalClipboardReadFn* = proc(terminal, userdata, request: pointer) {.cdecl.}
  TerminalDesktopNotificationFn* = proc(terminal, userdata: pointer;
    notification: ptr GhosttyTerminalDesktopNotification) {.cdecl.}
  TerminalCallbacks* = object
    writePty*: TerminalWritePtyFn
    bell*: TerminalBellFn
    titleChanged*: TerminalTitleChangedFn
    pwdChanged*: TerminalPwdChangedFn
    renderHold*: TerminalRenderHoldFn
    reset*: TerminalResetFn
    clipboardWrite*: TerminalClipboardWriteFn
    clipboardRead*: TerminalClipboardReadFn
    desktopNotification*: TerminalDesktopNotificationFn

const
  success: GhosttyResult = 0
  optionUserdata = 0'i32
  optionWritePty = 1'i32
  optionBell = 2'i32
  optionTitleChanged = 5'i32
  optionPwdChanged = 25'i32
  optionClipboardWrite = 26'i32
  optionDesktopNotification = 29'i32
  optionClipboardRead = 38'i32
  optionRenderHold = 41'i32
  optionReset = 43'i32

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc setOption(set: TerminalSetProc; handle: pointer;
               option: int32; value: pointer) =
  let status = set(handle, option, value)
  if status != success:
    raise newException(IOError,
      &"libghostty-vt rejected terminal option {option} with result {status}")

proc callbackPtr[T: proc](callback: T): pointer =
  cast[pointer](callback)

proc setCallbacks*(terminal: GhosttyTerminal; userdata: pointer;
                    callbacks: TerminalCallbacks) =
  ## Installs the supported synchronous effects and their shared userdata.
  let handle = terminal.rawHandle()
  let setProc = cast[TerminalSetProc](requiredSymbol(terminal.ghosttyLibrary(),
    "ghostty_terminal_set"))
  try:
    setOption(setProc, handle, optionUserdata, userdata)
    setOption(setProc, handle, optionWritePty, callbackPtr(callbacks.writePty))
    setOption(setProc, handle, optionBell, callbackPtr(callbacks.bell))
    setOption(setProc, handle, optionTitleChanged,
      callbackPtr(callbacks.titleChanged))
    setOption(setProc, handle, optionPwdChanged,
      callbackPtr(callbacks.pwdChanged))
    setOption(setProc, handle, optionClipboardWrite,
      callbackPtr(callbacks.clipboardWrite))
    setOption(setProc, handle, optionClipboardRead,
      callbackPtr(callbacks.clipboardRead))
    setOption(setProc, handle, optionDesktopNotification,
      callbackPtr(callbacks.desktopNotification))
    setOption(setProc, handle, optionRenderHold,
      callbackPtr(callbacks.renderHold))
    setOption(setProc, handle, optionReset, callbackPtr(callbacks.reset))
  except CatchableError:
    discard setProc(handle, optionWritePty, nil)
    discard setProc(handle, optionBell, nil)
    discard setProc(handle, optionTitleChanged, nil)
    discard setProc(handle, optionPwdChanged, nil)
    discard setProc(handle, optionClipboardWrite, nil)
    discard setProc(handle, optionClipboardRead, nil)
    discard setProc(handle, optionDesktopNotification, nil)
    discard setProc(handle, optionRenderHold, nil)
    discard setProc(handle, optionReset, nil)
    discard setProc(handle, optionUserdata, nil)
    raise

proc clearCallbacks*(terminal: GhosttyTerminal) =
  ## Removes the callbacks before releasing their shared userdata.
  let handle = terminal.rawHandle()
  let setProc = cast[TerminalSetProc](requiredSymbol(terminal.ghosttyLibrary(),
    "ghostty_terminal_set"))
  setOption(setProc, handle, optionWritePty, nil)
  setOption(setProc, handle, optionBell, nil)
  setOption(setProc, handle, optionTitleChanged, nil)
  setOption(setProc, handle, optionPwdChanged, nil)
  setOption(setProc, handle, optionClipboardWrite, nil)
  setOption(setProc, handle, optionClipboardRead, nil)
  setOption(setProc, handle, optionDesktopNotification, nil)
  setOption(setProc, handle, optionRenderHold, nil)
  setOption(setProc, handle, optionReset, nil)
  setOption(setProc, handle, optionUserdata, nil)
