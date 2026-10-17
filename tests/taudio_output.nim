import std/[assertions, os, sequtils, times]
import mynim/audio

let player = newSound(48_000, 1,
  newSeqWith(48_000, 0'f32)).play()
for attempt in 0 ..< 200:
  if player.position().inNanoseconds > 0:
    break
  sleep(5)
sleep(60)
doAssert player.position().inNanoseconds > 0
doAssert player.playing()
when defined(macosx):
  doAssert err().isNil
elif not (defined(linux) and (defined(amd64) or defined(arm64))):
  doAssert err() != nil
player.close()
