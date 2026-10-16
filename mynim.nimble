# Package

version       = "0.1.0"
author        = "mynim port"
description   = "Develop desktop apps with native UI or web frontend in Nim (port of egoist/mygo)"
license       = "MIT"
srcDir        = "src"
bin           = @["cmd/mygo"]

# Dependencies

requires "nim >= 2.2.0"

task compilecli, "Build the MyGo CLI with checks enabled":
  exec "nim c --checks:on -o:cmd/mygo src/cmd/mygo.nim"

task verify, "Typecheck the library and CLI":
  exec "nim check src/mynim.nim"
  exec "nim check src/cmd/mygo.nim"
