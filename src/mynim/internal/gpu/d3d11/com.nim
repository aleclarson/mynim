## Direct3D's COM vtable calls. Windows COM methods use stdcall, with the
## interface pointer as their first argument.

type
  Call0 = proc(a0: uint): uint {.stdcall.}
  Call1 = proc(a0, a1: uint): uint {.stdcall.}
  Call2 = proc(a0, a1, a2: uint): uint {.stdcall.}
  Call3 = proc(a0, a1, a2, a3: uint): uint {.stdcall.}
  Call4 = proc(a0, a1, a2, a3, a4: uint): uint {.stdcall.}
  Call5 = proc(a0, a1, a2, a3, a4, a5: uint): uint {.stdcall.}
  Call6 = proc(a0, a1, a2, a3, a4, a5, a6: uint): uint {.stdcall.}
  Call7 = proc(a0, a1, a2, a3, a4, a5, a6, a7: uint): uint {.stdcall.}
  Call8 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8: uint): uint {.stdcall.}
  Call9 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9: uint): uint
    {.stdcall.}
  Call10 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10: uint): uint
    {.stdcall.}
  Call11 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11: uint): uint
    {.stdcall.}
  Call12 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12: uint): uint
    {.stdcall.}
  Call13 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13: uint): uint
    {.stdcall.}
  Call14 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14: uint): uint
    {.stdcall.}
  Call15 = proc(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15: uint): uint
    {.stdcall.}

proc methodAddress(obj: uint; index: int): uint =
  if obj == 0:
    return 0
  let vtable = cast[ptr UncheckedArray[uint]](cast[pointer](obj))[0]
  cast[ptr UncheckedArray[uint]](cast[pointer](vtable))[index]

proc call*(obj: uint; index: int): uint =
  cast[Call0](cast[pointer](methodAddress(obj, index)))(obj)
proc call*(obj: uint; index: int; a1: uint): uint =
  cast[Call1](cast[pointer](methodAddress(obj, index)))(obj, a1)
proc call*(obj: uint; index: int; a1, a2: uint): uint =
  cast[Call2](cast[pointer](methodAddress(obj, index)))(obj, a1, a2)
proc call*(obj: uint; index: int; a1, a2, a3: uint): uint =
  cast[Call3](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3)
proc call*(obj: uint; index: int; a1, a2, a3, a4: uint): uint =
  cast[Call4](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5: uint): uint =
  cast[Call5](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6: uint): uint =
  cast[Call6](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7: uint): uint =
  cast[Call7](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8: uint): uint =
  cast[Call8](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9: uint): uint =
  cast[Call9](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10: uint): uint =
  cast[Call10](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11: uint): uint =
  cast[Call11](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12: uint): uint =
  cast[Call12](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13: uint): uint =
  cast[Call13](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14: uint): uint =
  cast[Call14](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14)
proc call*(obj: uint; index: int; a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15: uint): uint =
  cast[Call15](cast[pointer](methodAddress(obj, index)))(obj, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)

proc failed*(hr: uint): bool = int32(uint32(hr)) < 0

proc release*(obj: var uint) =
  if obj != 0:
    discard call(obj, 2)
    obj = 0
