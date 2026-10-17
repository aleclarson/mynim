## PulseAudio simple API with an ALSA fallback for Linux playback.

import std/[dynlib, locks, os]
import ../audio_output_types

const
  linuxFrames* = 480
  linuxSampleRate = 48_000'u32
  linuxChannels = 2'u32
  linuxFrameBytes = linuxChannels * sizeof(float32).uint32
  paStreamPlayback = 1'i32
  paSampleFloat32Le = 5'i32
  sndPcmStreamPlayback = 0'i32
  sndPcmFormatFloatLe = 14'i32
  sndPcmAccessRwInterleaved = 3'i32

type
  PaSampleSpec = object
    format: int32
    rate: uint32
    channels: uint8
    padding: array[3, uint8]

  PaBufferAttr = object
    maxLength, targetLength, preBuffer, minRequest, fragmentSize: uint32

  PaSimpleNew = proc(server, clientName: cstring; direction: int32;
    device, streamName: cstring; spec: ptr PaSampleSpec;
    channelMap, bufferAttr: pointer; errorCode: ptr int32): pointer
    {.cdecl, gcsafe.}
  PaSimpleWrite = proc(stream, data: pointer; size: csize_t;
    errorCode: ptr int32): int32 {.cdecl, gcsafe.}
  PaSimpleFree = proc(stream: pointer) {.cdecl, gcsafe.}
  PaStrerror = proc(errorCode: int32): cstring {.cdecl, gcsafe.}

  SndPcmOpen = proc(pcm: ptr pointer; name: cstring; stream, mode: int32): int32
    {.cdecl, gcsafe.}
  SndPcmSetParams = proc(pcm: pointer; format, access: int32;
    channels, rate: uint32; softResample: int32; latency: uint32): int32
    {.cdecl, gcsafe.}
  SndPcmWritei = proc(pcm, data: pointer; frames: csize_t): clong
    {.cdecl, gcsafe.}
  SndPcmRecover = proc(pcm: pointer; errorCode, silent: int32): int32
    {.cdecl, gcsafe.}
  SndPcmClose = proc(pcm: pointer): int32 {.cdecl, gcsafe.}
  SndStrerror = proc(errorCode: int32): cstring {.cdecl, gcsafe.}

  PulseOutput = ref object of AudioOutput
    stream: pointer

  AlsaOutput = ref object of AudioOutput
    pcm: pointer

static:
  doAssert sizeof(PaSampleSpec) == 12
  doAssert sizeof(PaBufferAttr) == 20

var
  pulseLock: Lock
  alsaLock: Lock
  pulseLoaded, alsaLoaded: bool
  pulseFailure, alsaFailure: string
  pulseLibrary, alsaLibrary: LibHandle
  paSimpleNew: PaSimpleNew
  paSimpleWrite: PaSimpleWrite
  paSimpleFree: PaSimpleFree
  paStrerror: PaStrerror
  sndPcmOpen: SndPcmOpen
  sndPcmSetParams: SndPcmSetParams
  sndPcmWritei: SndPcmWritei
  sndPcmRecover: SndPcmRecover
  sndPcmClose: SndPcmClose
  sndStrerror: SndStrerror

initLock(pulseLock)
initLock(alsaLock)

proc bindSymbol[T](library: LibHandle; name: string): T =
  let address = symAddr(library, name.cstring)
  if address.isNil:
    raise newException(CatchableError,
      "audio: missing symbol " & name)
  cast[T](address)

proc loadPulseApi(): string =
  acquire(pulseLock)
  defer: release(pulseLock)
  if not pulseLoaded:
    pulseLoaded = true
    pulseLibrary = loadLib("libpulse-simple.so.0", globalSymbols = true)
    if pulseLibrary.isNil:
      pulseFailure = "audio: cannot load libpulse-simple.so.0"
    else:
      try:
        paSimpleNew = bindSymbol[PaSimpleNew](pulseLibrary, "pa_simple_new")
        paSimpleWrite = bindSymbol[PaSimpleWrite](pulseLibrary,
          "pa_simple_write")
        paSimpleFree = bindSymbol[PaSimpleFree](pulseLibrary, "pa_simple_free")
        paStrerror = bindSymbol[PaStrerror](pulseLibrary, "pa_strerror")
      except CatchableError as error:
        pulseFailure = error.msg
        unloadLib(pulseLibrary)
        pulseLibrary = nil
  result = pulseFailure

proc loadAlsaApi(): string =
  acquire(alsaLock)
  defer: release(alsaLock)
  if not alsaLoaded:
    alsaLoaded = true
    alsaLibrary = loadLib("libasound.so.2", globalSymbols = true)
    if alsaLibrary.isNil:
      alsaFailure = "audio: cannot load libasound.so.2"
    else:
      try:
        sndPcmOpen = bindSymbol[SndPcmOpen](alsaLibrary, "snd_pcm_open")
        sndPcmSetParams = bindSymbol[SndPcmSetParams](alsaLibrary,
          "snd_pcm_set_params")
        sndPcmWritei = bindSymbol[SndPcmWritei](alsaLibrary, "snd_pcm_writei")
        sndPcmRecover = bindSymbol[SndPcmRecover](alsaLibrary,
          "snd_pcm_recover")
        sndPcmClose = bindSymbol[SndPcmClose](alsaLibrary, "snd_pcm_close")
        sndStrerror = bindSymbol[SndStrerror](alsaLibrary, "snd_strerror")
      except CatchableError as error:
        alsaFailure = error.msg
        unloadLib(alsaLibrary)
        alsaLibrary = nil
  result = alsaFailure

proc pulseMessage(errorCode: int32): string =
  let message = paStrerror(errorCode)
  if message.isNil: "error " & $errorCode else: $message

proc alsaMessage(errorCode: int32): string =
  let message = sndStrerror(errorCode)
  if message.isNil: "error " & $errorCode else: $message

proc applicationName(): string =
  result = getAppFilename().extractFilename
  if result.len == 0:
    result = "mynim"

proc openPulse(): AudioOutput =
  let loadError = loadPulseApi()
  if loadError.len > 0:
    raise newException(CatchableError, loadError)
  var spec = PaSampleSpec(format: paSampleFloat32Le,
    rate: linuxSampleRate, channels: uint8(linuxChannels))
  let clientName = applicationName()
  let bufferAttr = PaBufferAttr(
    maxLength: high(uint32),
    targetLength: linuxSampleRate div 25 * linuxFrameBytes,
    preBuffer: high(uint32),
    minRequest: uint32(linuxFrames) * linuxFrameBytes,
    fragmentSize: high(uint32))
  var errorCode: int32
  let stream = paSimpleNew(nil, clientName.cstring, paStreamPlayback, nil,
    clientName.cstring, addr spec, nil, unsafeAddr bufferAttr, addr errorCode)
  if stream.isNil:
    raise newException(CatchableError,
      "audio: PulseAudio: " & pulseMessage(errorCode))
  PulseOutput(stream: stream)

proc openAlsa(): AudioOutput =
  let loadError = loadAlsaApi()
  if loadError.len > 0:
    raise newException(CatchableError, loadError)
  var pcm: pointer
  let openStatus = sndPcmOpen(addr pcm, "default", sndPcmStreamPlayback, 0)
  if openStatus < 0:
    raise newException(CatchableError,
      "audio: ALSA: " & alsaMessage(openStatus))
  let status = sndPcmSetParams(pcm, sndPcmFormatFloatLe,
    sndPcmAccessRwInterleaved, linuxChannels, linuxSampleRate, 1, 40_000)
  if status < 0:
    discard sndPcmClose(pcm)
    raise newException(CatchableError,
      "audio: ALSA: " & alsaMessage(status))
  AlsaOutput(pcm: pcm)

proc openAudioOutput*(): AudioOutput =
  ## Opens PulseAudio, falling back to ALSA's default playback device.
  var pulseError = ""
  try:
    return openPulse()
  except CatchableError as error:
    pulseError = error.msg
  try:
    return openAlsa()
  except CatchableError as error:
    raise newException(CatchableError, pulseError & "; " & error.msg)

method write*(output: PulseOutput; samples: seq[float32]) =
  if output.stream.isNil:
    raise newException(CatchableError, "audio: PulseAudio stream is closed")
  if samples.len != linuxFrames * int(linuxChannels):
    raise newException(ValueError, "mynim/audio: invalid PulseAudio buffer size")
  var errorCode: int32
  if paSimpleWrite(output.stream, unsafeAddr samples[0],
      csize_t(samples.len * sizeof(float32)), addr errorCode) < 0:
    raise newException(CatchableError,
      "audio: PulseAudio: " & pulseMessage(errorCode))

method close*(output: PulseOutput) =
  if not output.stream.isNil:
    paSimpleFree(output.stream)
    output.stream = nil

method write*(output: AlsaOutput; samples: seq[float32]) =
  if output.pcm.isNil:
    raise newException(CatchableError, "audio: ALSA device is closed")
  if samples.len != linuxFrames * int(linuxChannels):
    raise newException(ValueError, "mynim/audio: invalid ALSA buffer size")
  var offset = 0
  while offset < samples.len:
    let frames = csize_t((samples.len - offset) div int(linuxChannels))
    let written = sndPcmWritei(output.pcm, unsafeAddr samples[offset], frames)
    if written < 0:
      let status = sndPcmRecover(output.pcm, int32(written), 1)
      if status < 0:
        raise newException(CatchableError,
          "audio: ALSA: " & alsaMessage(status))
    elif written == 0:
      raise newException(CatchableError, "audio: ALSA wrote no frames")
    else:
      offset += int(written) * int(linuxChannels)

method close*(output: AlsaOutput) =
  if not output.pcm.isNil:
    let pcm = output.pcm
    output.pcm = nil
    let status = sndPcmClose(pcm)
    if status < 0:
      raise newException(CatchableError,
        "audio: ALSA: " & alsaMessage(status))
