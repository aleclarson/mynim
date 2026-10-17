import std/assertions

when defined(macosx):
  import mynim/internal/gpu/metal as metal
  import mynim/plugins/glass as glass

  const blurSource = staticRead("../src/mynim/plugins/glass/blur.metal")

  let
    glassLibrary = metal.compileLibrary(
      metal.effectSource(glass.Effect.metal.source))
    blurLibrary = metal.compileLibrary(metal.effectSource(blurSource))
  doAssert glassLibrary.len > 0
  doAssert blurLibrary.len > 0
