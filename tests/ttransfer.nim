import std/[assertions, os, strutils]

import mynim/transfer as transfer

proc byteSeq(value: string): seq[byte] =
  result = newSeq[byte](value.len)
  for i, ch in value:
    result[i] = byte(ch)

type ReadWork = object
  data: ptr transfer.Data
  result: ptr int
  expectsError: bool

proc readWorker(work: ReadWork) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    for _ in 0..<64:
      let (value, err) = work.data[].read(transfer.HTML)
      if work.expectsError:
        if err == nil:
          work.result[] = 1
        elif err.msg != "encode failed":
          work.result[] = 2
      elif err != nil:
        work.result[] = 100
      elif transfer.bytesToString(value) != "<b>plain</b>":
        work.result[] = value.len * 100 +
          (if value.len > 0: int(value[0]) else: 0)

block immutable_values_and_collections:
  var input = byteSeq("plain")
  let data = transfer.newData(transfer.newItem(
    transfer.bytes(transfer.Text, input)))
  input[0] = byte('x')
  var (value, err) = data.read(transfer.Text)
  doAssert err == nil and transfer.bytesToString(value) == "plain"

  value[0] = byte('x')
  (value, err) = data.read(transfer.Text)
  doAssert err == nil and transfer.bytesToString(value) == "plain"

  var items = data.items()
  items[0] = transfer.newItem(transfer.bytes(transfer.Text, "changed"))
  doAssert transfer.bytesToString(data.read(transfer.Text).data) == "plain"

  let empty = transfer.bytes(transfer.Text, "")
  doAssert data.read(transfer.HTML).err != nil
  doAssert transfer.bytesToString(transfer.newItem(empty).read(
    transfer.Text).data) == ""

block negotiation_and_lazy_snapshot:
  var calls = 0
  let data = transfer.newData(transfer.newItem(
    transfer.lazy(transfer.HTML, proc(): tuple[data: seq[byte],
        err: ref CatchableError] =
      inc calls
      (data: byteSeq("<b>plain</b>"), err: nil)),
    transfer.bytes(transfer.Text, "plain")))
  doAssert data.formats() == @[transfer.HTML, transfer.Text]
  doAssert data.preferred(transfer.PNG, transfer.Text, transfer.HTML) ==
    (f: transfer.Text, ok: true)
  doAssert calls == 0

  let first = data.snapshot()
  let (firstBytes, firstErr) = first.read(transfer.HTML)
  doAssert firstErr == nil and transfer.bytesToString(firstBytes) ==
    "<b>plain</b>"
  doAssert calls == 1
  let second = data.snapshot()
  doAssert second.read(transfer.HTML).err == nil and calls == 2
  doAssert transfer.preferredFormat(data.formats(), transfer.PNG).ok == false

block concurrent_lazy_read:
  var calls = 0
  let data = transfer.newData(transfer.newItem(
    transfer.lazy(transfer.HTML, proc(): tuple[data: seq[byte],
        err: ref CatchableError] =
      inc calls
      (data: byteSeq("<b>plain</b>"), err: nil))))
  var results: array[8, int]
  var threads: array[8, Thread[ReadWork]]
  for i, thread in threads.mpairs:
    createThread(thread, readWorker,
      ReadWork(data: unsafeAddr data, result: addr results[i]))
  for thread in threads.mitems:
    joinThread(thread)
  doAssert calls == 1
  doAssert results == default(array[8, int]), $results

  when defined(gcAtomicArc):
    var failureCalls = 0
    let failedData = transfer.newData(transfer.newItem(
      transfer.lazy(transfer.HTML, proc(): tuple[data: seq[byte],
          err: ref CatchableError] =
        inc failureCalls
        (data: @[], err: newException(ValueError, "encode failed")))))
    results = default(array[8, int])
    for i, thread in threads.mpairs:
      createThread(thread, readWorker, ReadWork(data: unsafeAddr failedData,
        result: addr results[i], expectsError: true))
    for thread in threads.mitems:
      joinThread(thread)
    doAssert failureCalls == 1
    doAssert results == default(array[8, int]), $results

block materialize_and_cached_failures:
  var calls = 0
  let failure = newException(ValueError, "encode failed")
  let data = transfer.newData(transfer.newItem(
    transfer.bytes(transfer.Text, "ok"),
    transfer.lazy(transfer.HTML, proc(): tuple[data: seq[byte],
        err: ref CatchableError] =
      inc calls
      (data: @[], err: failure))))
  let (textOnly, textErr) = data.materialize([transfer.Text])
  doAssert textErr == nil and calls == 0
  doAssert textOnly.formats() == @[transfer.Text]
  doAssert data.materialize([transfer.HTML]).err == failure
  doAssert data.materialize([transfer.HTML]).err == failure
  doAssert calls == 1
  doAssert transfer.isErrFormat(data.materialize([transfer.PNG]).err)

  var panicCalls = 0
  let panicData = transfer.newData(transfer.newItem(
    transfer.lazy(transfer.HTML, proc(): tuple[data: seq[byte],
        err: ref CatchableError] =
      inc panicCalls
      raise newException(AssertionDefect, "codec failed")),
    transfer.bytes(transfer.Text, "fallback")))
  doAssert transfer.isErrProviderPanic(panicData.read(transfer.HTML).err)
  doAssert transfer.isErrProviderPanic(panicData.read(transfer.HTML).err)
  doAssert panicCalls == 1
  doAssert transfer.bytesToString(panicData.read(transfer.Text).data) ==
    "fallback"

block multi_item_reads_and_materialization:
  let custom = "application/vnd.mygo.test"
  let data = transfer.newData(
    transfer.newItem(transfer.bytes(transfer.Text, "a"),
                     transfer.bytes(custom, byteSeq("\x00\x01"))),
    transfer.newItem(transfer.bytes(transfer.Text, "b"),
                     transfer.bytes(custom, byteSeq("\x02\x03"))))
  doAssert transfer.bytesToString(data.read(transfer.Text).data) == "a\nb"
  doAssert data.read(custom).data == byteSeq("\x00\x01")
  let (customOnly, customErr) = data.materialize([custom])
  doAssert customErr == nil and customOnly.items().len == 2

block urls_and_files:
  let firstPath = getTempDir() / "a #%.txt"
  let secondPath = getTempDir() / "日本語.txt"
  let (files, fileErr) = transfer.fileData(firstPath, secondPath)
  doAssert fileErr == nil
  doAssert files.files().paths == @[firstPath, secondPath]
  doAssert files.items().len == 2
  doAssert "%23" in transfer.bytesToString(files.read(
    transfer.URIList).data)

  let (webUrl, urlErr) = transfer.urlData("https://example.com/a#b")
  doAssert urlErr == nil
  doAssert webUrl.read(transfer.URIList).err == nil
  doAssert webUrl.files().paths.len == 0
  doAssert transfer.fileData("relative").err != nil
  doAssert transfer.urlData("relative").err != nil
  doAssert transfer.urlData("https://example.com/a\nb").err != nil

  let remote = transfer.newData(transfer.newItem(transfer.bytes(
    transfer.URIList,
    "# comment\r\nfile://remote/tmp/a\r\nhttps://example.com\r\n")))
  doAssert remote.files().paths.len == 0
  doAssert remote.urls().urls == @["file://remote/tmp/a",
    "https://example.com"]

block operation_negotiation:
  let cases = [
    (transfer.Copy or transfer.Move, transfer.None, transfer.Move,
      transfer.Copy),
    (transfer.Copy or transfer.Move, transfer.Copy or transfer.Move,
      transfer.Move, transfer.Move),
    (transfer.Move, transfer.Copy, transfer.Move, transfer.None),
    (transfer.Copy, transfer.Move, transfer.Copy, transfer.None),
    (transfer.Copy or transfer.Move, transfer.Copy or transfer.Move,
      transfer.None, transfer.Copy),
    (transfer.Move, transfer.Move, transfer.Copy, transfer.Move),
    (transfer.None, transfer.Copy or transfer.Move, transfer.Copy,
      transfer.None)]
  for (source, destination, suggested, expected) in cases:
    doAssert transfer.negotiate(source, destination, suggested) == expected

  let offer = transfer.Offer(formats: @[transfer.HTML, transfer.Text],
    operations: transfer.Copy)
  doAssert offer.preferred(transfer.PNG, transfer.Text) ==
    (f: transfer.Text, ok: true)

block invalid_representations:
  doAssertRaises ValueError:
    discard transfer.bytes("", "data")
  doAssertRaises ValueError:
    discard transfer.bytes("bad\nformat", "data")
  doAssertRaises ValueError:
    discard transfer.lazy(transfer.Text, nil)
  doAssertRaises ValueError:
    discard transfer.newItem()
  doAssertRaises ValueError:
    discard transfer.newItem(transfer.bytes(transfer.Text, "a"),
      transfer.bytes(transfer.Text, "b"))
