import ../data

var db: DbConn

discard Person.where(unknown == "test") #[Error
                     ^ unknown doesn't exist in Person]#

discard db.find(everybody.orderBy([asc test])) #[Error
                                       ^ test doesn't exist in Person]#

Person.where(
  exists(Dog.where(owner == Person.owner)) #[Error
                                   ^ owner doesn't exist in Person]#
)
