import std/[assertions, os, tempfiles]
import ../src/cmd/init
import ../src/cmd/vet

proc testVetTypechecksNativeProject() =
  let temporary = createTempDir("mynim-vet-test-", "")
  defer:
    if dirExists(temporary):
      removeDir(temporary)
  let project = temporary / "project with spaces"
  doAssert runInit(@["--mygo", getCurrentDir(), project]) == 0
  doAssert runVet(@[project]) == 0

  writeFile(project / "src" / "main.nim", """import mynim
app.setName(42)
""")
  doAssert runVet(@[project]) != 0

proc testVetArguments() =
  doAssert runVet(@["--help"]) == 0
  doAssert runVet(@["one", "two"]) == 2

testVetTypechecksNativeProject()
testVetArguments()
