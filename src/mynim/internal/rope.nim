## Port of internal/rope: text as a persistent AVL tree of UTF-8 chunks
## of up to 4 KB, nodes summing the bytes, runes, UTF-16 units and
## newlines below them. An edit copies the chunks it touches and the
## path to them; a version is a pointer.

import std/[unicode, strutils]

const ChunkBytes* = 4096

type
  Node* = ref object
    ## A leaf holding text, or a branch of two; nil is the empty text.
    left, right: Node
    text: string ## only leaves own bytes
    sum: Summary
    height: int

  Summary* = object
    ## The count of a text: bytes, runes, UTF-16 units, newlines.
    bytes*, runes*, units*, lines*: int

proc add*(a, b: Summary): Summary =
  Summary(bytes: a.bytes + b.bytes, runes: a.runes + b.runes,
    units: a.units + b.units, lines: a.lines + b.lines)

proc `==`*(a, b: Summary): bool =
  a.bytes == b.bytes and a.runes == b.runes and
    a.units == b.units and a.lines == b.lines

proc sum*(n: Node): Summary =
  ## The summary of the text of n.
  if n == nil: Summary() else: n.sum

proc height(n: Node): int =
  if n == nil: 0 else: n.height

proc countRunes*(s: string): int =
  ## The runes of s, ASCII fast.
  var multi = false
  for i in 0 ..< s.len:
    if s[i].uint8 >= 0x80:
      multi = true
      break
  if not multi: return s.len
  result = 0
  for r in s.runes: inc result

proc summarize*(s: string): Summary =
  ## The count of s.
  let n = countRunes(s)
  var units = n
  if n != s.len:
    units = 0
    for r in s.runes:
      inc units
      if r.int32 > 0xffff: inc units
  var lines = 0
  for c in s:
    if c == '\n': inc lines
  Summary(bytes: s.len, runes: n, units: units, lines: lines)

proc leaf(s: string): Node =
  if s == "": return nil
  Node(text: s, sum: summarize(s), height: 1)

proc branch(a, b: Node): Node =
  if a == nil: return b
  if b == nil: return a
  Node(left: a, right: b, sum: a.sum.add(b.sum),
    height: 1 + max(a.height, b.height))

proc balance(n: Node): Node =
  if height(n.left) - height(n.right) > 1:
    var a = n.left
    if height(a.left) < height(a.right):
      let b = a.right
      a = branch(branch(a.left, b.left), b.right)
    return branch(a.left, branch(a.right, n.right))
  if height(n.right) - height(n.left) > 1:
    var b = n.right
    if height(b.right) < height(b.left):
      let a = b.left
      b = branch(a.left, branch(a.right, b.right))
    return branch(branch(n.left, b.left), b.right)
  n

proc join*(a, b: Node): Node =
  ## The text of a followed by that of b.
  if a == nil: return b
  if b == nil: return a
  if a.left == nil and b.left == nil and a.sum.bytes + b.sum.bytes <= ChunkBytes:
    return leaf(a.text & b.text)
  if a.height > b.height + 1:
    return balance(branch(a.left, join(a.right, b)))
  if b.height > a.height + 1:
    return balance(branch(join(a, b.left), b.right))
  branch(a, b)

proc build*(s: string): Node =
  ## A tree of s, owning its bytes, so that a small surviving fragment
  ## cannot pin a large input string.
  var leaves: seq[Node]
  var start = 0
  while start < s.len:
    var stop = start
    while stop < s.len and stop - start < ChunkBytes:
      stop += s.runeLenAt(stop)
    leaves.add leaf(s[start ..< stop])
    start = stop
  proc mk(a, z: int): Node =
    if a == z: return nil
    if z - a == 1: return leaves[a]
    let m = (a + z) div 2
    branch(mk(a, m), mk(m, z))
  mk(0, leaves.len)

proc split*(n: Node; at: int): tuple[before, rest: Node] =
  ## The text before byte at and the text from it.
  if n == nil: return (nil, nil)
  if at <= 0: return (nil, n)
  if at >= n.sum.bytes: return (n, nil)
  if n.left == nil:
    return (leaf(n.text[0 ..< at]), leaf(n.text[at .. ^1]))
  if at < n.left.sum.bytes:
    let (a, b) = split(n.left, at)
    return (a, join(b, n.right))
  let (a, b) = split(n.right, at - n.left.sum.bytes)
  (join(n.left, a), b)

proc replaceBytes*(n: Node; a, b: int; s: string): Node =
  ## The text with bytes a to b replaced by s.
  let total = sum(n).bytes
  let a = max(0, min(a, total))
  let b = max(0, min(b, total))
  let (left, rest) = split(n, a)
  let (_, right) = split(rest, b - a)
  join(join(left, build(s)), right)

proc byteOfRune*(n: Node; index: int): int =
  ## The byte rune index starts at.
  var index = max(0, min(index, sum(n).runes))
  var n = n
  while n != nil and n.left != nil:
    if index < n.left.sum.runes:
      n = n.left
    else:
      index -= n.left.sum.runes
      result += n.left.sum.bytes
      n = n.right
  if n == nil: return
  if n.sum.bytes == n.sum.runes:
    return result + index
  var at = 0
  while at < n.text.len:
    if index == 0:
      return result + at
    at += n.text.runeLenAt(at)
    dec index
  result + n.text.len

proc runeOfUnit*(n: Node; index: int): int =
  ## The rune holding UTF-16 unit index, or after it.
  var index = index
  var n = n
  while n != nil and n.left != nil:
    if index < n.left.sum.units:
      n = n.left
    else:
      index -= n.left.sum.units
      result += n.left.sum.runes
      n = n.right
  if n == nil: return
  if n.sum.runes == n.sum.units:
    return result + min(index, n.sum.runes)
  for r in n.text.runes:
    let count = if r.int32 > 0xffff: 2 else: 1
    if index < count: break
    index -= count
    inc result
  result

proc byteOfUnit*(n: Node; index: int): int =
  ## The byte of UTF-16 unit index, rounded down to a rune.
  var index = index
  var n = n
  while n != nil and n.left != nil:
    if index < n.left.sum.units:
      n = n.left
    else:
      index -= n.left.sum.units
      result += n.left.sum.bytes
      n = n.right
  if n == nil: return
  var i = 0
  while i < n.text.len:
    let k = if n.text.runeAt(i).int32 > 0xffff: 2 else: 1
    if index < k:
      return result + i
    index -= k
    i += n.text.runeLenAt(i)
  result + n.text.len

proc prefix*(n: Node; at: int): Summary =
  ## The summary of the text before byte at.
  if n == nil or at <= 0: return Summary()
  if at >= n.sum.bytes: return n.sum
  if n.left == nil: return summarize(n.text[0 ..< at])
  if at <= n.left.sum.bytes: return prefix(n.left, at)
  n.left.sum.add(prefix(n.right, at - n.left.sum.bytes))

proc lineStart*(n: Node; line: int): int =
  ## The byte line starts at, the end of the text past the last line.
  if line <= 0: return 0
  if line > sum(n).lines: return sum(n).bytes
  var line = line
  var n = n
  while n.left != nil:
    if line <= n.left.sum.lines:
      n = n.left
    else:
      line -= n.left.sum.lines
      result += n.left.sum.bytes
      n = n.right
  var from0 = 0
  for i in 0 ..< line:
    from0 += n.text.find('\n', from0) + 1
  result + from0

proc read*(n: Node; start, stop: int; o: var string) =
  ## Appends the bytes start to stop to o.
  if n == nil or start >= stop: return
  if n.left == nil:
    o.add n.text[start ..< stop]
    return
  let split = n.left.sum.bytes
  if start < split:
    read(n.left, start, min(stop, split), o)
  if stop > split:
    read(n.right, max(0, start - split), stop - split, o)

proc chunks*(n: Node; a, b: int; fn: proc(s: string): bool) =
  ## Calls fn with the text from a to b, a piece at a time, until fn
  ## returns false.
  let a = max(0, a)
  let b = min(b, sum(n).bytes)
  proc walk(n: Node; off: int): bool =
    if n == nil or off >= b or off + n.sum.bytes <= a: return true
    if n.left == nil:
      let lo = max(a - off, 0)
      let hi = min(b - off, n.text.len)
      return fn(n.text[lo ..< hi])
    walk(n.left, off) and walk(n.right, off + n.left.sum.bytes)
  discard walk(n, 0)

proc check*(n: Node): ref CatchableError =
  ## What is wrong with the tree, for tests.
  proc chk(n: Node): tuple[s: Summary, err: ref CatchableError] =
    if n == nil: return (Summary(), nil)
    if n.left == nil:
      if n.text.len > ChunkBytes + 3 or n.sum != summarize(n.text) or
          n.height != 1:
        return (Summary(), newException(ValueError, "rope: invalid leaf"))
      return (n.sum, nil)
    let (a, err) = chk(n.left)
    if err != nil: return (a, err)
    let (b, err2) = chk(n.right)
    if err2 != nil: return (b, err2)
    let d = n.left.height - n.right.height
    if d < -1 or d > 1 or n.height != 1 + max(n.left.height, n.right.height) or
        n.sum != a.add(b):
      return (Summary(), newException(ValueError, "rope: invalid branch"))
    (n.sum, nil)
  let (_, err) = chk(n)
  err

## --- text.go ---

type Text* = object
  ## A version of a text, read by bytes and lines. Its zero value is
  ## the empty text.
  n: Node

proc newText*(s: string): Text = Text(n: build(s))
  ## The text s.

proc textOf*(n: Node): Text = Text(n: n)
  ## The text of a tree.

proc root*(t: Text): Node = t.n
  ## The tree of the text.

proc same*(t, u: Text): bool = t.n == u.n
  ## Whether t and u are the same version, without comparing bytes.

proc len*(t: Text): int = sum(t.n).bytes
proc lineCount*(t: Text): int = sum(t.n).lines + 1

proc lineStart*(t: Text; line: int): int =
  ## The byte line starts at, clamped.
  lineStart(t.n, line)

proc lineEnd*(t: Text; line: int): int =
  ## The byte line ends at, before its newline.
  if line + 1 < t.lineCount():
    return lineStart(t.n, line + 1) - 1
  t.len

proc lineOf*(t: Text; off: int): int =
  ## The line holding byte off.
  prefix(t.n, off).lines

proc slice*(t: Text; a, b: int): string =
  ## Bytes a to b.
  let a = max(0, min(a, t.len))
  let b = max(0, min(b, t.len))
  if a >= b: return ""
  result = newStringOfCap(b - a)
  read(t.n, a, b, result)

proc line*(t: Text; i: int): string =
  ## Line i, without its newline.
  t.slice(t.lineStart(i), t.lineEnd(i))

proc `$`*(t: Text): string = t.slice(0, t.len)

proc byteAt*(t: Text; off: int): byte =
  ## The byte at off, or 0 past the end.
  if off < 0 or off >= sum(t.n).bytes: return 0
  var n = t.n
  var off = off
  while n.left != nil:
    if off < n.left.sum.bytes:
      n = n.left
    else:
      off -= n.left.sum.bytes
      n = n.right
  n.text[off].byte

proc runeAt*(t: Text; off: int): tuple[r: Rune, size: int] =
  ## The rune starting at off and its size, 0 and 0 at the end.
  if off < 0 or off >= t.len: return (Rune(0), 0)
  if t.byteAt(off) < 0x80: return (Rune(t.byteAt(off)), 1)
  let s = t.slice(off, off + 4)
  if s.len == 0: return (Rune(0), 0)
  (s.runeAt(0), s.runeLenAt(0))

proc runeBefore*(t: Text; off: int): tuple[r: Rune, size: int] =
  ## The rune ending at off and its size.
  if off <= 0: return (Rune(0), 0)
  if t.byteAt(off - 1) < 0x80: return (Rune(t.byteAt(off - 1)), 1)
  let s = t.slice(max(0, off - 4), off)
  var i = s.len - 1
  while i > 0 and (s[i].uint8 and 0xC0) == 0x80: dec i
  (s.runeAt(i), s.runeLenAt(i))

proc utf16*(t: Text; off: int): int =
  ## How many UTF-16 units come before byte off.
  prefix(t.n, off).units

proc fromUTF16*(t: Text; u: int): int =
  ## The byte of UTF-16 unit u, rounded down to a rune.
  byteOfUnit(t.n, u)

proc chunks*(t: Text; a, b: int; fn: proc(s: string): bool) =
  chunks(t.n, a, b, fn)

proc replace*(t: Text; a, b: int; s: string): Text =
  ## The text with bytes a to b replaced by s.
  Text(n: replaceBytes(t.n, a, b, s))

proc eachLine*(t: Text; first, last: int;
    fn: proc(i, start: int; s: string): bool) =
  ## Calls fn with lines from to last, exclusive, and the byte each
  ## starts at, reading them a batch at a time, until fn returns false.
  let last = min(last, t.lineCount())
  var i = max(0, first)
  while i < last:
    let stop = min(i + 256, last)
    var a = t.lineStart(i)
    var text = t.slice(a, t.lineEnd(stop - 1))
    while i < stop:
      var n = text.find('\n')
      if n < 0: n = text.len
      if not fn(i, a, text[0 ..< n]): return
      a += n + 1
      text = if n < text.len: text[n + 1 .. ^1] else: ""
      inc i

proc eachLineBack*(t: Text; first, last: int;
    fn: proc(i, start: int; s: string): bool) =
  ## Calls fn with lines from down to last, inclusive, as eachLine
  ## does going up.
  let first = min(first, t.lineCount() - 1)
  let last = max(0, last)
  var i = first
  while i >= last:
    let lo = max(i - 255, last)
    let a = t.lineStart(lo)
    let text = t.slice(a, t.lineEnd(i))
    var starts: seq[int]
    var at = 0
    while true:
      starts.add at
      let n = text.find('\n', at)
      if n < 0: break
      at += n + 1
    var k = starts.len - 1
    while k >= 0 and i >= lo:
      var stop = text.len
      if k + 1 < starts.len: stop = starts[k + 1] - 1
      if not fn(i, a + starts[k], text[starts[k] ..< stop]): return
      dec i
      dec k
