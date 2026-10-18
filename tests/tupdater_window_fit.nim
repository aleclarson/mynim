import std/[assertions, strutils]

import mynim/plugins/updater/frontend as updaterFrontend
import mynim/plugins/updater/markdown as updaterMarkdown
import mynim/plugins/updater/window as updaterWindow
import mynim/ui as ui

proc releaseSize(notesText: string): tuple[width, height: int] =
  let
    texts = updaterFrontend.Texts(title: "Software Update",
      releaseNotes: "Release Notes",
      automaticDownloads: "Install updates automatically", lang: "en")
    view = updaterFrontend.View(prompt: 1, release: true,
      title: "Update available", message: "Version 2.0 is ready.",
      notes: updaterMarkdown.parse(notesText), checkbox: true, buttons: @[
        updaterFrontend.Button(action: updaterFrontend.Skip, label: "Skip",
          aside: true),
        updaterFrontend.Button(action: updaterFrontend.Later, label: "Later",
          cancel: true),
        updaterFrontend.Button(action: updaterFrontend.Install,
          label: "Install", default: true)
      ])
    state = updaterWindow.newUpdaterWindow(texts, view,
      proc(prompt: int; action: updaterFrontend.Action;
           automaticDownloads: bool) = discard)
  var measured: tuple[width, height: int]
  let tester = ui.newTester(proc(c: ui.Context) =
    discard state.build(c)
    measured = state.measureReleaseSize(c, c.theme(), view)
  , 620, 440)
  defer: tester.close()
  measured

block bounded_release_size:
  doAssert updaterFrontend.fitSize(true, 320, 200) ==
    (width: 620, height: 440)
  doAssert updaterFrontend.fitSize(true, 1800, 900) ==
    (width: 1000, height: 600)
  doAssert updaterFrontend.fitSize(false, 480, 20) ==
    (width: 480, height: 80)

block short_notes_keep_default_height:
  doAssert releaseSize("- One small change\n").height == 440

block long_notes_grow_to_limit:
  let longNotes = strutils.repeat(
    "- A release change that wraps to several lines\n", 100)
  doAssert releaseSize(longNotes).height == 600
