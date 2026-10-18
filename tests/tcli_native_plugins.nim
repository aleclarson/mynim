import std/[assertions, json, os, osproc, streams, strutils, tempfiles]
import ../src/cmd/native_plugins
import ../src/mynim/internal/native_asset_cache
import ../src/mynim/internal/sha256

proc hostTarget(): tuple[os, arch: string] =
  let osName = when hostOS == "macosx": "darwin" else: $hostOS
  (osName, hostCPU)

proc compileFixture(project: string): string =
  let nim = findExe("nim")
  doAssert nim.len > 0
  let process = startProcess(nim, args = @[
    "c", "--hints:off", "--warnings:off", "-d:mynimCollectNativePlugins",
    "--nimcache:" & (project / "nimcache"),
    "--out:" & (project / "fixture"), "main.nim"],
    workingDir = project / "source",
    options = {poUsePath, poStdErrToStdOut})
  try:
    result = process.outputStream.readAll()
    let code = process.waitForExit()
    doAssert code == 0, result
  finally:
    process.close()

proc testNativePluginStaging() =
  let temporary = createTempDir("mynim-native-plugin-", "")
  defer: removeDir(temporary)

  let project = temporary / "project"
  let source = project / "source"
  createDir(source / "fixture")
  writeFile(source / "main.nim", "import fixture/plugin\n")
  writeFile(source / "fixture" / "plugin.nim", """when defined(mynimCollectNativePlugins):
  static:
    echo "MYNIM_NATIVE_PLUGIN_MODULE=" & currentSourcePath()
proc fixture*() = discard
""")

  let (targetOs, targetArch) = hostTarget()
  let name = "fixture-native" & (when hostOS == "windows": ".dll"
    elif hostOS == "macosx": ".dylib" else: ".so")
  let content = "verified native fixture"
  let digest = sha256Hex(content)
  var manifest = newJObject()
  var libraries = newJArray()
  var library = newJObject()
  library["name"] = %"fixture"
  var files = newJObject()
  var asset = newJObject()
  asset["name"] = %name
  asset["url"] = %"https://assets.invalid/fixture"
  asset["sha256"] = %digest
  files[targetOs & "-" & targetArch] = asset
  library["files"] = files
  libraries.add library
  manifest["libraries"] = libraries
  writeFile(source / "fixture" / "native-libraries.json", manifest.pretty)

  let cache = temporary / "cache"
  let cached = nativeAssetCachePath(cache, digest, name)
  createDir(cached.parentDir())
  writeFile(cached, content)

  let compilerOutput = compileFixture(project)
  let modules = pluginModulePaths(compilerOutput)
  doAssert modules.len == 1
  doAssert modules[0].endsWith("fixture/plugin.nim")

  let destination = temporary / "resources"
  createDir(destination)
  let staged = stageNativePlugins(compilerOutput, destination, targetOs,
    targetArch, cache)
  doAssert staged == @[destination / name]
  doAssert readFile(destination / name) == content

  let conflict = temporary / "conflict"
  createDir(conflict)
  writeFile(conflict / name, "existing resource")
  doAssertRaises(ValueError):
    discard stageNativePlugins(compilerOutput, conflict, targetOs, targetArch,
      cache)

  doAssertRaises(ValueError):
    discard stageNativePlugins(compilerOutput, temporary / "unsupported",
      "unsupported", "unsupported", cache)

testNativePluginStaging()
