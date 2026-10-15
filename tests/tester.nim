import std/os

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  echo "Running: ", cmd
  if execShellCmd(cmd) != 0: fatal cmd

let testDir = getCurrentDir() / "tests"
let compilerMode =
  when defined(danger): "-d:danger "
  elif defined(release): "-d:release "
  else: ""
for f in walkFiles(testDir / "t*.nim"):
  let name = f.extractFilename
  if name == "tester.nim":
    discard
  else:
    let testName = name.changeFileExt("")
    let binary = getTempDir() / ("mynim-" & testName)
    let cache = getTempDir() / ("mynim-test-cache-" & testName)
    exec "nim c -r " & compilerMode & "--nimcache:" & quoteShell(cache) &
      " --out:" & quoteShell(binary) & " " & quoteShell(testDir / name)

echo "All test files completed."
