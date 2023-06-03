import std/[
  unittest,
  options,
  times,
  strformat,
  algorithm,
  strutils,
  times
]
import data
import ponairi


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

  test "Upsert check fields exist":
    # This isn't in testament tests since it kept getting the file wrong
    check not compiles(db.upsert(jake, test))

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

  test "Can access outer table in inner call":
    check db.find(seq[Person].where(
      exists(Dog.where(owner == Person.name))
    )) == @[jake]

  test "Can perform nil checks":
    check db.find(seq[Person].where(extraInfo.isSome)) == @[jake]
    check db.find(seq[Person].where(extraInfo.isNone())) == @[john]

  test "Inside array":
    const query = seq[Person].where(age in [42, 45, 46])
    check query.whereExpr == "Person.age IN (42, 45, 46)"
    check db.find(query) == people

  test "In range":
    check db.find(seq[Person].where(age in 0..<45)) == @[jake]

  test "Pattern matching":
    check db.find(seq[Person].where(name ~= "%Ja%")) == @[jake]

  test "Parameters":
    check db.find(Person.where(name == {"Jake"})) == jake
    check db.find(Person.where(age == {jake.age} and name == {jake.name})) == jake

  test "Parameters can be reused":
    let
      name = "Jake"
      age = 42
    const query = Person.where(name == {name} and name == {name})
    checkpoint query.whereExpr
    check query.whereExpr == "Person.name == ?1 AND Person.name == ?1"
    check db.find(Person.where(
      name == {name} and age == {age} and
      name == {name} and age == {age}
    )) == jake

  test "Can delete":
    db.delete(Person.where(age == 42))
    check db.find(seq[Person]) == @[john]
    db.insert(jake)

  test "Can check existance":
    check db.exists(Person.where(age == 42))

  test "Can get default value for option":
    check db.find(
      Person.where(name == {"Jake"} and extraInfo.get("Some value") == {"Some value"})
    ) == jake

  const everybody = seq[Person].where()

  test "Can set order of query":
    check db
      .find(everybody.orderBy([asc age]))
      .isSorted(Ascending)

    check db
      .find(everybody.orderBy([desc age]))
      .isSorted(Descending)

  test "Can set null order":
    check db
      .find(everybody.orderBy([nullsFirst extraInfo]))[0]
      .extraInfo.isNone()

    check db
      .find(everybody.orderBy([nullsLast extraInfo]))[0]
      .extraInfo.isSome()

  test "Multiple orderings can be passed":
    # More just checking the query actually runs, I trust sqlite to work
    discard db.find(everybody.orderBy([asc age, desc name]))

  test "Works in overloaded templates":
    # This was a weird bug I found which was causing problems when used in async (Due to a feature I implemented funnyily enough)
    # Not an issue with async, but for some reason overloaded templates in general caused issues.
    #
    # For future reference in case this ever pops up again:
    # The problem was me assigning the query to a temporary const, not doing that fixed it (Guessing it was some weird sem matching problem)
    template foo(x: string) =
      echo x
    template foo(x: untyped) =
      discard x
    foo:
      db.find(Person.where())

  test "Works inside a proc":
    # Was running into a environment misses issue.
    # Issue was that I was building the parameters inside the find proc and so it couldn't access the outside scope.
    # worked in some circumstances since it could access global variables
    proc test() =
      let name = jake.name
      const query = Person.where(name == {name})
      check db.find(query) == jake
      check db.exists(query)
      db.delete(query)
      db.insert jake
    test()

  test "Has environment inside iterator":
    proc test() =
      for person in people:
        check db.exists(Person.where(name == {person.name}))
    test()

  test "Works with lent[T]":
    proc test() =
      for person in @people:
        const query = Person.where(name == {person.name})
        check db.find(query) == person
        check db.exists(query)
    test()
