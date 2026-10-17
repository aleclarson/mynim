## Shared-mode WASAPI output for Windows.

import std/[monotimes, times, unicode, strutils]
import ../audio_output_types

const
  windowsFrames* = 480
  sampleRate = 48_000'u32
  channels = 2'u32
  clsctxAll = 0x17'u32
  coinitMultithreaded = 0'u32
  eRender = 0'u32
  eConsole = 0'u32
  waveFormatExtensibleTag = 0xFFFE'u16
  speakerFrontLeft = 0x1'u32
  speakerFrontRight = 0x2'u32
  audclntShareModeShared = 0'u32
  audclntStreamFlagsEventCallback = 0x0004_0000'u32
  audclntStreamFlagsNoPersist = 0x0008_0000'u32
  audclntStreamFlagsAutoConvert = 0x8000_0000'u32
  audclntStreamFlagsSrcQuality = 0x0800_0000'u32
  waitFailed = 0xFFFF_FFFF'u32
  eNotFound = 0x8007_0490'u32

type
  Guid = object
    data1: uint32
    data2, data3: uint16
    data4: array[8, byte]

  WaveFormatExtensible = object
    formatTag, channelCount: uint16
    samplesPerSec, avgBytesPerSec: uint32
    blockAlign, bitsPerSample, extraSize, validBits: uint16
    channelMask: uint32
    subFormat: Guid

  WindowsAudioOutput = ref object of AudioOutput
    enumerator, client, render: uint
    event: uint
    frames: uint32
    endpointId: string
    checked: MonoTime
    comInitialized: bool

static:
  doAssert sizeof(Guid) == 16
  doAssert sizeof(WaveFormatExtensible) == 40

const
  clsidMMDeviceEnumerator = Guid(data1: 0xBCDE0395'u32,
    data2: 0xE52F'u16, data3: 0x467C'u16,
    data4: [0x8E'u8, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E])
  iidIMMDeviceEnumerator = Guid(data1: 0xA95664D2'u32,
    data2: 0x9614'u16, data3: 0x4F35'u16,
    data4: [0xA7'u8, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6])
  iidIAudioClient = Guid(data1: 0x1CB9AD4C'u32,
    data2: 0xDBFA'u16, data3: 0x4C32'u16,
    data4: [0xB1'u8, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2])
  iidIAudioRenderClient = Guid(data1: 0xF294ACFC'u32,
    data2: 0x3146'u16, data3: 0x4483'u16,
    data4: [0xA7'u8, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2])
  ksDataFormatSubtypeFloat = Guid(data1: 3'u32, data2: 0,
    data3: 0x10'u16,
    data4: [0x80'u8, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71])

proc coInitializeEx(reserved: pointer; coInit: uint32): int32
  {.importc: "CoInitializeEx", dynlib: "ole32.dll", stdcall.}
proc coUninitialize() {.importc: "CoUninitialize", dynlib: "ole32.dll", stdcall.}
proc coCreateInstance(classId: ptr Guid; outer: pointer; context: uint32;
    interfaceId: ptr Guid; output: ptr uint): int32
  {.importc: "CoCreateInstance", dynlib: "ole32.dll", stdcall.}
proc coTaskMemFree(memory: pointer)
  {.importc: "CoTaskMemFree", dynlib: "ole32.dll", stdcall.}
proc createEventW(attributes: pointer; manualReset, initialState: int32;
    name: pointer): uint
  {.importc: "CreateEventW", dynlib: "kernel32.dll", stdcall.}
proc waitForSingleObject(handle: uint; milliseconds: uint32): uint32
  {.importc: "WaitForSingleObject", dynlib: "kernel32.dll", stdcall.}
proc closeHandle(handle: uint): int32
  {.importc: "CloseHandle", dynlib: "kernel32.dll", stdcall.}

type
  ComCall0 = proc(this: uint): uint {.stdcall.}
  ComCall1 = proc(this, a1: uint): uint {.stdcall.}
  ComCall2 = proc(this, a1, a2: uint): uint {.stdcall.}
  ComCall3 = proc(this, a1, a2, a3: uint): uint {.stdcall.}
  ComCall4 = proc(this, a1, a2, a3, a4: uint): uint {.stdcall.}
  ComCall6 = proc(this, a1, a2, a3, a4, a5, a6: uint): uint {.stdcall.}

proc methodAddress(obj: uint; index: int): pointer =
  let vtable = cast[ptr UncheckedArray[uint]](cast[pointer](obj))[0]
  cast[pointer](cast[ptr UncheckedArray[uint]](cast[pointer](vtable))[index])

proc comCall(obj: uint; index: int): uint =
  cast[ComCall0](methodAddress(obj, index))(obj)
proc comCall(obj: uint; index: int; a1: uint): uint =
  cast[ComCall1](methodAddress(obj, index))(obj, a1)
proc comCall(obj: uint; index: int; a1, a2: uint): uint =
  cast[ComCall2](methodAddress(obj, index))(obj, a1, a2)
proc comCall(obj: uint; index: int; a1, a2, a3: uint): uint =
  cast[ComCall3](methodAddress(obj, index))(obj, a1, a2, a3)
proc comCall(obj: uint; index: int; a1, a2, a3, a4: uint): uint =
  cast[ComCall4](methodAddress(obj, index))(obj, a1, a2, a3, a4)
proc comCall(obj: uint; index: int; a1, a2, a3, a4, a5, a6: uint): uint =
  cast[ComCall6](methodAddress(obj, index))(obj, a1, a2, a3, a4, a5, a6)

proc failed(hr: uint): bool = int32(uint32(hr)) < 0

proc hresultError(operation: string; hr: uint): ref CatchableError =
  newException(CatchableError, "audio: " & operation &
    " failed (HRESULT 0x" & toHex(uint32(hr), 8) & ")")

proc release(obj: uint) =
  if obj != 0:
    discard comCall(obj, 2)

proc utf16String(value: uint): string =
  let units = cast[ptr UncheckedArray[uint16]](cast[pointer](value))
  var i = 0
  while units[i] != 0:
    var codepoint = uint32(units[i])
    inc i
    if codepoint >= 0xD800 and codepoint <= 0xDBFF and
        units[i] >= 0xDC00 and units[i] <= 0xDFFF:
      codepoint = 0x10000 + ((codepoint - 0xD800) shl 10) +
        (uint32(units[i]) - 0xDC00)
      inc i
    result.add $Rune(codepoint)

proc defaultEndpoint(enumerator: uint): uint =
  let hr = comCall(enumerator, 4, uint(eRender), uint(eConsole),
    cast[uint](addr result))
  if failed(hr):
    if uint32(hr) == eNotFound:
      raise newException(CatchableError, "audio: no audio output")
    raise hresultError("GetDefaultAudioEndpoint", hr)

proc deviceId(device: uint): string =
  var rawId: uint
  let hr = comCall(device, 5, cast[uint](addr rawId))
  if failed(hr):
    raise hresultError("IMMDevice.GetId", hr)
  try:
    result = utf16String(rawId)
  finally:
    coTaskMemFree(cast[pointer](rawId))

proc defaultId(enumerator: uint): string =
  let device = defaultEndpoint(enumerator)
  try:
    result = deviceId(device)
  finally:
    release(device)

proc initialize(output: WindowsAudioOutput) =
  var hr = coCreateInstance(unsafeAddr clsidMMDeviceEnumerator, nil,
    clsctxAll, unsafeAddr iidIMMDeviceEnumerator, addr output.enumerator)
  if hr < 0:
    raise hresultError("CoCreateInstance(MMDeviceEnumerator)", uint(hr))

  let device = defaultEndpoint(output.enumerator)
  try:
    output.endpointId = deviceId(device)
    hr = int32(comCall(device, 3, cast[uint](unsafeAddr iidIAudioClient),
      uint(clsctxAll), 0, cast[uint](addr output.client)))
    if hr < 0:
      raise hresultError("IMMDevice.Activate", uint(hr))
  finally:
    release(device)

  var format = WaveFormatExtensible(
    formatTag: waveFormatExtensibleTag,
    channelCount: uint16(channels),
    samplesPerSec: sampleRate,
    avgBytesPerSec: sampleRate * channels * 4,
    blockAlign: uint16(channels * 4),
    bitsPerSample: 32,
    extraSize: 22,
    validBits: 32,
    channelMask: speakerFrontLeft or speakerFrontRight,
    subFormat: ksDataFormatSubtypeFloat)
  let flags = audclntStreamFlagsEventCallback or
    audclntStreamFlagsNoPersist or audclntStreamFlagsAutoConvert or
    audclntStreamFlagsSrcQuality
  hr = int32(comCall(output.client, 3, uint(audclntShareModeShared),
    uint(flags), 400_000'u, 0, cast[uint](addr format), 0))
  if hr < 0:
    raise hresultError("IAudioClient.Initialize", uint(hr))

  var bufferFrames: uint32
  let bufferHr = comCall(output.client, 4, cast[uint](addr bufferFrames))
  if failed(bufferHr):
    raise hresultError("IAudioClient.GetBufferSize", bufferHr)
  output.frames = bufferFrames

  hr = int32(comCall(output.client, 14,
    cast[uint](unsafeAddr iidIAudioRenderClient),
    cast[uint](addr output.render)))
  if hr < 0:
    raise hresultError("IAudioClient.GetService", uint(hr))

  output.event = createEventW(nil, 0, 0, nil)
  if output.event == 0:
    raise newException(CatchableError, "audio: CreateEvent failed")
  let eventHr = comCall(output.client, 13, output.event)
  if failed(eventHr):
    raise hresultError("IAudioClient.SetEventHandle", eventHr)
  let startHr = comCall(output.client, 10)
  if failed(startHr):
    raise hresultError("IAudioClient.Start", startHr)
  output.checked = getMonoTime()

proc openAudioOutput*(): AudioOutput =
  let initHr = coInitializeEx(nil, coinitMultithreaded)
  if initHr < 0:
    raise hresultError("CoInitializeEx", uint(initHr))
  let output = WindowsAudioOutput(comInitialized: true)
  try:
    output.initialize()
  except CatchableError:
    output.close()
    raise
  output

method write(output: WindowsAudioOutput; samples: seq[float32]) =
  if output.client == 0 or output.render == 0:
    raise newException(CatchableError, "audio: the WASAPI client is closed")
  if samples.len != windowsFrames * int(channels):
    raise newException(ValueError, "mynim/audio: invalid WASAPI buffer size")

  let frames = uint32(samples.len div int(channels))
  let deadline = getMonoTime() + initDuration(seconds = 1)
  while true:
    var padding: uint32
    let hr = comCall(output.client, 6, cast[uint](addr padding))
    if failed(hr):
      raise hresultError("IAudioClient.GetCurrentPadding", hr)
    if padding <= output.frames and output.frames - padding >= frames:
      break
    if getMonoTime() >= deadline:
      raise newException(CatchableError,
        "audio: the audio client stopped asking for frames")
    if waitForSingleObject(output.event, 100) == waitFailed:
      raise newException(CatchableError, "audio: WaitForSingleObject failed")

  var destination: uint
  let bufferHr = comCall(output.render, 3, uint(frames),
    cast[uint](addr destination))
  if failed(bufferHr):
    raise hresultError("IAudioRenderClient.GetBuffer", bufferHr)
  if destination == 0:
    raise newException(CatchableError, "audio: WASAPI returned an empty buffer")
  copyMem(cast[pointer](destination), unsafeAddr samples[0],
    samples.len * sizeof(float32))
  let releaseHr = comCall(output.render, 4, uint(frames), 0)
  if failed(releaseHr):
    raise hresultError("IAudioRenderClient.ReleaseBuffer", releaseHr)

  if getMonoTime() - output.checked > initDuration(milliseconds = 500):
    output.checked = getMonoTime()
    try:
      if defaultId(output.enumerator) != output.endpointId:
        raise newException(CatchableError,
          "audio: the default output changed")
    except CatchableError:
      raise newException(CatchableError, "audio: the default output changed")

method close(output: WindowsAudioOutput) =
  if output.client != 0:
    discard comCall(output.client, 11)
  release(output.render)
  release(output.client)
  release(output.enumerator)
  output.render = 0
  output.client = 0
  output.enumerator = 0
  if output.event != 0:
    discard closeHandle(output.event)
    output.event = 0
  if output.comInitialized:
    coUninitialize()
    output.comInitialized = false
