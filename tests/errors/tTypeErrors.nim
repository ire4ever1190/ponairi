discard """
cmd: "nim check $file"
"""

import ../data

var db: DbConn



Person.where(name == 9) #[tt.Error
                  ^ type mismatch]#

let num = 9
db.find(Person.where(name == {num})) #[tt.Error
                          ^ type mismatch]#

