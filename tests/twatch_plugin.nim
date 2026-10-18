import std/[os, tables]

import mynim as core
import mynim/plugins/watch

core.use(newWatchPlugin(Options(roots: {
  "project": Root(path: getTempDir(), recursive: true),
}.toTable)))

core.bindTypeScript("plugin:watch", "Watch", [
  core.TypeScriptParam(name: "request", tsType: "unknown"),
  core.TypeScriptParam(name: "parts", tsType: "unknown", channel: true),
], "unknown")
