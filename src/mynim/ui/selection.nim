## An application-owned set of selected row keys.
##
## Its zero value is empty. Bind it to a list with `ListState.bindSelection`
## to keep app-side and list-side changes in sync.

type
  Selection*[K] = ref object
    keys: HashSet[K]

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
  selection.keys.incl(key)

proc remove*[K](selection: var Selection[K]; key: K) =
  ## Removes key from the selection.
  if selection != nil:
    selection.keys.excl(key)

proc clear*[K](selection: var Selection[K]) =
  ## Clears the selection.
  if selection != nil:
    selection.keys.clear()

iterator all*[K](selection: Selection[K]): K =
  ## Iterates selected keys in unspecified order.
  if selection != nil:
    for key in selection.keys:
      yield key
