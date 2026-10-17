# Package

version       = "0.1.0"
author        = "mynim port"
description   = "Develop desktop apps with native UI or web frontend in Nim (port of egoist/mygo)"
license       = "MIT"
srcDir        = "src"
bin           = @["cmd/mynim"]

# Dependencies

requires "nim >= 2.2.0"

task compilecli, "Build the MyNim CLI with checks enabled":
  exec "nim c --checks:on -o:cmd/mynim src/cmd/mynim.nim"

task verify, "Typecheck the library and CLI":
  exec "nim check src/mynim.nim"
  exec "nim check src/mynim/audio.nim"
  exec "nim check src/cmd/mynim.nim"
