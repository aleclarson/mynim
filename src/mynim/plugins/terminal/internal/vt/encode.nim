## Focus and paste helpers backed by libghostty-vt.

import std/strformat
import ./library

type
  GhosttyResult = int32
  FocusEncodeProc = proc(unfocused: bool; output: ptr UncheckedArray[byte];
    capacity: csize_t; written: ptr csize_t): GhosttyResult {.cdecl.}
  PasteEncodeProc = proc(data: ptr UncheckedArray[byte]; dataLen: csize_t;
    bracketed: bool; output: ptr UncheckedArray[byte]; capacity: csize_t;
    written: ptr csize_t): GhosttyResult {.cdecl.}
  PasteIsSafeProc = proc(data: ptr UncheckedArray[byte]; dataLen: csize_t): bool {.cdecl.}

const
  Success: GhosttyResult = 0
  OutOfSpace: GhosttyResult = -3

proc requiredSymbol(library: GhosttyVT; name: string): pointer =
  result = library.symbol(name)
  if result.isNil:
    raise newException(IOError, "libghostty-vt is missing " & name)

proc raiseResultError(name: string; code: GhosttyResult) {.noReturn.} =
  raise newException(IOError, &"libghostty-vt {name} failed with result {code}")

proc encodeFocus*(library: GhosttyVT; gained: bool): seq[byte] =
  ## Encodes the terminal focus gained/lost report (mode 1004).
  let encode = cast[FocusEncodeProc](requiredSymbol(library,
    "ghostty_focus_encode"))
  var output: array[8, byte]
  var written: csize_t
  let status = encode(not gained,
    cast[ptr UncheckedArray[byte]](addr output[0]),
    csize_t(output.len), addr written)
  if status != Success:
    raiseResultError("focus encoding", status)
  if written > csize_t(output.len):
    raise newException(IOError,
      "libghostty-vt returned an oversized focus report")
  result = newSeq[byte](int(written))
  if written > 0:
    copyMem(addr result[0], addr output[0], int(written))

proc encodePaste*(library: GhosttyVT; text: string;
                  bracketed: bool): seq[byte] =
  ## Encodes pasted bytes, sanitizing controls and optionally bracketing them.
  if text.len == 0:
    return
  if text.len > high(int) - 16:
    raise newException(ValueError, "paste is too large to encode")
  let encode = cast[PasteEncodeProc](requiredSymbol(library,
    "ghostty_paste_encode"))
  var data = newSeq[byte](text.len)
  copyMem(addr data[0], unsafeAddr text[0], text.len)
  var output = newSeq[byte](text.len + 16)
  var written: csize_t
  var status = encode(cast[ptr UncheckedArray[byte]](addr data[0]),
    csize_t(data.len), bracketed,
    cast[ptr UncheckedArray[byte]](addr output[0]),
    csize_t(output.len), addr written)
  if status == OutOfSpace and written > 0:
    if written > csize_t(high(int)):
      raise newException(IOError,
        "libghostty-vt requested an unrepresentable paste buffer")
    data = newSeq[byte](text.len)
    copyMem(addr data[0], unsafeAddr text[0], text.len)
    output = newSeq[byte](int(written))
    status = encode(cast[ptr UncheckedArray[byte]](addr data[0]),
      csize_t(data.len), bracketed,
      cast[ptr UncheckedArray[byte]](addr output[0]),
      csize_t(output.len), addr written)
  if status != Success:
    raiseResultError("paste encoding", status)
  if written > csize_t(output.len):
    raise newException(IOError,
      "libghostty-vt returned an oversized paste")
  output.setLen(int(written))
  result = move(output)

proc pasteIsSafe*(library: GhosttyVT; text: string): bool =
  ## Reports whether the pasted text cannot run a command by itself.
  if text.len == 0:
    return true
  let check = cast[PasteIsSafeProc](requiredSymbol(library,
    "ghostty_paste_is_safe"))
  var data = newSeq[byte](text.len)
  copyMem(addr data[0], unsafeAddr text[0], text.len)
  check(cast[ptr UncheckedArray[byte]](addr data[0]), csize_t(data.len))
