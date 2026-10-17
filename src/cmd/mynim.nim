## Command-line tool for MyNim applications.

import std/os
import ./build
import ./dev
import ./doctor
import ./generate
import ./init
import ./i18n_check
import ./keygen
import ./migrate_ui
import ./skills
import ./testing
import ./vet

const
  version = "0.1.0"
  usage = """mynim is the command-line tool for MyNim applications.

Usage:

  mynim <command> [arguments]

Commands:

  init            create a native UI or web frontend project
  install-skills  install the MyNim maintenance skill
  dev             build and run a native app with live reload
  build           compile a native project for this machine
  generate        write the typed client and Nim/TypeScript i18n accessors
  vet             typecheck a native Nim project
  test            run the project's test task
  i18n            check message catalogs
  keygen          create the key pair that signs updates
  migrate-ui      preview or apply the checked UI API migration
  doctor          check that the development environment is ready
  version         print the MyNim version
  help            print this help

"""

proc run(args: seq[string]): int =
  if args.len == 0:
    stderr.write(usage)
    return 2

  case args[0]
  of "version", "-v", "--version":
    stdout.writeLine("mynim " & version)
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
  of "dev":
    if args.len > 1:
      return runDev(args[1 .. ^1])
    return runDev(@[])
  of "generate", "gen":
    if args.len > 1:
      return runGenerate(args[1 .. ^1])
    return runGenerate(@[])
  of "i18n":
    if args.len > 1:
      return runI18n(args[1 .. ^1])
    return runI18n(@[])
  of "vet":
    if args.len > 1:
      return runVet(args[1 .. ^1])
    return runVet(@[])
  of "keygen":
    if args.len > 1:
      return runKeygen(args[1 .. ^1])
    return runKeygen(@[])
  of "migrate-ui":
    if args.len > 1:
      return runMigrateUI(args[1 .. ^1])
    return runMigrateUI(@[])
  of "test":
    return runTest(if args.len > 1: args[1 .. ^1] else: @[])
  else:
    stderr.writeLine("mynim: unknown command \"" & args[0] & "\"")
    stderr.write("\n")
    stderr.write(usage)
    return 2

when isMainModule:
  quit(run(commandLineParams()))
