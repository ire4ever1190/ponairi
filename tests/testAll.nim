import std/[
  unittest,
  options
]
import ponairi {.all.}

type
  Person = object
    name {.primary.}: string
    age: int
    alive*: bool
    extraInfo: Option[string]

  Dog* = object
    name {.primary.}: string
    owner* {.references(Person.name), cascade.}: string

  Something* = object
    name*, age*: string
    another {.references: Person.name, cascade.}: string


let db = newConn(":memory:")

test "Table creation":
  db.create(Person)
  db.create(Dog)
  db.create(Something)

const
  jake = Person(name: "Jake", age: 42, alive: true)
  john = Person(name: "John", age: 45, alive: false, extraInfo: some "Test")

const jakesDogs = [
  Dog(owner: "Jake", name: "Dog"),
  Dog(owner: "Jake", name: "Bark"),
  Dog(owner: "Jake", name: "Woof"),
  Dog(owner: "Jake", name: "something")
]

test "Insert":
  db.insert(jake)

test "Insert ID":
  check db.insertID(john) == 2

test "Find":
  check db.find(Person, sql"SELECT * FROM Person WHERE name = 'Jake'") == jake
  check db.find(Person, sql"SELECT * FROM Person WHERE name = 'John'") == john

test "Try find":
  check db.find(Option[Person], sql"SELECT * FROM Person WHERE name = 'John Doe'").isNone()
  check db.find(Option[Person], sql"SELECT * FROM Person").isSome()

test "Find all":
  check db.find(seq[Person]).len == 2

test "Insert with relation":
  db.insert(jakesDogs)

test "Find with relation":
  let dogs = db.find(seq[Dog], sql"SELECT * FROM Dog WHERE owner = 'Jake'")
  check dogs == jakesDogs

when false:
  test "Auto find with relation":
    check jakesDogs == db.findAllFor(Dog, Person)

test "Load parent in relation":
  let dog = jakesDogs[0]
  check db.load(dog, owner) == jake

test "Upsert":
  let oldVal = jakesDogs[0]
  var dog = jakesDogs[0]
  dog.name = "Soemthing else"
  check dog notin db.find(seq[Dog])
  db.upsert(dog)
  check dog in db.find(seq[Dog])
  db.upsert(oldVal)

test "Finding to tuples":
  let pairs = db.find(seq[tuple[owner: string, dog: string]], sql"SELECT Person.name, Dog.name FROM Dog JOIN Person ON Person.name = Dog.owner ")
  for row in pairs:
    check row.owner == "Jake"
    check row.dog != ""

test "Delete item":
  let dog = jakesDogs[0]
  db.delete(dog)
  check dog notin db.find(seq[Dog])
  db.insert(dog)

test "Exists":
  let dog = jakesDogs[0]
  check db.exists(dog)
  db.delete(dog)
  check not db.exists(dog)
  db.insert(dog)

test "Cascade deletion":
  db.delete(jake)
  check not db.exists(jake)
  check not db.exists(jake)
  for dog in jakesDogs:
    check not db.exists(dog)
  db.insert(jake)
  db.insert(jakesDogs)

import std/times
test "Store times":
  type
    Exercise = object
      # I know this doesn't make any sense
      time: Time
      date: DateTime
  db.create(Exercise)
  defer: db.drop(Exercise)

  var now = now()
  # SQLite doesn't store nanoseconds (Only milli) so we need to truncate to only seconds
  # or else they won't compare properly
  now = dateTime(now.year, now.month, now.monthday, now.hour, now.minute, now.second)
  let currTime = getTime().toUnix().fromUnix()

  let exercise = Exercise(time: currTime, date: now)
  db.insert(exercise)

  check db.find(seq[Exercise])[0] == exercise

test "Exists without primary key":
  type
    Basic = object
      a: string
      b: int
  db.create(Basic)
  defer: db.drop(Basic)

  let item = Basic(a: "foo", b: 9)
  check not db.exists(item)
  db.insert(item)
  check db.exists(item)

close db
