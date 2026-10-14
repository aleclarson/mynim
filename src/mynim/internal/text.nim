## Port of internal/text: lays out text and rasterizes glyphs with the
## system's own text stack: DirectWrite on Windows, Core Text on macOS
## and Pango with cairo on Linux. The engines find the fonts, fall back
## to other fonts for what one lacks, shape and break lines; the package
## assembles their lines into layouts, with carets, selection and
## truncation of its own, and keeps the glyphs in the atlases scenes
## draw from. All methods of System are safe from any thread; the ui
## package uses them from the main thread.

import std/[locks, math, strutils, unicode, tables, algorithm, hashes, sets, dynlib, syncio]
import scene
import segmenter
import ucd
import ../image

include text/types
include text/boundaries
include text/engine
when defined(macosx):
  include text/coretext
  proc newEngine(): Engine =
    try:
      newCoreText()
    except CatchableError as e:
      stderr.writeLine("mynim: " & e.msg & ": text will not show")
      StubEngine()
else:
  proc newEngine(): Engine = StubEngine()
include text/lang
include text/layout
include text/edit
include text/caret
include text/raster
include text/decoration
