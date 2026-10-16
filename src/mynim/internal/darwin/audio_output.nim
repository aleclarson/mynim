## CoreAudio output through AudioQueue.

import std/locks
import ../audio_output_types

const
  audioToolboxHeader = "<AudioToolbox/AudioToolbox.h>"
  aqBufferCount = 4
  aqBufferFrames* = 512
  aqSampleRate = 48_000.0
  aqChannels = 2
  aqBytesPerSample = 4
  bufferWaitTimeoutMs = 1_000
  kAudioFormatLinearPcm = 0x6C70636D'u32
  kAudioFormatFlagIsFloat = 1'u32
  kAudioFormatFlagIsPacked = 8'u32

{.passL: "-framework AudioToolbox".}

type
  OpaqueAudioQueue {.importc: "struct OpaqueAudioQueue",
      header: audioToolboxHeader, incompleteStruct.} = object
  AudioQueueRef = ptr OpaqueAudioQueue

  AudioQueueBuffer {.importc, header: audioToolboxHeader, bycopy.} = object
    mAudioDataBytesCapacity: uint32
    mAudioData: pointer
    mAudioDataByteSize: uint32
    mUserData: pointer
    mPacketDescriptionCapacity: uint32
    mPacketDescriptions: pointer
    mPacketDescriptionCount: uint32

  AudioStreamBasicDescription {.importc, header: audioToolboxHeader, bycopy.} = object
    mSampleRate: float64
    mFormatID: uint32
    mFormatFlags: uint32
    mBytesPerPacket: uint32
    mFramesPerPacket: uint32
    mBytesPerFrame: uint32
    mChannelsPerFrame: uint32
    mBitsPerChannel: uint32
    mReserved: uint32

  AudioQueueBufferRef = ptr AudioQueueBuffer
  AudioQueueOutputCallback = proc(userData: pointer; queue: AudioQueueRef;
    buffer: AudioQueueBufferRef) {.cdecl, gcsafe.}

  CallbackState = object
    queue: AudioQueueRef
    lock: Lock
    cond: Cond
    free: array[aqBufferCount, AudioQueueBufferRef]
    freeRead, freeCount: int
    closed: bool

  DarwinAudioOutput = ref object of AudioOutput
    state: ptr CallbackState
    queued: int
    started: bool

{.push cdecl, header: audioToolboxHeader, importc.}
proc AudioQueueNewOutput(format: ptr AudioStreamBasicDescription;
    callback: AudioQueueOutputCallback; userData: pointer; runLoop: pointer;
    runLoopMode: pointer; flags: uint32; output: ptr AudioQueueRef): int32
proc AudioQueueAllocateBuffer(queue: AudioQueueRef; size: uint32;
    output: ptr AudioQueueBufferRef): int32
proc AudioQueueEnqueueBuffer(queue: AudioQueueRef; buffer: AudioQueueBufferRef;
    packetCount: uint32; packetDescriptions: pointer): int32
proc AudioQueueStart(queue: AudioQueueRef; atTime: pointer): int32
proc AudioQueueStop(queue: AudioQueueRef; immediate: uint8): int32
proc AudioQueueDispose(queue: AudioQueueRef; immediate: uint8): int32
{.pop.}

{.emit: """
#include <errno.h>
#include <pthread.h>
#include <time.h>

int mynim_audio_timed_cond_wait(void *cond, void *mutex, int timeout_ms) {
  struct timespec deadline;
  if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return -2;
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    ++deadline.tv_sec;
    deadline.tv_nsec -= 1000000000L;
  }
  int status = pthread_cond_timedwait((pthread_cond_t *)cond,
      (pthread_mutex_t *)mutex, &deadline);
  return status == ETIMEDOUT ? -1 : status;
}
""".}

proc timedCondWait(cond, lock: pointer; timeoutMs: cint): cint {.
  importc: "mynim_audio_timed_cond_wait".}

{.emit: """
_Static_assert(sizeof(AudioStreamBasicDescription) == 40,
  "AudioStreamBasicDescription ABI mismatch");
_Static_assert(sizeof(AudioQueueBuffer) == 56, "AudioQueueBuffer ABI mismatch");
""".}

proc queueError(operation: string; status: int32): ref CatchableError =
  newException(CatchableError, "audio: " & operation &
    " failed (OSStatus " & $status & ")")

proc outputCallback(userData: pointer; queue: AudioQueueRef;
    buffer: AudioQueueBufferRef) {.cdecl, gcsafe.} =
  let state = cast[ptr CallbackState](userData)
  if state.isNil:
    return
  acquire(state.lock)
  if not state.closed and state.queue == queue and
      state.freeCount < aqBufferCount:
    let writeAt = (state.freeRead + state.freeCount) mod aqBufferCount
    state.free[writeAt] = buffer
    inc state.freeCount
    signal(state.cond)
  release(state.lock)

proc disposeState(state: ptr CallbackState) =
  if state.isNil:
    return
  deinitCond(state.cond)
  deinitLock(state.lock)
  deallocShared(state)

proc openAudioQueue*(): AudioOutput =
  var state = cast[ptr CallbackState](allocShared0(sizeof(CallbackState)))
  if state.isNil:
    raise newException(OutOfMemDefect, "mynim/audio: cannot allocate AudioQueue state")
  initLock(state.lock)
  initCond(state.cond)

  var format = AudioStreamBasicDescription(
    mSampleRate: aqSampleRate,
    mFormatID: kAudioFormatLinearPcm,
    mFormatFlags: kAudioFormatFlagIsFloat or kAudioFormatFlagIsPacked,
    mBytesPerPacket: uint32(aqChannels * aqBytesPerSample),
    mFramesPerPacket: 1,
    mBytesPerFrame: uint32(aqChannels * aqBytesPerSample),
    mChannelsPerFrame: aqChannels,
    mBitsPerChannel: uint32(aqBytesPerSample * 8))
  let status = AudioQueueNewOutput(addr format, outputCallback, state, nil,
    nil, 0, addr state.queue)
  if status != 0:
    disposeState(state)
    raise queueError("AudioQueueNewOutput", status)

  let bufferBytes = uint32(aqBufferFrames * aqChannels * aqBytesPerSample)
  for i in 0 ..< aqBufferCount:
    var buffer: AudioQueueBufferRef
    let allocationStatus = AudioQueueAllocateBuffer(state.queue, bufferBytes,
      addr buffer)
    if allocationStatus != 0:
      state.closed = true
      discard AudioQueueDispose(state.queue, 1)
      disposeState(state)
      raise queueError("AudioQueueAllocateBuffer", allocationStatus)
    state.free[i] = buffer
    inc state.freeCount

  DarwinAudioOutput(state: state)

method write*(output: DarwinAudioOutput; samples: seq[float32]) =
  let state = output.state
  if state.isNil:
    raise newException(CatchableError, "audio: the audio queue is closed")
  if samples.len != aqBufferFrames * aqChannels:
    raise newException(ValueError, "mynim/audio: invalid AudioQueue buffer size")

  acquire(state.lock)
  while state.freeCount == 0 and not state.closed:
    let waitStatus = timedCondWait(addr state.cond, addr state.lock,
      bufferWaitTimeoutMs)
    if waitStatus != 0:
      release(state.lock)
      if waitStatus == -1:
        raise newException(CatchableError,
          "audio: timed out waiting for an AudioQueue buffer")
      raise queueError("pthread_cond_timedwait", waitStatus)
  if state.closed:
    release(state.lock)
    raise newException(CatchableError, "audio: the audio queue is closed")
  let buffer = state.free[state.freeRead]
  state.freeRead = (state.freeRead + 1) mod aqBufferCount
  dec state.freeCount
  release(state.lock)

  let destination = cast[ptr UncheckedArray[float32]](buffer.mAudioData)
  for i, sample in samples:
    destination[i] = sample
  buffer.mAudioDataByteSize = uint32(samples.len * sizeof(float32))
  let enqueueStatus = AudioQueueEnqueueBuffer(state.queue, buffer, 0, nil)
  if enqueueStatus != 0:
    raise queueError("AudioQueueEnqueueBuffer", enqueueStatus)

  if not output.started:
    inc output.queued
    if output.queued == aqBufferCount:
      let startStatus = AudioQueueStart(state.queue, nil)
      if startStatus != 0:
        raise queueError("AudioQueueStart", startStatus)
      output.started = true

method close*(output: DarwinAudioOutput) =
  let state = output.state
  if state.isNil:
    return
  acquire(state.lock)
  state.closed = true
  signal(state.cond)
  release(state.lock)
  let stopStatus = AudioQueueStop(state.queue, 1)
  let disposeStatus = AudioQueueDispose(state.queue, 1)
  if stopStatus == 0 or disposeStatus == 0:
    disposeState(state)
    output.state = nil
  if stopStatus != 0:
    raise queueError("AudioQueueStop", stopStatus)
  if disposeStatus != 0:
    raise queueError("AudioQueueDispose", disposeStatus)
