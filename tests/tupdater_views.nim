import std/[assertions, strutils, tables]

import mynim/plugins/updater/frontend
import mynim/plugins/updater/texts as updaterTexts

let english = updaterTexts.newText("en-US", initTable[string, Strings]())

block status_views:
  let checking = english.checkingView()
  doAssert checking.title == "Checking for updates…"
  doAssert checking.bar and checking.progress == -1
  doAssert checking.buttons == @[Button(action: Cancel, label: "Cancel",
    cancel: true)]

  let current = english.upToDateView("Mynim", "1.0.0")
  doAssert current.title == "You’re up to date!"
  doAssert current.message ==
    "Mynim 1.0.0 is currently the newest version available."
  doAssert current.buttons[0].default and current.buttons[0].cancel

  let unavailable = english.unavailableView("Mynim", false)
  doAssert unavailable.message.startsWith("Mynim cannot update itself")
  let development = english.unavailableView("Mynim", true)
  doAssert development.message == "Development builds do not update themselves."

  let failed = english.errorView("An error occurred while checking",
    newException(IOError, "offline"))
  doAssert failed.title == "Update Error!"
  doAssert failed.detail == "offline"
  doAssert failed.buttons[0].action == Ok

block release_and_progress_views:
  let available = english.availableView("Mynim", "2.0.0", "1.0.0",
    "### Changes\n\n- Fixed a **bug**", true)
  doAssert available.release and available.checkbox and available.checked
  doAssert available.title == "A new version of Mynim is available!"
  doAssert available.message ==
    "Mynim 2.0.0 is now available—you have 1.0.0. Would you like to install it now?"
  doAssert available.notes.len > 0
  doAssert available.buttons.len == 3
  doAssert available.buttons[0].action == Skip and available.buttons[0].aside
  doAssert available.buttons[1].action == Later and available.buttons[1].cancel
  doAssert available.buttons[2].action == Install and available.buttons[2].default

  let noNotes = english.availableView("Mynim", "2.0.0", "1.0.0", "", false)
  doAssert not noNotes.release and noNotes.notes.len == 0

  let unknown = english.downloadingView(0, 0)
  doAssert unknown.progress == -1 and unknown.bar and unknown.message.len == 0
  let progress = english.downloadingView(5_000_000, 20_000_000)
  doAssert progress.progress == 0.25
  doAssert progress.message == "5.0 MB of 20.0 MB"

  let installing = english.installingView()
  doAssert installing.bar and installing.progress == -1
  doAssert installing.buttons[0].disabled

  let ready = english.readyView("Mynim", "2.0.0")
  doAssert ready.message.contains("2.0.0 is installed")
  doAssert ready.buttons[0].cancel and ready.buttons[1].default

  let german = updaterTexts.newText("de-DE", initTable[string, Strings]())
  doAssert german.downloadingView(5_000_000, 20_000_000).message ==
    "5,0 MB von 20,0 MB"
