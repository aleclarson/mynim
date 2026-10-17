import std/assertions

import mynim/plugins/updater/frontend
import mynim/plugins/updater/session as updaterSession

block responses:
  let state = updaterSession.newSession(Texts(title: "Software Update"), false)
  state.setView(View(title: "Update available", buttons: @[
    Button(action: Later, label: "Later", cancel: true),
    Button(action: Install, label: "Install", default: true)
  ]))

  let prompt = state.current().prompt
  doAssert prompt == 1
  state.respond(prompt, Skip, false)
  state.respond(prompt, Install, true)
  state.respond(prompt, Later, false)
  state.respond(prompt, Install, true)

  let answer = state.wait()
  doAssert answer == Response(action: Install, automaticDownloads: true)
  doAssert state.current().prompt == prompt + 1
  doAssert not state.isEnded()

  state.setView(View(title: "Installing", buttons: @[
    Button(action: Cancel, label: "Cancel", cancel: true, disabled: true)
  ]))
  let nextPrompt = state.current().prompt
  doAssert nextPrompt == prompt + 2
  state.respond(nextPrompt, Cancel, false)
  doAssert not state.isEnded()

  state.setView(View(title: "Ready", buttons: @[
    Button(action: Cancel, label: "Cancel", cancel: true)
  ]))
  let cancelPrompt = state.current().prompt
  state.respond(cancelPrompt, Cancel, false)
  doAssert state.isEnded()
  doAssert state.wait().action == Close
