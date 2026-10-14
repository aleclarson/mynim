## internal/web: the backend for browsers (the emscripten wasm build):
## windows showing content mynim draws itself (package ui) on canvases
## of the page, drawn with WebGL 2 by the GL renderer (internal/gpu/gl),
## or in memory where the browser has no WebGL 2. A window fills the
## page's element with the ID "mygo", or else the page; windows opened
## later cover earlier ones. Windows of web pages, menus, trays and the
## like have nothing in a browser to stand for them, and report so.
##
## The main thread is the browser's: JavaScript calls wasm functions on
## it, so events reach the handlers synchronously, like Go's backend
## marshals them to its main goroutine.

when not defined(emscripten):
  {.error: "internal/web is for the emscripten wasm build only".}

{.passL: "-sASYNCIFY".}
## step's sleep and the popup menus' nested event loop yield the wasm
## frame so the page's events arrive meanwhile.

import std/[os, strutils, tables, math, times, monotimes, unicode, sequtils, algorithm]
import platform
import ../transfer

include web/js
include web/types
include web/base
include web/files
include web/surface
include web/window
include web/menu
include web/web
