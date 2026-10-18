import std/[os, strutils, unittest]
import mynim/plugins/terminal/native_library

suite "Ghostty native library manifest":
  test "pins all supported platform artifacts":
    let assets = [
      ("darwin", "amd64", "libghostty-vt.dylib",
        "421e98d2683b39555209c59395655b4a217da0382e7669c92f6dff3949832664"),
      ("darwin", "arm64", "libghostty-vt.dylib",
        "6f385d3221f8c776ba40530db9baf8c71478907897959849896eeb0ddbf16b41"),
      ("linux", "amd64", "libghostty-vt.so",
        "9dcd8af0de67778a561f436cb673a9fb1738be8fa00849dad49606baed1e57d7"),
      ("linux", "arm64", "libghostty-vt.so",
        "fb163f8f123206956751f1c4f0303b40899513b7dc171a8ab8d85ba7cd541bc0"),
      ("windows", "amd64", "ghostty-vt.dll",
        "53e8e2dd979702e8f2c48107af19be5a76efc2e88eb7cf1097218e899665da41"),
      ("windows", "arm64", "ghostty-vt.dll",
        "de56a362f12cce8be38e883ffc8aec90a890e0574eb73aac6e833a60fda26064")]
    for (osName, arch, name, hash) in assets:
      let asset = nativeLibraryFor(osName, arch)
      check asset.name == name
      check asset.sha256 == hash
      check asset.url.startsWith("https://")

  test "rejects targets with no pinned asset":
    expect ValueError:
      discard nativeLibraryFor("plan9", "amd64")

  test "the explicit development override takes precedence":
    let hadPrevious = existsEnv("MYNIM_GHOSTTY_VT")
    let previous = getEnv("MYNIM_GHOSTTY_VT")
    let override = "/tmp/mynim-ghostty-override-test"
    putEnv("MYNIM_GHOSTTY_VT", override)
    defer:
      if hadPrevious:
        putEnv("MYNIM_GHOSTTY_VT", previous)
      else:
        delEnv("MYNIM_GHOSTTY_VT")
    check findGhosttyVTPath() == override
