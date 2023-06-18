import ../data
var db: DbConn


Person.where(Dog.name == "test") #[Error
             ^ Dog is not currently accessible]#
