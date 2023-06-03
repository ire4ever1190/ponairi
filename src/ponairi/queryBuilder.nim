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
  assert db.find(seq[Item].where().orderBy(asc name)).isSorted()

type
  SortOrder* = enum
    ## How should SQLite sort the column
    Ascending
    Descending
    NullsFirst
    NullsLast

  ColumnOrder = object
    ## Info about an ordering
    column*: string
    order*: SortOrder
    line: LineInfo # Store line info so error messages are better later

  TableQuery*[T] = object
    ## This is a full query. Stores the type of the table it is accessing
    ## and the SQL that will be executed
    # This is a constant that I probably could've stored in the type signature.
    # But that made life very difficult
    whereExpr*: string
    params*: int # Index into queryParameters
    order*: seq[ColumnOrder]

  QueryPart*[T] = distinct string
    ## This is a component of a query, stores the type that the SQL would return
    ## and also the SQL that it is

const queryParameters = CacheSeq"ponairi.parameters"
  ## We need to store the NimNode of parameters (Not the actual value)
  ## so that we can reconstruct the parameters.
  ## Each query is given an index which corresponds to the parameters for it
  ## Yes this is a hacky method
  ## but it was the best I could come up with.

func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

func tableName[T](x: typedesc[Option[T]]): string =
  result = $T

template makeOrder(name: untyped, ord: SortOrder, docs: untyped) =
  template name*(col: untyped): ColumnOrder =
    docs
    ColumnOrder(column: astToStr(col), order: ord, line: currentLine())

makeOrder(asc, Ascending):
  ## Make a column be in ascending order

makeOrder(desc, Descending):
  ## Make a column be in descending order

makeOrder(nullsFirst, NullsFirst):
  ## Makes `nil` values get returned first.
  ## Column must be optional

makeOrder(nullsLast, NullsLast):
  ## Makes `nil` values get returned last
  ## Column must be optional

func build(order: openArray[ColumnOrder]): string =
  ## Returns the ORDER BY clause. You probably won't need to use this
  ## But will be useful if you want to create your own functions
  if order.len > 0:
    # We can't set the string directly on the enum
    # since that would mess up the parseEnum call
    const toStr: array[SortOrder, string] = [
      "ASC",
      "DESC",
      "NULLS FIRST",
      "NULLS LAST"
    ]
    result = "ORDER BY "
    result.add order.seperateBy(", ") do (x: auto) -> string:
       x.column & " " & toStr[x.order]
#
# Functions that build the query
#

func pred*(x: QueryPart[int], y = 1): QueryPart[int] =
  result = QueryPart[int]($(x.string.parseInt() - y))

template `..<`*(a, b: QueryPart[int]): Slice[QueryPart[int]] =
  ## Overload for `..<` to work with `QueryPart[int]`
  a .. pred(b)

macro opToStr(op: untyped): string = newLit op[0].strVal

template defineInfixOp(op, sideTypes, returnType: untyped) =
  ## Creates an infix operator which has **sideTypes** on both sides of the operation and returns **returnType**
  func op*(a, b: QueryPart[sideTypes]): QueryPart[returnType] =
    # I know the toUpperAscii isn't required, but I like my queries formatted like that
    result = QueryPart[returnType](a.string & " " & toUpperAscii(opToStr(op)) & " " & b.string)

defineInfixOp(`<`, SomeNumber, bool)
defineInfixOp(`>`, SomeNumber, bool)
defineInfixOp(`>=`, SomeNumber, bool)
defineInfixOp(`<=`, SomeNumber, bool)
defineInfixOp(`==`, SomeNumber, bool)
defineInfixOp(`==`, bool, bool)
defineInfixOp(`==`, string, bool)

defineInfixOp(`and`, bool, bool)
defineInfixOp(`or`, bool, bool)

func `==`*[T](a, b: QueryPart[Option[T]]): QueryPart[bool] =
  ## Checks if two optional values are equal using SQLites `IS` operator.
  ## This means that two `none(T)` or two `some(T)` (if value inside is the same) values are considered equal
  result = QueryPart[bool](fmt"{a.string} IS {pattern.string}")

func `not`*(expression: QueryPart[bool]): QueryPart[bool] =
  result = QueryPart[bool](fmt"NOT ({expression.string})")

func `~=`*(a, pattern: QueryPart[string]): QueryPart[bool] =
  ## Used for **LIKE** matches. The pattern can use two wildcards
  ##
  ## - `%`: Matches >= 0 characters
  ## - `_`: Matches a single character
  result = QueryPart[bool](fmt"{a.string} LIKE {pattern.string}")

func exists*[T](q: TableQuery[T]): QueryPart[bool] =
  ## Implements `EXISTS()` for the query builder
  const table = T.tableName
  result = QueryPart[bool](fmt"EXISTS(SELECT 1 FROM {table} WHERE {q.whereExpr} LIMIT 1)")

func get*[T](q: QueryPart[Option[T]], default: QueryPart[T]): QueryPart[T] =
  ## Trys to get the value from the column but returns default if its `none(T)`
  result = QueryPart[T](fmt"COALESCE({q.string}, {default.string})")

func unsafeGet*[T](q: QueryPart[Option[T]]): QueryPart[T] =
  ## Just converts the type from `Option[T]` to `T`, doesn't do any actual SQL
  result = QueryPart[T](q.string)

func isSome*(q: QueryPart[Option[auto]]): QueryPart[bool] =
  ## Checks if a column is not null
  result = QueryPart[bool](fmt"{q.string} IS NULL")

func isNone*(q: QueryPart[Option[auto]]): QueryPart[bool] =
  ## Checks if a column is null
  result = QueryPart[bool](fmt"{q.string} IS NOT NULL")

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

func len*(str: QueryPart[string]): QueryPart[int] =
  ## Returns the length of a string
  result = QueryPart[int](fmt"LENGTH({str.string})")

#
# Macros that implement the initial QueryPart generation
#

using db: DbConn
using args: varargs[DbValue, dbValue]

func initQueryPartNode(x: NimNode, val: string): NimNode =
  ## Makes a QueryPart NimNode. This doesn't make an actual QueryPart
  let typ = x
  nnkCall.newTree(
    nnkBracketExpr.newTree(ident"QueryPart", typ),
    newLit val
  )

func initQueryPartNode[T](x: typedesc[T], val: string = $T): NimNode =
  initQueryPartNode(ident $T, val)


macro addParam[T](param: T, paramsIdx, idx: static[int], found: static[bool]): QueryPart[T] =
  ## Internal proc that saves the param info into a query.
  ## This is done so we get the actual symbol and dont run into mismatches later on.
  ## It then returns what the type of the param is so teh rest of the system stays typesafe
  if not found:
    queryParameters[paramsIdx] &= param
  result = quote do:
    QueryPart[typeof(`param`)]("?" & $`idx`)

proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode],
                  params: var seq[NimNode]): NimNode =
  ## Converts atoms like literals (e.g. integer, string, bool literals) and symbols (e.g. properties in an object, columns in current scope)
  ## into [QueryPart] variables. This then allows us to leave the rest of the query parsing to the Nim compiler which means I don't need to
  ## reinvent the wheel with type checking.

  template checkAfter(start: int) =
    ## Checks the rest of the nodes starting with `start`
    for i in start..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope, params)

  result = node
  case node.kind
  of nnkIdent, nnkSym:
    if node.eqIdent(["true", "false"]):
      # We technically could use TRUE and FALSE
      return initQueryPartNode(bool, $int(node.boolVal))
    else:
      let typ = currentTable.getType(node)
      if typ.isNone:
        doesntExistErr($node, $currentTable).error(node)
      return initQueryPartNode(typ.unsafeGet, fmt"{currentTable.strVal}.{node.strVal}")
  of nnkStrLit:
    return initQueryPartNode(string, fmt"'{node.strVal}'")
  of nnkIntLit:
    return initQueryPartNode(int, $node.intVal)
  of nnkFloatLit:
    return initQueryPartNode(float, $node.floatVal)
  of nnkDotExpr:
    # Bit of a hacky check, but only assume table access when the thing they are accessing
    # starts with capital letter (I've never seen user defined objects that go against this)
    let
      left = node[0]  # Left operand of dot expr
      right = node[1] # Right operand of dot expr
    if left.strVal[0].isUpperAscii:
      # Check the table they are accessing is allowed
      if not scope.anyIt(it.eqIdent(left)):
        fmt"{node[0]} is not currently accessible".error(left)
      # If found then add expression to access expression.
      # We don't need to check if property exists since that will be checked next
      return checkSymbols(right, left, scope, params)
    else:
      # Assume its a function call
      result[0] = checkSymbols(node[0], currentTable, scope, params)
  of nnkInfix, nnkCall:
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
    checkAfter(1)
  of nnkCurly:
    if node.len == 1:
      let param = node[0]
      # If its a variable that see if we can match it to an existing variable.
      # This stops us creating multiple variables of the same type.
      # We don't do this for anything else (e.g. calls) since they might have side effects
      let paramsIdx = queryParameters.len - 1 # No BackwardsIndex implemented =(
      var
        pos = params.len
        found = false
      if param.kind == nnkIdent:
        var foundIdx = params.findIt(it.kind == nnkIdent and it.eqIdent(param))
        if foundIdx != -1:
          found = true
          pos = foundIdx
        else:
          params &= param
      else:
        params &= param

      # Insert a call in its place which sets the type and places a parameter that can
      # be binded to later
      result = newCall(bindSym"addParam", param, newLit(paramsIdx), newLit(pos + 1), newLit found)
    else:
      checkAfter(0)
  else:
    checkAfter(0)

func whereImpl*[T](table: typedesc[T], query: static[QueryPart[bool]],
                   params: int): TableQuery[T] =
  ## This is the internal proc that forces the query to be compiled
  TableQuery[table](whereExpr: query.string, params: params)

macro where*(table: typedesc, query: untyped): TableQuery =
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
      (id == 9 and name.len > 9) or price == 0.0 or name == {name}
    )
    # Gets compiled into
    # ShopItem.id == 9 AND LENGTH(ShopItem.name) > 9 OR ShopItem.price == 0.0 OR ShopItem.name == ?1
  #==#
  let
    tableObject = if table.kind == nnkBracketExpr: table[1] else: table
    paramsIdx = queryParameters.len
  # Initialise the parameters list for this query
  queryParameters &= newStmtList()
  var params: seq[NimNode]
  let queryNodes = checkSymbols(query, tableObject, @[tableObject], params)
  # Boolean literals aren't allowed to be the entire query
  # Realised this would compile, but fail at runtime when trying to do Type.where(true)
  # TODO: Just convert this into a proper boolean statement
  if query.kind == nnkIdent and query.eqIdent(["true", "false"]):
    "Query cannot be a single boolean value".error(query)
  # Add dbValue calls to convert the params
  result = newCall(bindSym"whereImpl", table, queryNodes, newLit paramsIdx)

template where*[T](table: typedesc[T]): TableQuery[T] =
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
    if order.order in {NullsFirst, NullsLast}:
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
    discard seq[Citizen].where(age > 5).orderBy(asc name, desc age)
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
  # TODO: Convert to array when I get #17 merged
  result = nnkBracket.newTree()
  for param in queryParameters[paramsIdx]:
    result &= newCall("dbValue", param)

proc find*[T](db; q: static[TableQuery[T]]): T =
  const
    table = T.tableName
    orderBy = q.order.build()
  const query = sql fmt"SELECT * FROM {table} WHERE {q.whereExpr} {orderBy}"
  db.find(T, query, getParams(q.params))


proc exists*[T](db; q: static[TableQuery[T]]): bool =
  ## Returns true if the query finds atleast one row
  const table = T.tableName
  const query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.whereExpr} LIMIT 1)"
  db.getValue[:int64](query, getParams(q.params)).unsafeGet() == 1

proc delete*[T](db; q: static[TableQuery[T]]) =
  ## Deletes any rows that match the query
  const table = T.tableName
  const query = sql fmt"DELETE FROM {table} WHERE {q.whereExpr}"
  db.exec(query, getParams(q.params))

proc `$`*(x: TableQuery): string =
  ## Used for debugging a query, returns the generated SQL
  x.whereExpr

