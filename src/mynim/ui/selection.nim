## An application-owned set of selected row keys.
##
## Its zero value is empty. Bind it to a list or grid with
## `ListState.bindSelection` or `GridState.bindSelection` to keep app-side and
## UI-side changes in sync.

type
  Selection*[K] = ref object
    keys: HashSet[K]
  SelectionBinding = ref object
    containsItem: proc(item: int): bool {.closure.}
    setItem: proc(item: int; selected: bool): bool {.closure.}
    clearItems: proc(): bool {.closure.}
    itemCount: proc(): int {.closure.}

proc setSelectionKey[K](selection: Selection[K]; key: K;
                        selected: bool): bool =
  if selection == nil:
    return false
  let exists = selection.keys.contains(key)
  if exists == selected:
    return false
  if selected:
    selection.keys.incl(key)
  else:
    selection.keys.excl(key)
  true

proc clearSelectionKeys[K](selection: Selection[K]): bool =
  if selection == nil or selection.keys.len == 0:
    return false
  selection.keys.clear()
  true

proc ensure[K](selection: var Selection[K]) =
  if selection == nil:
    new(selection)
    selection.keys = initHashSet[K]()

proc has*[K](selection: Selection[K]; key: K): bool =
  ## Reports whether key is selected.
  selection != nil and selection.keys.contains(key)

proc len*[K](selection: Selection[K]): int =
  ## Returns the number of selected keys.
  if selection != nil:
    result = selection.keys.len

proc add*[K](selection: var Selection[K]; key: K) =
  ## Selects key.
  selection.ensure()
  discard selection.setSelectionKey(key, true)

proc remove*[K](selection: var Selection[K]; key: K) =
  ## Removes key from the selection.
  discard selection.setSelectionKey(key, false)

proc clear*[K](selection: var Selection[K]) =
  ## Clears the selection.
  discard selection.clearSelectionKeys()

iterator all*[K](selection: Selection[K]): K =
  ## Iterates selected keys in unspecified order.
  if selection != nil:
    for key in selection.keys:
      yield key

proc newSelectionBinding[K](selection: var Selection[K];
    keyAt: proc(item: int): K {.closure.}): SelectionBinding =
  selection.ensure()
  let shared = selection
  result = SelectionBinding(
    containsItem: proc(item: int): bool = shared.has(keyAt(item)),
    setItem: proc(item: int; selected: bool): bool =
      shared.setSelectionKey(keyAt(item), selected),
    clearItems: proc(): bool = shared.clearSelectionKeys(),
    itemCount: proc(): int = shared.len
  )
