import ndb/sqlite
import std/[
  macros,
  strformat,
  options,
  typetraits,
  macrocache,
  sugar
]

import macroUtils

##[
  Query builder that can be used to make type safe queries.
  This doesn't aim to replace SQL and so certain situations will still require you to write SQL.

  It basically is just for writing **WHERE** clauses that get interpreted different depeneding on the function you pass them to e.g.
  If you pass a [TableQuery] to [find] then it will return the row/rows that match the clause but if you pass it to delete then it deletes
  any row that matches
]##

type TableQuery[T] = distinct string

type
  QueryPart*[T] = distinct string

proc `and`(a, b: QueryPart[bool]): QueryPart[bool] =
  result = QueryPart[bool](fmt"({a.string} AND {b.string})")

macro opToStr(op: untyped): string = newLit op[0].strVal

dumpAstGen:
  QueryPart[string]("Hello")

template defineInfixOp(op, sideTypes, returnType: untyped) =
  ## Creates an infix operator which has **sideTypes** on both sides of the operation and returns **returnType**
  proc op*(a, b: QueryPart[sideTypes]): QueryPart[returnType] =
    result = QueryPart[returnType](a.string & " " & opToStr(op) & " " & b.string)

defineInfixOp(`<`, int, bool)
defineInfixOp(`>`, int, bool)
defineInfixOp(`>=`, int, bool)
defineInfixOp(`<=`, int, bool)
defineInfixOp(`==`, int, bool)
defineInfixOp(`==`, bool, bool)
defineInfixOp(`==`, string, bool)

defineInfixOp(`and`, bool, bool)
defineInfixOp(`or`, bool, bool)

macro `?`*(param: untyped): QueryPart =
  ## Adds a parameter into the query
  const usageMsg = "parameters must be specified with ?[size, typ] or ?typ"
  var
    typ: NimNode
    size = ""
  case param.kind
  of nnkIdent:
    typ = param
  of nnkBracket:
    if param.len != 2:
      usageMsg.error(param)
    else:
      if param[0].kind != nnkIntLit:
        "Size must be an integer literal".error(param[0])
      elif param[1].kind != nnkIdent:
        "Second parameter must be a type".error(param[1])
      size = $param[0]
      typ = param[1]
  else:
    usageMsg.error(param)

  result = nnkObjConstr.newTree(
      nnkBracketExpr.newTree(bindSym"QueryPart", typ,
      newLit "?" & size
    )
  )

using db: DbConn
using args: varargs[DbValue, dbValue]


func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

func tableName[T](x: typedesc[Option[T]]): string =
  result = $T

func sqlExists*[T](q: static[TableQuery[T]]): string =
  ## Implements `EXISTS()` for the query builder
  const table = T.tableName
  result = fmt"EXISTS(SELECT 1 FROM {table} WHERE {q.string} LIMIT 1)"

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


proc checkSymbols(node: NimNode, currentTable: NimNode, scope: seq[NimNode]): NimNode =
  ## Converts atoms like literals (e.g. integer, string, bool literals) and symbols (e.g. properties in an object, columns in current scope)
  ## into [QueryPart] variables. This then allows us to leave the rest of the query parsing to the Nim compiler which means I don't need to
  ## reinvent the wheel with type checking.
  ##
  case node.kind
  of nnkIdent, nnkSym:
    if not node.eqIdent("true") and not node.eqIdent("false"):
      let typ = currentTable.getType(node)
      if typ.isNone:
        fmt"{node} doesn't exist in {currentTable}".error(node)
      return initQueryPartNode(typ.unsafeGet, fmt"{currentTable.strVal}.{node.strVal}")
    else:
      # We technically could use TRUE and FALSE
      return initQueryPartNode(bool, $int(node.boolVal))
  of nnkStrLit:
    return initQueryPartNode(string, fmt"'{node.strVal}'")
  of nnkIntLit:
    return initQueryPartNode(int, $node.intVal)
  of nnkDotExpr:
    when false:
      # Check the table they are accessing is allowed
      var found = false
      for table in scope:
        if table.eqIdent(node[0]):
          found = true
      if not found:
        fmt"{x[0]} is not currently accessible".error(x[0])
    # If found then add expression to access expression.
    # We don't need to check if property exists since that will be checked next
    let table = node[0]
    return checkSymbols(node[1], table, scope)
  of nnkInfix, nnkCall:
    result = node
    for i in 1..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope)
  else:
    result = node
    for i in 0..<node.len:
      result[i] = result[i].checkSymbols(currentTable, scope)

proc whereImpl*[T](table: typedesc[T], query: QueryPart[bool]): TableQuery[T] =
  result = TableQuery[T](query.string)

macro where*[T](table: typedesc[T], query: untyped): TableQuery[T] =
  let tableObject = if table.kind == nnkBracketExpr: table[1] else: table
  result = newCall(bindSym"whereImpl", table, checkSymbols(query, tableObject, @[tableObject]))
  echo result.treeRepr



proc find*[T](db; q: static[TableQuery[T]], args): T =
  const
    table = T.tableName
    query = sql fmt"SELECT * FROM {table} WHERE {q.string}"
  db.find(T, query, args)

proc exists*[T](db; q: static[TableQuery[T]], args): bool =
  const
    table = T.tableName
    query = sql fmt"SELECT EXISTS (SELECT 1 FROM {table} WHERE {q.string} LIMIT 1)"
  db.getValue[:int64](query).unsafeGet() == 1

