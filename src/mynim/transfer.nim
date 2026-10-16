## Port of mygo's `transfer` package: data exchanged through the clipboard
## and native drag and drop. Values contain explicit representations, never
## object references. The immutable model is shared by both integrations.

import std/[locks, uri, strutils, os]
import ./image

proc cloneBytes(b: openArray[byte]): seq[byte] =
  result = newSeq[byte](b.len)
  for i, value in b:
    result[i] = value

proc bytesToString*(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc encodePath*(p: string): string =
  ## Percent-encodes a URL path like Go's (&url.URL{Path: p}).String():
  ## unreserved bytes, sub-delims and : @ / = stay; everything else is
  ## %XX-escaped.
  const unreserved = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~',
                      '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
                      ':', '@', '/'}
  result = newStringOfCap(p.len)
  for c in p:
    if c in unreserved: result.add(c)
    else:
      result.add('%')
      result.add(toHex(int(c), 2))

type
  Format* = string
    ## Names a representation. Use a MIME type for custom serialized data.
    ## (Go: `type Format string`.)

const
  Text*: Format = "text/plain"
  HTML*: Format = "text/html"
  URIList*: Format = "text/uri-list"
  ## FileList is a URI list known to contain local files. Backends expose
  ## it as the system's file-list format as well as text/uri-list.
  FileList*: Format = "application/x-mygo-file-list"
  PNG*: Format = "image/png"
  ## Markdown is Markdown's text (RFC 7763), net.daringfireball.markdown
  ## on macOS.
  Markdown*: Format = "text/markdown"

const
  errFormatMsg = "transfer: representation unavailable"

type
  TransferError* = object of CatchableError

proc errFormat*(): ref TransferError =
  ## The requested item or representation is not available
  ## (transfer.ErrFormat).
  newException(TransferError, errFormatMsg)

proc errProviderPanic*(msg: string): ref TransferError =
  ## A lazy provider panicked (transfer.ErrProviderPanic).
  newException(TransferError, "transfer: provider panicked: " & msg)

proc isErrFormat*(e: ref CatchableError): bool =
  e != nil and e.msg == errFormatMsg

proc isErrProviderPanic*(e: ref CatchableError): bool =
  e != nil and e.msg.startsWith("transfer: provider panicked")

type
  Value = ref object
    lock: Lock
    done: bool
    provider: proc(): tuple[data: seq[byte], err: ref CatchableError] {.closure.}
    bytes: seq[byte]
    err: ref CatchableError

  Representation* = object
    ## One format of an item, made with bytes/lazy.
    format: Format
    value: Value

proc validateFormat(f: Format) =
  if f == "" or find(f, {'\x00', '\r', '\n'}) >= 0:
    raise newException(ValueError, "transfer: invalid format")

proc bytes*(format: Format, b: seq[byte] | string): Representation =
  ## Makes a representation, copying b. Empty data is valid.
  validateFormat(format)
  let v = Value()
  initLock(v.lock)
  v.done = true
  when b is string:
    v.bytes = newSeq[byte](b.len)
    for i, value in b:
      v.bytes[i] = byte(value)
  else:
    v.bytes = cloneBytes(b)
  Representation(format: format, value: v)

proc lazy*(format: Format,
           provider: proc(): tuple[data: seq[byte], err: ref CatchableError]): Representation =
  ## Advertises a format without producing its bytes. The provider runs at
  ## most once per snapshot, when a destination requests this format;
  ## failures are cached too. Native integrations call it on the main
  ## thread. It must return promptly and must not wait for another
  ## main-thread action.
  validateFormat(format)
  if provider == nil:
    raise newException(ValueError, "transfer: nil provider")
  let v = Value(provider: provider)
  initLock(v.lock)
  Representation(format: format, value: v)

type
  Item* = object
    ## A value with alternative representations, in preference order.
    reps: seq[Representation]

proc newItem*(reps: varargs[Representation]): Item =
  ## Makes an item. Duplicate formats and zero representations are a
  ## programming error (Go panics).
  if reps.len == 0:
    raise newException(ValueError,
      "transfer: invalid or duplicate representation")
  var seen: seq[Format]
  for r in reps:
    if r.value == nil or r.format in seen:
      raise newException(ValueError, "transfer: invalid or duplicate representation")
    seen.add(r.format)
  Item(reps: @reps)

proc formats*(i: Item): seq[Format] =
  result = newSeq[Format](i.reps.len)
  for n, r in i.reps: result[n] = r.format

proc readItem(i: ptr Item; format: Format):
    tuple[data: seq[byte], err: ref CatchableError] =
  ## Returns a copy of the requested bytes. Provider evaluation and caching
  ## are serialized across callers. When sharing these values across OS
  ## threads, follow Nim's memory-manager rules: under ORC use a thread-safe
  ## transfer such as a Channel, or compile with atomic reference counting.
  for repIndex in 0..<i[].reps.len:
    if i[].reps[repIndex].format != format: continue
    let value = addr i[].reps[repIndex].value[]
    acquire(value.lock)
    try:
      if not value.done:
        try:
          if value.provider != nil:
            let res = value.provider()
            value.err = res.err
            value.bytes = if res.err != nil: @[] else:
              cloneBytes(res.data)
        except CatchableError as e:
          value.bytes = @[]
          value.err = errProviderPanic(e.msg)
        except Defect as e:
          # Go's recover contains every provider panic at this boundary.
          # Nim separates programmer defects from catchable errors, so
          # translate both here to preserve that public contract.
          value.bytes = @[]
          value.err = errProviderPanic(e.msg)
        value.done = true
      return (cloneBytes(value.bytes), value.err)
    finally:
      release(value.lock)
  (@[], errFormat())

proc read*(i: Item, format: Format):
    tuple[data: seq[byte], err: ref CatchableError] =
  readItem(unsafeAddr i, format)

type
  Data* = object
    ## An immutable collection of items. Its default value is empty.
    items: seq[Item]

proc newData*(items: varargs[Item]): Data = Data(items: @items)

proc items*(d: Data): seq[Item] =
  ## Returns a copy of the collection; editing it does not change the data.
  result = newSeq[Item](d.items.len)
  for i, item in d.items:
    result[i] = Item(reps: item.reps)

proc formats*(d: Data): seq[Format] =
  ## Lists all formats, in item order, without invoking providers.
  for i in d.items:
    for f in i.formats:
      if f notin result: result.add(f)

proc preferredFormat*(offered: openArray[Format],
                      preferred: varargs[Format]): tuple[f: Format, ok: bool] =
  ## Negotiates formats from a clipboard or drag offer without requesting
  ## data. Receiver preference order wins over source item order.
  for f in preferred:
    if f in offered: return (f, true)
  ("", false)

proc preferred*(d: Data, formats: varargs[Format]): tuple[f: Format, ok: bool] =
  ## Chooses the first preferred format advertised by the data, without
  ## invoking any provider.
  preferredFormat(d.formats, formats)

proc snapshot*(d: Data): Data =
  ## Starts a new provider cache, as each clipboard write or drag does.
  var items = newSeq[Item](d.items.len)
  for n, i in d.items:
    var reps: seq[Representation]
    for r in i.reps:
      let v = Value(provider: r.value.provider)
      initLock(v.lock)
      if v.provider == nil:
        v.bytes = cloneBytes(r.value.bytes)
        v.done = true
      reps.add(Representation(format: r.format, value: v))
    items[n] = Item(reps: reps)
  Data(items: items)

proc read*(d: Data, format: Format): tuple[data: seq[byte], err: ref CatchableError] =
  ## Reads a format for platforms with a single selection/data object.
  ## Text items are joined with newlines and URI lists with CRLF. Other
  ## formats use the first item offering them; macOS preserves separate
  ## items.
  var parts: seq[seq[byte]]
  for itemIndex in 0..<d.items.len:
    var offered = false
    for repIndex in 0..<d.items[itemIndex].reps.len:
      if d.items[itemIndex].reps[repIndex].format == format:
        offered = true
        break
    if not offered: continue
    let (b, err) = readItem(addr d.items[itemIndex], format)
    if err != nil: return (@[], err)
    parts.add(b)
    if format != Text and format != URIList and format != FileList:
      break
  if parts.len == 0: return (@[], errFormat())
  if format == URIList or format == FileList:
    var res: seq[byte]
    for i, p in parts:
      if i > 0: res.add([byte('\r'), byte('\n')])
      res.add(p)
    return (res, nil)
  var res: seq[byte]
  for i, p in parts:
    if i > 0: res.add(byte('\n'))
    res.add(p)
  (res, nil)

proc materialize*(d: Data, formats: openArray[Format]): tuple[data: Data, err: ref CatchableError] =
  ## Copies matching representations into data with no providers. A failed
  ## representation rejects the transfer; an empty match is errFormat.
  var items: seq[Item]
  for i in d.items:
    var reps: seq[Representation]
    for f in i.formats:
      if f notin formats: continue
      let (b, err) = i.read(f)
      if err != nil: return (Data(), err)
      reps.add(bytes(f, b))
    if reps.len > 0: items.add(newItem(reps))
  if items.len == 0: return (Data(), errFormat())
  (Data(items: items), nil)

proc textData*(text: string): Data =
  ## Offers a plain text item.
  newData(newItem(bytes(Text, text)))

proc urlData*(raw: string): tuple[data: Data, err: ref CatchableError] =
  ## Offers a URL as a URI list and as plain text.
  let u = parseUri(raw)
  if u.scheme == "" or find(raw, {'\r', '\n', '\x00'}) >= 0:
    return (Data(), newException(TransferError, "transfer: invalid URL " & raw))
  (newData(newItem(bytes(URIList, raw), bytes(Text, raw))), nil)

proc fileData*(paths: varargs[string]): tuple[data: Data, err: ref CatchableError] =
  ## Offers existing file paths as file URLs, one item per path. Paths
  ## must be absolute. It neither reads nor deletes the files.
  var items = newSeqOfCap[Item](paths.len)
  for path in paths:
    if not isAbsolute(path) or contains(path, '\x00'):
      return (Data(), newException(TransferError,
        "transfer: file path must be absolute: " & path))
    var p = path.replace('\\', '/')
    if not p.startsWith("/"): p = "/" & p
    let u = "file://" & encodePath(p)
    items.add(newItem(bytes(FileList, u), bytes(URIList, u)))
  (newData(items), nil)

proc urls*(d: Data): tuple[urls: seq[string], err: ref CatchableError] =
  ## The URLs of all URI-list items, ignoring comments and blanks.
  let (b, err) = d.read(URIList)
  if err != nil: return (@[], err)
  var res: seq[string]
  for line in split(bytesToString(b).replace("\r\n", "\n"), '\n'):
    let line = line.strip()
    if line != "" and not line.startsWith("#"):
      res.add(line)
  (res, nil)

proc files*(d: Data): tuple[paths: seq[string], err: ref CatchableError] =
  ## Local file paths only. Remote file authorities and other URL schemes
  ## are ignored, so a network URL never becomes a filesystem path.
  var urls: seq[string]
  var err: ref CatchableError
  let (b, e) = d.read(FileList)
  if e == nil:
    urls = split(bytesToString(b).replace("\r\n", "\n"), '\n')
  elif isErrFormat(e):
    (urls, err) = d.urls()
  else:
    err = e
  if err != nil: return (@[], err)
  var paths: seq[string]
  for raw in urls:
    let u = parseUri(raw.strip())
    let decPath = decodeUrl(u.path, decodePlus = false)
    if u.scheme != "file" or (u.hostname != "" and u.hostname != "localhost") or
        contains(decPath, '\x00'):
      continue
    var p = decPath
    if p.len > 3 and p[0] == '/' and p[2] == ':':
      p = p[1..^1]
    when defined(windows):
      p = p.replace('/', '\\')
    if isAbsolute(p):
      paths.add(p)
  (paths, nil)

## --- drag.go ---

type
  Operation* = uint8
    ## A native drag effect, or a bitmask of allowed effects.

const
  None*: Operation = 0
  Copy*: Operation = 1
  Move*: Operation = 2

proc allowed*(o: Operation): Operation =
  ## The safe default (copy) and removes unsupported effects.
  if o == None: Copy else: o and (Copy or Move)

proc negotiate*(source, destination, suggested: Operation): Operation =
  ## Chooses one effect shared by source and destination. A source's
  ## modifier-key suggestion wins when allowed; otherwise copy precedes move.
  let allowed = source and destination.allowed
  if suggested == Copy or suggested == Move:
    if (allowed and suggested) != 0: return suggested
  if (allowed and Copy) != 0: return Copy
  if (allowed and Move) != 0: return Move
  None

type
  DragOptions* = object
    ## Configures a native source. The default operation is copy.
    operations*: Operation
    ## Preview is copied at drag start. Hotspot is in image pixels; the
    ## preview is displayed in DIPs (one pixel per DIP).
    preview*: Image
    hotspot*: Point
    ## done runs on the main thread exactly once, including cancellation,
    ## startup failure and source-window destruction. Delete or remove the
    ## original only after a successful Move; MyGo never deletes files.
    done*: proc(r: Result)

  Result* = object
    ## The destination's final effect. `opNone` means no drop.
    operation*: Operation
    canceled*: bool
    err*: ref CatchableError

  Offer* = object
    ## A drag during hover, without reading its bytes.
    formats*: seq[Format]
    operations*: Operation
    suggested*: Operation

  DropOptions* = object
    ## A destination. At least one offered format must match `formats`.
    ## Empty `formats` accepts none; zero `operations` permits copy.
    formats*: seq[Format]
    operations*: Operation

  Drop* = object
    ## A completed transfer. Its data is independent of the native
    ## session and can be read later, from any thread.
    data*: Data
    operation*: Operation

proc preferred*(o: Offer, formats: varargs[Format]): tuple[f: Format, ok: bool] =
  preferredFormat(o.formats, formats)
