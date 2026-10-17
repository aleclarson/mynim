# Package

version       = "0.1.0"
author        = "Alec Larson"
description   = "Build desktop apps with native UI or web frontend in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["cmd/nim-xplat"]

# Dependencies

requires "nim >= 2.2.0"

task compilecli, "Build the nim-xplat CLI with checks enabled":
  exec "nim c --checks:on -o:cmd/nim-xplat src/cmd/nim_xplat.nim"

task verify, "Typecheck the library and CLI":
  exec "nim check src/mynim.nim"
  exec "nim check src/mynim/audio.nim"
  exec "nim check src/cmd/nim_xplat.nim"
