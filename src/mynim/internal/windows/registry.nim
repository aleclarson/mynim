## registry.nim (registry.go): registry access for the settings of the
## current user.

const
  keyQueryValue* = 0x0001'u32
  keySetValue* = 0x0002'u32
  regSz* = 1'u32
  hkeyCurrentUser* = 0x80000001'u
  errorFileNotFound = 2'u32

proc regErr(what: string, r: uint): ref CatchableError =
  newException(CatchableError, "mynim: cannot " & what &
    ": " & $r)

## regGetBytes reads a value as it is stored, reporting whether it
## exists.
proc regGetBytes*(root: uint, path, name: string): tuple[data: seq[byte],
    ok: bool] =
  var key: uint
  if procRegOpenKeyExW(uint(root), cast[uint](u16(path)), 0, keyQueryValue,
      cast[uint](addr key)) != 0:
    return (@[], false)
  defer: discard procRegCloseKey(key)
  var size: uint32
  if procRegQueryValueExW(key, cast[uint](u16(name)), 0, 0, 0,
      cast[uint](addr size)) != 0:
    return (@[], false)
  var data = newSeq[byte](size)
  if size > 0:
    if procRegQueryValueExW(key, cast[uint](u16(name)), 0, 0,
        cast[uint](addr data[0]), cast[uint](addr size)) != 0:
      return (@[], false)
  (data[0 ..< int(size)], true)

## regGet reads a string value, reporting whether it exists.
proc regGet*(root: uint, path, name: string): tuple[s: string,
    ok: bool] =
  let (data, ok) = regGetBytes(uint(root), path, name)
  if not ok:
    return ("", false)
  var buf = newSeq[uint16](data.len div 2)
  for i in 0 ..< buf.len:
    buf[i] = uint16(data[2 * i]) or uint16(data[2 * i + 1]) shl 8
  (u16str(buf), true)

## regSet writes a string value, creating the key.
proc regSet*(root: uint, path, name, value: string): ref CatchableError =
  var key: uint
  let r = procRegCreateKeyExW(uint(root), cast[uint](u16(path)), 0, 0, 0,
    uint(keySetValue), 0, cast[uint](addr key), 0)
  if r != 0:
    return regErr("create registry key " & path, r)
  defer: discard procRegCloseKey(key)
  let data = utf16z(value)
  let size = uint(data.len * 2)
  let w = procRegSetValueExW(key, cast[uint](u16(name)), 0, regSz,
    cast[uint](u16Seq(data)), size)
  if w != 0:
    return regErr("write registry value " & path & "\\" & name, w)

## regDeleteValue removes a value; a missing one is not an error.
proc regDeleteValue*(root: uint, path, name: string): ref CatchableError =
  var key: uint
  if procRegOpenKeyExW(uint(root), cast[uint](u16(path)), 0, keySetValue,
      cast[uint](addr key)) != 0:
    return nil
  defer: discard procRegCloseKey(key)
  let r = procRegDeleteValueW(key, cast[uint](u16(name)))
  if r != 0 and uint32(r) != errorFileNotFound:
    return regErr("delete registry value " & path & "\\" & name, r)

## regDeleteTree removes a key and everything in it.
proc regDeleteTree*(root: uint, path: string): ref CatchableError =
  let r = procRegDeleteTreeW(uint(root), cast[uint](u16(path)))
  if r != 0 and uint32(r) != errorFileNotFound:
    return regErr("delete registry key " & path, r)
