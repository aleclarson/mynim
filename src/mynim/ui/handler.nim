## Raw input events delivered to the element that handles them.

proc handleInput*(e: Element;
                  handler: proc(ev: InputEvent): bool {.closure.}): Element =
  ## Handles input for this element as it arrives on the UI thread.
  ##
  ## Key, text, composition, and command events go to the focused element.
  ## Pointer and scroll events go to the topmost handler under the pointer.
  ## Taking a pointer down captures its moves and release, including outside
  ## the element. Returning false lets the event continue through normal UI
  ## handling. Registered shortcuts run before key-down events.
  result = e
  let node = e.node
  if node != nil:
    node.inputHandler = handler
