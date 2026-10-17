import std/assertions

import mynim/plugins/updater/frontend
import mynim/plugins/updater/markdown
import mynim/plugins/updater/window as updaterWindow
import mynim/image as sourceImage
import mynim/ui as ui

block release_window:
  var answers: seq[(int, Action, bool)]
  let pixels = sourceImage.newRgba(sourceImage.rect(0, 0, 2, 2))
  pixels.set(0, 0, sourceImage.Rgba(r: 255, g: 0, b: 0, a: 255))
  let icon = sourceImage.pngEncode(pixels)
  let
    view = frontend.View(prompt: 1, release: true, title: "Update available",
      message: "Version 2.0 is ready.", notes: parse("## Changes\n\n- Fixed a bug"),
      checkbox: true, buttons: @[
        Button(action: Skip, label: "Skip", aside: true),
        Button(action: Later, label: "Later", cancel: true),
        Button(action: Install, label: "Install", default: true)
      ])
    texts = Texts(title: "Software Update", releaseNotes: "Release Notes",
      automaticDownloads: "Install updates automatically", lang: "en")
    state = updaterWindow.newUpdaterWindow(texts, view,
      proc(prompt: int; action: Action; automaticDownloads: bool) =
        answers.add((prompt, action, automaticDownloads)), iconPng = icon)
    tester = ui.newTester(proc(c: ui.Context) = discard state.build(c), 620, 440)
  defer: tester.close()

  doAssert tester.hasText("Update available")
  doAssert tester.hasText("Release Notes")
  doAssert tester.hasText("Fixed a bug")
  doAssert tester.hasText("Install updates automatically")
  doAssert tester.click("Install updates automatically") == nil
  doAssert tester.click("Install") == nil
  doAssert answers == @[(1, Install, true)]

  state.setView(frontend.View(prompt: 2, title: "Installing", bar: true,
    progress: 0.5,
    buttons: @[Button(action: Cancel, label: "Cancel", cancel: true)]))
  tester.frame()
  doAssert tester.hasText("Installing")
  doAssert tester.click("Cancel") == nil
  doAssert answers.len == 2 and answers[^1] == (2, Cancel, false), $answers

block default_shortcut:
  var answers: seq[(int, Action, bool)]
  var rootKeyCalls = 0
  let
    state = updaterWindow.newUpdaterWindow(
      Texts(title: "Software Update"),
      frontend.View(prompt: 1, title: "Up to date", buttons: @[
        Button(action: Ok, label: "OK", default: true, cancel: true)
      ]),
      proc(prompt: int; action: Action; automaticDownloads: bool) =
        answers.add((prompt, action, automaticDownloads)))
    tester = ui.newTester(proc(c: ui.Context) =
      discard state.build(c)
      c.onShortcut(0, ui.keyA, proc() = inc rootKeyCalls)
    , 480, 148)
  defer: tester.close()

  tester.setFocused(true)
  tester.key(0, ui.keyA)
  doAssert rootKeyCalls == 1
  tester.key(0, ui.keyEnter)
  doAssert answers == @[(1, Ok, false)]
  state.setView(frontend.View(prompt: 2, title: "Update paused", buttons: @[
    Button(action: Later, label: "Later", cancel: true)
  ]))
  tester.frame()
  tester.key(0, ui.keyEscape)
  doAssert answers[^1] == (2, Later, false)
