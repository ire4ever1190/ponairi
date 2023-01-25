# Pónairí 🫘

Simple ORM to handle basic CRUD tasks. Future plans are to expand the query generation to make needing to write SQL less common

[Docs here](https://tempdocs.netlify.app/ponairi/stable/ponairi.html)

### Create

To start you want to create your objects that will define your schema

```nim
type
  Customer = object
    id {.primary, autoIncrement.}: int64
    email: string
    firstName, lastName: string

  Order = object
    id {.primary, autoIncrement.}: int64
    name: string
    customer {.references: Customer.id.}: int64

# Open connection to database, make sure to close connection when finished
let db = newConn(":memory:")
# Create the tables
db.create(Customer)
db.create(Order)
```

Now you can start inserting data

```nim
var john = Customer(
  email: "foo@example.com",
  firstName: "John",
  lastName: "Doe"
)
john.id = db.insertID(john)

var tableOrder = Order(
  name: "Table",
  customer: john.id
)
tableOrder.id = db.insertID(tableOrder)
```

### Read

Reading is done via the `find()` proc

```nim
# Look through every order
for order in db.find(seq[Order]):
  echo order

# Find first one that matches a query.
# Tables are named same as the object
echo db.find(Order, "SELECT * FROM Order WHERE customer = ?", john.id)

# Option[T] can also be used if the query mighn't return anything
import std/options
assert db.find(Option[Order], "SELECT * FROM Order WHERE customer = 99999").isNone
```

Currently there is some support for automatically loading objects through references (This will be expanded on in future)

```nim
# We want to load the object that is referenced by tableOrder in the customer field
let customer = db.load(tableOrder, customer)
assert customer is Customer
```

### Update

Updating is currently only support via `upsert()` which either inserts an object or updates any row that it collides with

```nim
tableOrder.name = "Better table"
db.upsert(tableOrder)
assert db.find(Order, "SELECT * FROM Order WHERE id = ?", tableOrder.id).name == "Better table"
```

### Delete

Deleting is done by simply calling delete with an object

```nim
assert db.exists(tableOrder)
db.delete(tableOrder)
assert not db.exists(tableOrder)
```

