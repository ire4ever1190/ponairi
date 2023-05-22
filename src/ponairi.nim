import std/[
  macros,
  strformat,
  macrocache,
  strutils,
  options,
  times,
  tables
]

import lowdb/sqlite {.all.}
from db_connector/sqlite3 import SQLITE_OK, reset, PStmt, prepare_v2

import ponairi/[
  pragmas,
  macroUtils
]

##[
Pónairí can be used when all you need is a simple ORM for CRUD tasks.

 - **C**reate: [insert] can be used for insertion
 - **R**ead: [find] is used with a type based API to perform selections on your data
 - **U**pdate: [upsert] will either insert or update your data
 - **D**elete: [delete] does what it says on the tin, deletes

Currently there is not support for auto migrations and so you'll need to perform those yourself
if modifying the schema

## Getting started

After installing the library through nimble (or any other means) you'll want to open a connection with [newConn] which will be used
for all interactions with the database.
While this library does just use the connection object from [lowdb](https://github.com/xzfc/lowdb.nim), it is best to use
this since it configures certain settings to make things like foreign keys work correctly

```nim
let db = newConn(":memory:") # Or pass a path to a file
```

After that your first step will be creating your schema through objects and then using [create] to build them in the database

```nim
type
  # Create your objects like any other object.
  # You then use pragmas to control aspects of the columns
  Person = object
    name {.primary.}: string
    age: int

  Item = object
    ## An item is just something owned by a person
    id {.autoIncrement, primary.}: int
    name: string
    # Add a one-to-many relation (one person owns many objects)
    owner {.references: Person.name.}: string

# We can also run db.drop(Type) if we want to drop a table
db.create(Person)
db.create(Item)
```

Now you'll probably want to start doing some CRUD tasks which is very easy to do

#### Create

Just call [insert] with an object of your choice

```nim
db.insert(Person(name: "Jake", age: 42))
```

#### Read

[find] is used for all operations relating to getting objects from a database.
It uses a type based API where the first parameter (after the db connection) determines the return type.
Currently most tasks require you to write SQL yourself but this will hopefully change in the future

```nim
# Gets the Object we created before
assert db.find(Person, sql"SELECT * FROM Person WHERE name = 'Jake'").age == 42

# We can use Option[T] to handle when a query might not return a value
# It would return an exception otherwise
import std/options
assert db.find(Option[Person], sql"SELECT * FROM Person WHERE name = 'John Doe'").isNone

# We can use seq[T] to return all rows that match the query
for person in db.find(seq[Person], sql"SELECT * FROM Person WHERE age > 1"):
  echo person
# This can also be used to get every row in a table
for person in db.find(seq[Person]):
  echo person
```

#### Update

Updating is done with the [upsert] proc. This only works for tables with primary keys since it needs
to be able to find the old object to be able to update it. If object doesn't exist then this acts
like a normal insert

```nim
# Lets use the person we had before, but make them travel back in time
let newPerson = Person(name: "Jake", age: 25)
db.upsert(newPerson)
```

#### Delete

Deleting is done via [delete] and requires passing the object that should be deleted.
It finds the row to delete by either matching the primary keys or comparing all the values (If there is no primary keys defined)

```nim
db.delete(Person(name: "Jake"))
```

## Custom types

Custom types can be added by implementing three functions

- [sqlType]: Returns a string that will be the type to use in the SQL table
- [dbValue]: For converting from the type to a value the database can read (See [lowdb DbValue](https://philippmdoerner.github.io/lowdb/lowdb/sqlite.html#DbValue))
- [to]: For converting from the database value back to the Nim type

Here is an example of implementing these for [SecureHash](https://nim-lang.org/docs/sha1.html#SecureHash).
This code isn't very performant (performs unneeded copies) but is more of an example
]##

runnableExamples:
  import std/sha1

  # Its just an array of bytes so blob is the best storage type
  proc sqlType(t: typedesc[SecureHash]): string = "BLOB"

  proc dbValue(s: SecureHash): DbValue =
    # We need to convert it into a blob for the database
    # SHA1 hashes are 20 bytes in length
    var blob = newString(20)
    for i in 0..<20:
      blob[i] = char(Sha1Digest(s)[i])
    DbValue(kind: dvkBlob, b: DbBlob(blob))

  proc to(src: DbValue, dest: var SecureHash) =
    for i in 0..<20:
      Sha1Digest(dest)[i] = uint8(string(src.b)[i])

  type
    User = object
      # Usually you would add some salt and pepper and use a more cryptographic hash.
      # But once again, this is an example
      username {.primary.}: string
      password: SecureHash

  let db = newConn(":memory:")
  db.create(User)

  let user = User(
    username: "coolDude",
    password: secureHash("laptop")
  )
  # We will now show that we can send the user to the DB and get the same values back
  db.insert user
  assert db.find(User, sql"SELECT * FROM User") == user
#==#

type
  SomeTable* = ref[object] | object
    ## Supported types for reprsenting table schema

const dateFormat = "yyyy-MM-dd HH:mm:ss'.'fff"

func sqlType*(T: typedesc[string]): string {.inline.} = "TEXT"
func sqlType*(T: typedesc[SomeOrdinal]): string {.inline.} = "INTEGER"
func sqlType*(T: typedesc[bool]): string {.inline.} = "BOOL"
func sqlType*[V](T: typedesc[Option[V]]): string {.inline.} = sqlType(V)
func sqlType*(T: typedesc[SomeFloat]): string {.inline.} = "REAL"
# We store Time as UNIX time and DateTime in sqlites format (Both in utc)
func sqlType*(T: typedesc[Time]): string {.inline.} = "INTEGER"
func sqlType*(T: typedesc[DateTime]): string {.inline.} = "TEXT"

using db: DbConn
using args: varargs[DbValue, dbValue]

proc join(x: var NimNode, y: string) =
  ## Appends two string literal nodes together
  x = nnkInfix.newTree(ident "&", x, newLit(y))

proc join(x: var NimNode, y: NimNode) =
  ## Appends a string literal node with another node
  x = nnkInfix.newTree(ident "&", x, y)

proc sqlLit(x: NimNode): NimNode =
  ## Makes the string become an sql string literal
  result = newCall("sql", x)

proc newConn*(file: string): DbConn =
  ## Sets up a new connection with needed configuration.
  ## File is just a normal sqlite file string
  result = open(file, "", "", "")
  # Needs to be turned on to enable cascade deletion and actual checking of foreign keys
  result.exec(sql"PRAGMA foreign_keys = ON");

proc startTransaction*(db) =
  ## Starts a transaction context
  db.exec(sql"BEGIN TRANSACTION")

proc rollback*(db) =
  ## Runs a rollback on the current transaction
  db.exec(sql"ROLLBACK")

proc commit*(db) =
  ## Commits a transaction
  db.exec(sql"COMMIT")

template transaction*(db; body: untyped) =
  ## Runs the body in a transaction.
  ## If any error happens then it rolls back the transaction
  db.startTransaction()
  try:
    body
    db.commit()
  except CatchableError, Defect:
    db.rollback()
    raise

proc getName(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym:
    result = n.strVal
  of nnkPostFix:
    result = n[1].getName()
  of nnkTypeDef:
    result = n[0].getName()
  else:
    echo n.treeRepr
    assert false, "Name is invalid"

proc getProperties(impl: NimNode): seq[Property] =
  let identDefs = if impl[2].kind == nnkRefTy: impl[2][0][2] else: impl[2][2]
  for identDef in identDefs:
    for property in identDef[0 ..< ^2]:
      var newProp = Property(typ: identDef[^2])
      if property.kind == nnkPragmaExpr:
        newProp.name = property[0].getName
        for pragma in property[1]:
          newProp.pragmas &= initPragma(pragma)
      else:
        newProp.name = property.getName
      result &= newProp

template fieldPairs(x: ref object): untyped = fieldPairs(x[])

macro createSchema(T: typedesc[SomeTable]): SqlQuery =
  ## Returns a string that can be used to create a table in a database
  let
    impl = T.lookupImpl()
    tableName = impl.getName()
  # TODO: Try and remember why I create a string node instead of making string directly
  result = newLit(fmt"CREATE TABLE IF NOT EXISTS {tableName} (")
  let properties = impl.getProperties()
  var
    # Keep list of primary keys so that we can generate them last.
    # This enables composite primary keys
    primaryKeys: seq[string]
    # Track what indexes we need to build after the table
    # Mapping of index name -> columns
    indexes: Table[string, tuple[unique: bool, columns: seq[string]]]
    # Sqlite only allows for one auto increment primary key
    hasAutoPrimary = false
  # We now generate all the columns
  for i in 0..<properties.len:
    let property = properties[i]
    # We start by adding a type which makes a call to sqlType() to allow overridding
    result.join property.name & " "
    # Using parseExpr was easiest way to desym the whole type
    result.join newCall("sqlType", parseExpr repr property.typ)
    # If the parameter isn't then we want it to be NOT NULL
    if not property.isOptional():
      result.join " NOT NULL"
    # Go through pragmas and see how we need to change the column definition
    # This needs to be done in a loop so we can properly line up pragmas with their arguments
    for pragma in property.pragmas:
      case nimIdentNormalize pragma.name
      of "index", "uniqueindex":
        let
          name = if pragma.parameters[0].strVal.isEmptyOrWhitespace(): property.name
                 else: pragma.parameters[0].strVal
          isUnique = pragma.name.eqIdent("uniqueIndex")
          extraKeyPrefix = if isUnique: "unique_" else: ""
          key = fmt"""{tableName}_index_{extraKeyPrefix}{name}"""
        if key notin indexes:
          indexes[key] = (isUnique, @[property.name])
        else:
          indexes[key].columns &= property.name
      of "references":
         # Check the reference has correct syntax
        let refParam = pragma.parameters[0]
        if refParam.kind != nnkDotExpr:
          "Reference must be in object.field notation".error(refParam)

        result.join fmt" REFERENCES {refParam[0].strVal}({refParam[1].strVal})"
        if "cascade" in property.pragmas:
          result.join " ON DELETE CASCADE "

    # Primary keys and autoIncrement need to be handled together
    # so we work with them outside the loop
    if "autoIncrement" in property.pragmas and "primary" in property.pragmas:
      if hasAutoPrimary:
        "Only one auto incremented primary key is allowed".error(impl[0])
      hasAutoPrimary = true
      result.join " PRIMARY KEY AUTOINCREMENT"
    elif "primary" in property.pragmas:
      primaryKeys &= property.name

    if i < properties.len - 1:
      result.join ", "
  if primaryKeys.len > 0:
    result.join ", PRIMARY KEY (" & primaryKeys.join(", ") & ")"
  result.join ");"
  # Add in the indexes
  for index, (unique, columns) in indexes:
    result.join fmt"""CREATE INDEX IF NOT EXISTS {index} ON {tableName} ({columns.join(", ")});"""
  result = sqlLit(result)

macro createInsert[T: SomeTable](table: typedesc[T]): SqlQuery =
  ## Returns a string that can be used to insert an object into the database
  let impl = table.lookupImpl()
  result = newLit(fmt"INSERT INTO {impl.getName()} (")
  let properties = impl.getProperties()
  var
    columns = ""
    variables = ""
  for i in 0..<properties.len:
    let property = properties[i]
    if "autoIncrement" in property.pragmas: continue
    columns &= property.name
    variables &= "?"
    if i < properties.len - 1:
      columns &= ", "
      variables &= ", "
  result.join fmt"{columns}) VALUES ({variables})"
  result = sqlLit(result)

macro createUpsert[T: SomeTable](table: typedesc[T], excludeProps: openArray[string]): SqlQuery =
  ## Returns a string that can be used to insert or update an object into the database
  result = newCall("string", newCall(bindSym"createInsert", table))
  let impl = table.lookupImpl()
  let properties = impl.getProperties()
  var
    conflicts: seq[string]
    updateStmts: seq[string]
    excludes: seq[string]
  # Check all the excluded properties exist
  for prop in excludeProps:
    if not table.hasProperty(prop):
      fmt"{prop} doesn't exist in {impl.getName()}".error(prop)
    excludes &= prop.strVal

  for property in properties:
    if "primary" in property.pragmas:
      conflicts &= property.name
    elif property.name notin excludes:
      updateStmts &= fmt"{property.name}=excluded.{property.name}"
  if conflicts.len == 0:
    fmt"Upsert doesn't work on {impl.getName()} since it has no primary keys".error(table)
  result.join fmt""" ON CONFLICT ({conflicts.join(" ,")}) DO UPDATE SET {updateStmts.join(", ")}"""
  result = sqlLit(result)

template makeParams[T](item: T): seq[DbValue] =
  var params {.inject.}: seq[DbValue]
  for name, field in item.fieldPairs:
    # Insert fields, but ignore anything with autoIncrement since we want the database to generate that
    when not field.hasCustomPragma(autoIncrement):
      params &= dbValue(field)
  params

proc insert*[T: SomeTable](db; item: T) =
  ## Inserts an object into the database
  const query = createInsert(T)
  db.exec(query, makeParams item)

proc insertID*[T: SomeTable](db; item: T): int64 =
  ## Inserts an object and returns the auto generated ID
  const query = createInsert(T)
  db.insertID(query, makeParams item)

template checkSQL(x: bool) =
  if not x:
    dbError(db)

template checkSQL(x: Option) =
  if isNone(x):
    dbError(db)

template checkSQL(x: int32) =
  if x != SQLITE_OK:
    dbError(db)

proc insert*[T: SomeTable](db; items: openArray[T]) =
  ## Inserts the list of items into the database.
  ## This gets ran in a transaction so if an error happens then none
  ## of the items are saved to the database
  const query = createInsert(T)
  db.transaction:
    # We build the statement, then reuse it when inserting.
    # This duplicates a lot of code from lowdb :(
    # TODO: Maybe try and get something like this moved upstream to lowdb
    assert(not db.isNil, "Database not connected.")
    var stmt: Pstmt
    defer:
      # Make sure to clean up
      if stmt != nil:
        checkSQL tryFinalize(stmt)
    checkSQL prepare_v2(db, query.cstring, query.string.len.cint, stmt, nil)
    # Now we need to
    #  - bind args from items
    #  - run query
    #  - reset statement
    # for each item
    for item in items:
      # TODO: Make PR to remove query, it isn't used
      checkSQL db.bindArgs(stmt, query, makeParams(item))
      # Run the statement
      discard next(stmt)
      checkSQL reset(stmt)


proc upsertImpl[T: SomeTable](db; item: T, exclude: static[openArray[string]] = []) =
  const query = createUpsert(T, exclude)
  var params: seq[DbValue]
  for name, field in item.fieldPairs:
    params &= dbValue(field)
  db.exec(query, params)

proc upsertImpl[T: SomeTable](db; items: openArray[T], exclude: static[openArray[string]] = []) =
  db.transaction:
    for item in items:
      db.upsertImpl(item, exclude)

# We use a macro so we can get the items as nodes.
# Means that we can properly assign compile time errors to them

# Need to use untyped since macros currently have problems with matching openArray | T
macro upsert*(db; item: untyped, excludes: varargs[untyped]) =
  ##[
    Trys to insert an item (or items) into the database. If it conflicts with an
    existing item then it insteads updates the values to reflect item. If inserting a list of items
    then it is ran in a transaction

    If you don't want fields to be excluded then you can pass a list of fields to exclude in.

    ```nim
    # Using the person example we can show how to update
    var jake = db.find(Person, sql"SELECT * WHERE name = 'Jake'")
    jake.age = 100
    # We have now updated Jake in the database to be 100 years old
    db.upsert(jake)
    # If we want other fields untouched then we can exclude them.
    # This is handy if constructing the object yourself and not initialising all the fields.
    # If we didn't exclude age then Jake would become 0 years old
    db.upsert(Person(name: "Jake"), age)
    ```

    .. note:: This checks for conflicts on primary keys only and so won't work if your object has no primary keys
  ]##
  var excludedProps = nnkBracket.newTree()
  for prop in excludes:
    if prop.kind != nnkIdent:
      "Only properties can be excluded".error(prop)
    # Since we can't lookup the implementation of T here we instead
    # just build a list of props and then check if they exist later in createUpsert
    excludedProps &= newLit prop.strVal
  result = newCall(bindSym"upsertImpl", db, item, excludedProps)

proc create*[T: SomeTable](db; table: typedesc[T]) =
  ## Creates a table in the database that reflects an object
  runnableExamples:
    let db = newConn(":memory:")
    # Create object
    type Something = object
      foo, bar: int
    # Use `create` to make a table named 'something' with field reflecting `Something`
    db.create Something
  #==#
  const schema = createSchema(T)
  # TODO: Write PR for lowdb to run multiple sql queries at once
  for part in schema.string.split(';'):
    if not part.isEmptyOrWhitespace():
      db.exec(sql part)

macro create*(db; tables: varargs[typed]) =
  ## Creates multiple classes at once
  ##
  ## - See [create(db, table)]
  result = newStmtList()
  for table in tables:
    if table.kind != nnkSym:
      "Only type names should be passed".error(tables)
    result &= nnkCall.newTree(ident"create", db, table)

proc drop*[T: object](db; table: typedesc[T]) =
  ## Drops a table from the database
  const stmt = sql("DROP TABLE IF EXISTS " & $T)
  db.exec(stmt)

proc dbValue*(b: bool): DbValue =
  result = DbValue(kind: dvkInt, i: if b: 1 else: 0)

proc dbValue*(d: DateTime): DbValue =
  result = DbValue(kind: dvkString, s: d.utc.format(dateFormat))

proc dbValue*(t: Time): DbValue =
  result = DbValue(kind: dvkInt, i: t.toUnix())

func dbValue*(e: enum): DbValue =
  result = DbValue(kind: dvkInt, i: e.ord)

func to*(src: DbValue, dest: var string) {.inline.} = dest = src.s
func to*[T: SomeOrdinal](src: DbValue, dest: var T) {.inline.} = dest = T(src.i)
func to*[T: SomeFloat](src: DbValue, dest: var T) {.inline.} = dest = T(src.f)
func to*[T](src: DbValue, dest: var Option[T]) =
  if src.kind != dvkNull:
    when T is SomeTable:
      var val = T()
    else:
      var val: T
    src.to(val)
    dest = some val
func to*(src: DbValue, dest: var bool) {.inline.} = dest = src.i == 1
func to*(src: DbValue, dest: var Time) {.inline.} = dest = src.i.fromUnix()
proc to*(src: DbValue, dest: var DateTime) {.inline.} = dest = src.s.parse(dateFormat, utc())

proc to*[T: SomeTable | tuple](row: Row, dest: var T) =
  var i = 0
  # Make sure the ref object is initialised
  when T is ref:
    dest = T()
  # Convert the rows into the values.
  # If a tuple has an object inside it then we need to treat it like a JOIN i.e. the values are all in the row
  for field, value in dest.fieldPairs:
    when T is tuple and value is SomeTable:
      # Make sure refs are initialised
      when value is ref:
        value = typeof(value)()
      # Now do its children
      for f, v in value.fieldPairs:
        row[i].to(v)
        i += 1
    else:
      row[i].to(value)
      i += 1

macro load*[C: SomeTable](db; child: C, field: untyped): object =
  ## Loads parent from child using field
  runnableExamples:
    let db = newConn(":memory:")

    type
      User = object
        id {.primary, autoIncrement.}: int64
        name: string
      Item = object
        id {.primary, autoIncrement.}: int64
        owner {.references: User.id.}: int64
        name: string

    db.create(User, Item)

    let
      ownerID = db.insertID(User(name: "Jake"))
      item = Item(owner: ownerID, name: "Lamp")
    db.insert(item)
    # We can now load the parent object that is referenced in the owner field
    assert db.load(item, owner).name == "Jake"
  #==#
  if field.kind != nnkIdent:
    "Field must just be the property of the child object that contains the relation".error(field)
  let impl = child.lookupImpl()
  let properties = impl.getProperties()
  for property in properties:
    if property.name.eqIdent(field):
      if "references" notin property.pragmas:
        "Field doesn't reference anything'".error(field)
      let reference = property.pragmas["references"]
      let
        table = reference.getTable()
        column = reference.getColumn()
      let query = fmt"SELECT * FROM {table} WHERE {column} = ?"
      return newCall("find", db, ident table, newCall("sql", newLit query), nnkDotExpr.newTree(child, field))
  fmt"{field} is not a property of {impl.getName()}".error(field)

proc find*[T: SomeTable | tuple](db; table: typedesc[T], query: SqlQuery, args): T =
  ## Returns first row that matches **query**
  let row = db.getRow(query, args)
  doAssert row.isSome(), "Could not find row in database"
  row.unsafeGet().to(result)

proc find*[T: SomeTable](db; table: typedesc[Option[T]], query: SqlQuery, args): Option[T] =
  ## Returns first row that matches **query**. If nothing matches then it returns `none(T)`
  let row = db.getRow(query, args)
  if row.isSome:
    var res: T
    row.unsafeGet().to(res)
    result = some res

iterator find*[T: SomeTable | tuple](db; table: typedesc[seq[T]], query: SqlQuery, args): T =
  for row in db.rows(query, args):
    var res = default(T)
    row.to(res)
    yield res

iterator find*[T: SomeTable | tuple](db; table: typedesc[seq[T]]): T =
  ## Returns all rows that belong to **table**
  for row in db.find(table, sql("SELECT * FROM " & $T)):
    yield row

proc find*[T: SomeTable | tuple](db; table: typedesc[seq[T]], query: SqlQuery, args): seq[T] =
  for row in db.find(table, query, args):
    result &= row

proc find*[T: SomeTable](db; table: typedesc[seq[T]]): seq[T] =
  for row in db.find(table):
    result &= row

proc explain*(db; query: SqlQuery): string =
  ## Returns the [query plan](https://www.sqlite.org/eqp.html) for a query
  db.getRow(sql("EXPLAIN QUERY PLAN " & query.string)).get()[3].to(result)

macro createUniqueWhere[T: SomeTable](table: typedesc[T]): (bool, string) =
  ## Returns a WHERE clause that can be used to uniquely identify an object in
  ## the table. If there are any primary keys, it will only use those in the WHERE clause.
  ## if there are no primary keys, they it will check every field
  # That doc comment is a lie, I have not implemented only primary key checking yet
  let impl = table.lookupImpl()
  let properties = impl.getProperties()
  var
    primaryKeys: seq[string]
    columns: seq[string]
  # Convert the properties into a series of where clauses
  for property in properties:
    # Optional values need to use IS so that null values can be compared
    let operator = if property.isOptional: "IS" else: "="
    let stmt = fmt"{property.name} {operator} ?"
    if property.isPrimary():
      primaryKeys &= stmt
    columns &= stmt
  # If there are some primary keys they we will only use those for the where clause.
  # Else we will use every other column
  # TODO: Actually use primary keys
  let usePrimary = primaryKeys.len > 0
  result = newLit (if usePrimary: primaryKeys else: columns).join(" AND ")
  result = nnkTupleConstr.newTree(newLit usePrimary, result)

template queryWithWhere(query: static[string], call: untyped): untyped =
  ## Replaces :where in **query** with a where clause that uniquely
  ## identifies a single item in the table
  ## Runs **call** with db, stmt, and params as parameters
  bind replace
  bind hasCustomPragma
  const
    (usePrimary, whereClause) = createUniqueWhere(T)
    stmt = query.replace(":where", whereClause).sql
  var params: seq[DbValue]
  for name, field in item.fieldPairs:
    when not usePrimary or field.hasCustomPragma(primary):
      params &= dbValue(field)
  # Having this call is just a hack, for some reason stmt wasn't made available in scope of where it was called
  call(db, stmt, params)

proc delete*[T: SomeTable](db; item: T) =
  ## Tries to delete item from table. Does nothing if it doesn't exist
  queryWithWhere(fmt"DELETE FROM {$T} WHERE :where", exec)

proc exists*[T: SomeTable](db; item: T): bool =
  ## Returns true if item already exists in the database
  queryWithWhere(fmt"SELECT EXISTS (SELECT 1 FROM {$T} WHERE :where LIMIT 1)", getValue[int64]).unsafeGet() == 1

export hasCustomPragma # Wouldn't bind
export replace
export pragmas
export sqlite
