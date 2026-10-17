## Commands and key bindings for the native code editor.

import mynim/ui as ui

type
  Command* = enum
    noCommand
    moveLeft, moveRight, moveUp, moveDown, moveWordLeft, moveWordRight,
    moveSubwordLeft, moveSubwordRight, moveLineStart, moveLineEnd,
    moveDocStart, moveDocEnd, moveParagraphUp, moveParagraphDown,
    movePageUp, movePageDown, moveToBracket,
    selectLeft, selectRight, selectUp, selectDown, selectWordLeft,
    selectWordRight, selectSubwordLeft, selectSubwordRight,
    selectLineStart, selectLineEnd, selectDocStart, selectDocEnd,
    selectParagraphUp, selectParagraphDown, selectPageUp, selectPageDown,
    selectToBracket,
    selectAll, selectLine, selectNext, selectPrevious, selectAllMatches,
    addCursorAbove, addCursorBelow, selectLarger, selectSmaller,
    undoSelection, redoSelection, splitSelectionIntoLines, cancel,
    undo, redo, cut, copy, paste, backspace, delete, deleteWordLeft,
    deleteWordRight, deleteSubwordLeft, deleteSubwordRight, deleteToLineStart,
    deleteToLineEnd, cutToLineEnd, deleteLine, newline, newlineAbove,
    newlineBelow, moveLinesUp, moveLinesDown, duplicateLinesUp,
    duplicateLinesDown, duplicateSelection, joinLines, transpose, indent,
    outdent, tab, backtab, toggleComment, toggleBlockComment, sortLines,
    sortLinesCaseInsensitive, reverseLines, uniqueLines, uppercase, lowercase,
    titleCase, snakeCase, kebabCase, camelCase, pascalCase,
    trimTrailingWhitespace,
    fold, unfold, toggleFold, foldAll, unfoldAll, foldRecursive,
    unfoldRecursive, foldSelection, foldLevel1, foldLevel2, foldLevel3,
    foldLevel4, foldLevel5, foldLevel6, foldLevel7, foldLevel8, foldLevel9,
    find, findReplace, findNext, findPrevious, useSelectionForFind,
    findInSelection, goToLine, scrollCursorCenter, scrollLineUp,
    scrollLineDown, goToDefinition, showCompletions, showHover, nextHunk,
    previousHunk, revertHunk, toggleSoftWrap, toggleLineNumbers

  Binding* = object
    mods*: ui.Modifiers
    key*: ui.Key
    thenMods*: ui.Modifiers
    thenKey*: ui.Key
    command*: Command

proc commandName*(command: Command): string =
  ## Returns the stable keymap name for a command.
  if command == Command.noCommand:
    return "none"
  for candidate in Command:
    if candidate == command:
      return $command
  "unknown"

proc commandNamed*(name: string): tuple[command: Command, found: bool] =
  ## Finds a command by its stable keymap name.
  for command in Command:
    if command.commandName() == name:
      return (command, true)
  (noCommand, false)

proc defaultBindings*(): seq[Binding] =
  ## Returns the currently implemented editor shortcuts for this platform.
  let commandMod = when defined(macosx): ui.modSuper else: ui.modCtrl
  result = @[
    Binding(mods: 0, key: ui.keyEnter, command: Command.newline),
    Binding(mods: ui.modShift, key: ui.keyEnter, command: Command.newline),
    Binding(mods: commandMod, key: ui.keyEnter,
      command: Command.newlineBelow),
    Binding(mods: commandMod or ui.modShift, key: ui.keyEnter,
      command: Command.newlineAbove),
    Binding(mods: ui.modAlt, key: ui.keyUp, command: Command.moveLinesUp),
    Binding(mods: ui.modAlt, key: ui.keyDown, command: Command.moveLinesDown),
    Binding(mods: ui.modAlt or ui.modShift, key: ui.keyUp,
      command: Command.duplicateLinesUp),
    Binding(mods: ui.modAlt or ui.modShift, key: ui.keyDown,
      command: Command.duplicateLinesDown),
    Binding(mods: commandMod or ui.modShift, key: ui.keyK,
      command: Command.deleteLine),
    Binding(mods: ui.modCtrl, key: ui.keyJ, command: Command.joinLines),
    Binding(mods: commandMod, key: ui.keyBracketRight,
      command: Command.indent),
    Binding(mods: commandMod, key: ui.keyBracketLeft,
      command: Command.outdent),
    Binding(mods: commandMod, key: ui.keyL, command: Command.selectLine),
    Binding(mods: commandMod, key: ui.keySlash,
      command: Command.toggleComment),
    Binding(mods: 0, key: ui.keyTab, command: Command.tab),
    Binding(mods: ui.modShift, key: ui.keyTab, command: Command.backtab)
  ]
  when defined(macosx):
    result.add(Binding(mods: commandMod, key: ui.keyK, thenMods: commandMod,
      thenKey: ui.keySlash, command: Command.toggleBlockComment))
  else:
    result.add(Binding(mods: commandMod or ui.modShift, key: ui.keyA,
      command: Command.toggleBlockComment))
