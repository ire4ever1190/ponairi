## Tests for macro utils

import std/[
  unittest,
  macros,
  strutils
]
import ponairi/macroUtils


type
  Person = object
    name: string
    age: int
    a, b: string

{.experimental: "dynamicBindSym".}
proc getSym(x: typedesc): NimNode = bindSym($x)

test "Check object has a property":
  const passed = static:
    var res = true
    for field, value in Person().fieldPairs:
      let fieldName =  astToStr(field).strip(chars = {'"'})
      if not Person.getSym().hasProperty(fieldName):
        checkpoint("Doesn't have: " & fieldName)
        res = false
    res
  check passed
