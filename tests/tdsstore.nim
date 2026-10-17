import std/[assertions, os]
import ../src/cmd/dsstore
import ../src/cmd/dmg

let fixture = currentSourcePath().parentDir / "data" / "mygo_dmg.DS_Store"
var expected: seq[byte]
for ch in readFile(fixture): expected.add byte(ord(ch))
doAssert dsStore("Hello MyGo.app") == expected
doAssert dmgFileName("Ada & Counter", "1.2.3", "arm64") ==
  "Ada & Counter 1.2.3 arm64.dmg"
doAssert dmgFileName("Ada/Counter", "1:2", "universal") ==
  "Ada-Counter 1-2.dmg"
