## Native drag sources.

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
