import std/macros
import std/strformat
import std/parseutils
import std/macrocache
import std/strutils
import std/options
import std/times
import ndb/sqlite

type
  Pragma = object
    ## Represents a pragma attached to a field/table
    name: string
    parameters: seq[NimNode]

  Property = object
    ## Represents a property of an object
    name: string
    typ: NimNode
    # I don't think a person will have too many pragmas so a seq should be fine for now
    pragmas: seq[Pragma]

const dateFormat = "yyyy-MM-dd HH:mm:ss'.'fff"

func initPragma(pragmaVal: NimNode): Pragma =
  ## Creates a pragma object from nnkPragmaExpr node
  if pragmaVal.kind == nnkCall:
    result.name = pragmaVal[0].strVal
    for parameter in pragmaVal[1..^1]:
      result.parameters &= parameter
  else:
    result.name = pragmaVal.strVal

func getTable(pragma: Pragma): string =
  ## Returns name of table for references pragma
  pragma.parameters[0][0].strVal

func getColumn(pragma: Pragma): string =
  ## Returns name of column for references pragma
  pragma.parameters[0][1].strVal

# I know these operations are slow, but I want to make it work first
func contains(items: seq[Pragma], name: string): bool =
  for item in items:
    if item.name.eqIdent(name): return true

func `[]`(items: seq[Pragma], name: string): Pragma =
  for item in items:
    if item.name.eqIdent(name): return item

func isOptional(prop: Property): bool =
  ## Returns true if the property has an optional type
  result = prop.typ.kind == nnkBracketExpr and prop.typ[0].eqIdent("Option")

func isPrimary(prop: Property): bool =
  ## Returns true if the property is a primary key
  result = "primary" in prop.pragmas

func sqlType*(T: typedesc[string]): string {.inline.} = "TEXT"
func sqlType*(T: typedesc[SomeInteger]): string {.inline.} = "INTEGER"
func sqlType*(T: typedesc[bool]): string {.inline.} = "BOOL"
func sqlType*[V](T: typedesc[Option[V]]): string {.inline.} = sqlType(V)
# We store Time as UNIX time and DateTime in sqlites format (Both in utc)
func sqlType*(T: typedesc[Time]): string {.inline.} = "INTEGER"
func sqlType*(T: typedesc[DateTime]): string {.inline.} = "TEXT"

template primary*() {.pragma.}
  ## Make the column be a primary key
template autoIncrement*() {.pragma.}
  ## Make the column auto increment
template references*(column: untyped) {.pragma.}
  ## Specify the column that the field references
template cascade*() {.pragma.}
  ## Turns on cascade deletion for a foreign key reference

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

template transaction(db; body: untyped) =
  ## Runs the body in a transaction.
  ## If any error happens then it rolls back the transaction
  db.startTransaction()
  try:
    body
    db.commit()
  except CatchableError, Defect: # Should I catch Defect?
    db.rollback()
    raise

proc getProperties(impl: NimNode): seq[Property] =
  for identDef in impl[2][2]:
    for property in identDef[0 ..< ^2]:
      var newProp = Property(typ: identDef[^2])
      if property.kind == nnkPragmaExpr:
        newProp.name = property[0].strVal
        for pragma in property[1]:
          newProp.pragmas &= initPragma(pragma)
      else:
        newProp.name = $property
      result &= newProp

proc lookupImpl(T: NimNode): NimNode =
  ## Performs a series of magical lookups to get the original
  ## type def of something
  result = T
  while result.kind != nnkTypeDef:
    case result.kind
    of nnkSym:
      let impl = result.getImpl()
      if impl.kind == nnkNilLit:
        result = result.getTypeImpl()
      else:
        result = impl
    of nnkBracketExpr:
      result = result[1]
    of nnkIdentDefs:
      result = result[0].getTypeInst()
    else:
      echo result.treeRepr
      "Beans misconfigured: Could not look up type".error(T)


macro createSchema(T: typedesc[object]): SqlQuery =
  ## Returns a string that can be used to create a table in a database
  let impl = T.lookupImpl()
  result = newLit(fmt"CREATE TABLE IF NOT EXISTS {impl[0].strVal} (")
  let properties = impl.getProperties()
  # Keep list of primary keys so that we can generate them last.
  # This enables composite primary keys
  var primaryKeys: seq[string]
  # Sqlite only allows for one auto increment primary key
  var hasAutoPrimary = false
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
    if "autoIncrement" in property.pragmas and "primary" in property.pragmas:
      if hasAutoPrimary:
        "Only one auto incremented primary key is allowed".error(impl[0])
      hasAutoPrimary = true
      result.join " PRIMARY KEY AUTOINCREMENT"

    elif "primary" in property.pragmas:
      primaryKeys &= property.name

    elif "references" in property.pragmas:
      # Check the reference has correct syntax
      let pragma = property.pragmas["references"]
      let refParam = pragma.parameters[0]
      if refParam.kind != nnkDotExpr:
        "Reference must be in object.field notation".error(refParam)

      result.join fmt" REFERENCES {refParam[0].strVal}({refParam[1].strVal})"
      if "cascade" in property.pragmas:
        result.join " ON DELETE CASCADE "
    if i < properties.len - 1:
      result.join ", "
  if primaryKeys.len > 0:
    result.join ", PRIMARY KEY (" & primaryKeys.join(", ") & ")"
  result.join ")"
  result = sqlLit(result)

macro createInsert[T: object](table: typedesc[T]): SqlQuery =
  ## Returns a string that can be used to insert an object into the database
  let impl = table.lookupImpl()
  result = newLit(fmt"INSERT INTO {$impl[0]} (")
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

macro createUpsert[T: object](table: typedesc[T]): SqlQuery =
  ## Returns a string that can be used to insert or update an object into the database
  result = newCall("string", newCall(bindSym"createInsert", table))
  let impl = table.lookupImpl()
  let properties = impl.getProperties()
  var
    conflicts: seq[string]
    updateStmts: seq[string]
  for property in properties:
    if "primary" in property.pragmas:
      conflicts &= property.name
    else:
      updateStmts &= fmt"{property.name}=excluded.{property.name}"
  if conflicts.len == 0:
    fmt"Upsert doesn't work on {impl[0].strVal} since it has no primary keys".error(table)
  result.join fmt""" ON CONFLICT ({conflicts.join(" ,")}) DO UPDATE SET {updateStmts.join(" ,")}"""
  result = sqlLit(result)

template insertImpl() =
  const query {.inject.} = createInsert(T)
  var params {.inject.}: seq[DbValue]
  for name, field in item.fieldPairs:
    # Insert fields, but ignore anything with autoIncrement since we want the database to generate that
    when not field.hasCustomPragma(autoIncrement):
      params &= dbValue(field)

proc insert*[T: object](db; item: T) =
  ## Inserts an object into the database
  insertImpl()
  db.exec(query, params)

proc insertID*[T: object](db; item: T): int64 =
  insertImpl()
  db.insertID(query, params)

proc insert*[T: object](db; items: openArray[T]) =
  ## Inserts the list of items into the database.
  ## This gets ran in a transaction so if an error happens then none
  ## of the items are saved to the database
  db.transaction:
    for item in items:
      db.insert item

proc upsert*[T: object](db; item: T) =
  ## Trys to insert an item into the database. If it conflicts with an
  ## existing item then it insteads updates the values to reflect item.
  ##
  ## .. note:: This checks for conflicts on primary keys only and so won't work if your object has no primary keys
  const query = createUpsert(T)
  var params: seq[DbValue]
  for name, field in item.fieldPairs:
    params &= dbValue(field)
  db.exec(query, params)

proc upsert*[T: object](db; items: openArray[T]) =
  ## Upsets a list of items into the database
  ##
  ## - See [upsert(DbConn, T)]
  ## - See [insert(DbConn, openArray[T])]
  db.transaction:
    for item in items:
      db.upsert item

proc create*[T: object](db; table: typedesc[T]) =
  ## Creates a table in the database that reflects an object
  const schema = createSchema(T)
  db.exec(schema)

proc drop*[T: object](db; table: typedesc[T]) =
  ## Drops a table from the database
  const stmt = "DROP TABLE IF EXISTS " & $T
  db.exec(stmt)

proc dbValue*(b: bool): DbValue =
  result = DbValue(kind: dvkInt, i: if b: 1 else: 0)

proc dbValue*(d: DateTime): DbValue =
  result = DbValue(kind: dvkString, s: d.utc.format(dateFormat))

proc dbValue*(t: Time): DbValue =
  result = DbValue(kind: dvkInt, i: t.toUnix())

func to*(src: DbValue, dest: var string) {.inline.} = dest = src.s
func to*[T: SomeInteger](src: DbValue, dest: var T) {.inline.} = dest = T(src.i)
func to*[T](src: DbValue, dest: var Option[T]) =
  if src.kind != dvkNull:
    var val: T
    src.to(val)
    dest = some val
func to*(src: DbValue, dest: var bool) {.inline.} = dest = src.i == 1
func to*(src: DbValue, dest: var Time) {.inline.} = dest = src.i.fromUnix()
proc to*(src: DbValue, dest: var DateTime) {.inline.} = dest = src.s.parse(dateFormat, utc())

proc to*[T: object | tuple](row: Row, dest: var T) =
  var i = 0
  for field, value in dest.fieldPairs:
    row[i].to(value)
    i += 1

macro load*[C: object](db; child: C, field: untyped): object =
  ## Loads parent from child using field
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
  fmt"{field} is not a property of {impl[0]}".error(field)

proc find*[T: object | tuple](db; table: typedesc[T], query: SqlQuery, args): T =
  ## Returns first row that matches **query**
  let row = db.getRow(query, args)
  doAssert row.isSome(), "Could not find row in database"
  row.unsafeGet().to(result)

proc find*[T: object](db; table: typedesc[Option[T]], query: SqlQuery, args): Option[T] =
  ## Returns first row that matches **query**. If nothing matches then it returns `none(T)`
  let row = db.getRow(query, args)
  if row.isSome:
    var res: T
    row.unsafeGet().to(res)
    result = some res

iterator find*[T: object | tuple](db; table: typedesc[seq[T]], query: SqlQuery, args): T =
  for row in db.rows(query, args):
    var res: T
    row.to(res)
    yield res

iterator find*[T: object | tuple](db; table: typedesc[seq[T]]): T =
  ## Returns all rows that belong to **table**
  for row in db.find(table, sql("SELECT * FROM " & $T)):
    yield row

macro createUniqueWhere[T: object](table: typedesc[T], ): string =
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
  result = newLit (columns).join(" AND ")

proc delete*[T: object](db; item: T) =
  ## Tries to delete item from table. Does nothing if it doesn't exist
  const stmt = sql(fmt"DELETE FROM {$T} WHERE " & createUniqueWhere(T))
  var params: seq[DbValue]
  for name, field in item.fieldPairs:
    params &= dbValue(field)
  db.exec(stmt, params)

proc exists*[T: object](db; item: T): bool =
  ## Returns true if item already exists in the database
  const
    whereClause = createUniqueWhere(T)
    stmt = sql(fmt"SELECT EXISTS (SELECT 1 FROM {$T} WHERE {whereClause} LIMIT 1)")
  var params: seq[DbValue]
  for name, field in item.fieldPairs:
    params &= dbValue(field)
  result = db.getValue[:int64](stmt, params).unsafeGet() == 1

export sqlite
