import ndb/sqlite
import std/[
  macros,
  strformat,
  options,
  typetraits
]

type TableQuery[T] = distinct string


using db: DbConn
using args: varargs[DbValue, dbValue]

proc generateExpr(x: NimNode): string =
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
    else:
      fmt"{op} is not supported".error(op)
  of nnkIdent, nnkSym:
    result = x.strVal
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
  else:
    echo x.kind
    "Invalid SQL query".error(x)

func tableName[T](x: typedesc[T]): string =
  result = $T

func tableName[T](x: typedesc[seq[T]]): string =
  result = $T

macro where*[T](table: typedesc[T], query: untyped, variables: varargs[typed]): TableQuery[T] =
  let whereClause =  query.generateExpr()
  result = nnkCall.newTree(nnkBracketExpr.newTree(bindSym"TableQuery", table), newLit whereClause)

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
