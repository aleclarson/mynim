## Helpers for URLs and files passed on the application's command line.

import std/[os, sets, strutils, uri]

proc isURLScheme*(s: string): bool =
  ## Reports whether s follows the URL scheme grammar.
  for i, c in s:
    let letter = c in 'a'..'z' or c in 'A'..'Z'
    if not letter and
        (i == 0 or not (c in '0'..'9' or c in {'+', '-', '.'})):
      return false
  s.len > 0

proc urlArgs*(args: openArray[string]; schemes: openArray[string]): seq[string] =
  ## Returns arguments whose URL schemes are handled by the app.
  var handled = initHashSet[string]()
  for scheme in schemes:
    handled.incl scheme.toLowerAscii()
  for arg in args:
    let colon = arg.find(':')
    # A one-letter scheme is ambiguous with a Windows drive letter.
    if colon <= 1:
      continue
    let scheme = arg[0 ..< colon]
    if isURLScheme(scheme) and scheme.toLowerAscii() in handled:
      result.add arg

proc fileArgs*(args: openArray[string]; workingDir: string;
               extensions: openArray[string]): seq[string] =
  ## Returns existing regular files with one of the associated extensions.
  if extensions.len == 0:
    return

  var associated = initHashSet[string]()
  for extension in extensions:
    let normalized = extension.strip(chars = {'.'}).toLowerAscii()
    if normalized != "":
      associated.incl normalized

  for arg in args:
    var path = arg
    if arg.toLowerAscii().startsWith("file:"):
      try:
        let uri = parseUri(arg)
        if uri.scheme.toLowerAscii() == "file":
          path = decodeUrl(uri.path, decodePlus = false)
          when defined(windows):
            path = path.replace('/', '\\')
            if path.len >= 3 and path[0] == '\\' and path[2] == ':':
              path = path[1 .. ^1]
      except CatchableError:
        discard

    let extension = path.splitFile().ext.strip(chars = {'.'}).toLowerAscii()
    if extension notin associated:
      continue
    if not path.isAbsolute:
      path = workingDir / path
    if path.fileExists():
      result.add path
