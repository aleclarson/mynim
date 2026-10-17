## Internal platform device interface for game controllers.

import ./types

type Device* = ref object of RootObj

method key*(device: Device): string {.base.} = ""
method name*(device: Device): string {.base.} = ""
method read*(device: Device; state: var State): bool {.base.} = false
method close*(device: Device) {.base.} = discard
