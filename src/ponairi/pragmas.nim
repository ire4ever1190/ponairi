##[
Pragmas are used to control extra info about fields such as references or how to handle deletions
]##

template primary*() {.pragma.}
  ## Make the column be a primary key.
  ## There can be multiple primary keys per table

template autoIncrement*() {.pragma.}
  ## Make the column auto increment.
  ## By default an integer primary key will choose the next available ID
  ## but by setting autoIncrement you make sure that old ID's aren't reused (i.e. ID's of deleted rows are never reused )

template references*(column: untyped) {.pragma.}
  ##[
    Specify the column that the field references.
    Type must match the type in the parent table
    ```nim
    type
      Parent = object
        id {.primary.}: int64
      Child = object
        id {.primary.}: int64
        # reference is done via Type.field syntax.
        # Notice how they are the same type
        parent {.references: Parent.id.}: int64
    ```
  ]##

template cascade*() {.pragma.}
  ## Turns on cascade deletion for a foreign key reference
