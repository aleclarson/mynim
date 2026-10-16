import std/assertions

import mynim/ui as ui

let router = ui.newRouter("/notes")
doAssert router.path() == "/notes"
doAssert router.location() == "/notes"
doAssert not router.canGoBack()
doAssert not router.canGoForward()

router.push("/notes/42")
router.push("edit")
doAssert router.location() == "/notes/edit"
router.push("../settings/")
doAssert router.path() == "/settings"
router.push("?tab=fonts")
doAssert router.location() == "/settings?tab=fonts"
doAssert router.query("tab") == "fonts"
router.push("/settings?tab=fonts")
doAssert router.location() == "/settings?tab=fonts",
  "pushing the current location should not add history"

router.back()
doAssert router.location() == "/settings"
doAssert router.canGoBack() and router.canGoForward()
router.go(-2)
doAssert router.location() == "/notes/42"
router.forward()
doAssert router.location() == "/notes/edit"

router.push("/a%20b")
doAssert router.location() == "/a%20b"
doAssert router.path() == "/a b"
router.replace("/search?q=go%20ui")
doAssert router.path() == "/search"
doAssert router.query("q") == "go ui"
router.replace("?q=updated")
doAssert router.location() == "/search?q=updated"
router.push("/bad%xx")
doAssert router.location() == "/search?q=updated",
  "malformed percent escapes should be ignored"

router.go(-1000)
doAssert router.location() == "/notes"
doAssert not router.canGoBack() and router.canGoForward()
router.go(1000)
doAssert router.location() == "/search?q=updated"
doAssert router.canGoBack() and not router.canGoForward()

router.push("https://example.com")
doAssert router.location() == "/",
  "external URI components should not become part of an app location"

let normalized = ui.newRouter("/a/./b/../c")
doAssert normalized.path() == "/a/c"

let routes = ui.newRouter("/notes/42/edit?tab=info")
let route = routes.route()
doAssert route.path() == "/notes/42/edit"
doAssert route.match("/notes/{id}/edit")
doAssert route.param("id") == "42"
doAssert route.query("tab") == "info"
route.title("Edit note")
doAssert routes.title() == "Edit note"
routes.replace("?tab=detail")
doAssert routes.query("tab") == "detail"
doAssert routes.title() == "Edit note",
  "replacing the query on the same path should keep its page title"
doAssert not route.match("/users/{id}")
doAssert route.param("id") == "42",
  "a failed match should leave the last successful parameters intact"

let escapedRoute = ui.newRouter("/files/a%2Fb").route()
doAssert escapedRoute.match("/files/{name}")
doAssert escapedRoute.param("name") == "a/b"
let emptyRest = ui.newRouter("/files").route()
doAssert emptyRest.match("/files/{path...}")
doAssert emptyRest.param("path") == ""
var badRestPatternRejected = false
try:
  discard route.match("/{rest...}/edit")
except ValueError:
  badRestPatternRejected = true
doAssert badRestPatternRejected

let branch = ui.newRouter("/one")
branch.push("/two")
branch.push("/three")
branch.back()
branch.push("/four")
doAssert branch.location() == "/four"
doAssert not branch.canGoForward(),
  "pushing after Back should discard later entries"

let bounded = ui.newRouter("/")
for index in 0..<150:
  bounded.push("/n/" & $index)
bounded.go(-1000)
doAssert bounded.location() == "/n/50",
  "router history should retain the newest 100 entries"
doAssert not bounded.canGoBack() and bounded.canGoForward()
