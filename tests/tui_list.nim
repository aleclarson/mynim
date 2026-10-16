import std/assertions
import mynim/ui

proc keyedAnchorAfterPrepend(keepOffset: bool):
    tuple[offset: float32, firstVisible: int] =
  let context = newContext()
  var firstKey = 0
  let rowKey: ListRowKey = proc(row: int): string = $(firstKey + row)
  let state = newListState(20, 2, rowKey, keepOffset)
  var count = 100

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  state.scrollTo(50)
  buildList()
  discard context.layout(120, 40)

  firstKey = -5
  count = 105
  buildList()
  discard context.layout(120, 40)
  result.offset = state.offset().y
  result.firstVisible = state.visible().first

block list_virtualizes_and_tracks_scroll_requests:
  let context = newContext()
  let state = newListState(20, 2)
  var built: seq[int]

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, 100, proc(row: int) =
        built.add(row)
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  var layout = context.layout(120, 40)
  doAssert built.len < 100
  doAssert state.maxOffset().y == 2158

  built.setLen(0)
  buildList()
  layout = context.layout(120, 40)
  doAssert built.len == 4
  doAssert state.visible() == (first: 0, last: 1)

  state.scrollTo(50)
  built.setLen(0)
  buildList()
  layout = context.layout(120, 40)
  doAssert state.offset().y == 1100
  doAssert 50 in built
  doAssert state.visible() == (first: 50, last: 51)

  state.scrollTo(50, Align.Center)
  buildList()
  layout = context.layout(120, 40)
  doAssert state.offset().y == 1090

  state.scrollTo(50, Align.End)
  buildList()
  layout = context.layout(120, 40)
  doAssert state.offset().y == 1080

  state.scrollIntoView(99)
  buildList()
  layout = context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y
  doAssert state.visible().last == 99
  doAssert state.atEnd()

  state.scrollToEnd()
  buildList()
  layout = context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y

block measured_variable_rows_refine_estimates:
  let context = newContext()
  let state = newListState(20)
  var built: seq[int]
  context.build(proc(ctx: Context) =
    discard ctx.list(state, 1000, proc(row: int) =
      built.add(row)
      discard ctx.box().height(if row mod 2 == 0: 20 else: 40).shrink(0)
    ).size(100, 60)
  )
  discard context.layout(100, 60)
  doAssert built.len < 100
  doAssert state.maxOffset().y > 0
  let firstBuildCount = built.len
  built.setLen(0)
  context.build(proc(ctx: Context) =
    discard ctx.list(state, 1000, proc(row: int) =
      built.add(row)
      discard ctx.box().height(if row mod 2 == 0: 20 else: 40).shrink(0)
    ).size(100, 60)
  )
  discard context.layout(100, 60)
  doAssert built.len < firstBuildCount

block shrinking_list_clamps_scroll_before_selecting_rows:
  let context = newContext()
  let state = newListState(20, 2)
  var count = 100
  var built: seq[int]

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        built.add(row)
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  state.scrollTo(80)
  count = 10
  built.setLen(0)
  buildList()
  doAssert state.offset().y == state.maxOffset().y
  doAssert state.maxOffset().y == 178
  doAssert built.len > 0 and built[^1] == 9
  discard context.layout(120, 40)

block keyed_anchor_follows_prepend_or_keeps_numeric_offset:
  let following = keyedAnchorAfterPrepend(false)
  doAssert following.offset == 1210
  doAssert following.firstVisible == 55

  let fixedOffset = keyedAnchorAfterPrepend(true)
  doAssert fixedOffset.offset == 1100
  doAssert fixedOffset.firstVisible == 50

block selection_follows_keyed_rows_and_can_be_cleared:
  let context = newContext()
  var prepended = false
  let rowKey: ListRowKey = proc(row: int): string =
    if prepended:
      if row == 0: "new" else: $(row - 1)
    else:
      $row
  let state = newListState(20, rowKey = rowKey, selectable = true)
  var count = 10

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  state.select(5)
  doAssert state.selected() == 5

  prepended = true
  inc count
  buildList()
  discard context.layout(120, 40)
  doAssert state.selected() == 6

  count = 5
  buildList()
  discard context.layout(120, 40)
  doAssert state.selected() == -1

  state.select(-1)
  doAssert state.selected() == -1

block multi_selection_follows_keyed_rows:
  let context = newContext()
  var prepended = false
  let rowKey: ListRowKey = proc(row: int): string =
    if prepended:
      if row == 0: "new" else: $(row - 1)
    else:
      $row
  let state = newListState(20, rowKey = rowKey, multiSelectable = true)
  var count = 10

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  state.select(2)
  state.toggleSelection(5)
  doAssert state.selectedRows() == @[2, 5]

  prepended = true
  inc count
  buildList()
  discard context.layout(120, 40)
  doAssert state.selected() == 6
  doAssert state.isSelected(3)
  doAssert state.isSelected(6)
  doAssert state.selectedRows() == @[3, 6]

  state.clearSelection()
  doAssert state.selected() == -1
  doAssert state.selectedRows().len == 0

block keyed_app_selection_stays_in_sync:
  let context = newContext()
  var offset = 0
  let rowKey: ListRowKey = proc(row: int): string = $(offset + row)
  let state = newListState(20, rowKey = rowKey)
  var selected: Selection[string]
  selected.add("2")
  discard state.bindSelection(selected)
  var count = 4

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  doAssert state.isSelected(2)
  doAssert selected.has("2")

  state.toggleSelection(1)
  doAssert selected.has("1")
  selected.add("3")
  buildList()
  discard context.layout(120, 40)
  doAssert state.isSelected(1)
  doAssert state.isSelected(2)
  doAssert state.isSelected(3)

  offset = -1
  inc count
  buildList()
  discard context.layout(120, 40)
  doAssert state.isSelected(2)
  doAssert state.isSelected(3)
  doAssert state.isSelected(4)

  selected.remove("2")
  buildList()
  discard context.layout(120, 40)
  doAssert not state.isSelected(3)
  doAssert selected.len == 2

  state.clearSelection()
  doAssert selected.len == 0
  doAssert state.selectedRows().len == 0

block unkeyed_app_selection_uses_row_indices:
  let context = newContext()
  let state = newListState(20)
  var selected: Selection[int]
  selected.add(1)
  discard state.bindSelection(selected)

  context.build(proc(ctx: Context) =
    discard ctx.list(state, 4, proc(row: int) =
      discard ctx.box().height(20).shrink(0)
    ).size(120, 40)
  )
  discard context.layout(120, 40)
  doAssert state.isSelected(1)

  state.toggleSelection(3)
  doAssert selected.has(3)
  state.clearSelection()
  doAssert selected.len == 0

block app_selection_key_type_must_match_list:
  var keyed: Selection[int]
  let keyedState = newListState(20, rowKey = proc(row: int): string = $row)
  doAssertRaises ValueError:
    discard keyedState.bindSelection(keyed)

  var unkeyed: Selection[string]
  let unkeyedState = newListState(20)
  doAssertRaises ValueError:
    discard unkeyedState.bindSelection(unkeyed)

block list_click_updates_bound_selection:
  var selected: Selection[string]
  let state = newListState(20,
    rowKey = proc(row: int): string = "id-" & $row,
    rowLabel = proc(row: int): string = "Item " & $row)
  discard state.bindSelection(selected)
  let tester = newTester(proc(ctx: Context) =
    discard ctx.list(state, 3, proc(row: int) =
      discard ctx.text("Item " & $row).size(80, 20)
    ).size(120, 60)
  , 120, 60)
  defer: tester.close()

  doAssert tester.click("Item 0") == nil
  doAssert selected.len == 1
  doAssert selected.has("id-0")

  doAssert tester.click("Item 2") == nil
  doAssert selected.len == 1
  doAssert selected.has("id-2")
  doAssert not selected.has("id-0")

block follow_end_tracks_growth_until_scrolled_away:
  let context = newContext()
  let state = newListState(20, followEnd = true)
  var count = 5

  proc buildList() =
    context.build(proc(ctx: Context) =
      discard ctx.list(state, count, proc(row: int) =
        discard ctx.box().height(20).shrink(0)
      ).size(120, 40)
    )

  buildList()
  discard context.layout(120, 40)
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y

  count = 10
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y

  state.scrollTo(0)
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == 0

  count = 15
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == 0
  doAssert state.offset().y < state.maxOffset().y

  state.scrollToEnd()
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y

  count = 20
  buildList()
  discard context.layout(120, 40)
  doAssert state.offset().y == state.maxOffset().y
