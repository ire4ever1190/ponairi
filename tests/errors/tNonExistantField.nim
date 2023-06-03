discard """
cmd: "nim check $file"
"""

import ../data

var db: DbConn

discard Person.where(unknown == "test") #[tt.Error
                     ^ unknown doesn't exist in Person]#

discard db.find(everybody.orderBy([asc test])) #[tt.Error
                                       ^ test doesn't exist in Person]#

Person.where(
  exists(Dog.where(owner == Person.owner)) #[tt.Error
                                   ^ owner doesn't exist in Person]#
)
