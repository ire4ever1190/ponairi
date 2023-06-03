## Stores all the data for our tess

import ../src/ponairi
import std/[
  options,
  strformat
]

when (NimMajor, NimMinor) < (1, 7):
  {.experimental: "overloadableEnums".}

type
  Status* = enum
    Alive
    Dead
    Undead # Our schema supports zombie apocalypse

  Person* {.table.} = object
    name* {.primary.}: string
    age*: int
    status*: Status
    extraInfo*: Option[string]

  Dog* {.table.} = ref object
    name* {.primary.}: string
    owner* {.references(Person.name), cascade.}: string

  Something* {.table.} = object
    name*, age*: string
    another* {.references: Person.name, cascade.}: string
    price*: float

func `$`*(d: Dog): string =
  if d != nil:
    fmt"{d.name} -> {d.owner}"
  else:
    "nil"

func `==`*(a, b: Dog): bool =
  a.name == b.name and a.owner == b.owner


const
  jake* = Person(name: "Jake", age: 42, status: Alive)
  john* = Person(name: "John", age: 45, status: Dead, extraInfo: some "Test")
  people* = [jake, john]
  everybody* = seq[Person].where(1 == 1)


proc `<`*(a, b: Person): bool =
  a.age < b.age

let jakesDogs* = [
  Dog(owner: "Jake", name: "Dog"),
  Dog(owner: "Jake", name: "Bark"),
  Dog(owner: "Jake", name: "Woof"),
  Dog(owner: "Jake", name: "something")
]

export ponairi
