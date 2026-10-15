## Package mynim — a port of github.com/egoist/mygo to Nim — develops
## desktop apps with native UI or web frontend. One binary, native
## controls, GPU-rendered UI, and typed IPC between Nim and the page's
## JavaScript.
##
## One Nim module: the Go package's files become parts, included in
## dependency order. Shared type fields live in core/types.nim because
## they reference each other cyclically.

import std/[os, strutils, strtabs, tables, sets, json, atomics, times,
            options, strformat, hashes, osproc, uri, math, sequtils,
            parseutils, base64, algorithm]
import core/locks
import mynim/transfer, mynim/image
import mynim/ui as uiPackage
import mynim/internal/platform, mynim/internal/callcontext,
       mynim/internal/accelerator, mynim/internal/bridge,
       mynim/internal/surface, mynim/internal/l10n, mynim/i18n
import mynim/internal/vfs, mynim/internal/unsupported
import mynim/internal/launchargs as launchargs
export newUnsupportedBackend
when defined(emscripten):
  import mynim/internal/web
elif defined(macosx):
  import mynim/internal/darwin
elif defined(linux):
  import mynim/internal/linux

export transfer, image, platform, i18n

include mynim/core/color
include mynim/core/events
include mynim/core/loop
include mynim/core/http
include mynim/core/types
include mynim/core/state
include mynim/core/fwd
include mynim/core/dev
include mynim/core/frontend
include mynim/core/channel
include mynim/core/ipc
include mynim/core/window
include mynim/core/protocol
include mynim/core/app
include mynim/core/deeplink
include mynim/core/clipboard
include mynim/core/menu
include mynim/core/modules
include mynim/core/paths
include mynim/core/power
include mynim/core/secrets
include mynim/core/random
include mynim/core/pending

when isMainModule:
  echo "mynim: a port of egoist/mygo"
