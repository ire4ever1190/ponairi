import std/[
  unittest,
  options,
  times,
  strformat
]
import ponairi

type
  Status = enum
    Alive
    Dead
    Undead # Our schema supports zombie apocalypse

  Person = object
    name {.primary.}: string
    age: int
    status*: Status
    extraInfo: Option[string]

  Dog* = ref object
    name {.primary.}: string
    owner* {.references(Person.name), cascade.}: string

  Something* = object
    name*, age*: string
    another {.references: Person.name, cascade.}: string

func `$`(d: Dog): string =
  if d != nil:
    fmt"{d.name} -> {d.owner}"
  else:
    "nil"

func `==`(a, b: Dog): bool =
  a.name == b.name and a.owner == b.owner





const
  jake = Person(name: "Jake", age: 42, status: Alive)
  john = Person(name: "John", age: 45, status: Dead, extraInfo: some "Test")
  people = [jake, john]


let jakesDogs = [
  Dog(owner: "Jake", name: "Dog"),
  Dog(owner: "Jake", name: "Bark"),
  Dog(owner: "Jake", name: "Woof"),
  Dog(owner: "Jake", name: "something")
]

suite "Base API":
  let db = newConn(":memory:")

  test "Table creation":
    db.create(Person, Dog, Something)

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

  test "Upsert can ignore fields":
    let oldVal = jake
    var person = jake
    person.age = int.high
    db.upsert(person, age)
    check db.find(Option[Person], sql"SELECT * FROM Person WHERE age = ?", person.age).isNone()

  test "Upsert a sequence":
    db.upsert(jakesDogs)

  test "Upsert check fields exist":
    check not compiles(db.upsert(jake, test))

  test "Finding to tuples":
    let pairs = db.find(seq[tuple[owner: string, dog: string]], sql"SELECT Person.name, Dog.name FROM Dog JOIN Person ON Person.name = Dog.owner ")
    for row in pairs:
      check row.owner == "Jake"
      check row.dog != ""

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

suite "Query builder":
  let db = newConn(":memory:")
  db.create(Person, Dog)
  db.insert(people)
  db.insert(jakesDogs)

  test "Find one":
    check db.find(Person.where(name == "Jake")) == jake

  test "Find multiple":
    check db.find(seq[Person].where(age > 40)) == @people

  test "Exists":
    check db.exists(Person.where(name == "Jake"))
    check not db.exists(Person.where(age < 10))

  test "Inner SQL exists":
    check db.exists(Person.where(
      exists(Dog.where(owner == "Jake")))
    )

  test "Can't use property that doesn't exist":
    check not compiles(Person.where(unknown == "test"))

  test "Scope changes when directly accessing table":
    check not compiles(Person.where(
      exists(Dog.where(owner == Person.owner))
    ))

  test "Can only access tables that are in scope":
    check not compiles(Person.where(Dog.name == "test"))

  test "Can access outer table in inner call":
    check db.find(seq[Person].where(
      exists(Dog.where(owner == Person.name))
    )) == @[jake]

  test "Types are checked":
    check not compiles(db.find(Person.where(name == 9)))

  test "Can perform nil checks":
    check db.find(seq[Person].where(extraInfo.isSome)) == @[jake]
    check db.find(seq[Person].where(extraInfo.isNone())) == @[john]

  test "Inside array":
    check db.find(seq[Person].where(age in [42, 45, 46])) == people

  test "In range":
    check db.find(seq[Person].where(age in 0..<45)) == @[jake]

  test "Pattern matching":
    check db.find(seq[Person].where(name ~= "%Ja%")) == @[jake]

  test "Parameters":
    check db.find(Person.where(name == ?string), "Jake") == jake
    check db.find(Person.where(name == ?[1, string]), "Jake") == jake
    check db.find(Person.where(age == ?[1, int]), 42) == jake
