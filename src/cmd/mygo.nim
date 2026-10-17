## Command-line entry point for the Nim port of MyGo.

import std/os
import ./build
import ./doctor
import ./generate
import ./init
import ./i18n_check
import ./skills

const
  version = "0.1.0"
  usage = """mygo is the command-line tool for MyGo applications.

Usage:

  mygo <command> [arguments]

Commands:

  init            create a native UI project
  install-skills  install the MyNim maintenance skill
  build           compile a native project for this machine
  generate        write the typed TypeScript client
  i18n            check message catalogs
  doctor          check that the development environment is ready
  version         print the MyGo version
  help            print this help

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
  of "doctor":
    if args.len > 1:
      return runDoctor(args[1 .. ^1])
    return runDoctor(@[])
  of "init":
    if args.len > 1:
      return runInit(args[1 .. ^1])
    return runInit(@[])
  of "install-skills":
    if args.len > 1:
      return runInstallSkills(args[1 .. ^1])
    return runInstallSkills(@[])
  of "build":
    if args.len > 1:
      return runBuild(args[1 .. ^1])
    return runBuild(@[])
  of "generate", "gen":
    if args.len > 1:
      return runGenerate(args[1 .. ^1])
    return runGenerate(@[])
  of "i18n":
    if args.len > 1:
      return runI18n(args[1 .. ^1])
    return runI18n(@[])
  of "vet", "migrate-ui", "dev", "keygen":
    stderr.writeLine("mygo: command \"" & args[0] & "\" is not ported yet")
    return 1
  else:
    stderr.writeLine("mygo: unknown command \"" & args[0] & "\"")
    stderr.write("\n")
    stderr.write(usage)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
