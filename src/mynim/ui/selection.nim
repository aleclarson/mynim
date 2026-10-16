## A set of selected row keys, usable as application-owned state.

type
  Selection*[K] = object
    keys: HashSet[K]
    initialized: bool

proc ensure[K](selection: var Selection[K]) =
  if not selection.initialized:
    selection.keys = initHashSet[K]()
    selection.initialized = true

proc has*[K](selection: Selection[K]; key: K): bool =
  ## Reports whether key is selected.
  selection.initialized and selection.keys.contains(key)

proc len*[K](selection: Selection[K]): int =
  ## Returns the number of selected keys.
  if selection.initialized:
    result = selection.keys.len

proc add*[K](selection: var Selection[K]; key: K) =
  ## Selects key.
  selection.ensure()
  selection.keys.incl(key)

proc remove*[K](selection: var Selection[K]; key: K) =
  ## Removes key from the selection.
  if selection.initialized:
    selection.keys.excl(key)

proc clear*[K](selection: var Selection[K]) =
  ## Clears the selection.
  if selection.initialized:
    selection.keys.clear()

iterator all*[K](selection: Selection[K]): K =
  ## Iterates selected keys in unspecified order.
  if selection.initialized:
    for key in selection.keys:
      yield key
