import ../data

var db: DbConn

let num = 9
db.find(Person.where(name == {num})) #[Error
                          ^ type mismatch]#
