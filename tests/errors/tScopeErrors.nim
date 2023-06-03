discard """
cmd: "nim check $file"
"""
import ../data
var db: DbConn


Person.where(Dog.name == "test") #[tt.Error
             ^ Dog is not currently accessible]#
