import std/[
  macrocache,
  macros
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

proc getName*(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym:
    result = n.strVal
  of nnkPostFix:
    result = n[1].getName()
  of nnkTypeDef:
    result = n[0].getName()
  else:
    echo n.treeRepr
    assert false, "Name is invalid"

proc getProperties*(impl: NimNode): seq[Property] =
  for identDef in impl[2][2]:
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


func isOptional*(prop: Property): bool =
  ## Returns true if the property has an optional type
  result = prop.typ.kind == nnkBracketExpr and prop.typ[0].eqIdent("Option")

func isPrimary*(prop: Property): bool =
  ## Returns true if the property is a primary key
  result = "primary" in prop.pragmas

const properties = CacheTable"ponairi.properties"

proc hasProperty*(obj: NimNode, property: string | NimNode): bool =
  let key = obj.strVal
  if key in properties:
    # Do simple linear scan for property
    for prop in properties[key]:
      if prop.eqIdent(property): # TODO: Maybe normalise first to make comparison quicker?
        return true
  else:
    var props = newStmtList()
    for properties in obj.lookupImpl().getProperties():
      props &= ident properties.name
    properties[key] = props
    # TODO: Run check while adding? Don't think that would cause too much slowdown tho
    result = obj.hasProperty(property)
