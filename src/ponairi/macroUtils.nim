import std/[
  macrocache,
  macros,
  options
]

type
  Pragma* = object
    ## Represents a pragma attached to a field/table
    name*: string
    parameters*: seq[NimNode]

  Property* = object
    ## Represents a property of an object
    name*: string
    typ*: NimNode
    # I don't think a person will have too many pragmas so a seq should be fine for now
    pragmas*: seq[Pragma]

const identNodes* = {nnkIdent, nnkSym}

func isIdent*(x: NimNode): bool =
  ## Returns if the node is an ident type (See identNodes)
  x.kind in identNodes

when not declared(macrocache.contains):
  # Naive version for when on old versions of Nim
  proc contains*(t: CacheTable, key: string): bool =
    for k, val in pairs(t):
      if k == key: return true

func initPragma*(pragmaVal: NimNode): Pragma =
  ## Creates a pragma object from nnkPragmaExpr node
  case pragmaVal.kind
  of nnkCall, nnkExprColonExpr:
    result.name = pragmaVal[0].strVal
    for parameter in pragmaVal[1..^1]:
      result.parameters &= parameter
  else:
    result.name = pragmaVal.strVal

func getTable*(pragma: Pragma): string =
  ## Returns name of table for references pragma
  pragma.parameters[0][0].strVal

func getColumn*(pragma: Pragma): string =
  ## Returns name of column for references pragma
  pragma.parameters[0][1].strVal

# I know these operations are slow, but I want to make it work first
func contains*(items: seq[Pragma], name: string): bool =
  for item in items:
    if item.name.eqIdent(name): return true

func `[]`*(items: seq[Pragma], name: string): Pragma =
  for item in items:
    if item.name.eqIdent(name): return item

proc getNameSym*(n: NimNode): NimNode =
  ## Gets the name node for an object definition
  case n.kind
  of nnkIdent, nnkSym:
    result = n
  of nnkPostFix:
    result = n[1].getNameSym()
  of nnkTypeDef:
    result = n[0].getNameSym()
  of nnkPragmaExpr:
    result = n[0].getNameSym()
  else:
    echo n.treeRepr
    assert false, "Name is invalid"

proc getName*(n: NimNode): string =
  result = n.getNameSym.strVal

proc getProperties*(impl: NimNode): seq[Property] =
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

proc lookupImpl*(T: NimNode): NimNode =
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

func isOptional*(prop: Property | NimNode): bool =
  ## Returns true if the property has an optional type
  when prop is Property:
    let node = prop.typ
  else:
    let node = prop
  result = node.kind == nnkBracketExpr and node[0].eqIdent("Option")

func isPrimary*(prop: Property): bool =
  ## Returns true if the property is a primary key
  result = "primary" in prop.pragmas

const properties = CacheTable"ponairi.properties"
  ## List of properties for an object.
  ## Is stored as a list of IdentDefs

proc registerTable*(obj: NimNode) =
  ## Adds a tables properties to the properties cache table
  var props = newStmtList()
  # Find the type def
  let impl = if obj.isIdent():
      if obj.strVal in properties: return
      obj.lookupImpl()
    else:
      obj

  # Convert the properties to identDefs and save in the table.
  # This is still better than accessing the object raw since it means properties like
  # a, b, c: int
  # are normalised into a: int, b: int, c: int which means less checking later
  for properties in impl.getProperties():
    props &= newIdentDefs(ident properties.name, properties.typ)
  properties[if obj.isIdent: obj.strVal else: obj.getName()] = props

using obj: NimNode | string

proc getProperties*(key: string): seq[NimNode] =
  for prop in properties[key]:
    result &= prop

proc getType*(obj; property: string | NimNode): Option[NimNode] =
  ## Returns the type for a property if it exists
  when obj is NimNode:
    let key = obj.strVal
  else:
    let key = obj
  bind items
  if key in properties:
    for prop in properties[key].items:
      if prop[0].eqIdent(property):
        return some prop[1]
  else:
    when obj is NimNode:
      # TODO: Add parameter to stop infinite recursion
      registerTable(obj)
      result = obj.getType(property)
    else:
      error("Make sure you have used create to register the table with ponairi")

proc hasProperty*(obj; property: string | NimNode): bool =
  ## Returns true if **obj** has **property**
  result = obj.getType(property).isSome

func eqIdent*(name: NimNode | string, idents: openArray[string]): bool =
  ## Returns true if `name` equals any of the idents.
  for ident in idents:
    if name.eqIdent(ident):
      return true

func withArgs*(call, args: NimNode | openArray[NimNode]): NimNode =
  ## Adds all arguments in `args` to be appended to call
  result = call
  for arg in args:
    call &= arg

func newBlockExpr*(body: varargs[NimNode]): NimNode =
  ## Creates a new block expression using the nodes in `body` as the statement list
  # Is called newBlockExpr instead of newBlockStmt so that it isn't confused with
  # the overload that takes label + body
  var bodyItems = newStmtList()
  for item in body:
    bodyItems &= item
  result = newBlockStmt(bodyItems)

proc error*(msg: string, line: LineInfo) =
  ## Sets an error to be on a specific line
  let tmp = newEmptyNode()
  when declared(macros.setLineInfo):
    tmp.setLineInfo(line)
  msg.error(tmp)

func newLit*[T](x: openArray[T]): NimNode =
  var items = nnkBracket.newTree()
  for item in x:
    items &= newLit item
  result = items.prefix("@") # TODO: Maybe just return an array?

func makeError*(msg: string, line: LineInfo): NimNode =
  ## Makes an error pragma with line info correctly set.
  result = nnkPragma.newTree(
    nnkExprColonExpr.newTree(
      ident"error",
      newLit msg
    )
  )
  result.setLineInfo(line)

const testSeq = CacheSeq"test"

when not compiles(testSeq[^1]):
  # Stolen from my Nim PR =P
  proc `[]`*(s: CacheSeq; i: BackwardsIndex): NimNode =
    s[s.len - int(i)]
