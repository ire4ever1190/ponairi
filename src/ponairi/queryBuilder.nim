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
    ## Info about an ordering
    # Column is a string so that it can suport extensions (LIKE FTS5).
    # It is formatted with the column name later (Use $# as the place holder)
    column*: string
    order*: string
    line: LineInfo # Store line info so error messages are better later

  TableQuery*[T] = object
    ## This is a full query. Stores the type of the table it is accessing
    ## and the SQL that will be executed
    whereExpr*: string
    params*: seq[string] # Passing
    order*: seq[ColumnOrder]

  QueryPart*[T] = distinct string
    ## This is a component of a query, stores the type that the SQL would return
    ## and also the SQL that it is

func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

func tableName[T](x: typedesc[Option[T]]): string =
  result = $T

template makeOrder(name: untyped, ord: string, docs: untyped) =
  template name*(col: untyped): ColumnOrder =
    docs
    ColumnOrder(column: astToStr(col), order: ord, line: currentLine())

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

func pred*(x: QueryPart[int], y = 1): QueryPart[int] =
  result = QueryPart[int]($(x.string.parseInt() - y))

template `..<`*(a, b: QueryPart[int]): Slice[QueryPart[int]] =
  ## Overload for `..<` to work with `QueryPart[int]`
  a .. pred(b)

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
    echo param.treeRepr
    param[^2] = wrapPart(param[^2])
    # Add each parameter into the parts so the formatter can access them
    for prop in param[0 ..< ^2]:
      # We need to convert it back into a string
      sqlParts &= newCall("string", prop)
  # Now format it inside the body
  var body = newStmtList()
  if prc.body.kind != nnkEmpty:
    body = prc.body
  body.add quote do:
    result = typeof(result)(`format` % `sqlParts`)
  prc.body = body
  result = prc

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

func exists*[T](q: TableQuery[T]): QueryPart[bool] =
  ## Implements `EXISTS()` for the query builder
  const table = T.tableName
  result = QueryPart[bool](fmt"EXISTS(SELECT 1 FROM {table} WHERE {q.whereExpr} LIMIT 1)")

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

func initQueryPartNode(x: NimNode, val: string): NimNode =
  ## Makes a QueryPart NimNode. This doesn't make an actual QueryPart
  let typ = x
  nnkCall.newTree(
    nnkBracketExpr.newTree(ident"QueryPart", typ),
    newLit val
  )

func initQueryPartNode[T](x: typedesc[T], val: string = $T): NimNode =
  initQueryPartNode(ident $T, val)

#[
  - Evaluate the expression inside a block of code where it has a context variable inside its scope
  - This context just stores all parameters
  - When we encounter a nested query, we append its information to the parameters.
  - This means that the contains things will need to be templates, no biggy
]#

proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode],
                  params: var seq[string]): NimNode =
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
  of nnkPrefix:
    if node[0].eqIdent("?"):
      let param = node[1]

      var
        pos = params.len
        typ: NimNode

      case param.kind
      of nnkIdent, nnkSym:
        # Render to a string to better handle complex types like Option[T]
        typ = param.toStrLit()
      of nnkBracket:
        # TODO: Check parameters
        pos = param[0].intVal
        typ = param[1]
      else:
        # TODO: Handle invalid parameter
        "nope".error(node)
      # TODO: Bind to a template or something that checks the typ is a typedesc
      result = initQueryPartNode(typ, "?" & $pos)
    else:
      checkAfter(1)
  else:
    checkAfter(0)

func whereImpl[T](table: typedesc[T], query: static[QueryPart[bool]],
                   params: openArray[string]): TableQuery[T] =
  ## This is the internal proc that forces the query to be compiled
  TableQuery[T](whereExpr: query.string, params: @params)

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
  let tableObject = if table.kind == nnkBracketExpr: table[1] else: table
  # Initialise the parameters list for this query
  var params = @["k"]
  let queryNodes = checkSymbols(query, tableObject, @[tableObject], params)
  # Boolean literals aren't allowed to be the entire query
  # Realised this would compile, but fail at runtime when trying to do Type.where(true)
  # TODO: Just convert this into a proper boolean statement
  if query.kind == nnkIdent and query.eqIdent(["true", "false"]):
    "Query cannot be a single boolean value".error(query)
  # Add dbValue calls to convert the params
  let queryLine = query.lineInfoObj
  result = quote do:
    TableQuery[`table`](whereExpr: `query`.string, params: @[""])
  echo result.treeRepr

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

# macro checkParams(typs: static[seq[string]], params: openArray[untyped]) =
#   # TODO: Check lengths line up
#   result = newStmtList()
#   for (typ, param) in zip(typs, params):
#     discard

template find*[T](db; q: static[TableQuery[T]], params: varargs[untyped]): T =
  ## Returns all rows that match
  const
    table = T.tableName
    orderBy = q.order.build()
    query = sql fmt"SELECT * FROM {table} WHERE {q.whereExpr} {orderBy}"
  db.find(T, query, params)


template exists*[T](db; q: static[TableQuery[T]], params: varargs[untyped]): bool =
  ## Returns true if the query finds atleast one row
  const
    table = T.tableName
    query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.whereExpr} LIMIT 1)"
  db.getValue[:int64](query, params).unsafeGet() == 1

template delete*[T](db; q: static[TableQuery[T]], params: openArray[untyped]) =
  ## Deletes any rows that match the query
  const
    table = T.tableName
    query = sql fmt"DELETE FROM {table} WHERE {q.whereExpr}"
  db.exec(query, params)

proc `$`*(x: TableQuery): string =
  ## Used for debugging a query, returns the generated SQL
  x.whereExpr

