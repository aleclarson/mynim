type AudioOutput* = ref object of RootObj

method write*(output: AudioOutput; samples: seq[float32]) {.base.} =
  raiseAssert("mynim/audio: write on the base output")

method close*(output: AudioOutput) {.base.} = discard
