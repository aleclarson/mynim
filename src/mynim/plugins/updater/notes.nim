## Builds selectable release notes for the native updater window.

import std/[strutils, unicode]

import mynim/plugins/updater/markdown as markdown
import mynim/ui as ui

type
  NotesState* = ref object
    buffer: ui.TextBuffer
    body: string
    lineStyles: seq[seq[ui.Span]]
    links: seq[LinkRange]

  LinkRange = object
    start, pastLast: int
    url: string

  RunStyle = object
    font: string
    size: float32
    weight: int
    italic, underline: bool
    color, background: ui.Color

  NotesBuilder = object
    theme: ui.Theme
    body: string
    lines: seq[seq[ui.Span]]
    currentLine: seq[ui.Span]
    links: seq[LinkRange]
    runeOffset: int
    lineStarted: bool

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

proc scanDirection(text: string; direction: var ui.Direction; found: var bool) =
  var i = 0
  while i < text.len and not found:
    let rune = text.runeAt(i)
    if rune.rtlRune:
      direction = ui.Direction.RightToLeft
      found = true
    elif rune.isAlpha:
      direction = ui.Direction.LeftToRight
      found = true
    i += max(text.runeLenAt(i), 1)

proc scanInlines(values: openArray[markdown.Inline]; direction: var ui.Direction;
                 found: var bool) =
  for value in values:
    if not found:
      scanDirection(value.text, direction, found)
      scanInlines(value.children, direction, found)

proc scanBlocks(values: openArray[markdown.Block]; direction: var ui.Direction;
                found: var bool) =
  for value in values:
    if not found:
      scanInlines(value.inlines, direction, found)
      scanDirection(value.text, direction, found)
      for item in value.items:
        scanBlocks(item, direction, found)
      scanBlocks(value.blocks, direction, found)

proc notesDirection(values: openArray[markdown.Block]): ui.Direction =
  result = ui.Direction.LeftToRight
  var found = false
  scanBlocks(values, result, found)

proc newNotesState*(): NotesState =
  ## Creates persistent text storage for the selectable release notes.
  NotesState(buffer: ui.newTextBuffer())

proc track(theme: ui.Theme): ui.Color =
  if theme.dark: ui.rgba(255, 255, 255, 0.12'f32)
  else: ui.rgba(0, 0, 0, 0.1'f32)

proc startLine(builder: var NotesBuilder) =
  if not builder.lineStarted:
    if builder.lines.len > 0:
      builder.body.add('\n')
      inc builder.runeOffset
    builder.lineStarted = true

proc finishLine(builder: var NotesBuilder) =
  builder.startLine()
  builder.lines.add(move(builder.currentLine))
  builder.currentLine = @[]
  builder.lineStarted = false

proc append(builder: var NotesBuilder; text: string; style: RunStyle) =
  if text.len == 0:
    return
  builder.startLine()
  var span = ui.Span(text: text, font: style.font, size: style.size,
    weight: style.weight, italic: style.italic, underline: style.underline,
    color: style.color, background: style.background)
  builder.currentLine.add(span)
  builder.body.add(text)
  builder.runeOffset += text.runeLen

proc appendInlines(builder: var NotesBuilder;
                   values: openArray[markdown.Inline]; style: RunStyle) =
  for value in values:
    case value.kind
    of markdown.Text:
      builder.append(value.text, style)
    of markdown.CodeSpan:
      var code = style
      code.font = "monospace"
      code.size = builder.theme.fontSize * (12'f32 / 13)
      code.background = builder.theme.track()
      builder.append(value.text, code)
    of markdown.Emphasis, markdown.Strong:
      var nested = style
      if value.kind == markdown.Emphasis:
        nested.italic = true
      else:
        nested.weight = max(nested.weight, 700)
      builder.appendInlines(value.children, nested)
    of markdown.Link:
      var linked = style
      linked.color = builder.theme.accent
      linked.underline = true
      let first = builder.runeOffset
      builder.appendInlines(value.children, linked)
      if builder.runeOffset > first:
        builder.links.add(LinkRange(start: first,
          pastLast: builder.runeOffset, url: value.url))

proc prefixed(builder: var NotesBuilder; prefix: string; style: RunStyle) =
  builder.append(prefix, style)

proc appendBlock(builder: var NotesBuilder; value: markdown.Block;
                 depth: int; prefix, continuation: string;
                 style: RunStyle)

proc appendBlocks(builder: var NotesBuilder;
                  values: openArray[markdown.Block]; depth: int;
                  prefix, continuation: string; style: RunStyle;
                  tight: bool) =
  for index, value in values:
    if index > 0 and not tight:
      builder.finishLine()
    let linePrefix = if tight and index > 0: continuation else: prefix
    builder.appendBlock(value, depth, linePrefix, continuation, style)

proc appendBlock(builder: var NotesBuilder; value: markdown.Block;
                 depth: int; prefix, continuation: string;
                 style: RunStyle) =
  case value.kind
  of markdown.Paragraph, markdown.Heading:
    var inlineStyle = style
    if value.kind == markdown.Heading:
      const headingSizes = [16'f32 / 13, 14'f32 / 13, 1'f32]
      inlineStyle.size = builder.theme.fontSize *
        headingSizes[min(value.level, headingSizes.len) - 1]
      inlineStyle.weight = max(inlineStyle.weight, 700)
    builder.prefixed(prefix, inlineStyle)
    builder.appendInlines(value.inlines, inlineStyle)
    builder.finishLine()
  of markdown.Code:
    var codeStyle = style
    codeStyle.font = "monospace"
    codeStyle.size = builder.theme.fontSize * (12'f32 / 13)
    codeStyle.background = builder.theme.track()
    let lines = value.text.split('\n')
    for index in 0..<lines.len:
      builder.prefixed(if index == 0: prefix else: continuation, codeStyle)
      builder.append(lines[index], codeStyle)
      builder.finishLine()
  of markdown.Quote:
    var quoteStyle = style
    quoteStyle.color = builder.theme.textMuted
    builder.appendBlocks(value.blocks, depth, prefix & "│ ",
      continuation & "│ ", quoteStyle, tight = false)
  of markdown.List:
    for index, item in value.items:
      let marker = if value.ordered: $(index + 1) & ". "
        else: (if depth == 0: "• " elif depth == 1: "◦ " else: "▪ ")
      let indent = prefix & repeat(" ", marker.runeLen)
      builder.appendBlocks(item, depth + 1, prefix & marker, indent, style,
        tight = true)
  of markdown.Rule:
    builder.prefixed(prefix, style)
    builder.append("────────────────────────",
      style)
    builder.finishLine()

proc buildNotes(values: openArray[markdown.Block]; theme: ui.Theme):
    tuple[body: string, lines: seq[seq[ui.Span]], links: seq[LinkRange],
          direction: ui.Direction] =
  var builder = NotesBuilder(theme: theme)
  builder.appendBlocks(values, 0, "", "", RunStyle(), tight = false)
  if builder.lineStarted:
    builder.lines.add(move(builder.currentLine))
  elif builder.lines.len == 0:
    builder.lines.add(@[])
  result = (builder.body, builder.lines, builder.links,
    notesDirection(values))

proc render*(state: NotesState; context: ui.Context; theme: ui.Theme;
             values: openArray[markdown.Block];
             label = "Release notes"): ui.Element =
  ## Adds styled, read-only release notes with native text selection and copy.
  let persistent = if state == nil: newNotesState() else: state
  let notes = buildNotes(values, theme)
  if persistent.body != notes.body:
    persistent.buffer.set(notes.body)
    persistent.body = notes.body
  persistent.lineStyles = notes.lines
  persistent.links = notes.links
  let styleLine: ui.TextAreaStyler = proc(line: int;
      text: string): seq[ui.Span] =
    if line >= 0 and line < persistent.lineStyles.len:
      result = persistent.lineStyles[line]
  result = context.column().direction(notes.direction).grow()
  let root = result
  discard root.children(proc() =
    let field = context.textAreaBufferStyledBase(persistent.buffer, styleLine)
      .label(label).readOnly().grow()
    let openLink = context
    discard field.onClick(proc() =
      let selection = field.textSelection()
      if selection.start == selection.`end`:
        for link in persistent.links:
          if selection.start >= link.start and selection.start < link.pastLast:
            openLink.openUrl(link.url)
            break
    )
  )

proc measureHeight*(state: NotesState; context: ui.Context;
                    width: float32): float32 =
  ## Measures wrapped, styled release notes in DIPs at the given width.
  if state == nil or context == nil:
    return
  let lineHeight = context.measureText(width, ui.Span(text: " ")).height
  for line in state.lineStyles:
    let height = if line.len == 0: lineHeight
      else: context.measureText(width, line).height
    result += max(lineHeight, height)
