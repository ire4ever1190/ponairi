import ../data

var db: DbConn


discard db.find(Person.where(1 + 1)) #[Error
                               ^ Query must return 'bool']#

Person.where(name == 9) #[Error
                  ^ type mismatch]#




