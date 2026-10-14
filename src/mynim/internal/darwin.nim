## internal/darwin: the macOS backend (AppKit + WKWebView). Compiled only
## on macOS.

import std/[tables, strutils, locks, posix, times, math, algorithm, tempfiles, sequtils,
            sets, options, unicode, os, sequtils]
import platform
import ../image
import ../transfer
import accelerator
import bridge
import watchdriver
import vec
import text

include darwin/objc
include darwin/cf
include darwin/types
include darwin/system
include darwin/hotkey
include darwin/network
include darwin/power
include darwin/locale
include darwin/secrets
include darwin/notify
include darwin/replace
include darwin/login
include darwin/clipboard
include darwin/access_text
include darwin/scheme
include darwin/cookies
include darwin/watch
include darwin/dialog
include darwin/popover
include darwin/access
include darwin/menu
include darwin/icon
include darwin/dock
include darwin/deeplink
include darwin/surface_input
include darwin/surface_drag
include darwin/surface
include darwin/window
include darwin/webview
include darwin/app
include darwin/testhooks
