## platform/watch.go — file watching contract. (FileWatch itself is
## declared in types.nim; FileWatchNotice and the kinds are here.)

import std/os

type
  FileWatchTarget* = object
    ## A file or directory the core enrolls in a FileWatch. IDs are
    ## never reused within a FileWatch.
    id*: uint64
    path*: string
    directory*: bool
    ## info is what the core's scan saw at path. Backends open the
    ## target and check it is still the same file, so that a replacement
    ## racing the enrollment is not watched in its place.
    info*: FileInfo
    ## subtree asks to watch everything beneath the directory with this
    ## one target, and to name what changes deeper down by its
    ## slash-separated path relative to it. A backend that can't raises
    ## errUnsupported, and the core enrolls every directory instead.
    subtree*: bool

  FileWatchKind* = enum
    ## What changed. Backends report what the system tells them; the
    ## core rescans what a notice names, so a kind is only a hint.
    ## fileWatchDirty means something about the target or its child
    ## changed.
    fileWatchDirty
    fileWatchWrite
    fileWatchCreate
    fileWatchRemove
    fileWatchMoveFrom
    fileWatchMoveTo
    ## fileWatchLost means the system stopped watching the target, for
    ## example because it was deleted; the core enrolls it again if it
    ## still exists.
    fileWatchLost

  FileWatchNotice* = object
    ## A change to a target (name empty) or to one of the immediate
    ## children of a directory target (name its name; a path for a
    ## subtree target). A notice with err set ends the watch, except
    ## errFileWatchOverflow, after which the core rescans everything.
    target*: uint64
    kind*: FileWatchKind
    name*: string
    err*: ref CatchableError

method add*(w: FileWatch, target: FileWatchTarget) {.base.} =
  raise errUnsupported()
method remove*(w: FileWatch, id: uint64) {.base.} = discard
method close*(w: FileWatch) {.base.} = discard
