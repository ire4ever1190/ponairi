import ndb/sqlite except `?`
import std/[
  macros,
  strformat,
  options,
  typetraits,
  macrocache,
  sugar,
  strutils,
  genasts
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
  # Parameters need to have their types specified and so this doesn't compile since
  # id is a string
  assert not compiles(Card.where(id == ?string))

  # We can write simple queries to check columns
  db.insert Item(name: "Lamp", price: 9.0)
  assert db.find(Item.where(price > 5.0)).name == "Lamp"

  # We can also use parameters, only difference is we need to annotate the type.
  # The position can also be set like ?[pos, typ]
  assert db.find(Item.where(price > ?float), 5.0).name == "Lamp"

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
    line: LineInfo

  TableQuery*[T] = object
    ## This is a full query. Stores information about the main table it is trying to access,
    ## what the SQL to run is, and what parameters it has
    sql*: string
    # Sequence of types for the parameters
    # Was too much of a pain to move around NimNodes
    params*: seq[string]
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

func buildOrderBy*(table: TableQuery): string =
  ## Returns the ORDER BY clause
  runnableExamples:
    type Person = object
      name: string
      age: int
    const query = seq[Person].where().orderBy(asc name, desc age)
    assert query.buildOrderBy() == "ORDER BY name ASC, age DESC"
  #==#
  if table.order.len > 0:
    # We can't set the string directly on the enum
    # since that would mess up the parseEnum call
    const toStr: array[SortOrder, string] = [
      "ASC",
      "DESC",
      "NULLS FIRST",
      "NULLS LAST"
    ]
    result = "ORDER BY "
    result.add table.order.seperateBy(", ") do (x: auto) -> string:
      fmt"{x.column} {toStr[x.order]}"
#
# Functions that build the query
#

func pred*(x: QueryPart[int], y = 1): QueryPart[int] =
  result = QueryPart[int]($(x.string.parseInt() - y))

template `..<`*(a, b: QueryPart[int]): HSlice[QueryPart[int], QueryPart[int]] =
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
  result = QueryPart[bool](fmt"EXISTS(SELECT 1 FROM {table} WHERE {q.sql} LIMIT 1)")

func isSome*(q: QueryPart[Option[auto]]): QueryPart[bool] =
  ## Checks if a column is not null
  result = QueryPart[bool](fmt"{q.string} IS NULL")

func isNone*(q: QueryPart[Option[auto]]): QueryPart[bool] =
  ## Checks if a column is null
  result = QueryPart[bool](fmt"{q.string} IS NOT NULL")

func contains*[T](items: openArray[QueryPart[T]], q: QueryPart[T]): QueryPart[bool] =
  ## Checks if a value is in an array of values
  var sqlArray = "("
  for i in 0..<items.len:
    sqlArray &= q.string
    if i < items.len - 1:
      sqlArray &= ", "
  sqlArray &= ")"
  result = QueryPart[bool](fmt"{q.string} IN {sqlArray}")

func contains*[T: SomeInteger](range: HSlice[QueryPart[T], QueryPart[T]], number: QueryPart[T]): QueryPart[bool] =
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

proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode],
                  params: var seq[string]): NimNode =
  ## Converts atoms like literals (e.g. integer, string, bool literals) and symbols (e.g. properties in an object, columns in current scope)
  ## into [QueryPart] variables. This then allows us to leave the rest of the query parsing to the Nim compiler which means I don't need to
  ## reinvent the wheel with type checking.
  ##
  result = node
  case node.kind
  of nnkIdent, nnkSym:
    if node.eqIdent(["true", "false"]):
      # We technically could use TRUE and FALSE
      return initQueryPartNode(bool, $int(node.boolVal))
    else:
      let typ = currentTable.getType(node)
      if typ.isNone:
        fmt"{node} doesn't exist in {currentTable}".error(node)
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
    if node[0].strVal[0].isUpperAscii:
      # Check the table they are accessing is allowed
      var found = false
      for table in scope:
        if table.eqIdent(node[0]):
          found = true
      if not found:
        fmt"{node[0]} is not currently accessible".error(node[0])
      # If found then add expression to access expression.
      # We don't need to check if property exists since that will be checked next
      let table = node[0]
      return checkSymbols(node[1], table, scope, params)
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

    for i in 1..<result.len:
      result[i] = result[i].checkSymbols(currentTable, scope, params)
  of nnkPrefix:
    if node[0].eqIdent("?"):
      # ? parameters need to be implemented like this so we can keep track of the
      # parameters. Used to be implemented as a macro but then I couldn't get the parameters
      # later
      let param = node[1]
      const usageMsg = "parameters must be specified with ?[pos, typ] or ?typ"
      var
        pos: BiggestInt = params.len
        typ: NimNode
      case param.kind
      of nnkIdent, nnkSym:
        typ = ident param.strVal
      of nnkBracket:
        if param.len != 2:
          usageMsg.error(param)
        else:
          if param[0].kind != nnkIntLit:
            "Size must be an integer literal".error(param[0])
          elif param[1].kind != nnkIdent:
            "Second parameter must be a type".error(param[1])
        pos = param[0].intVal
        typ = param[1]
      else:
        usageMsg.error(node)
      if pos == params.len:
        params.insert(repr typ, pos)
      elif pos > params.len:
        "Invalid position for parameter".error(param)
      elif repr(typ) != params[pos]:
        fmt"Parameter at index {pos} is {params[pos]} but you tried to override with {typ}".error(param)
      result = initQueryPartNode(typ, "?" & $(pos + 1)) # SQLite parameters are 1 indexed
    else:
      for i in 1..<node.len: # We can ignore the first node, Nim will check it later
        result[i] = result[i].checkSymbols(currentTable, scope, params)
  else:
    for i in 0..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope, params)

func whereImpl*[T](table: typedesc[T], query: QueryPart[bool], params: openArray[string]): TableQuery[T] =
  ## This is the internal proc that forces the query to be compiled
  result.sql = query.string
  for i in params:
    result.params &= i

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

    discard ShopItem.where(
      # Normal Nim code gets put in here which gets converted into SQL.
      (id == 9 and name.len > 9) or price == 0.0 or name == ?string
    )
    # Gets compiled into
    # ShopItem.id == 9 AND LENGTH(ShopItem.name) > 9 OR ShopItem.price == 0.0 OR ShopItem.name == ?1
  #==#
  let tableObject = if table.kind == nnkBracketExpr: table[1] else: table
  var params: seq[string]
  let queryNodes = checkSymbols(query, tableObject, @[tableObject], params)
  # Boolean literals aren't allowed to be the entire query
  # Realised this would compile, but fail at runtime when trying to do Type.where(true)
  if query.kind == nnkIdent and query.eqIdent(["true", "false"]):
    "Query cannot be a single boolean value".error(query)
  # Move the parameters into a node that we can pass into the second call
  result = newCall(bindSym"whereImpl", table, queryNodes, newLit(params)[1])

func where*[T](table: typedesc[T]): TableQuery[T] =
  ## Create a where statement that matches anything
  result = TableQuery[T](sql: "1 == 1")

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

macro orderByImpl[T](tableTyp: typedesc[T], table: TableQuery[T],
                     orderList: static[seq[ColumnOrder]]): TableQuery[T] =
  ## This is the actual implementation of orderBy. The only difference is that it takes
  ## a typedesc parameter so I can actually lookup the table parameters
  let tableName = tableTyp.lookupImpl().getNameSym()
  # Check the ordering is valid
  for order in orderList:
    if not tableName.hasProperty(order.column):
      fmt"{order.column} doesn't exist in {tableName}".error(table)

    # Check if type can actually be nullable
    if order.order in {NullsFirst, NullsLast}:
      # We already checked the property exists, so we can safely get it
      let typ = tableName.getType(order.column).get()
      if not typ.isOptional:
        fmt"{order.column} is not nullable".error(order.line)

  # Generate code to add the items to the order
  result = genAst(table, items = newLit(orderList), lookupSym = bindSym"lookupImpl"):
    # Create copy we can edit (Since it might just be a whereImpl call)
    # Then append the order
    var x = table
    x.order &= items
    x

proc orderBy*[T: not seq](table: TableQuery[T], order: varargs[ColumnOrder]): TableQuery[T] {.error: "orderBy only works on seq[T]".}

proc orderBy*[T: seq](table: TableQuery[T], sortings: varargs[ColumnOrder]): TableQuery[T] =
  # Build query manually so that the line info stays correct
  let obj = T.tableName()
  result = table
  # Check the ordering is valid
  for order in sortings:
    echo obj.hasProperty(order.column)
    if not obj.hasProperty(order.column):
      fmt"{order.column} doesn't exist in {obj}".error(order.line)

    # Check if type can actually be nullable
    if order.order in {NullsFirst, NullsLast}:
      # We already checked the property exists, so we can safely get it
      let typ = obj.getType(order.column).get()
      if not typ.isOptional:
        fmt"{order.column} is not nullable".error(order.line)

    result.order &= order
#
# Overloads to use TableQuery
#

proc findImpl[T](db; q: static[TableQuery[T]], args): T {.inline.} =
  const
    table = T.tableName
    query = sql fmt"SELECT * FROM {table} WHERE {q.sql} {q.buildOrderBy()}"
  db.find(T, query, args)

proc existsImpl[T](db; q: static[TableQuery[T]], args): bool =
  const
    table = T.tableName
    query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.sql} LIMIT 1)"
  db.getValue[:int64](query, args).unsafeGet() == 1

proc deleteImpl[T](db; q: static[TableQuery[T]], args) =
  const
    table = T.tableName
    query = sql fmt"DELETE FROM {table} WHERE {q.sql}"
  db.exec(query, args)

macro checkArgs(types: static[seq[string]], args: varargs[untyped]) =
  ## Generates a series of checks to make sure the args types are correct
  if types.len != args.len:
    fmt"Got {args.len} arguments but expected {types.len}".error(args)
  result = newStmtList()
  for i in 0..<args.len:
    let arg = args[i]
    let info = arg.lineInfoObj
    let foo = genAst(typ = parseExpr types[i], arg, i):
      when typeof(arg) isnot typ:
        {.error: "Expected " & $typ & " but got " & $typeof(arg) & " for argument " & $i.}

    when declared(macros.setLineInfo):
      # We want the error message to point to where the user is calling the query (Instead of pointing to here)
      foo[0][1][0][0].setLineInfo(info)
    result &= foo


template generateIntermediateMacro(name, docs: untyped) =
  ## We need to have a macro that checks the types and then passes it off to the actual proc.
  ## This just removes the boiler plate of having to write that macro for each proc
  macro name*(db; q: TableQuery, args: varargs[untyped]): untyped =
    docs
    # When we get a query we perform two steps
    # - Check the arguments are correct (types, number of args)
    # - Then run the query
    let
      f = bindSym(astToStr(name) & "impl")
      # Make temp variable incase TableQuery is a call and not a value
      tmp = ident"tmp"
    tmp.copyLineInfo(q)
    # Build manually so errors point to correct lines
    # TODO: Create a temp so that we aren't generating the query twice (See test 'Works in overloaded templates')
    result = newBlockExpr(
      # Call to heck the arguments passed are correct
      newCall(bindSym"checkArgs", newDotExpr(q, ident"params")).withArgs(args),
      # Call to the actual function
      newCall(f, db, q).withArgs(args)
    )

proc `$`*(x: TableQuery): string =
  ## Used for debugging a query, returns the generated SQL
  x.sql

generateIntermediateMacro(find):
  ## Finds any row/rows that match the query

generateIntermediateMacro(exists):
  ## Returns true if the query finds atleast one row

generateIntermediateMacro(delete):
  ## Deletes any rows that match the query

