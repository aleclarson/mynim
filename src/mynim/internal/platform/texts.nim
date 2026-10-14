## platform/texts.go — the words backends say of their own, in the
## language the app shows.

import std/atomics

type
  Texts* = object
    ## The buttons of the panels of pages' alert, confirm and prompt,
    ## the titles and buttons of file dialogs, and the title of the
    ## about panel. Backends read them with currentTexts from any thread.
    ok*, cancel*, open*, save*, selectFolder*: string
    ## about is the title of the about panel with "\x00" for the app's
    ## name: "About \x00".
    about*: string

## defaultTexts are the texts in English, before package mynim sets others.
const defaultTexts* = Texts(
  ok: "OK", cancel: "Cancel", open: "Open", save: "Save",
  selectFolder: "Select Folder", about: "About \x00")

var textsPtr: Atomic[pointer]

proc setTexts*(t: Texts) =
  ## Sets the texts backends say.
  let p = cast[ptr Texts](allocShared0(sizeof(Texts)))
  p[] = t
  var old = textsPtr.load(moAcquire)
  while not textsPtr.compareExchange(old, p, moRelease, moAcquire):
    discard
  # Old Texts contain strings owned by this process heap; freeing the
  # old block would leave dangling seq/string fields only if it held any
  # — Texts is all strings, so just leak the small block (set once).
  discard old

proc currentTexts*(): Texts =
  ## The texts backends say.
  let p = cast[ptr Texts](textsPtr.load(moAcquire))
  if p != nil: p[] else: defaultTexts
