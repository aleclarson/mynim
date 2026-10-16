import std/[assertions, sets]
import mynim/ui as ui

var names: ui.Selection[string]
doAssert names.len == 0
doAssert not names.has("readme.md")

names.add("readme.md")
names.add("main.nim")
names.add("readme.md")
doAssert names.len == 2
doAssert names.has("readme.md")

var visited = initHashSet[string]()
for name in names.all():
  visited.incl(name)
doAssert visited.len == 2
doAssert visited.contains("readme.md")
doAssert visited.contains("main.nim")

names.remove("readme.md")
doAssert names.len == 1
doAssert not names.has("readme.md")
names.clear()
doAssert names.len == 0

var rows: ui.Selection[int]
rows.add(2)
rows.add(5)
doAssert rows.has(2) and rows.has(5)

echo "selection tests passed"
