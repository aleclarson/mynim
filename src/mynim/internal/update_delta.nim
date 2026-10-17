## Signed app-tree deltas shared by update publishing and installation.

import std/[algorithm, json, os, sets, strutils, tables]
import ./[bsdiff, deflate, sha256]

const
  deltaMagic* = "mygo delta 1\n"
  maxDeltaIndex = 16 shl 20
  maxDeltaSize = 1'i64 shl 30
  maxDiffSize = 256 shl 20
  stapledTicket = "Contents/CodeResources"

type
  DeltaEntry = object
    path, link, sha256, fromPath: string
    directory: bool
    mode: uint32
    size, data: int64

  OldFile = object
    sha256: string
    size: int64

proc toBytes(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for i, ch in value:
    result[i] = byte(ord(ch))

proc toString(value: openArray[byte]): string =
  result = newString(value.len)
  for i, ch in value:
    result[i] = char(ch)

proc appendUvarint(target: var seq[byte]; value: uint64) =
  var remaining = value
  while remaining >= 0x80:
    target.add byte((remaining and 0x7f) or 0x80)
    remaining = remaining shr 7
  target.add byte(remaining)

proc readUvarint(data: openArray[byte]; pos: var int;
    value: var uint64): bool =
  value = 0
  for shift in countup(0, 63, 7):
    if pos >= data.len: return false
    let current = data[pos]
    inc pos
    if shift == 63 and current > 1: return false
    value = value or (uint64(current and 0x7f) shl shift)
    if current < 0x80: return true
  false

proc safeDeltaPath(path: string): bool =
  if path.len == 0 or path[0] == '/' or '\\' in path or '\0' in path:
    return false
  if path.len >= 2 and path[1] == ':': return false
  for part in path.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return false
  true

proc linkStaysInside(path, target: string): bool =
  if target.len == 0 or target[0] == '/' or '\\' in target or '\0' in target:
    return false
  if target.len >= 2 and target[1] == ':': return false
  var depth = path.split('/').len - 1
  for part in target.split('/'):
    if part == "..":
      if depth == 0: return false
      dec depth
    elif part != "" and part != ".":
      inc depth
  true

proc osPath(path: string): string =
  path.replace('/', DirSep)

proc pathPermissions(path: string): uint32 =
  let permissions = getFilePermissions(path)
  if fpUserRead in permissions: result = result or 0o400'u32
  if fpUserWrite in permissions: result = result or 0o200'u32
  if fpUserExec in permissions: result = result or 0o100'u32
  if fpGroupRead in permissions: result = result or 0o040'u32
  if fpGroupWrite in permissions: result = result or 0o020'u32
  if fpGroupExec in permissions: result = result or 0o010'u32
  if fpOthersRead in permissions: result = result or 0o004'u32
  if fpOthersWrite in permissions: result = result or 0o002'u32
  if fpOthersExec in permissions: result = result or 0o001'u32

proc toPermissions(mode: uint32): set[FilePermission] =
  if (mode and 0o400) != 0: result.incl fpUserRead
  if (mode and 0o200) != 0: result.incl fpUserWrite
  if (mode and 0o100) != 0: result.incl fpUserExec
  if (mode and 0o040) != 0: result.incl fpGroupRead
  if (mode and 0o020) != 0: result.incl fpGroupWrite
  if (mode and 0o010) != 0: result.incl fpGroupExec
  if (mode and 0o004) != 0: result.incl fpOthersRead
  if (mode and 0o002) != 0: result.incl fpOthersWrite
  if (mode and 0o001) != 0: result.incl fpOthersExec

proc jsonEntry(entry: DeltaEntry): JsonNode =
  result = newJObject()
  result["path"] = %entry.path
  if entry.directory:
    result["dir"] = %true
  elif entry.link.len > 0:
    result["link"] = %entry.link
  else:
    result["mode"] = %entry.mode
    result["size"] = %entry.size
    result["sha256"] = %entry.sha256
    if entry.fromPath.len > 0:
      result["from"] = %entry.fromPath
    if entry.data > 0:
      result["data"] = %entry.data

proc childPaths(directory: string): seq[string] =
  for _, path in walkDir(directory):
    result.add path
  result.sort()

proc collectOldFiles(root, prefix: string; old: var Table[string, OldFile];
    byHash: var Table[string, string]) =
  for path in childPaths(root):
    let name = path.lastPathPart()
    let relative = if prefix.len == 0: name else: prefix & "/" & name
    let info = getFileInfo(path, followSymlink = false)
    if info.kind == pcDir:
      collectOldFiles(path, relative, old, byHash)
    elif info.kind == pcFile and relative != stapledTicket:
      let content = readFile(path)
      let digest = sha256Hex(content)
      old[relative] = OldFile(sha256: digest, size: int64(content.len))
      if not byHash.hasKey(digest):
        byHash[digest] = relative

proc collectNewEntry(root, path, relative: string;
    oldDir: string; old: Table[string, OldFile]; byHash: Table[string, string];
    entries: var seq[DeltaEntry]; blobs: var seq[seq[byte]]) =
  if not safeDeltaPath(relative):
    raise newException(ValueError, "delta: unsafe path " & relative.escape())
  let info = getFileInfo(path, followSymlink = false)
  if info.kind == pcDir:
    entries.add DeltaEntry(path: relative, directory: true)
    for child in childPaths(path):
      collectNewEntry(root, child, relative & "/" & child.lastPathPart(),
        oldDir, old, byHash, entries, blobs)
  elif info.kind in {pcLinkToDir, pcLinkToFile}:
    let target = expandSymlink(path).replace('\\', '/')
    if not linkStaysInside(relative, target):
      raise newException(ValueError,
        "delta: link points outside the app: " & relative.escape())
    entries.add DeltaEntry(path: relative, link: target)
  elif info.kind == pcFile:
    let content = readFile(path)
    let digest = sha256Hex(content)
    var entry = DeltaEntry(path: relative, mode: pathPermissions(path),
      size: int64(content.len), sha256: digest)
    let previous = old.getOrDefault(relative)
    if previous.sha256 == digest and previous.size == entry.size:
      entry.fromPath = relative
    elif byHash.hasKey(digest):
      entry.fromPath = byHash[digest]
    else:
      let compressedFile = deflateRaw(toBytes(content))
      var payload = compressedFile
      if relative != stapledTicket and previous.size > 0 and
          previous.size <= maxDiffSize and content.len <= maxDiffSize:
        let oldBytes = toBytes(readFile(oldDir / osPath(relative)))
        let patchBytes = diff(oldBytes, toBytes(content))
        if patchBytes.len < compressedFile.len:
          entry.fromPath = relative
          payload = patchBytes
      entry.data = int64(payload.len)
      blobs.add payload
    entries.add entry
  else:
    raise newException(ValueError,
      "delta: unsupported app entry " & relative.escape())

proc writeDelta*(fromVersion, toVersion, oldDir, newDir: string;
    selectedEntries: seq[string] = @[]): seq[byte] =
  ## Writes a versioned app-tree delta. Empty selectedEntries means the full tree.
  if fromVersion.len == 0 or toVersion.len == 0:
    raise newException(ValueError, "delta: source and target versions are required")
  if not dirExists(oldDir) or not dirExists(newDir):
    raise newException(IOError, "delta: app directories must exist")
  var old = initTable[string, OldFile]()
  var byHash = initTable[string, string]()
  collectOldFiles(oldDir, "", old, byHash)
  var tops = selectedEntries
  if tops.len == 0:
    for path in childPaths(newDir):
      tops.add path.lastPathPart()
  tops.sort()
  var entries: seq[DeltaEntry]
  var blobs: seq[seq[byte]]
  for top in tops:
    if not safeDeltaPath(top):
      raise newException(ValueError, "delta: unsafe selected path " & top.escape())
    collectNewEntry(newDir, newDir / osPath(top), top, oldDir, old, byHash,
      entries, blobs)

  var index = newJObject()
  index["from"] = %fromVersion
  index["version"] = %toVersion
  var entryNodes = newJArray()
  for entry in entries:
    entryNodes.add jsonEntry(entry)
  index["entries"] = entryNodes
  let compressedIndex = deflateRaw(toBytes($index))
  if int64(compressedIndex.len) > maxDeltaIndex:
    raise newException(ValueError, "delta: index is too large")
  result = toBytes(deltaMagic)
  result.appendUvarint(uint64(compressedIndex.len))
  result.add compressedIndex
  for blob in blobs:
    result.add blob
  if int64(result.len) > maxDeltaSize:
    raise newException(ValueError, "delta: output is too large")

proc jsonString(node: JsonNode; key: string; required = false): string =
  if not node.hasKey(key):
    if required:
      raise newException(ValueError, "delta: missing " & key)
    return ""
  if node[key].kind != JString:
    raise newException(ValueError, "delta: invalid " & key)
  node[key].getStr()

proc jsonInt(node: JsonNode; key: string; default = 0'i64): int64 =
  if not node.hasKey(key): return default
  if node[key].kind != JInt:
    raise newException(ValueError, "delta: invalid " & key)
  node[key].getInt()

proc jsonBool(node: JsonNode; key: string): bool =
  if not node.hasKey(key): return false
  if node[key].kind != JBool:
    raise newException(ValueError, "delta: invalid " & key)
  node[key].getBool()

proc parseEntry(node: JsonNode): DeltaEntry =
  if node.kind != JObject:
    raise newException(ValueError, "delta: invalid entry")
  result.path = jsonString(node, "path", required = true)
  result.directory = jsonBool(node, "dir")
  result.link = jsonString(node, "link")
  let rawMode = jsonInt(node, "mode")
  if rawMode < 0 or rawMode > 0o777:
    raise newException(ValueError, "delta: invalid mode")
  result.mode = uint32(rawMode)
  result.size = jsonInt(node, "size")
  result.sha256 = jsonString(node, "sha256")
  result.fromPath = jsonString(node, "from")
  result.data = jsonInt(node, "data")

proc safeOldFile(root, relative: string): string =
  if not safeDeltaPath(relative):
    raise newException(ValueError, "delta: unsafe source path " & relative.escape())
  var current = root
  let parts = relative.split('/')
  for i, part in parts:
    current = current / part
    let info = getFileInfo(current, followSymlink = false)
    if info.kind in {pcLinkToDir, pcLinkToFile}:
      raise newException(ValueError,
        "delta: source path passes through a link: " & relative.escape())
    if i < parts.high and info.kind != pcDir:
      raise newException(ValueError,
        "delta: source parent is not a directory: " & relative.escape())
    if i == parts.high and info.kind != pcFile:
      raise newException(ValueError,
        "delta: source is not a regular file: " & relative.escape())
  current

proc pathExists(path: string): bool =
  fileExists(path) or dirExists(path) or symlinkExists(path)

proc removeTree(path: string) =
  if not dirExists(path):
    if pathExists(path): removeFile(path)
    return
  for kind, child in walkDir(path):
    if kind == pcDir:
      removeTree(child)
    else:
      removeFile(child)
  removeDir(path)

proc removeNewTreeOnFailure(path: string; success: var bool) =
  if not success and pathExists(path):
    try:
      removeTree(path)
    except CatchableError:
      discard

proc applyFile(entry: DeltaEntry; payload: openArray[byte]; oldDir,
    newRoot: string) =
  if entry.size < 0 or entry.size > maxDeltaSize or
      entry.size > int64(high(int)):
    raise newException(ValueError, "delta: invalid file size")
  let expected = int(entry.size)
  var content: seq[byte]
  if entry.fromPath.len == 0:
    content = inflateRaw(payload, expected)
  else:
    let oldPath = safeOldFile(oldDir, entry.fromPath)
    let oldContent = toBytes(readFile(oldPath))
    if payload.len == 0:
      content = oldContent
    else:
      content = patch(oldContent, payload, expected)
  if content.len != expected or sha256Hex(content) != entry.sha256:
    raise newException(IOError, "delta: the output file did not match its digest")
  let outputPath = newRoot / osPath(entry.path)
  createDir(outputPath.parentDir())
  writeFile(outputPath, toString(content))
  var permissions = toPermissions(entry.mode)
  permissions.incl fpUserWrite
  setFilePermissions(outputPath, permissions)

proc applyDelta*(data: openArray[byte]; fromVersion, toVersion,
    oldDir, newDir: string) =
  ## Applies a delta only after validating its index and all output digests.
  if data.len < deltaMagic.len + 1 or int64(data.len) > maxDeltaSize:
    raise newException(ValueError, "delta: damaged update")
  for i, ch in deltaMagic:
    if data[i] != byte(ord(ch)):
      raise newException(ValueError, "delta: not a delta update")
  var pos = deltaMagic.len
  var indexSize: uint64
  if not readUvarint(data, pos, indexSize) or indexSize == 0 or
      indexSize > maxDeltaIndex or indexSize > uint64(data.len - pos):
    raise newException(ValueError, "delta: damaged update index")
  let indexStart = pos
  let indexPast = pos + int(indexSize)
  var compressedIndex = newSeq[byte](int(indexSize))
  for i in 0 ..< compressedIndex.len:
    compressedIndex[i] = data[indexStart + i]
  let indexBytes = inflateRaw(compressedIndex, maxDeltaIndex)
  let index = parseJson(toString(indexBytes))
  if index.kind != JObject or jsonString(index, "from", required = true) !=
      fromVersion or jsonString(index, "version", required = true) != toVersion:
    raise newException(ValueError,
      "delta: version mismatch (expected " & fromVersion & " to " & toVersion & ")")
  if not index.hasKey("entries") or index["entries"].kind != JArray:
    raise newException(ValueError, "delta: invalid entry list")

  var entries: seq[DeltaEntry]
  var paths = initHashSet[string]()
  var links = initHashSet[string]()
  var offset = indexPast
  for node in index["entries"]:
    let entry = parseEntry(node)
    if not safeDeltaPath(entry.path) or entry.path in paths or
        entry.size < 0 or entry.data < 0 or
        entry.mode > 0o777'u32 or
        (entry.directory and entry.link.len > 0) or
        (not entry.directory and entry.link.len > 0 and
          (entry.size != 0 or entry.data != 0 or entry.fromPath.len > 0)) or
        (not entry.directory and entry.link.len == 0 and
          (entry.sha256.len != 64 or entry.size > maxDeltaSize)) or
        (entry.fromPath.len > 0 and not safeDeltaPath(entry.fromPath)):
      raise newException(ValueError, "delta: damaged entry " & entry.path.escape())
    if entry.link.len > 0:
      if not linkStaysInside(entry.path, entry.link):
        raise newException(ValueError,
          "delta: link points outside the app: " & entry.path.escape())
      links.incl entry.path
    elif entry.directory:
      if entry.size != 0 or entry.data != 0 or entry.fromPath.len > 0:
        raise newException(ValueError, "delta: damaged directory entry")
    elif entry.fromPath.len == 0 and entry.data == 0:
      raise newException(ValueError, "delta: file has no data")
    if entry.data > int64(data.len - offset):
      raise newException(ValueError, "delta: damaged data length")
    offset += int(entry.data)
    paths.incl entry.path
    entries.add entry
  if offset != data.len:
    raise newException(ValueError, "delta: trailing or missing file data")
  for entry in entries:
    var parent = parentDir(entry.path)
    while parent.len > 0 and parent != ".":
      if parent in links:
        raise newException(ValueError,
          "delta: path passes through a symbolic link: " & entry.path.escape())
      parent = parentDir(parent)

  if not dirExists(oldDir):
    raise newException(IOError, "delta: installed app directory is missing")
  if pathExists(newDir):
    raise newException(IOError, "delta: output directory already exists")
  let outputParent = newDir.parentDir()
  if outputParent.len > 0: createDir(outputParent)
  createDir(newDir)
  var success = false
  defer: removeNewTreeOnFailure(newDir, success)
  var dataOffset = indexPast
  for entry in entries:
    let entryPath = newDir / osPath(entry.path)
    if entry.directory:
      createDir(entryPath.parentDir())
      createDir(entryPath)
    elif entry.link.len > 0:
      createDir(entryPath.parentDir())
      createSymlink(osPath(entry.link), entryPath)
    else:
      let payloadSize = int(entry.data)
      var payload = newSeq[byte](payloadSize)
      for i in 0 ..< payloadSize:
        payload[i] = data[dataOffset + i]
      applyFile(entry, payload, oldDir, newDir)
      dataOffset += payloadSize
  success = true
