import std/[assertions, strutils]
import mynim/ui as ui
import mynim/image as imagePackage
import mynim/internal/platform as platform
import mynim/transfer as transfer

block headless_render_query_and_click:
  var clicks = 0
  var languageSeen = ""
  var rightToLeft = false
  var titleBarSeen = platform.TitleBar()
  var vibrancySeen = false
  let tester = ui.newTester(proc(ctx: ui.Context) =
    languageSeen = ctx.locale()
    rightToLeft = ctx.direction() == ui.Direction.RightToLeft
    titleBarSeen = ctx.titleBar()
    vibrancySeen = ctx.vibrancy()
    discard ctx.column().children(proc() =
      discard ctx.text("Hello tester")
      discard ctx.button("Activate").onClick(proc() = inc clicks)
    )
  , 120, 64)
  defer: tester.close()

  doAssert tester.hasText("Hello")
  doAssert tester.texts().len > 0
  let (bounds, found) = tester.find("Activate")
  doAssert found
  doAssert bounds.w > 0 and bounds.h > 0
  let image = tester.image()
  doAssert imagePackage.dx(image.rect) == 120
  doAssert imagePackage.dy(image.rect) == 64
  doAssert image.pix.len == 120 * 64 * 4

  doAssert tester.click("Activate") == nil
  doAssert clicks == 1

  tester.setLocale("fr")
  tester.setDirection(ui.Direction.RightToLeft)
  doAssert languageSeen == "fr"
  doAssert rightToLeft

  tester.setTitleBar(platform.TitleBar(height: 24, left: 72))
  doAssert titleBarSeen == platform.TitleBar(height: 24, left: 72)
  tester.setVibrancy(true)
  doAssert vibrancySeen

  tester.setScale(2)
  doAssert imagePackage.dx(tester.image().rect) == 240
  tester.setSize(80, 40)
  let resized = tester.image()
  doAssert imagePackage.dx(resized.rect) == 160
  doAssert imagePackage.dy(resized.rect) == 80

  tester.setClipboard("copied")
  doAssert tester.clipboard() == "copied"
  tester.setClipboardData(transfer.textData("data copied"))
  doAssert tester.clipboard() == "data copied"
  let (clipboardBytes, clipboardError) = tester.clipboardData().read(transfer.Text)
  doAssert clipboardError == nil
  doAssert transfer.bytesToString(clipboardBytes) == "data copied"

block missing_element_reports_error:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.text("Visible")
  , 40, 20)
  defer: tester.close()

  let err = tester.click("Missing")
  doAssert err != nil
  doAssert err.msg.contains("Missing")

block headless_text_input_events:
  var value = "start"
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.textInput(value).label("Name")
  , 160, 40)
  defer: tester.close()

  doAssert tester.click("Name") == nil
  doAssert tester.focused("Name")
  let (caret, active) = tester.textCaret()
  doAssert active and caret.h > 0
  tester.typeText("!")
  doAssert value == "start!"
  tester.setFocused(false)
  doAssert not tester.textInputActive()
  doAssert not tester.textInputNoInputMethod()

block no_input_method:
  var value = "command"
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.textInput(value).label("Command").inputMethod(false)
  , 160, 40)
  defer: tester.close()

  doAssert tester.click("Command") == nil
  doAssert tester.textInputActive()
  doAssert tester.textInputNoInputMethod()
  doAssert tester.textCaret().active
  tester.compose("あ", 1)
  doAssert value == "command"
  tester.typeText("x")
  doAssert value == "commandx"

block headless_native_menu:
  let tester = ui.newTester(proc(ctx: ui.Context) =
    discard ctx.menuButton("Actions", proc(menu: ui.Menu) =
      discard menu.item("Run")
      discard menu.item("Unavailable").disabled()
    )
  , 120, 40)
  defer: tester.close()

  doAssert tester.click("Actions") == nil
  doAssert tester.menu() == @["Run", "Unavailable"]
  let disabled = tester.chooseMenuItem("Unavailable")
  doAssert disabled != nil
  doAssert tester.menu().len == 2
  doAssert tester.chooseMenuItem("Run") == nil
  doAssert tester.menu().len == 0

block headless_accessibility_cursor_and_urls:
  var sendAnnouncement = false
  let tester = ui.newTester(proc(ctx: ui.Context) =
    if sendAnnouncement:
      sendAnnouncement = false
      ctx.announce("Ready")
    discard ctx.text("Hover me").cursor(platform.cursorPointer)
    discard ctx.link("Docs", "https://example.com/docs")
  , 140, 60)
  defer: tester.close()

  sendAnnouncement = true
  tester.frame()
  doAssert tester.announcements() == @["Ready"]
  doAssert tester.announcements().len == 0

  let (bounds, found) = tester.find("Hover me")
  doAssert found
  tester.move(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2)
  doAssert tester.cursor() == platform.cursorPointer
  doAssert tester.click("Docs") == nil
  doAssert tester.openedUrls() == @["https://example.com/docs"]
