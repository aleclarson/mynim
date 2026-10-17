import std/[assertions, os, strutils, tables, tempfiles]
import ../src/cmd/migrate_ui

block syntax_edits:
  let source = """package app
import native "github.com/egoist/mygo/ui"
func view(c *native.Context) {
  var element *native.Element
  var parts *native.TabsParts
  var context *native.Context
  _ = element
  _ = parts
  _ = context
  native.Box(c).Rows(3)
  foreign.Box(c).Rows(4)
}
"""
  let migrated = migrateFile("view.go", source)
  doAssert migrated.changed
  doAssert "var element native.Element" in migrated.source
  doAssert "var parts native.TabsParts" in migrated.source
  doAssert "var context *native.Context" in migrated.source
  doAssert "native.Box(c).GridRows(3)" in migrated.source
  doAssert "foreign.Box(c).Rows(4)" in migrated.source
  doAssert not migrateFile("view.go", migrated.source).changed

block import_boundaries:
  let unrelated = """package app
import ui "example.org/other/ui"
type model struct { element *ui.Element }
"""
  let kept = migrateFile("other.go", unrelated)
  doAssert not kept.changed
  doAssert kept.source == unrelated

  let dotImport = migrateFile("dot.go", """package app
import . "github.com/egoist/mygo/ui"
""")
  doAssert not dotImport.changed
  doAssert dotImport.notes == @[
    "replace the dot import with an explicit MyGo UI alias before migrating"]

  var failed = false
  try:
    discard migrateFile("broken.go", "package app\nfunc broken( {")
  except ValueError:
    failed = true
  doAssert failed

block scoped_nil_migration:
  let source = """package app
import native "github.com/egoist/mygo/ui"
func missing() *native.Element { return nil }
func contextNil() *native.Context { return nil }
func pair() (*native.Element, *native.TabsParts) { return nil, nil }
func one() (int, *native.Element) { return 0, nil }
func closureFacts(c *native.Context) *int {
  callback := func(element *native.Element) *native.Element {
    if element != nil { element.Focus() }
    return nil
  }
  _ = callback
  return nil
}
func view(c *native.Context) {
  element := native.Text(c, "Hello")
  if element != nil { element.Focus() }
  var stored *native.Element
  var parts *native.TabsParts
  if stored == nil { stored = element }
  stored = nil
  parts = nil
  var other *int
  if other == nil { _ = other }
}
"""
  let migrated = migrateFile("view.go", source)
  doAssert "func missing() native.Element { return native.Element{} }" in
    migrated.source
  doAssert "func contextNil() *native.Context { return nil }" in
    migrated.source
  doAssert "return native.Element{}, native.TabsParts{}" in migrated.source
  doAssert "return 0, native.Element{}" in migrated.source
  doAssert "if element.Valid()" in migrated.source
  doAssert "if !stored.Valid()" in migrated.source
  doAssert "stored = native.Element{}" in migrated.source
  doAssert "parts = native.TabsParts{}" in migrated.source
  doAssert "if other == nil" in migrated.source
  doAssert "if element.Valid()" in migrated.source
  doAssert "callback := func(element native.Element) native.Element {\n    if element.Valid() { element.Focus() }\n    return native.Element{}\n  }" in
    migrated.source, migrated.source
  doAssert "return native.Element{}" in migrated.source
  doAssert "return nil" in migrated.source

block package_facts:
  let sources = {
    "app/model.go": """package app
import ui "github.com/egoist/mygo/ui"
type window struct { element *ui.Element; other *int }
func rowBuilder() {}
""",
    "app/view.go": """package app
import native "github.com/egoist/mygo/ui"
func (w *window) view(c *native.Context) {
  if w.element != nil { w.element.Focus() }
  if w.other != nil { _ = *w.other }
  native.Box(c).Rows(rowBuilder)
  foreign.Children(func() {})
}
func newWindow() (*window, int) { return &window{}, 0 }
func makeElement(c *native.Context) *native.Element {
  return native.Text(c, "hello")
}
func check(c *native.Context) {
  w, _ := newWindow()
  if w.element == nil { w.element = makeElement(c) }
  element := makeElement(c)
  if element != nil { element.Focus() }
}
"""}.toTable
  let migrated = migrateFiles(sources)
  doAssert "if w.element.Valid()" in migrated["app/view.go"].source
  doAssert "if !w.element.Valid()" in migrated["app/view.go"].source
  doAssert "if !w.element.Valid() { w.element = makeElement(c) }" in
    migrated["app/view.go"].source
  doAssert "if element.Valid()" in migrated["app/view.go"].source
  doAssert "if w.other != nil" in migrated["app/view.go"].source
  doAssert "native.Box(c).Rows(rowBuilder)" in migrated["app/view.go"].source
  doAssert "foreign.Children(func() {})" in migrated["app/view.go"].source

block key_migration:
  let source = """package app
import native "github.com/egoist/mygo/ui"
func view(c *native.Context, v *bool) {
  native.Checkbox(c, v, "Done").Disabled(false).Key("done").OnChange(func() {})
  native.Button(c, "Two").Key("first").Key("second")
  element := native.Text(c, "stored")
  element.Key("stored-key")
}
"""
  let migrated = migrateFile("view.go", source)
  doAssert "Checkbox(c.Key(\"done\"), v, \"Done\").Disabled(false).OnChange" in
    migrated.source
  doAssert "Button(c.Key(\"first\").Key(\"second\"), \"Two\")" in
    migrated.source
  doAssert "element.Key(\"stored-key\")" in migrated.source
  doAssert migrated.notes == @[
    "move a stored element's Key to Context.Key before its constructor"]
  doAssert not migrateFile("view.go", migrated.source).changed

block rows_callback_and_non_integer:
  let source = """package app
import "github.com/egoist/mygo/ui"
func rows() {}
func view(c *ui.Context) {
  count := 3
  ui.Box(c).Rows(3)
  ui.Box(c).Rows(count)
  ui.Box(c).Rows(0xF)
  ui.Box(c).Rows(0x1p2)
  ui.Box(c).Rows(3.5)
  ui.Box(c).Rows(3i)
  ui.Box(c).Rows(3 + 1)
  ui.Box(c).Rows(func(i int) {})
  ui.Box(c).Rows(rows)
  ui.Box(c).Rows(1, 2)
}
"""
  let migrated = migrateFile("view.go", source)
  doAssert "GridRows(3)" in migrated.source
  doAssert "GridRows(count)" in migrated.source
  doAssert "GridRows(0xF)" in migrated.source
  doAssert "GridRows(0x1p2)" in migrated.source
  doAssert "GridRows(3.5)" in migrated.source
  doAssert "GridRows(3i)" in migrated.source
  doAssert "GridRows(3 + 1)" in migrated.source
  doAssert "Rows(func(i int) {})" in migrated.source
  doAssert "Rows(rows)" in migrated.source
  doAssert "Rows(1, 2)" in migrated.source

block preview_write_skip_and_permissions:
  let temporary = createTempDir("mynim-migrate-ui-", "")
  defer:
    if dirExists(temporary): removeDir(temporary)
  let project = temporary / "project with spaces"
  createDir(project / "vendor")
  let sourcePath = project / "view.go"
  let vendorPath = project / "vendor" / "view.go"
  let source = """package app
import "github.com/egoist/mygo/ui"
func view(c *ui.Context) { ui.Box(c).Rows(3) }
"""
  writeFile(sourcePath, source)
  writeFile(vendorPath, source)
  setFilePermissions(sourcePath, {fpUserRead, fpUserWrite})
  let originalPermissions = getFilePermissions(sourcePath)

  doAssert runMigrateUI(@[project]) == 0
  doAssert readFile(sourcePath) == source
  doAssert readFile(vendorPath) == source

  doAssert runMigrateUI(@["-write", project]) == 0
  doAssert "GridRows(3)" in readFile(sourcePath)
  doAssert readFile(vendorPath) == source
  doAssert getFilePermissions(sourcePath) == originalPermissions
  doAssert runMigrateUI(@["-write=false", project]) == 0
  doAssert runMigrateUI(@["-write=maybe", project]) == 2

  doAssert runMigrateUI(@["one", "two"]) == 2
