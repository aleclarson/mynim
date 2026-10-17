## Typecheck a native nim-xplat application without linking or running it.

import std/[os, osproc, strutils]

const usageVet = """Usage: nim-xplat vet [dir]

Typecheck a native project with the Nim compiler.

Flags:
  -h, --help  show this help
"""

proc runVet*(args: seq[string]): int =
  var paths: seq[string]
  for arg in args:
    if arg in ["-h", "--help"]:
      stdout.write(usageVet)
      return 0
    if arg.startsWith("-"):
      stderr.writeLine("nim-xplat vet: unknown flag " & arg)
      stderr.write(usageVet)
      return 2
    paths.add arg

  if paths.len > 1:
    stderr.writeLine("nim-xplat vet: expected at most one project directory")
    stderr.write(usageVet)
    return 2

  try:
    let projectDir = if paths.len == 0: getCurrentDir()
      else: absolutePath(paths[0])
    if not dirExists(projectDir):
      raise newException(ValueError,
        "nim-xplat vet: " & projectDir & " is not a directory")
    let source = if fileExists(projectDir / "src" / "main.nim"):
      projectDir / "src" / "main.nim" else: projectDir / "main.nim"
    if not fileExists(source):
      raise newException(ValueError,
        "nim-xplat vet: expected src/main.nim or main.nim in " & projectDir)
    let nim = findExe("nim")
    if nim.len == 0:
      raise newException(IOError, "nim was not found on PATH")
    let process = startProcess(nim, args = @["check", source],
      workingDir = projectDir, options = {poUsePath, poParentStreams})
    try:
      result = process.waitForExit()
    finally:
      process.close()
  except CatchableError as error:
    stderr.writeLine("nim-xplat vet: " & error.msg)
    return 1
