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

proc generateExpr(x, currentTable: NimNode, scope: seq[NimNode]): string

macro whereImpl*[T](table: typedesc[T], query: untyped, tables: varargs[typedesc]): TableQuery[T] =
  let tableObject = if table.kind == nnkBracketExpr: table[1] else: table
  let scope = collect:
    for table in tables:
      table
  let whereClause =  query.generateExpr(tableObject, scope & @[tableObject])
  result = nnkCall.newTree(nnkBracketExpr.newTree(bindSym"TableQuery", table), newCall(bindSym"fmt", newLit whereClause))

macro where*[T](table: typedesc[T], query: untyped): TableQuery[T] =
  result = newCall(bindSym"whereImpl", table, query)

proc generateExpr(x, currentTable: NimNode, scope: seq[NimNode]): string =
  ## Implements the main bulk of converting Nim code to SQL
  ##
  ## **currentTable** is used for checking if the column the user is trying to access is available
  ## **scope** is list of tables that are available. Used to check that the user isn't accessing a table that isn't available atm
  template generateExpr(x: NimNode): string = generateExpr(x, currentTable, scope)
  case x.kind
  of nnkInfix:
    let
      op = x[0]
      lhs = x[1]
      rhs = x[2]
    case op.strVal
    of "==":
      result = fmt"({generateExpr(lhs)} = {generateExpr(rhs)})"
    of "and", "or", ">", "<", ">=", "<=", "!=":
      result = fmt"({generateExpr(lhs)} {op.strVal} {generateExpr(rhs)})"
    of "in":
      result = fmt"{generateExpr(lhs)} IN {generateExpr(rhs)}"
    else:
      fmt"{op} is not supported".error(op)
  of nnkIdent, nnkSym:
    if x.strVal notin ["true", "false"]:
      if not currentTable.hasProperty(x):
        fmt"{x} doesn't exist in {currentTable}".error(x)
      result = x.strVal
    else:
      # We technically could use TRUE and FALSE 
      result = $int(x.boolVal)
  of nnkPrefix:
    if x[0].strVal == "?":
      # TODO: Check value is number
      result = fmt"?{x[1].intVal}"
    else:
      "Invalid prefix used".error(x[0])
  of nnkStrLit:
    result = fmt"'{x.strVal}'"
  of nnkIntLit:
    result = $x.intVal
  of nnkCall:
    # Add the current scope to any where calls
    for i in 1..<x.len:
      let param = x[i]
      template whereNode(): var NimNode = (if param[0].kind == nnkDotExpr: param[0][1] else: param[0])

      if whereNode.eqIdent("where"):
        # Rebind the call to use the version of where that can take custom scope
        if param[0].kind == nnkDotExpr:
           param[0][1] = bindSym "whereImpl"
        else:
          param[0] = bindSym "whereImpl"
        for table in scope:
          param &= table
        x[i] = param
    result = fmt"{{sql{x[0].strVal}({repr(x[1])})}}"
  of nnkDotExpr:
    # Check the table they are accessing is allowed
    var found = false
    for table in scope:
      if table.eqIdent(x[0]):
        found = true
    if not found:
      fmt"{x[0]} is not currently accessible".error(x[0])
    # If found then add expression to access expression.
    # We don't need to check if property exists since that will be checked next
    result = fmt"{x[0]}.{generateExpr(x[1], x[0], scope & @[x[0]])}"
  of nnkBracket:
    result = "("
    for i in 0..<x.len:
      result &= generateExpr(x[i])
      if i < x.len - 1:
        result &= ", "
    result &= ")"
  else:
    echo x.kind
    "Invalid SQL query".error(x)

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

