## Package vfs is the filesystem abstraction the public API takes where
## Go's takes fs.FS: a tree of files served as the app's frontend or by
## Protocol handlers.

import std/[os, times, tables]

type
  Fs* = ref object of RootObj
    ## A tree of files, as Go's fs.FS: names are slash-separated, "."
    ## is the root.

method readFile*(f: Fs; name: string):
    tuple[data: seq[byte], err: ref CatchableError] {.base.} =
  ## The contents of name; err is non-nil when it is not a file.
  (@[], newException(IOError, "vfs: cannot read " & name))

method stat*(f: Fs; name: string):
    tuple[size: int64, mtime: Time, isDir, ok: bool] {.base.} =
  ## The file's size and modification time; ok is false without a file.
  (0.int64, getTime(), false, false)

## --- dirFs: os.DirFS ---

type DirFs = ref object of Fs
  root: string

method readFile(f: DirFs; name: string):
    tuple[data: seq[byte], err: ref CatchableError] =
  let p = f.root / name
  try:
    let s = readFile(p)
    var b = newSeq[byte](s.len)
    copyMem(b.addr, s.cstring, s.len)
    (b, nil)
  except CatchableError as e:
    (@[], e)

method stat(f: DirFs; name: string):
    tuple[size: int64, mtime: Time, isDir, ok: bool] =
  let p = f.root / name
  if dirExists(p):
    return (0.int64, getTime(), true, true)
  if fileExists(p):
    let info = getFileInfo(p)
    return (info.size, info.lastWriteTime, false, true)
  (0.int64, getTime(), false, false)

proc dirFs*(root: string): Fs =
  ## The files of a directory, as os.DirFS.
  DirFs(root: root)

## --- mapFs: files kept in memory (Go: an embed.FS or fstest.MapFS) ---

type MapFs = ref object of Fs
  files: Table[string, seq[byte]]

method readFile(f: MapFs; name: string):
    tuple[data: seq[byte], err: ref CatchableError] =
  if f.files.hasKey(name):
    (f.files[name], nil)
  else:
    (@[], newException(IOError, "vfs: no file " & name))

method stat(f: MapFs; name: string):
    tuple[size: int64, mtime: Time, isDir, ok: bool] =
  if f.files.hasKey(name):
    (f.files[name].len.int64, getTime(), false, true)
  else:
    (0.int64, getTime(), false, false)

proc mapFs*(files: Table[string, seq[byte]]): Fs =
  ## Files kept in memory by path, as fstest.MapFS.
  MapFs(files: files)
