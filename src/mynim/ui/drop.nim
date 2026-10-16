## Native data and file drop destinations.

proc dropCandidates(layout: LayoutResult; x, y: float32): seq[int] =
  let owner = layout.owner
  if owner == nil or owner.closed or owner.inBuild or
      not owner.hasFrame or layout.generation != owner.generation or
      layout.rects.len != owner.nodes.len:
    return
  let usePaintOrder = owner.paintSlots.len == layout.rects.len
  var orderIndex = if usePaintOrder: owner.paintSlots.high
    else: layout.rects.high
  while orderIndex >= 1:
    let slot = if usePaintOrder: owner.paintSlots[orderIndex] else: orderIndex
    if slot > 0 and slot < owner.nodes.len and
        owner.inActiveModalScope(slot) and
        not owner.effectivelyToolbarCollapsed(slot) and
        not layout.pointerTransparent(slot) and
        layout.rects[slot].contains(x, y) and
        layout.insideClips(slot, x, y):
      result.add(slot)
    dec orderIndex

proc fileDropTargetAt(layout: LayoutResult; x, y: float32): int =
  let owner = layout.owner
  for candidate in layout.dropCandidates(x, y):
    var slot = candidate
    while slot > 0 and slot < owner.nodes.len:
      if owner.nodes[slot].fileDropTarget and
          not owner.effectivelyDisabled(slot):
        return slot
      slot = int(owner.nodes[slot].parent)

proc dataDropTargetAt(layout: LayoutResult; x, y: float32;
                      drag: platform.DataDragEvent):
                      tuple[slot: int, formats: seq[transfer.Format],
                            operation: transfer.Operation,
                            localValue: bool] =
  if drag == nil:
    return
  let owner = layout.owner
  var offered = drag.offer.formats
  if drag.hasFiles and transfer.FileList notin offered:
    offered.add(transfer.FileList)
  for candidate in layout.dropCandidates(x, y):
    var slot = candidate
    while slot > 0 and slot < owner.nodes.len:
      let node = owner.nodes[slot]
      if drag.`local` != nil and node.valueAccepts != nil and
          node.valueAccepts(drag.`local`) and
          not owner.effectivelyDisabled(slot):
        let operation = transfer.negotiate(drag.offer.operations,
          transfer.Copy, drag.offer.suggested)
        if operation != transfer.None:
          return (slot, @[], operation, true)
      if node.dropDataTarget and not owner.effectivelyDisabled(slot):
        var formats: seq[transfer.Format]
        for format in node.dropDataOptions.formats:
          if format != platform.DragSessionFormat and format in offered and
              format notin formats:
            formats.add(format)
        let operation = transfer.negotiate(drag.offer.operations,
          node.dropDataOptions.operations, drag.offer.suggested)
        if formats.len > 0 and operation != transfer.None:
          return (slot, formats, operation, false)
      slot = int(node.parent)

proc dataDragOver*(e: Element; options: transfer.DropOptions):
                    tuple[offer: transfer.Offer, over: bool] =
  ## Makes this element a native destination and reports its current offer.
  ## The offer lists formats and operations without reading their data.
  let node = e.node
  if node == nil:
    return
  node.dropDataTarget = true
  node.dropDataOptions = options
  node.dropDataOptions.formats = @(options.formats)
  if e.owner.dataOverIdentity == node.identity:
    result.offer = e.owner.dataOverOffer
    result.offer.formats = @(result.offer.formats)
    result.over = true

proc dropData*(e: Element; options: transfer.DropOptions):
               tuple[value: transfer.Drop, ok: bool] =
  ## Makes this element a native destination and returns each completed
  ## transfer once, in the build after it is dropped.
  let node = e.node
  if node == nil:
    return
  node.dropDataTarget = true
  node.dropDataOptions = options
  node.dropDataOptions.formats = @(options.formats)
  if e.owner.pendingDataDrops.hasKey(node.identity):
    result.value = e.owner.pendingDataDrops[node.identity]
    e.owner.pendingDataDrops.del(node.identity)
    result.ok = true

proc droppedFiles*(e: Element): seq[string] =
  ## Makes this element take dropped files and returns each drop once.
  let node = e.node
  if node == nil:
    return
  node.fileDropTarget = true
  if e.owner.pendingFileDrops.hasKey(node.identity):
    result = e.owner.pendingFileDrops[node.identity]
    e.owner.pendingFileDrops.del(node.identity)

proc fileDragOver*(e: Element): bool =
  ## Reports whether files dragged from another app are over this element.
  let node = e.node
  if node == nil:
    return false
  node.fileDropTarget = true
  e.owner.fileOverIdentity == node.identity
