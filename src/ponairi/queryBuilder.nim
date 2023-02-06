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

import macroUtils

##[
  Query builder that can be used to make type safe queries.
  This doesn't aim to replace SQL and so certain situations will still require you to write SQL.

  It basically is just for writing **WHERE** clauses that get interpreted different depeneding on the function you pass them to e.g.
  If you pass a [TableQuery] to [find] then it will return the row/rows that match the clause but if you pass it to delete then it deletes
  any row that matches
]##


type
  TableQuery*[T] = object
    sql: string
    # Sequence of types for the parameters
    # Was too much of a pain to move around NimNodes
    params: seq[string]

  QueryPart*[T] = distinct string

func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

func tableName[T](x: typedesc[Option[T]]): string =
  result = $T

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

defineInfixOp(`<`, int, bool)
defineInfixOp(`>`, int, bool)
defineInfixOp(`>=`, int, bool)
defineInfixOp(`<=`, int, bool)
defineInfixOp(`==`, int, bool)
defineInfixOp(`==`, bool, bool)
defineInfixOp(`==`, string, bool)

defineInfixOp(`and`, bool, bool)
defineInfixOp(`or`, bool, bool)

func `~=`*(a, pattern: QueryPart[string]): QueryPart[bool] =
  ## Used for **LIKE** matches. The pattern can use two wildcards
  ##
  ## - `%`: Matches >= 0 characters
  ## - `_`: Matches a single character
  result = QueryPart[bool](fmt"{a.string} LIKE {pattern.string}")

func sqlLit(x: string): string = fmt"'{x}'"
func sqlLit(x: SomeNumber): string = $x
func sqlLit(x: bool): string = (if x: "TRUE" else: "FALSE")

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

#
# Macros that implement the initial QueryPart generation
#

using db: DbConn
using args: varargs[DbValue, dbValue]

func initQueryPartNode(x: NimNode, val: string): NimNode =
  ## Makes a QueryPart NimNode. This doesn't make an actual QueryPart
  when x is NimNode:
    let typ = x
  else:
    let typ = ident $T
  nnkCall.newTree(
    nnkBracketExpr.newTree(ident"QueryPart", typ),
    newLit val
  )

func initQueryPartNode[T](x: typedesc[T], val: string = $T): NimNode =
  initQueryPartNode(ident $T, val)

proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode], params: var seq[string]): NimNode =
  ## Converts atoms like literals (e.g. integer, string, bool literals) and symbols (e.g. properties in an object, columns in current scope)
  ## into [QueryPart] variables. This then allows us to leave the rest of the query parsing to the Nim compiler which means I don't need to
  ## reinvent the wheel with type checking.
  ##
  result = node
  case node.kind
  of nnkIdent, nnkSym:
    if node.eqIdent("true") or node.eqIdent("false"):
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
      params &= repr typ
      result = initQueryPartNode(typ, "?" & $(pos + 1)) # SQLite parameters are 1 indexed

  else:
    for i in 0..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope, params)

proc whereImpl*[T](table: typedesc[T], query: QueryPart[bool], params: openArray[string]): TableQuery[T] =
  ## This is the internal proc that forces the query to be compiled
  result = TableQuery[T](sql: query.string, params: @params)

macro where*[T](table: typedesc[T], query: untyped): TableQuery[T] =
  let tableObject = if table.kind == nnkBracketExpr: table[1] else: table
  var params: seq[string]
  let queryNodes = checkSymbols(query, tableObject, @[tableObject], params)
  # Move the parameters into a node that we can pass into the second call
  result = newCall(bindSym"whereImpl", table, queryNodes, newLit params)

#
# Overloads to use TableQuery
#

macro checkArgs(types: static[seq[string]], args: varargs[untyped]) =
  ## Generates a series of checks to make sure the args types are correct
  if types.len != args.len:
    fmt"Got {args.len} arguments but expected {types.len}".error(args)
  result = newStmtList()
  for i in 0..<args.len:
    let arg = args[i]
    let foo = genAst(typ = parseExpr types[i], arg, i):
      when typeof(arg) isnot typ:
        {.error: "Expected " & $typ & " but got " & $typeof(arg) & " for argument " & $i.}
    # We want the error message to point to where the user is calling the query so we need to set it.
    let info = args.lineInfoObj
    # Set the line info of the error pragma
    foo[0][1][0][0].setLineInfo(args.lineInfoObj)
    result &= foo

proc find[T](db; q: static[TableQuery[T]], args): T {.inline.} =
  const
    table = T.tableName
    query = sql fmt"SELECT * FROM {table} WHERE {q.sql}"
  db.find(T, query, args)

proc exists[T](db; q: static[TableQuery[T]], args): bool =
  const
    table = T.tableName
    query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.sql} LIMIT 1)"
  db.getValue[:int64](query, args).unsafeGet() == 1

proc delete[T](db; q: static[TableQuery[T]], args) =
  const
    table = T.tableName
    query = sql fmt"DELETE FROM {table} WHERE {q.sql}"
  db.exec(query, args)

template generateIntermediateMacro(name, docs: untyped) =
  ## We need to have a macro that checks the types and then passes it off to the actual proc.
  ## This just removes the boiler plate of having to write that macro for each proc
  macro name*(db; q: TableQuery, args: varargs[untyped]): untyped =
    docs
    # When we get a query we perform two steps
    # - Check the arguments are correct (types, number of args)
    # - Then run the query
    #
    let checkArgsSym = bindSym"checkArgs"
    result = genAst(db, q, args, checkArgsSym):
      checkArgsSym(q.params, args)
      db.name(q, args)

generateIntermediateMacro(find):
  ## Finds any row/rows that match the query

generateIntermediateMacro(exists):
  ## Returns true if the query finds atleast one row

generateIntermediateMacro(delete):
  ## Deletes any rows that match the query

