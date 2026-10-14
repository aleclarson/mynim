## Package raster draws scenes in memory: the software renderer behind
## headless rendering, window captures and windows without a GPU
## renderer. Coverage comes from signed distances to rounded
## rectangles, so edges, corners and clips are anti-aliased the way
## the GPU shaders do it (internal/raster).

import std/[math, locks, atomics, tables, cpuinfo]
import scene
import ../image

proc abs(v: float32): float32 {.inline.} =
  if v < 0: -v else: v

proc clamp01(v: float32): float32 {.inline.} =
  if v < 0: 0 elif v > 1: 1 else: v

proc to8(v: float32): byte {.inline.} =
  if v <= 0: 0 elif v >= 1: 255 else: byte(v * 255 + 0.5)

include raster/corner
## A large area is drawn on several cores at once, in bands of bandRows
## rows that each takes in turn, as rows differ in how much they draw:
## each pixel is what drawing the area whole gives, as no pixel depends
## on another. An area of fewer than workArea pixels a core is not
## worth waking cores for, and maxWorkers is about where memory
## bandwidth and the lower clock of all cores stop paying for more.
##
## An effect costs much more a pixel and is often short, as a bar: the
## operations from one are drawn in bands of effectRows rows, so that
## more cores share it.
const
  bandRows = 64
  effectRows = 16
  workArea = 128 shl 10
  maxWorkers = 8

include raster/team
include raster/core
include raster/transform
include raster/effect
include raster/draw
include raster/clipmask
include raster/damage
