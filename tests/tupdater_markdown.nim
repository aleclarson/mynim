import std/assertions

import mynim/plugins/updater/markdown

proc inlineText(values: openArray[Inline]): string =
  for value in values:
    if value.kind in {Text, CodeSpan}:
      result.add(value.text)
    else:
      result.add(inlineText(value.children))

block parses_block_shapes:
  let blocks = parse("""
### Added

- one
- two

1. first
2. second

> quoted
> text

```nim
let x = 1
```

---
""")
  doAssert blocks.len == 6
  doAssert blocks[0].kind == Heading and blocks[0].level == 3
  doAssert inlineText(blocks[0].inlines) == "Added"
  doAssert blocks[1].kind == List and not blocks[1].ordered
  doAssert blocks[1].items.len == 2
  doAssert inlineText(blocks[1].items[0][0].inlines) == "one"
  doAssert blocks[2].kind == List and blocks[2].ordered
  doAssert blocks[2].items.len == 2
  doAssert blocks[3].kind == Quote
  doAssert inlineText(blocks[3].blocks[0].inlines) == "quoted text"
  doAssert blocks[4].kind == Code and blocks[4].text == "let x = 1"
  doAssert blocks[5].kind == Rule

block parses_nested_and_continued_lists:
  let blocks = parse("- a\n  - b\n  - c\n- d")
  doAssert blocks.len == 1 and blocks[0].kind == List
  doAssert blocks[0].items.len == 2
  doAssert blocks[0].items[0].len == 2
  doAssert blocks[0].items[0][1].kind == List
  doAssert blocks[0].items[0][1].items.len == 2
  doAssert inlineText(blocks[0].items[0][0].inlines) == "a"
  doAssert inlineText(blocks[0].items[1][0].inlines) == "d"

  let continued = parse("- first\n\n  second\n- next")
  doAssert continued[0].items.len == 2
  doAssert continued[0].items[0].len == 2
  doAssert inlineText(continued[0].items[0][1].inlines) == "second"

  let emptyItem = parse("- \n- filled")
  doAssert emptyItem[0].items.len == 2
  doAssert emptyItem[0].items[0].len == 0
  doAssert inlineText(emptyItem[0].items[1][0].inlines) == "filled"

block parses_common_inline_markup:
  let blocks = parse("**bold *em* bold** and `code` and \\*literal\\*")
  let inlines = blocks[0].inlines
  doAssert inlines.len == 4
  doAssert inlines[0].kind == Strong
  doAssert inlines[0].children.len == 3
  doAssert inlines[0].children[1].kind == Emphasis
  doAssert inlineText(inlines[0].children) == "bold em bold"
  doAssert inlines[1].kind == Text and inlines[1].text == " and "
  doAssert inlines[2].kind == CodeSpan and inlines[2].text == "code"
  doAssert inlines[3].text == " and *literal*"

block parses_nested_links_and_lists:
  let blocks = parse("## Fixed\n\n- A **bold [link](https://example.com)** fix\n" &
    "  1. nested\n\n> `code`")
  doAssert blocks.len == 3
  doAssert blocks[0].kind == Heading and blocks[0].level == 2
  let item = blocks[1].items[0]
  doAssert item.len == 2
  let inlines = item[0].inlines
  doAssert inlines[1].kind == Strong
  doAssert inlines[1].children[1].kind == Link
  doAssert inlines[1].children[1].url == "https://example.com"
  doAssert item[1].kind == List and item[1].ordered
  doAssert inlineText(item[1].items[0][0].inlines) == "nested"
  doAssert blocks[2].kind == Quote
  doAssert blocks[2].blocks[0].inlines[0].kind == CodeSpan
  doAssert blocks[2].blocks[0].inlines[0].text == "code"

block permits_only_safe_links:
  let blocks = parse("[docs](https://example.com/a?x=1) [bad](javascript:alert(1)) <b>raw</b>")
  let inlines = blocks[0].inlines
  doAssert inlines[0].kind == Link
  doAssert inlines[0].url == "https://example.com/a?x=1"
  doAssert inlineText(inlines[0].children) == "docs"
  doAssert inlineText(inlines[1 .. ^1]) == " bad) <b>raw</b>"
  let automatic = parse("See https://example.com/x_(y). <mailto:help@example.com>")
  doAssert automatic[0].inlines[1].kind == Link
  doAssert automatic[0].inlines[1].url == "https://example.com/x_(y)"
  doAssert automatic[0].inlines[^1].kind == Link
  doAssert automatic[0].inlines[^1].url == "mailto:help@example.com"
  doAssert safeUrl("HTTPS://example.com")
  doAssert safeUrl("mailto:user@example.com")
  doAssert not safeUrl("javascript:alert(1)")
  doAssert not safeUrl("/relative")

block handles_plain_text_and_line_endings:
  doAssert parse("").len == 0
  doAssert inlineText(parse("One\r\nworld")[0].inlines) == "One world"
  doAssert inlineText(parse("snake_case_name and 2 * 3 * 4")[0].inlines) ==
    "snake_case_name and 2 * 3 * 4"
  doAssert inlineText(parse("Café — ünïcode")[0].inlines) == "Café — ünïcode"
  doAssert inlineText(parse("<script>alert(1)</script>")[0].inlines) ==
    "<script>alert(1)</script>"
