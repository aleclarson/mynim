# Package

version       = "0.1.0"
author        = "mynim port"
description   = "Develop desktop apps with native UI or web frontend in Nim (port of egoist/mygo)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"

task build, "Build the mynim library check and CLI":
  exec "nim c --checks:on src/cmd/mygo.nim"

task check, "Typecheck everything":
  exec "nim check src/mynim.nim"
  exec "nim check src/cmd/mygo.nim"
