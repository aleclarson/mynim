import std/assertions

include "../src/mynim.nim"
import mynim/internal/fake as fakeBackend
import mynim/ui as ui

var testName, testEmail, testCity, testDisabledName: string
var testNotify, testExpress: bool
var testSize = "Small"
var testSaveClicks: int
var testAccountDisabled: bool

type FormHandles = ref object
  emailField, notifyField, deliveryField, expressField,
    disabledField: ui.Element

proc accessNode(tree: ref platform.AccessTree; role: platform.AccessRole;
                label: string): platform.AccessNode =
  if tree != nil:
    for node in tree.nodes:
      if node.role == role and node.label == label:
        return node
  raise newException(AssertionDefect,
    "missing access node " & $role & " labeled " & label)

proc buildForm(ctx: ui.Context; handles: FormHandles) =
  discard ctx.form(proc() =
    discard ctx.field("Name", proc() =
      discard ctx.textInput(testName)
    ).description("As on your passport.")
    handles.emailField = ctx.field("Email address", proc() =
      discard ctx.textInput(testEmail)
    ).description("For receipts.").error("Enter an email address.")
    handles.notifyField = ctx.field("Notifications", proc() =
      discard ctx.checkbox(testNotify, "Send emails")
    )
    handles.deliveryField = ctx.field("Delivery", proc() =
      discard ctx.radioGroup(proc() =
        discard ctx.radio(testSize, "Small", "Small")
        discard ctx.radio(testSize, "Large", "Large")
      )
    )
    handles.expressField = ctx.field("Express", proc() =
      discard ctx.switch(testExpress)
    )
    discard ctx.fieldset("Shipping", proc() =
      discard ctx.field("City", proc() = discard ctx.textInput(testCity))
    )
    let account = ctx.fieldset("Account", proc() =
      handles.disabledField = ctx.field("Disabled name", proc() =
        discard ctx.textInput(testDisabledName)
      )
      discard ctx.button("Save").onClick(proc() = inc testSaveClicks)
    ).disabled()
    testAccountDisabled = account.isDisabled()
  )

let fake = fakeBackend.newFakeBackend()
theBackend = platform.Backend(fake)
backendMade = true
fake.init(AppHandlerImpl(), platform.AppOptions(name: "ui form test"))
app.initialized = true
app.handleReady()

let runtimeHandles = FormHandles()
let formContent = ui.newContent(proc(ctx: ui.Context) =
  buildForm(ctx, runtimeHandles)
)
let formWindow = newWindow(WindowOptions(width: 520, height: 520, hidden: true,
  content: formContent))
let native = fake.windows[^1].surface
doAssert native.frame()
doAssert native.send(platform.SurfaceEvent(kind: platform.accessibilityOn))
var tree = native.accessibility()[0]
doAssert tree != nil
doAssert testAccountDisabled

let nameNode = accessNode(tree, platform.roleTextField, "Name")
doAssert nameNode.description == "As on your passport."
doAssert (nameNode.states and platform.accessInvalid) ==
  platform.AccessStates(0)
let emailNode = accessNode(tree, platform.roleTextField, "Email address")
doAssert emailNode.description ==
  "Enter an email address.\nFor receipts."
doAssert (emailNode.states and platform.accessInvalid) !=
  platform.AccessStates(0)
doAssert accessNode(tree, platform.roleCheckBox, "Send emails").label ==
  "Send emails"
discard accessNode(tree, platform.roleGroup, "Notifications")
discard accessNode(tree, platform.roleRadioGroup, "Delivery")
discard accessNode(tree, platform.roleSwitch, "Express")
let cityNode = accessNode(tree, platform.roleTextField, "City")
let disabledNode = accessNode(tree, platform.roleTextField, "Disabled name")
let saveNode = accessNode(tree, platform.roleButton, "Save")
doAssert (disabledNode.states and platform.accessDisabled) !=
  platform.AccessStates(0)
doAssert (saveNode.states and platform.accessDisabled) !=
  platform.AccessStates(0)
doAssert (accessNode(tree, platform.roleGroup, "Account").states and
  platform.accessDisabled) != platform.AccessStates(0)
doAssert tree.nodes.len > 0

# The control column starts at one x coordinate, including fields in a
# fieldset. The outer field handle gives the label cell's clickable area.
let measureContext = ui.newContext()
let measuredHandles = FormHandles()
measureContext.build(proc(ctx: ui.Context) =
  buildForm(ctx, measuredHandles)
)
let formLayout = measureContext.layout(520, 520)
let emailFieldBounds = formLayout.bounds(measuredHandles.emailField)
let notifyBounds = formLayout.bounds(measuredHandles.notifyField)
let deliveryBounds = formLayout.bounds(measuredHandles.deliveryField)
let expressBounds = formLayout.bounds(measuredHandles.expressField)
let disabledFieldBounds = formLayout.bounds(measuredHandles.disabledField)
doAssert emailNode.bounds.x > emailFieldBounds.x
doAssert abs(emailNode.bounds.x - cityNode.bounds.x) < 1

# Clicking the label cell focuses its text field.
let labelX = emailFieldBounds.x + 4
let labelY = emailFieldBounds.y + 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: labelX, y: labelY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: labelX, y: labelY))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus == emailNode.id

# A field label toggles the self-naming checkbox inside its own group.
let notifyX = notifyBounds.x + 4
let notifyY = notifyBounds.y + 10
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: notifyX, y: notifyY))
doAssert native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: notifyX, y: notifyY))
doAssert native.frame()
doAssert testNotify

# A radio-group field label focuses its selected option; a switch label
# activates the switch.
let deliveryX = deliveryBounds.x + 4
let deliveryY = deliveryBounds.y + 10
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: deliveryX, y: deliveryY))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: deliveryX, y: deliveryY))
doAssert native.frame()
tree = native.accessibility()[0]
let smallNode = accessNode(tree, platform.roleRadio, "Small")
doAssert tree.focus == smallNode.id and testSize == "Small"

let expressX = expressBounds.x + 4
let expressY = expressBounds.y + 10
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: expressX, y: expressY))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: expressX, y: expressY))
doAssert native.frame()
doAssert testExpress

# Disabled fieldsets reject both label activation and control activation.
doAssert not native.send(platform.SurfaceEvent(kind: platform.accessAction,
  id: saveNode.id, action: platform.accessPress))
let disabledLabelX = disabledFieldBounds.x + 4
let disabledLabelY = disabledFieldBounds.y + 10
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: disabledLabelX, y: disabledLabelY))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: disabledLabelX, y: disabledLabelY))
let saveBounds = saveNode.bounds
discard native.send(platform.SurfaceEvent(kind: platform.pointerDown,
  x: saveBounds.x + saveBounds.w / 2,
  y: saveBounds.y + saveBounds.h / 2))
discard native.send(platform.SurfaceEvent(kind: platform.pointerUp,
  x: saveBounds.x + saveBounds.w / 2,
  y: saveBounds.y + saveBounds.h / 2))
doAssert native.frame()
tree = native.accessibility()[0]
doAssert tree.focus != disabledNode.id
doAssert testDisabledName == "" and testSaveClicks == 0

formWindow.destroy()
loop.shutdown()
