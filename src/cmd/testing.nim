## Run the test task of a nim-xplat application with the active toolchain.

import std/[os, osproc, strutils]

const usageTest = """
Usage: nim-xplat test [dir]

Run the project's Nimble test task.
"""

proc runTest*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["-h", "--help"]:
    stdout.write(usageTest)
    return 0
  if args.len > 1 or (args.len == 1 and args[0].startsWith("-")):
    stderr.write(usageTest)
    return 2
  try:
    let projectDir = if args.len == 0: getCurrentDir() else: absolutePath(args[0])
    let nimble = findExe("nimble")
    if nimble.len == 0:
      raise newException(IOError, "nimble was not found on PATH")
    let process = startProcess(nimble, args = @["test"], workingDir = projectDir,
      options = {poUsePath, poParentStreams})
    try:
      result = process.waitForExit()
    finally:
      process.close()
  except CatchableError as error:
    stderr.writeLine("nim-xplat test: " & error.msg)
    return 1
