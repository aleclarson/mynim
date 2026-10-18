## View data shared by the updater service and its window.

import mynim/plugins/updater/markdown

type
  Action* = enum
    Ok, Cancel, Skip, Later, Install, Relaunch, Close

  Button* = object
    action*: Action
    label*: string
    default*, cancel*, aside*, disabled*: bool

  View* = object
    prompt*: int
    release*: bool
    title*, message*, detail*: string
    notes*: seq[Block]
    bar*: bool
    progress*: float64
    checkbox*, checked*: bool
    buttons*: seq[Button]

  Texts* = object
    title*, releaseNotes*, automaticDownloads*: string
    lang*: string
    rtl*: bool

const
  statusWidth* = 480
  statusHeight* = 148
  releaseWidth* = 620
  releaseHeight* = 440

proc size*(release: bool): tuple[width, height: int] =
  ## Returns the initial content size for a status or release view.
  if release:
    (releaseWidth, releaseHeight)
  else:
    (statusWidth, statusHeight)

proc fitSize*(release: bool; width, height: int): tuple[width, height: int] =
  ## Bounds a measured updater size while retaining each view's default size.
  let (minimumWidth, defaultHeight) = size(release)
  result.width = max(minimumWidth, min(width, 1000))
  result.height = if release: min(max(height, defaultHeight), 600)
    else: min(max(height, 80), 600)

proc background*(): tuple[light, dark: string] =
  ## Returns the light and dark updater window backgrounds.
  when defined(macosx):
    ("#ececec", "#1e1e1e")
  else:
    ("#fff", "#1e1e1e")
