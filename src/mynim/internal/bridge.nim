## Package bridge embeds the renderer runtime that MyNim injects into
## pages.
##
## bridge.js is built from ../../packages/bridge by `bun run build` and
## committed, so building a MyNim application never requires Bun.

import std/json

import platform

const source = staticRead("bridge/bridge.js")

type Config* = object
  ## Passed to the bridge as __MYGO_CONFIG__.
  platform*: string
  windowId*: int
  version*: string
  ## secret prefixes every message the bridge posts.
  secret*: string
  ## locale is the language the app shows, e.g. "zh-Hans", and dir the
  ## direction it is written in, "ltr" or "rtl", which pages read as
  ## mynim.locale and mynim.dir from document start.
  locale*: string
  dir*: string

proc `%`*(c: Config): JsonNode =
  %*{"platform": c.platform, "windowId": c.windowId, "version": c.version,
     "secret": c.secret, "locale": c.locale, "dir": c.dir}

proc script*(cfg: Config): string =
  ## The bridge source configured for one window.
  "(function(__MYGO_CONFIG__){\n" & source & "})(" & $(%cfg) & ");"

## titleBarEvent tells a page of a window with a hidden title bar the
## room the window controls take. The bridge keeps it in the
## --mygo-titlebar-* CSS variables.
const titleBarEvent* = "mygo:title-bar"

## localeEvent tells the pages of a window that the language the app
## shows changed, with a Locale. The bridge configuration tells pages
## the language at document start; the event is sent as a page loads
## too, for one that started loading as the language changed, and the
## bridge tells its listeners only of a language the page did not have.
const localeEvent* = "mygo:locale"

type
  Locale* = object
    ## The payload of localeEvent.
    locale*: string
    dir*: string

  TitleBar* = object
    ## The payload of titleBarEvent, in CSS pixels.
    height*: float64
    left*: float64
    right*: float64

proc `%`*(l: Locale): JsonNode = %*{"locale": l.locale, "dir": l.dir}
proc `%`*(t: TitleBar): JsonNode =
  %*{"height": t.height, "left": t.left, "right": t.right}

proc newTitleBar*(tb: platform.TitleBar; zoom: float64): TitleBar =
  ## Converts the room of the window controls to the CSS pixels of a
  ## page shown at zoom.
  var zoom = zoom
  if zoom <= 0: zoom = 1
  TitleBar(height: tb.height.float64 / zoom, left: tb.left.float64 / zoom,
           right: tb.right.float64 / zoom)

proc titleBarScript*(tb: platform.TitleBar; zoom: float64): string =
  ## Delivers titleBarEvent at document start, after the bridge, so
  ## that a page lays out around the window controls before it first
  ## paints.
  "window.__mygo&&window.__mygo.receive({\"t\":\"event\",\"n\":\"" &
    titleBarEvent & "\",\"p\":" & $(%newTitleBar(tb, zoom)) & "});"

## preferencesEvent tells a page the accent color and the accessibility
## settings of the desktop. The bridge keeps the accent in the
## --mygo-accent CSS variable and the text scale in --mygo-text-scale.
const preferencesEvent* = "mygo:preferences"

type Preferences* = object
  ## A page's view of the desktop's settings.
  ## accent is the color of the desktop's controls as "#rrggbb", or
  ## empty where the desktop has none.
  accent*: string
  ## reduceMotion reports that the desktop asks for less animation.
  reduceMotion*: bool
  ## highContrast reports that the desktop uses a contrast theme.
  highContrast*: bool
  ## textScale is the factor the desktop asks text to grow by; 1 is
  ## usual.
  textScale*: float64

proc `%`*(p: Preferences): JsonNode =
  %*{"accent": p.accent, "reduceMotion": p.reduceMotion,
     "highContrast": p.highContrast, "textScale": p.textScale}

proc preferencesScript*(p: Preferences): string =
  ## Delivers preferencesEvent at document start, after the bridge has
  ## registered the handler that turns it into CSS variables.
  "window.__mygo&&window.__mygo.receive({\"t\":\"event\",\"n\":\"" &
    preferencesEvent & "\",\"p\":" & $(%p) & "});"
