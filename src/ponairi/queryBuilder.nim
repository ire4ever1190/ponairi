import ndb/sqlite except `?`
import std/[
  macros,
  strformat,
  options,
  typetraits,
  macrocache,
  strutils,
  sequtils
]

import macroUtils, utils

##[

  ## User Guide

  Query builder that can be used to make type safe queries.
  This doesn't aim to replace SQL and so certain situations will still require you to write SQL.

  The query building is done with the [where][where(table)] macro which takes a Table (which will be the expected return type) and a Nim expression.
  The Nim expression is checked at compile time and then converted into SQL and so only the raw SQL string is stored. This means that there
  is no runtime overhead when using the query builder.

  Supported procedures are
  - [find][find]
  - [delete][delete]
  - [exists][exists]
]##

runnableExamples:
  import ponairi
  # First we define our schema
  type
    Customer = object
      ## A customer of the store
      name {.primary.}: string

    Item = object
      ## An item in the store
      name {.primary.}: string
      price: float

    Cart = object
      ## A cart containing the customers items that they are wanting to buy
      id {.primary, autoIncrement.}: int
      customer {.references: Customer.name.}: string

    CartItem = object
      ## Implements the many-to-many mapping of cart <-> item
      item {.primary, references: Item.name.}: string
      cart {.primary, references: Card.id.}: int

  let db = newConn(":memory:")
  db.create(Customer, Item, Cart, CartItem)

  # Now we can use the query builder to write some queries.
  # But first I'll show what it can protect against

  # Doesn't compile since the cart ID is an integer and not a string
  assert not compiles(Cart.where(id == "9"))
  # Doesn't compile since CartItem table isn't accessible currently
  assert not compiles(Cart.where(id == CartItem.item))


  # We can write simple queries to check columns
  db.insert Item(name: "Lamp", price: 9.0)
  assert db.find(Item.where(price > 5.0)).name == "Lamp"

  # Params can be passed inside {} just like std/strformat
  # Any nim expression is allowed
  assert db.find(Item.where(price > {3.0 + 2.0})).name == "Lamp"
  let someLowerLimit = 5.0
  assert db.find(Item.where(price > {someLowerLimit})).name == "Lamp"


  # We can also build complex sub queries. We will add in some more data
  # and then find all customers that have a Lamp in their cart
  db.insert Customer(name: "John Doe")
  let id = db.insertID Cart(customer: "John Doe")
  db.insert CartItem(item: "Lamp", cart: int(id))

  assert db.find(Customer.where(
      Cart.where(
        CartItem.where(item == "Lamp" and cart == Cart.id).exists()
      ).exists())
  ).name == "John Doe"

  # We can also order the fields

  # This will be used to check it is sorted, not needed for functionality
  import std/algorithm except SortOrder
  func `<`(a, b: Item): bool =
    a.price < b.price
  # Add some more items
  db.insert Item(name: "Table", price: 10.0)
  db.insert Item(name: "Chair", price: 5.0)
  # We pass the ordering to orderBy, multiple orderings can be passed
  # i.e. sort by first parameter, then by second if any are equal, ..., etc
  assert db.find(seq[Item].where().orderBy([asc name])).isSorted()

type
  ColumnOrder = object
    ## Info about an ordering.
    ## Column is a string so that it can suport extensions (LIKE FTS5).
    ## It is formatted with the column name later (Use $# as the place holder).
    column*: string
    order*: string
    line: LineInfo # Store line info so error messages are better later

  TableQuery*[T] = object
    ## This is a full query. Stores the type of the table it is accessing
    ## and the SQL that will be executed
    whereExpr*: QueryPart[bool]
    paramsIdx*: int # see `queryParameters` CacheSeq. This is the index into that
    order*: seq[ColumnOrder]

  PartKind* = enum
    Pattern
    Int
    Float
    Str
    Raw
    Bool
    Param

  PartBase* = object
    case kind*: PartKind
    of Pattern:
      pattern*: string
      args*: seq[PartBase]
    of Int:
      ival*: int
    of Float:
      fval*: float
    of Str, Raw:
      sval*: string
    of Bool:
      bval*: bool
    of Param:
      index*: int

  QueryPart*[T] = distinct PartBase
    ## This is a component of a query, stores the type that the SQL would return
    ## and also the SQL that it is

const queryParameters = CacheSeq"ponairi.parameters"
  ## We need to store the NimNode of parameters (Not the actual value)
  ## so that we can reconstruct the parameters.
  ## Each query is given an index which corresponds to the parameters for it
  ## Yes this is a hacky method
  ## but it was the best I could come up with.


func `$`(part: PartBase): string =
  case part.kind
  of Str:
    "'" & part.sval.escapeQuoteSQL() & "'"
  of Int:
    $part.ival
  of Float:
    $part.fval
  of Raw:
    part.sval
  of Bool:
    $part.bval
  of Param:
    "$" & $part.index
  else:
    part.pattern % part.args.mapIt($it)


func newQueryPart*[T: SomeInteger](val: T): QueryPart[T] =
  typeof(result) PartBase(kind: Int, ival: val)

func newQueryPart*[T: SomeFloat](val: T): QueryPart[T] =
  typeof(result) PartBase(kind: Float, fval: val)

func newQueryPart*(val: string): QueryPart[string] =
  typeof(result) PartBase(kind: Str, sval: val)

func newQueryPart*(val: bool): QueryPart[bool] =
  typeof(result) PartBase(kind: Bool, bval: val)

func newParamPart*[T](index: int, kind: typedesc[T]): QueryPart[T] =
  typeof(result) PartBase(kind: Param, index: index)

func newRawPart*[T](val: string, kind: typedesc[T]): QueryPart[T] =
  typeof(result) PartBase(kind: Raw, sval: val)

func newFormattedPart*[T](pattern: string, args: varargs[PartBase]): QueryPart[T] =
  ## Creates a part that puts its args into the pattern.
  ## Pattern follows the same as [strutils %](https://nim-lang.org/docs/strutils.html#%25%2Cstring%2CopenArray%5Bstring%5D).
  runnableExamples:
    assert $newQueryPart("$# + $#", 1, 1) == "1 + 1"
    assert $newQueryPart("$1 + $1", 9) == "9 + 9"
  #==#
  typeof(result) PartBase(
    kind: Pattern,
    pattern: pattern,
    args: @args
  )

func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

func tableName[T](x: typedesc[Option[T]]): string =
  result = $T

template makeOrder*(name: untyped, format: string, docs: untyped) =
  ## Allows you to create your own ordering. Use this to support other libraries.
  ##
  ## - `format`: supports a single optional `$#` which specifies where to place the column name
  runnableExamples:
    # FTS5 has a `rank` ordering which can be supported like so
    makeOrder(rank, "rank")
    # We can now use `rank` in an orderBy call
  #==#
  template name*(col: untyped): ColumnOrder =
    docs
    ColumnOrder(column: astToStr(col), order: format, line: currentLine())

makeOrder(asc, "$# ASC"):
  ## Make a column be in ascending order

makeOrder(desc, "$# DESC"):
  ## Make a column be in descending order

const
  # Store so we can check later
  nullsFirstStr = "$# NULLS FIRST"
  nullsLastStr = "$# NULLS LAST"

makeOrder(nullsFirst, nullsFirstStr):
  ## Makes `nil` values get returned first.
  ## Column must be optional

makeOrder(nullsLast, nullsLastStr):
  ## Makes `nil` values get returned last
  ## Column must be optional

func build(order: openArray[ColumnOrder]): string =
  ## Returns the ORDER BY clause. You probably won't need to use this
  ## But will be useful if you want to create your own functions
  if order.len > 0:
    result = "ORDER BY "
    result.add order.seperateBy(", ") do (x: auto) -> string:
      x.order % [x.column]

#
# Functions that build the query
#

macro importSQL*(format: static[string], prc: untyped) =
  ## Like `importc` except for SQL expressions.
  ## This is used to simplify the process by
  ##  - Annotating all parameters and return type as `QueryPart[T]`
  ##  - Creating the proc body
  ## This is only a helper, you can also construct the expression yourself.
  ## `format` string follows same rules as [strutils.`%`](https://nim-lang.org/docs/strutils.html#%25,string,openArray[string])
  runnableExamples:
    func `mod`[T: SomeInteger](a, b: T): T {.importSQL: "$# % $#".}
      ## Performs `%` operation
  #==#
  proc wrapPart(typ: NimNode): NimNode = nnkBracketExpr.newTree(ident"QueryPart", typ)

  if prc.kind notin {nnkProcDef, nnkFuncDef}:
    "Pragma must be used on a proc/func".error(prc)
  let params = prc.params
  if params[0].kind == nnkEmpty:
    "Return type cannot be 'void'".error(params[0])
  params[0] = wrapPart(params[0])
  var sqlParts = nnkBracket.newTree()
  # Wrap all the types in QueryPart
  for param in params:
    if param.kind != nnkIdentDefs: continue
    param[^2] = wrapPart(param[^2])
    # Add each parameter into the parts so the formatter can access them
    for prop in param[0 ..< ^2]:
      # We need to convert it back into a string
      sqlParts &= newCall("PartBase", prop)
  # Now format it inside the body
  var body = newStmtList()
  if prc.body.kind != nnkEmpty:
    body = prc.body
  body.add quote do:
    result = newFormattedPart[result.T](`format`, `sqlParts`)
  prc.body = body
  result = prc
  echo result.toStrLit

macro opToStr(op: untyped): string = newLit op[0].strVal

template defineInfixOp(op, sideTypes, returnType: untyped) =
  ## Creates an infix operator which has **sideTypes** on both sides of the operation and returns **returnType**
  # I know the toUpperAscii isn't required, but I like my queries formatted like that
  func op*(a, b: sideTypes): returnType {.importSQL: "$# " & toUpperAscii(opToStr(op)) & " $#".}

defineInfixOp(`<`, SomeNumber, bool)
defineInfixOp(`>`, SomeNumber, bool)
defineInfixOp(`>=`, SomeNumber, bool)
defineInfixOp(`<=`, SomeNumber, bool)
defineInfixOp(`==`, SomeNumber, bool)
defineInfixOp(`==`, bool, bool)
defineInfixOp(`==`, string, bool)

template defineMathOp(op, restriction: untyped) =
  ## Creates a math operation that will have the inputs return the same type.
  # Should probably manually define the math types to better reflect how they can be used
  func `op`*[T: restriction](a, b: T): T {.importSQL: "$# " & opToStr(op) & " $#".}

defineMathOp(`+`, SomeNumber)
defineMathOp(`*`, SomeNumber)
defineMathOp(`-`, SomeNumber)
defineMathOp(`/`, SomeFloat)

proc `..<`*(a, b: QueryPart[int]): Slice[QueryPart[int]] =
  ## Overload for `..<` to work with `QueryPart[int]`
  a .. (b - newQueryPart(1))

defineInfixOp(`and`, bool, bool)
defineInfixOp(`or`, bool, bool)

func `==`*[T](a, b: QueryPart[Option[T]]): QueryPart[bool] =
  ## Checks if two optional values are equal using SQLites `IS` operator.
  ## This means that two `none(T)` or two `some(T)` (if value inside is the same) values are considered equal
  result = QueryPart[bool](fmt"{a.string} IS {pattern.string}")

func `not`*(statement: bool): bool {.importSQL: "NOT ($#)".}

func `~=`*(a, pattern: string): bool {.importSQL: "$# LIKE $#".} =
  ## Used for **LIKE** matches. The pattern can use two wildcards
  ##
  ## - `%`: Matches >= 0 characters
  ## - `_`: Matches a single character

proc addParamsFrom(a, b: int) =
  ## Adds parameters from `a` into `b`.
  ## `a` and `b` are both indexes into ponairi.parmaters CacheSeq
  for param in queryParameters[b]:
    queryParameters[a] &= param

template exists*[T](query: TableQuery[T]): QueryPart[bool] =
  ## Implements `EXISTS()` for the query builder
  bind addParamsFrom
  # We make it a const first so we aren't copying it multiple times if they pass a literal
  # Get some info out of it
  const tableName = query.T.tableName()
  const whereExpr = query.whereExpr
  # Add its parameters into the parent query
  static:
    addParamsFrom(paramsIdx, query.paramsIdx)
  QueryPart[bool]("EXISTS(SELECT 1 FROM $# WHERE $# LIMIT 1)" % [tableName, whereExpr])

func get*[T](q: Option[T], default: T): T {.importSQL: "COALESCE($#, $#)".} =
  ## Trys to get the value from the column but returns default if its `none(T)`

func unsafeGet*[T](q: Option[T]): T {.importSQL: "$#".}=
  ## Just converts the type from `Option[T]` to `T`, doesn't do any actual SQL

func isSome*(q: Option[auto]): bool {.importSQL: "$# IS NULL".}=
  ## Checks if a column is not null

func isNone*(q: Option[auto]): bool {.importSQL: "$# IS NOT NULL".} =
  ## Checks if a column is null

func contains*[T](items: openArray[QueryPart[T]], q: QueryPart[T]): QueryPart[bool] =
  ## Checks if a value is in an array of values
  var sqlArray = "("
  sqlArray.add items.seperateBy(", ") do (item: auto) -> string:
    item.string
  sqlArray &= ")"
  result = QueryPart[bool](fmt"{q.string} IN {sqlArray}")

func contains*[T: SomeInteger](range: Slice[QueryPart[T]], number: QueryPart[T]): QueryPart[bool] =
  ## Checks if a number is within a range
  result = QueryPart[bool](fmt"{number.string} BETWEEN {range.a.string} AND {range.b.string}")

func len*(str: string): int {.importSQL: "LENGTH($#)".} =
  ## Returns the length of a string

#
# Macros that implement the initial QueryPart generation
#

using db: DbConn
using args: varargs[DbValue, dbValue]

func initQueryPartNode(val: NimNode): NimNode =
  ## Makes a QueryPart NimNode. This doesn't make an actual QueryPart
  result = nnkCall.newTree(
    bindSym"newQueryPart",
    val
  )
  result.copyLineInfo(val)

macro field(x: untyped): untyped =
  # Ignore calls to field
  if x.kind == nnkCall and x[0].kind == nnkSym and x[0].eqIdent("field"):
    return x
  let fieldIdent = ident "field " & x.strVal
  fieldIdent.copyLineInfo(x)
  result = nnkWhenStmt.newTree(
    nnkElifBranch.newTree(newCall("declared", fieldIdent), fieldIdent),
    nnkElse.newTree(x)
  )

proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode],
                  paramsIdx: int): NimNode =
  ## Converts atoms like literals (e.g. integer, string, bool literals) and symbols (e.g. properties in an object, columns in current scope)
  ## into [QueryPart] variables. This then allows us to leave the rest of the query parsing to the Nim compiler which means I don't need to
  ## reinvent the wheel with type checking.

  template checkAfter(start: int) =
    ## Checks the rest of the nodes starting with `start`
    for i in start..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope, paramsIdx)

  result = node
  case node.kind
  of nnkIdent, nnkSym:
    if node.eqIdent(["true", "false"]):
      return initQueryPartNode(node)
    elif not node.strVal.startsWith("field "):
      let fieldNode = newCall(bindSym"field", node)
      fieldNode.copyLineInfo(node)
      return fieldNode
  of nnkStrLit, nnkIntLit, nnkFloatLit:
    return initQueryPartNode(node)
  of nnkDotExpr:
    # Assume its a function call
    result[0] = checkSymbols(node[0], currentTable, scope, paramsIdx)
  of nnkCurly:
    if node.len == 1:
      let
        param = node[0]
        params = queryParameters[^1]
      var
        pos = params.len
        found = false

      # If its a variable that see if we can match it to an existing variable.
      # This allows us to reuse values in the query.
      # We don't do this for anything else (e.g. calls) since they might have side effects
      if param.kind in identNodes:
        var foundIdx = params.findIt(it.kind == nnkIdent and it.eqIdent(param))
        if foundIdx != -1:
          found = true
          pos = foundIdx

      if not found:
        queryParameters[^1] &= param

      # Insert a QueryPart[T] so the query knows the type of the parameter
      # TODO: Insert the type so that we can ensure the same type is getting passed later
      let posVal = newLit "?" & $(pos + 1) # SQLite parameters are 1 indexed
      result = quote do:
        QueryPart[typeof(`param`)](`posVal`)
    else:
      checkAfter(0)
  of nnkInfix, nnkCall, nnkPrefix:
    var
      scope = scope
      currentTable = currentTable
    if (node[0].kind == nnkDotExpr and node[0][1].eqIdent("where")) or (node.len > 1 and node[1].eqIdent("where")):
      # User has done a `where` call and so we need to update the current table and scope to have
      # the table that they are calling where on
      currentTable = if node[0].kind == nnkDotExpr: node[0][0] else: node[1]
      scope &= currentTable
    elif node[0].kind == nnkBracketExpr and node[0][0].eqIdent("QueryPart"):
      # Ignore QueryPart, don't even know how they get here
      return node
    elif node[0].kind == nnkDotExpr:
      # Normalise dot call syntax into normal function call
      let
        firstParam = node[0][0]
        function = node[0][1]
      result[0] = function
      result.insert(1, firstParam)
    elif node[0].eqIdent("%") and node[1].strVal[0].isUpperAscii():
      return node
    checkAfter(1)
  else:
    checkAfter(0)

macro where*[T](table: typedesc[T], query: untyped): TableQuery[T] =
  ## Use this macro for genearting queries.
  ## The query is a boolean expression made in Nim code
  runnableExamples:
    import ponairi/pragmas

    type
      ShopItem = object
        id {.primary, autoIncrement.}: int
        name: string
        price: float # I know float is bad for price, this is an example

    let name = "Chair"
    discard ShopItem.where(
      # Normal Nim code gets put in here which gets converted into SQL.
      # Variables are passed like {var}
      (id == 9 and name.len > 9) or price == 0.0 or name == ?string
    )
    # Gets compiled into
    # ShopItem.id == 9 AND LENGTH(ShopItem.name) > 9 OR ShopItem.price == 0.0 OR ShopItem.name == ?1
  #==#
  let
    tableObject = if table.kind == nnkBracketExpr: table[1] else: table
    paramsIdx = queryParameters.len
  # Initialise the parameters list for this query
  queryParameters &= newStmtList()
  # We wrap in a StmtList so the `quote do` doesn't screw with line info
  let queryNodes = newStmtList(checkSymbols(query, tableObject, @[tableObject], paramsIdx))
  echo queryNodes.treeRepr
  # To allow the user to access field `Foo.bar` without specifying bar, we add a series
  # of variables for all the properties
  var quickAccessors = nnkConstSection.newTree()
  for prop in tableObject.strVal.getProperties:
    quickAccessors &= nnkConstDef.newTree(ident "field " & prop[0].strVal, newEmptyNode(), infix(ident tableObject.strVal, "%", prop[0]))
  # Boolean literals aren't allowed to be the entire query
  # Realised this would compile, but fail at runtime when trying to do Type.where(true)
  # TODO: Just convert this into a proper boolean statement
  if query.kind == nnkIdent and query.eqIdent(["true", "false"]):
    "Query cannot be a single boolean value".error(query)
  # Add dbValue calls to convert the params
  let invalidReturn = makeError("Query must return 'bool'", query.lineInfoObj)
  result = newStmtList()
  let
    dotOp = ident "%" # I needed something with high precedance
    paramsIdent = ident"paramsIdx"
  result.add quote do:
    block:
      # Allow templates to access the parameters index
      const `paramsIdent` = `paramsIdx`
      # Add operators to access fields.
      template `dotOp`(x: typedesc[`tableObject`], field: untyped): untyped =
        newRawPart(astToStr(x.field), typeof(x.field))
      # Add inverse to match if trying to access field out of scope
      macro `dotOp`(x: typedesc[not `tableObject`], field: untyped): untyped {.used.} =
        ($x & " is not in scope").error(x)
      # Add the quick accessors
      `quickAccessors`
      # const query = `queryNodes`
      when `queryNodes`.T isnot bool:
        `invalidReturn`
      TableQuery[`table`](whereExpr: `queryNodes`, paramsIdx: `paramsIdent`)

func where*[T](table: typedesc[T]): TableQuery[T] =
  ## Create a where statement that matches anything
  TableQuery[table](whereExpr: "1 == 1")

func normaliseCall(node: NimNode): NimNode =
  ## Normalises
  ## - something.proc()
  ## - proc something
  ## - something.proc
  ## into proc(something)
  ##
  ## If the node passed is not a call then it just returns
  case node.kind:
  of nnkCall:
    if node[0].kind == nnkDotExpr:
      result = normaliseCall(node[0])
      # Add rest of the arguments
      if node.len > 1:
        for arg in node[1 ..< ^1]:
          result &= arg
    else:
      result = node
  of nnkDotExpr:
    # We just need to swap the nodes
    result = nnkCall.newTree(node[1], node[0])
  else:
    result = node

when not defined(docs):
  # Error when using on non seq types, makes the type mismatch be clearer
  proc orderBy*[T: not seq](table: TableQuery[T], order: varargs[ColumnOrder]): TableQuery[T] {.error: "orderBy only works on seq[T]".}

proc checkFieldOrdering(x: typedesc, sortings: openArray[ColumnOrder]) {.compileTime.} =
  ## Performs checks on sortings to ensure that the orderings given make sense
  ## e.g. Not calling NullsFirst on a non nullable field. not sorting something that doesn't exist
  let obj = x.tableName()
  for order in sortings:
    if not obj.hasProperty(order.column):
      doesntExistErr(order.column, obj).error(order.line)
    # Check if type can actually be nullable
    elif order.order in [nullsFirstStr, nullsLastStr]:
      # We already checked the property exists, so we can safely get it
      let typ = obj.getType(order.column).get()
      if not typ.isOptional:
        fmt"{order.column} is not nullable".error(order.line)

proc orderBy*[T: seq](table: TableQuery[T], sortings: static[varargs[ColumnOrder]]): TableQuery[T] =
  ## Call after [where] to change how SQL sorts your data.
  ##
  ## Sorting will be a list of [asc], [desc], [nullsFirst], or [nullsLast] calls to order different columns.
  ## These sortings run in order e.g. If the first column getting sorted is equal, then the next column will be used to compare
  runnableExamples:
    import ponairi/pragmas
    type
      Citizen {.table.} = object
        name: string
        age: int
    # Get everyone older than 5 and first sort names alphabetically (From A to Z) and show the oldest
    # person first if two people have the same name
    discard seq[Citizen].where(age > 5).orderBy([asc name, desc age])
  #==#
  static:
    checkFieldOrdering(T, sortings)
  # Build query manually so that the line info stays correct
  result = table
  # Check the ordering is valid
  for order in sortings:
    result.order &= order

#
# Overloads to use TableQuery
#

macro getParams(paramsIdx: static[int]): untyped =
  result = nnkBracket.newTree()
  for param in queryParameters[paramsIdx]:
    result &= newCall("dbValue", param)

macro hackyWorkaround(prc: untyped): untyped =
  ## Implements my hacky workaround for buggy templates + missing environment
  # There was a problem with missing environment since I was creating the parameters inside
  # the proc and so it couldn't access the scope that the parameters were made in.
  # Easy fix, wrap in a template.
  # Except that was giving problems with a sequence becoming an array somehow.
  # So I make a macro that is a glorified template
  result = newStmtList()
  let
    name = prc.name
    newName = name.strVal & "Impl"
    dbIdent = ident"db"
    queryIdent = ident"query"
  prc.name = ident newName
  let docs = prc.extractDocCommentsAndRunnables()
  result &= prc
  let wrapperMacro = quote do:
    macro `name`*[T](`dbIdent`: DbConn, `queryIdent`: TableQuery[T]) =
      `docs`
      result = newCall(
        bindSym `newName`,
        `dbIdent`,
        `queryIdent`,
        newCall(bindSym"getParams", newDotExpr(`queryIdent`, ident"paramsIdx"))
      )
  wrapperMacro.params[0] = prc.params[0]

  result &= wrapperMacro

# TODO: Make this work as an iterator
proc find[T](db; q: static[TableQuery[T]], params: openArray[DbValue]): T {.inline, hackyWorkaround.} =
  const
    table = T.tableName
    orderBy = q.order.build()
    query = sql fmt"SELECT * FROM {table} WHERE {q.whereExpr} {orderBy}"
  db.find(T, query, params)


proc exists[T](db; q: static[TableQuery[T]], params: openArray[DbValue]): bool {.inline, hackyWorkaround.} =
  ## Returns true if the query finds atleast one row
  const
    table = T.tableName
    query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.whereExpr} LIMIT 1)"
  db.getValue[:int64](query, params).unsafeGet() == 1

proc delete[T](db; q: static[TableQuery[T]], params: openArray[DbValue]) {.inline, hackyWorkaround.} =
  ## Deletes any rows that match the query
  const table = T.tableName
  const query = sql fmt"DELETE FROM {table} WHERE {q.whereExpr}"
  db.exec(query, params)

proc `$`*(x: TableQuery): string =
  ## Used for debugging a query, returns the generated SQL
  x.whereExpr

