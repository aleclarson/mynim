## Typed and native drag sources.

type
  TypedDragValueBase = ref object of RootObj
    typeIdentity: pointer

  TypedDragValue[T] = ref object of TypedDragValueBase
    value: T

proc typedDragTypeIdentity[T](): pointer =
  var marker {.global.}: byte
  addr marker

proc typedDragValue[T](value: RootRef): tuple[value: T, ok: bool] =
  if value != nil and value of TypedDragValueBase and
      TypedDragValueBase(value).typeIdentity == typedDragTypeIdentity[T]():
    result.value = TypedDragValue[T](value).value
    result.ok = true

proc acceptsTypedDragValue(value: RootRef; typeIdentity: pointer): bool =
  value != nil and value of TypedDragValueBase and
    TypedDragValueBase(value).typeIdentity == typeIdentity

proc drag*[T](e: Element; value: T): Element =
  ## Makes this element a source for typed drops within this process.
  result = e
  let node = e.node
  if node == nil:
    return
  node.dragValueProvider = proc(): RootRef =
    TypedDragValue[T](typeIdentity: typedDragTypeIdentity[T](), value: value)

proc dragData*(e: Element; data: transfer.Data;
               options = transfer.DragOptions()): Element =
  ## Makes this element a native drag source after a primary press moves
  ## four DIPs. The data is snapshotted when the platform drag begins.
  result = e
  let node = e.node
  if node == nil:
    return
  node.dragDataProvider = proc(): transfer.Data = data
  node.dragDataOptions = options

proc dragDataFrom*(e: Element;
                   provider: proc(): transfer.Data {.closure.};
                   options = transfer.DragOptions()): Element =
  ## Gets data when the drag gesture starts, so the source can follow a
  ## changing selection. The provider and options.done run on the UI thread.
  result = e
  let node = e.node
  if node == nil:
    return
  if provider == nil:
    raise newException(ValueError, "ui: nil drag data source")
  node.dragDataProvider = provider
  node.dragDataOptions = options

proc dragOver*[T](e: Element; _: typedesc[T]): tuple[value: T, over: bool] =
  ## Takes values of type T dragged within this process and reports the
  ## value while it is over this element. Pass the type as a typedesc,
  ## for example `target.dragOver(string)`.
  let node = e.node
  if node == nil:
    return
  let typeIdentity = typedDragTypeIdentity[T]()
  node.valueAccepts = proc(value: RootRef): bool =
    acceptsTypedDragValue(value, typeIdentity)
  let owner = e.owner
  if owner.dragOverIdentity == node.identity and not owner.dragCanceled:
    let current = typedDragValue[T](owner.dragValue)
    if current.ok:
      return (current.value, true)
  if owner.dataOverLocalIdentity == node.identity:
    let current = typedDragValue[T](owner.dataOverLocal)
    if current.ok:
      return (current.value, true)

proc drop*[T](e: Element; _: typedesc[T]): tuple[value: T, ok: bool] =
  ## Takes values of type T dragged within this process and returns each
  ## completed drop once, in the build after release. Pass the type as a
  ## typedesc, for example `target.drop(string)`.
  let node = e.node
  if node == nil:
    return
  let typeIdentity = typedDragTypeIdentity[T]()
  node.valueAccepts = proc(value: RootRef): bool =
    acceptsTypedDragValue(value, typeIdentity)
  let identity = node.identity
  if e.owner.pendingValueDrops.hasKey(identity):
    let current = typedDragValue[T](e.owner.pendingValueDrops[identity])
    if current.ok:
      e.owner.pendingValueDrops.del(identity)
      return (current.value, true)

proc dragging*(e: Element): bool =
  ## Reports whether this value or element is being dragged by the pointer.
  let node = e.node
  node != nil and
    ((node[].draggable and node[].draggableDragging) or
     (e.owner.dragSourceIdentity == node[].identity and
      not e.owner.dragCanceled))

proc valueDropTargetAt(layout: LayoutResult; x, y: float32;
                       value: RootRef): int =
  let owner = layout.owner
  if owner == nil or value == nil:
    return
  for candidate in layout.dropCandidates(x, y):
    var slot = candidate
    while slot > 0 and slot < owner.nodes.len:
      let node = owner.nodes[slot]
      if not owner.effectivelyDisabled(slot) and node.valueAccepts != nil and
          node.valueAccepts(value):
        return slot
      slot = int(node.parent)
