template primary*() {.pragma.}
  ## Make the column be a primary key
template autoIncrement*() {.pragma.}
  ## Make the column auto increment
template references*(column: untyped) {.pragma.}
  ## Specify the column that the field references
template cascade*() {.pragma.}
  ## Turns on cascade deletion for a foreign key reference
