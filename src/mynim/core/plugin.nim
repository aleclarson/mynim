## Plugins extend an app with internal IPC services and setup callbacks.

type
  Plugin* = object
    ## A plugin's unique name, optional IPC methods, and one-time setup.
    name*: string
    service*: seq[tuple[name: string, fn: BoundMethod]]
    setup*: proc(): ref CatchableError {.closure.}

proc validPluginName(name: string): bool =
  if name.len == 0 or name[0] notin {'a'..'z'}:
    return false
  for ch in name:
    if ch notin {'a'..'z', '0'..'9', '-'}:
      return false
  true

proc use*(plugins: varargs[Plugin]) =
  ## Registers plugins before app.run. Plugin methods are bound internally
  ## under plugin:<name>, and do not appear in the generated client.
  for plugin in plugins:
    if not validPluginName(plugin.name):
      raise newException(ValueError,
        "mynim: plugin name \"" & plugin.name &
          "\" must be lowercase letters, digits and hyphens, starting with a letter")
    if plugin.name == "mygo":
      raise newException(ValueError,
        "mynim: plugin name \"mygo\" is reserved")
    registerPlugin(plugin.name, plugin.service)
    if plugin.setup != nil:
      var setupError: ref CatchableError
      try:
        setupError = plugin.setup()
      except CatchableError as error:
        setupError = error
      if setupError != nil:
        raise newException(ValueError,
          "mynim: plugin " & plugin.name & ": " & setupError.msg)
