## internal/gpu/d3d11/device.nim (d3d11/device/device.go): creates
## Direct3D 11 devices — the device of package d3d11's renderer, and
## that of the Windows backend, which shows the controls of windows
## with a material through DirectComposition without the renderer.
## It depends on nothing of mynim, so apps that draw no native UI
## link none of the renderer.

import std/dynlib
import std/widestrs

var procD3D11CreateDevice*: proc(a0, a1, a2, a3, a4, a5, a6, a7, a8,
    a9: uint): uint {.stdcall.}

## systemDir returns the system directory, which system DLLs load
## from, never from the application directory or the search path.
proc systemDir*(): string =
  var buf = newSeq[Utf16Char](260)
  let k = loadLib("kernel32.dll")
  if k.isNil:
    return "C:\\Windows\\System32"
  let p = symAddr(k, "GetSystemDirectoryW")
  if p.isNil:
    return "C:\\Windows\\System32"
  let getDir = cast[proc(a0: pointer, a1: cint): cint {.stdcall.}](p)
  let n = getDir(addr buf[0], cint(buf.len))
  if n == 0 or int(n) > buf.len:
    return "C:\\Windows\\System32"
  $cast[WideCString](addr buf[0])

proc bindDevice*() =
  if procD3D11CreateDevice.isNil:
    let lib = loadLib(systemDir() & "\\d3d11.dll")
    if not lib.isNil:
      procD3D11CreateDevice = cast[typeof(procD3D11CreateDevice)](
        symAddr(lib, "D3D11CreateDevice"))

## new creates a Direct3D 11 device and its immediate context, on
## the GPU or, when there is none, with Windows' software rasterizer
## (WARP), which software reports. The caller releases the device
## and the context.
proc newDevice*(): tuple[device, context: uint, software: bool,
    err: string] =
  bindDevice()
  if procD3D11CreateDevice.isNil:
    return (0'u, 0'u, false, "no D3D11CreateDevice")
  var levels = [0xb000'u32, 0xa100, 0xa000] ## 11_0, 10_1, 10_0
  const bgraSupport = 0x20'u
  const hardware = 1'u
  const warp = 5'u
  var hr = 0'u
  for driver in [hardware, warp]:
    var device, context, level: uint
    hr = procD3D11CreateDevice(0, driver, 0, bgraSupport,
      cast[uint](addr levels[0]), uint(levels.len), 7,
      cast[uint](addr device), cast[uint](addr level),
      cast[uint](addr context))
    if int32(uint32(hr)) >= 0:
      return (device, context, driver == warp, "")
  (0'u, 0'u, false, "d3d11: cannot create a device: " & $uint32(hr))
