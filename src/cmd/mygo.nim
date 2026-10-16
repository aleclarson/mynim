## Command-line entry point for the Nim port of MyGo.

import std/os

const
  version = "0.1.0"
  usage = """mygo is the command-line tool for MyGo applications.

Usage:

  mygo <command> [arguments]

Commands:

  version    print the MyGo version
  help       print this help

Other MyGo commands are not ported yet.
"""

proc run(args: seq[string]): int =
  if args.len == 0:
    stderr.write(usage)
    return 2

  case args[0]
  of "version", "-v", "--version":
    stdout.writeLine("mygo " & version)
  of "help", "-h", "--help":
    stdout.write(usage)
  of "init", "install-skills", "vet", "migrate-ui", "generate", "gen",
     "dev", "i18n", "build", "doctor", "keygen":
    stderr.writeLine("mygo: command \"" & args[0] & "\" is not ported yet")
    return 1
  else:
    stderr.writeLine("mygo: unknown command \"" & args[0] & "\"")
    stderr.write("\n")
    stderr.write(usage)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
