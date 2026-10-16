import std/[assertions, json, os, tempfiles]
import ../src/cmd/resources

proc testResourceSelection() =
  let temporary = createTempDir("mynim-resources-", "")
  defer: removeDir(temporary)

  let project = temporary / "project"
  let source = project / "resources"
  createDir(source / "data")
  writeFile(source / "data" / "seed.txt", "shared")
  createDir(source / "darwin" / "data")
  writeFile(source / "darwin" / "data" / "mac.txt", "macOS")
  createDir(source / "darwin-arm64" / "data")
  writeFile(source / "darwin-arm64" / "data" / "arm.txt", "arm64")
  createDir(source / "darwin-amd64" / "data")
  writeFile(source / "darwin-amd64" / "data" / "intel.txt", "amd64")
  createDir(source / "linux-amd64" / "data")
  writeFile(source / "linux-amd64" / "data" / "linux.txt", "linux")
  writeFile(source / ".hidden", "skip")
  writeFile(project / "license.txt", "listed")

  var config = newJObject()
  let listed = newJArray()
  listed.add(%"license.txt")
  config["resources"] = listed

  let output = temporary / "output"
  createDir(output)
  copyResources(project, output, "darwin", "arm64", config)
  doAssert readFile(output / "data" / "seed.txt") == "shared"
  doAssert readFile(output / "data" / "mac.txt") == "macOS"
  doAssert readFile(output / "data" / "arm.txt") == "arm64"
  doAssert not fileExists(output / "data" / "intel.txt")
  doAssert not fileExists(output / "data" / "linux.txt")
  doAssert not fileExists(output / ".hidden")
  doAssert readFile(output / "license.txt") == "listed"

  writeFile(source / "darwin-arm64" / "data" / "seed.txt", "conflict")
  let conflictOutput = temporary / "conflict"
  createDir(conflictOutput)
  doAssertRaises(ValueError):
    copyResources(project, conflictOutput, "darwin", "arm64", config)

  let typoProject = temporary / "typo"
  createDir(typoProject / "resources" / "macos")
  let typoOutput = temporary / "typo-output"
  createDir(typoOutput)
  doAssertRaises(ValueError):
    copyResources(typoProject, typoOutput, "darwin", "arm64", newJObject())

testResourceSelection()
