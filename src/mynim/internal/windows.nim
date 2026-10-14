## internal/windows: the Windows backend (Win32 + WebView2 + Direct3D 11,
## all through the system DLLs).

when defined(windows) and (defined(amd64) or defined(arm64)):
  import std/[tables, strutils, sugar, locks, math, algorithm,
              sequtils, sets, unicode, os, ospaths, monotimes,
              options, hashes, widestrs, atomics, times,
              dynlib, json]
  import platform
  import ../image
  import webview2
  import ../transfer
  import accelerator
  import bridge
  import watchdriver
  import vec
  import text
  import ../internal/scene as scene
  import ../internal/gpu as gpu
  import ../internal/gpu/d3d11/device as d3d11device
  import std/threadpool

  include windows/win32
  include windows/com
  include windows/types
  include windows/oleformats
  include windows/surface_drag
  include windows/surface_drop
  include windows/registry
  include windows/locale
  include windows/secrets
  include windows/network
  include windows/power
  include windows/apps
  include windows/icon
  include windows/login
  include windows/deeplink
  include windows/replace
  include windows/system
  include windows/webview2
  include windows/app
  include windows/window
  include windows/surface
  include windows/surface_input
  include windows/flyout
  include windows/compositor
  include windows/menu
  include windows/surface_access
  include windows/uia_text
