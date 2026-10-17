## Builds release-note blocks for the native updater window.

import std/unicode

import mynim/plugins/updater/markdown as markdown
import mynim/ui as ui

type
  NotesState* = ref object
    codeScrolls: seq[ui.ScrollState]

  NotesBuilder = ref object
    state: NotesState
    theme: ui.Theme
    rtl: bool
    nextCodeScroll: int

proc newNotesState*(): NotesState =
  ## Creates persistent horizontal-scroll state for rendered code blocks.
  NotesState()

proc rtlRune(rune: Rune): bool =
  let c = int32(rune)
  (c >= 0x0590 and c <= 0x05FF) or (c >= 0xFB1D and c <= 0xFB4F) or
    (c >= 0x0600 and c <= 0x06FF) or (c >= 0x0750 and c <= 0x077F) or
    (c >= 0x0870 and c <= 0x089F) or (c >= 0x08A0 and c <= 0x08FF) or
    (c >= 0xFB50 and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF) or
    (c >= 0x10EC0 and c <= 0x10EFF) or (c >= 0x1EE00 and c <= 0x1EEFF) or
    (c >= 0x0700 and c <= 0x074F) or (c >= 0x0860 and c <= 0x086F) or
    (c >= 0x0780 and c <= 0x07BF) or (c >= 0x07C0 and c <= 0x07FF) or
    (c >= 0x0800 and c <= 0x083F) or (c >= 0x0840 and c <= 0x085F) or
    (c >= 0x1E900 and c <= 0x1E95F)

proc scanDirection(text: string; rtl, found: var bool) =
  var i = 0
  while i < text.len and not found:
    let rune = text.runeAt(i)
    if rune.rtlRune:
      rtl = true
      found = true
    elif rune.isAlpha:
      rtl = false
      found = true
    i += max(text.runeLenAt(i), 1)

proc scanInlines(values: openArray[markdown.Inline]; rtl, found: var bool) =
  for value in values:
    if found:
      return
    scanDirection(value.text, rtl, found)
    scanInlines(value.children, rtl, found)

proc scanBlocks(values: openArray[markdown.Block]; rtl, found: var bool) =
  for value in values:
    if found:
      return
    scanInlines(value.inlines, rtl, found)
    scanDirection(value.text, rtl, found)
    for item in value.items:
      scanBlocks(item, rtl, found)
    scanBlocks(value.blocks, rtl, found)

proc rightToLeft(values: openArray[markdown.Block]): bool =
  var found = false
  scanBlocks(values, result, found)

proc track(theme: ui.Theme): ui.Color

proc paragraph(builder: NotesBuilder; context: ui.Context;
                values: openArray[markdown.Inline]): ui.Element

proc inlines(builder: NotesBuilder; context: ui.Context;
             values: openArray[markdown.Inline]) =
  for value in values:
    case value.kind
    of markdown.Text:
      discard ui.text(context, value.text)
    of markdown.CodeSpan:
      discard ui.text(context, value.text)
        .textFamily("monospace")
        .textSize(builder.theme.fontSize * (12'f32 / 13))
        .background(track(builder.theme))
        .radius(3)
    of markdown.Emphasis, markdown.Strong:
      let styled = ui.richText(context)
      let children = value.children
      if value.kind == markdown.Emphasis:
        discard styled.textItalic()
      else:
        discard styled.textWeight(700)
      discard styled.children(proc() = builder.inlines(context, children))
    of markdown.Link:
      let link = ui.link(context, "", value.url)
      let children = value.children
      discard link.children(proc() = builder.inlines(context, children))

proc paragraph(builder: NotesBuilder; context: ui.Context;
               values: openArray[markdown.Inline]): ui.Element =
  result = ui.richText(context)
  let current = result
  let content = @values
  discard current.children(proc() = builder.inlines(context, content))

proc codeScroll(builder: NotesBuilder): ui.ScrollState =
  if builder.nextCodeScroll == builder.state.codeScrolls.len:
    builder.state.codeScrolls.add(ui.newScrollState())
  result = builder.state.codeScrolls[builder.nextCodeScroll]
  inc builder.nextCodeScroll

proc blocks(builder: NotesBuilder; context: ui.Context;
            values: openArray[markdown.Block]; tight: bool; depth: int)
proc bullet(depth: int): string

proc blockView(builder: NotesBuilder; context: ui.Context;
              value: markdown.Block; depth: int): ui.Element =
  case value.kind
  of markdown.Heading:
    const headingSizes = [16'f32 / 13, 14'f32 / 13, 1'f32]
    let size = headingSizes[min(value.level, headingSizes.len) - 1]
    result = builder.paragraph(context, value.inlines)
      .textSize(builder.theme.fontSize * size)
      .textWeight(700)
  of markdown.List:
    result = ui.column(context)
    let current = result
    discard current.children(proc() =
      for index, item in value.items:
        var row = ui.row(context).alignItems(ui.Align.Start)
        if builder.rtl:
          row = row.reverse()
        let itemBlocks = item
        discard row.children(proc() =
          var marker = ui.text(context,
            if value.ordered: $(index + 1) & "." else: bullet(depth))
          marker = marker.width(20).shrink(0)
          if builder.rtl:
            marker = marker.padding(0, 0, 0, 6)
          else:
            marker = marker.textAlign(ui.Align.End).padding(0, 6, 0, 0)
          discard marker
          let body = ui.column(context).grow()
          discard body.children(proc() = builder.blocks(context, itemBlocks,
            tight = true, depth = depth + 1))
        )
    )
  of markdown.Quote:
    var quote = ui.column(context)
      .borderColor(builder.theme.border)
      .textColor(builder.theme.textMuted)
    if builder.rtl:
      quote = quote.borderWidth(0, 3, 0, 0).padding(0, 10, 0, 0)
    else:
      quote = quote.borderWidth(0, 0, 0, 3).padding(0, 0, 0, 10)
    let nested = value.blocks
    discard quote.children(proc() = builder.blocks(context, nested,
      tight = false, depth = depth))
    result = quote
  of markdown.Code:
    let scroll = ui.scrollHorizontal(context, builder.codeScroll())
      .background(track(builder.theme))
      .radius(3)
    let code = value.text
    discard scroll.children(proc() =
      discard ui.text(context, code).textFamily("monospace")
        .textSize(builder.theme.fontSize * (12'f32 / 13))
        .noWrap().padding(6, 8)
    )
    result = scroll
  of markdown.Rule:
    result = ui.divider(context)
  of markdown.Paragraph:
    result = builder.paragraph(context, value.inlines)

proc bullet(depth: int): string =
  case depth
  of 0: "•"
  of 1: "◦"
  else: "▪"

proc track(theme: ui.Theme): ui.Color =
  if theme.dark: ui.rgba(255, 255, 255, 0.12'f32)
  else: ui.rgba(0, 0, 0, 0.1'f32)

proc blocks(builder: NotesBuilder; context: ui.Context;
            values: openArray[markdown.Block]; tight: bool; depth: int) =
  for index, value in values:
    var gap: float32
    if index == 0 or tight:
      gap = 0
    elif value.kind == markdown.Heading:
      gap = 12
    elif values[index - 1].kind == markdown.Heading:
      gap = 4
    else:
      gap = 8
    discard builder.blockView(context, value, depth).margin(gap, 0, 0, 0)

proc render*(state: NotesState; context: ui.Context; theme: ui.Theme;
             values: openArray[markdown.Block]): ui.Element =
  ## Adds parsed release notes to the native UI and retains code-block scroll.
  let persistent = if state == nil: newNotesState() else: state
  let builder = NotesBuilder(state: persistent, theme: theme,
    rtl: rightToLeft(values))
  result = ui.column(context)
  let root = result
  let content = @values
  discard root.children(proc() = builder.blocks(context, content,
    tight = false, depth = 0))
