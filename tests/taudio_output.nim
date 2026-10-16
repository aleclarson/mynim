import std/[assertions, os, sequtils, times]
import mynim/audio

let player = newSound(48_000, 1,
  newSeqWith(48_000, 0.25'f32)).play()
sleep(60)
doAssert player.position().inNanoseconds > 0
doAssert player.playing()
doAssert err() != nil
player.close()
