## Package a macOS app bundle as a Finder-ready compressed disk image.

import std/[os, osproc, streams, strutils, tempfiles]
import ./dsstore

const finderHasCustomIcon = 0x0400

proc fsName(value: string): string =
  for ch in value.strip:
    if ord(ch) < 0x20 or ch in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'}:
      result.add '-'
    else:
      result.add ch

proc dmgFileName*(name, version, arch: string): string =
  let base = fsName(name) & " " & fsName(version)
  if arch == "universal": base & ".dmg"
  else: base & " " & fsName(arch) & ".dmg"

proc run(executable: string; args: openArray[string]):
    tuple[code: int, output: string] =
  let process = startProcess(executable, args = @args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally:
    process.close()

proc command(executable: string; args: openArray[string]) =
  let executed = run(executable, args)
  if executed.code != 0:
    raise newException(IOError, executable & " " & args.join(" ") &
      " failed with status " & $executed.code & "\n" & executed.output.strip)

proc hdiutilBusy(message: string): bool =
  "Resource busy" in message

proc hdiutilRetrying(args: openArray[string]) =
  var firstFailure = ""
  var failure = ""
  for attempt in 0..<5:
    let executed = run("/usr/bin/hdiutil", args)
    if executed.code == 0: return
    failure = "hdiutil " & args.join(" ") & " failed with status " &
      $executed.code & "\n" & executed.output.strip
    if firstFailure.len == 0: firstFailure = failure
    if not hdiutilBusy(failure) or attempt == 4: break
    sleep(2000 shl attempt)
  if failure != firstFailure:
    failure.add "\nfirst attempt: " & firstFailure
  raise newException(IOError, failure)

proc attachedDisk(output: string): string =
  for line in output.splitLines:
    let fields = line.splitWhitespace
    if fields.len > 0 and fields[0].startsWith("/dev/disk"):
      return fields[0]
  raise newException(IOError, "hdiutil attach returned no disk device\n" & output)

proc hdiutilAttach(args: openArray[string]): string =
  var attachArgs = @["attach"]
  attachArgs.add args
  let executed = run("/usr/bin/hdiutil", attachArgs)
  if executed.code != 0:
    raise newException(IOError, "hdiutil attach failed with status " &
      $executed.code & "\n" & executed.output.strip)
  attachedDisk(executed.output)

proc setFinderFlags(path: string; flags: uint16) =
  var finderInfo = repeat('0', 64)
  let hex = toHex(int(flags shr 8), 2) & toHex(int(flags and 0xff), 2)
  finderInfo[16] = hex[0]
  finderInfo[17] = hex[1]
  finderInfo[18] = hex[2]
  finderInfo[19] = hex[3]
  command("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", finderInfo, path])

proc removeTemporaryPath(path: string) =
  if dirExists(path): removeDir(path)
  elif fileExists(path): removeFile(path)

proc buildDmg*(app, dir, name, version, arch, title: string): string =
  ## Builds a read-only, compressed image containing the app and Applications.
  let filename = dmgFileName(name, version, arch)
  let work = createTempDir(".dmg-", "", dir)
  defer:
    if dirExists(work): removeDir(work)

  let source = work / "src"
  createDir(source)
  let appName = app.lastPathPart()
  command("/usr/bin/ditto", ["--noclone", app, source / appName])
  createSymlink("/Applications", source / "Applications")
  writeDsStore(source / ".DS_Store", appName)

  let appIcon = app / "Contents" / "Resources" / "AppIcon.icns"
  let hasIcon = fileExists(appIcon)
  if hasIcon:
    copyFile(appIcon, source / ".VolumeIcon.icns")

  let readWriteImage = work / "rw.dmg"
  hdiutilRetrying(["create", "-ov", "-volname", title,
    "-srcfolder", source, "-fs", "HFS+", "-fsargs", "-c c=64,a=16,e=16",
    "-format", "UDRW", readWriteImage])

  let mountPoint = work / "mnt"
  createDir(mountPoint)
  let disk = hdiutilAttach(["-readwrite", "-noverify", "-noautoopen",
    "-nobrowse", "-mountpoint", mountPoint, readWriteImage])
  var attached = true
  defer:
    if attached:
      discard run("/usr/bin/hdiutil", ["detach", "-force", disk])

  if hasIcon: setFinderFlags(mountPoint, finderHasCustomIcon.uint16)
  removeTemporaryPath(mountPoint / ".fseventsd")
  removeTemporaryPath(mountPoint / ".Trashes")
  hdiutilRetrying(["detach", disk])
  attached = false

  result = dir / filename
  command("/usr/bin/hdiutil", ["convert", readWriteImage,
    "-format", "ULMO", "-ov", "-o", result])
